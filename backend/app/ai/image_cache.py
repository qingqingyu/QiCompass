"""每日运势插画 SQLite 状态缓存(S2,2026-08-30「一幅图」)。

与 interpretation_cache 同模式但**不共用表**:插画身份维度不同
(content_hash × target_date × prompt_version 三列即唯一),且带
generating/ready/failed 状态机(异步生成的进度载体)。

图二进制不进 SQLite:1.5-2MB/张进库使 DB 膨胀、WAL 写放大;存文件
`{images_dir}/{content_hash}_{target_date}.png`,删行即删文件。

错误显式传播(严格遵守 CLAUDE.md,同 InterpretationCache 口径):
- sqlite3 / 文件 I/O 异常不吞,向上抛(sqlite 故障 → 路由层 500)
- FileNotFoundError(行在文件不在)→ 路由层删行自愈 + 404 重生成
- 不用默认值掩盖失败
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..errors import InvalidInputError

CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS daily_image_cache (
    content_hash   TEXT NOT NULL,
    target_date    TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    prompt_hash    TEXT NOT NULL DEFAULT '',
    status         TEXT NOT NULL,
    image_path     TEXT NOT NULL DEFAULT '',
    error_message  TEXT NOT NULL DEFAULT '',
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL,
    PRIMARY KEY (content_hash, target_date, prompt_version)
);
"""

# 状态机:generating → ready | failed;failed/stale 可重派(generating 回写)
STATUS_GENERATING = "generating"
STATUS_READY = "ready"
STATUS_FAILED = "failed"

_EXPECTED_COLUMNS = frozenset({
    "content_hash", "target_date", "prompt_version", "prompt_hash",
    "status", "image_path", "error_message", "created_at", "updated_at",
})


def _utcnow() -> str:
    return datetime.now(timezone.utc).isoformat()


class DailyImageCache:
    """插画状态缓存 + 图文件存取(同步 I/O,路由层 run_in_threadpool 包)。"""

    def __init__(self, db_path: str, images_dir: str | Path | None = None):
        """Args:
            db_path: SQLite 文件路径(config.DB_PATH)。
            images_dir: 图目录;None 用 db_path 同级 images/(data/images)。
        """
        self._db_path = db_path
        if images_dir is None:
            images_dir = Path(db_path).parent / "images"
        self._images_dir = Path(images_dir)

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=5.0)

    # ---------- schema ----------

    def init_schema(self) -> None:
        """建表(幂等)+ WAL + 确保 images 目录存在。lifespan 启动时调用。"""
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            _drop_legacy_table_if_needed(conn)
            conn.execute(CREATE_TABLE_SQL)
            conn.commit()
        self._images_dir.mkdir(parents=True, exist_ok=True)

    # ---------- 行级操作 ----------

    def get(
        self, content_hash: str, target_date: str, prompt_version: int,
    ) -> dict[str, Any] | None:
        """查状态行。

        Returns:
            命中 → dict(prompt_hash, status, image_path, error_message,
            created_at, updated_at);未命中 → None
        """
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT prompt_hash, status, image_path, error_message, "
                "created_at, updated_at FROM daily_image_cache "
                "WHERE content_hash=? AND target_date=? AND prompt_version=?",
                (content_hash, target_date, prompt_version),
            ).fetchone()
        if row is None:
            return None
        return dict(row)

    def upsert(
        self,
        content_hash: str,
        target_date: str,
        prompt_version: int,
        status: str,
        *,
        prompt_hash: str = "",
        image_path: str = "",
        error_message: str = "",
    ) -> None:
        """写状态行(INSERT OR REPLACE,幂等;REPLACE 重置 created_at 可接受——
        重派意味着重新生成,时间线重开)。"""
        now = _utcnow()
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO daily_image_cache "
                "(content_hash, target_date, prompt_version, prompt_hash, "
                " status, image_path, error_message, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (content_hash, target_date, prompt_version, prompt_hash,
                 status, image_path, error_message, now, now),
            )
            conn.commit()

    def get_latest(
        self, content_hash: str, target_date: str,
    ) -> dict[str, Any] | None:
        """取该 (content_hash, target_date) 最新 prompt_version 的行。

        GET content 端点用:客户端不感知 prompt_version,服务端取最新
        (lifetime 内最多一个版本在用,老版本行只剩历史价值)。
        返回含 prompt_version(GET 自愈删行需按 PK 定位)。
        """
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT prompt_version, prompt_hash, status, image_path, "
                "error_message, created_at, updated_at "
                "FROM daily_image_cache "
                "WHERE content_hash=? AND target_date=? "
                "ORDER BY prompt_version DESC LIMIT 1",
                (content_hash, target_date),
            ).fetchone()
        if row is None:
            return None
        return dict(row)

    def delete(
        self, content_hash: str, target_date: str, prompt_version: int,
    ) -> None:
        """删状态行(GET 自愈用:ready 行但图文件丢失时删行触发重生成)。"""
        with self._connect() as conn:
            conn.execute(
                "DELETE FROM daily_image_cache WHERE content_hash=? "
                "AND target_date=? AND prompt_version=?",
                (content_hash, target_date, prompt_version),
            )
            conn.commit()

    def count_generated_today(self, target_date: str) -> int:
        """当日已发起/已完成的生图行数(generating + ready)。

        成本护栏的计数口径:DAILY_IMAGE_LIMIT 限制「单日全局发起量」。
        failed 不计(失败不应吃掉用户的配额)。
        """
        with self._connect() as conn:
            row = conn.execute(
                "SELECT COUNT(*) FROM daily_image_cache "
                "WHERE target_date=? AND status IN (?, ?)",
                (target_date, STATUS_GENERATING, STATUS_READY),
            ).fetchone()
        return int(row[0])

    # ---------- 图文件 ----------

    def save_image(
        self, content_hash: str, target_date: str, data: bytes,
    ) -> str:
        """图 bytes 落盘,返回文件名(存表用;load 时按 images_dir 拼回)。

        存表只存文件名不存完整路径:路径含 cwd/部署位置信息,换目录重启
        后旧路径失效。汇点守卫拒路径穿越(content_hash 是无格式约束的
        客户端串,不守卫可越出 images 目录写文件)。

        Raises:
            InvalidInputError: 文件名逃逸 images 目录(疑似路径穿越)。
            OSError: 写盘失败(不吞,向上抛)。
        """
        self._images_dir.mkdir(parents=True, exist_ok=True)
        rel = f"{content_hash}_{target_date}.png"
        if Path(rel).name != rel:
            raise InvalidInputError(
                f"非法图文件名(疑似路径穿越): {content_hash!r}",
            )
        path = self._images_dir / rel
        path.write_bytes(data)
        return rel

    def load_image(self, image_path: str) -> bytes:
        """读图文件。存表值为文件名;取 name 拼回兼容旧版存的相对/绝对路径。

        Raises:
            FileNotFoundError: 行在文件不在(外部清理/磁盘故障)——显式抛,
            路由层自愈删行 + 404(见 daily_image.py),不降级成 202 空转。
        """
        return (self._images_dir / Path(image_path).name).read_bytes()


def _drop_legacy_table_if_needed(conn: sqlite3.Connection) -> None:
    """旧表 schema 不匹配时丢弃(同 InterpretationCache 口径:可再生成)。"""
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='daily_image_cache'"
    ).fetchone()
    if row is None:
        return
    columns = {
        str(col[1])
        for col in conn.execute("PRAGMA table_info(daily_image_cache)").fetchall()
    }
    if columns != _EXPECTED_COLUMNS:
        conn.execute("DROP TABLE daily_image_cache")
