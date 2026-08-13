"""后端 AI 解读 SQLite 缓存(D2 第二级 + i18n 第 8 维度 language)。

- 表结构:
- PK = (content_hash, module, prompt_version, target_date, prompt_hash,
        provider, model, language)
- target_date 非 daily_fortune 时存空串(避免 NULL 进 PK 歧义)
- prompt_hash 由渲染后的 prompt sha256 得到,避免客户端用同一 content_hash
  携带不同 context 污染跨用户缓存
- provider/model 是缓存身份,切换后不会误用另一家/另一模型的结果
- language 是 i18n 身份(i18n 决策 3),同 content_hash 不同 language 独立缓存,
  避免英文用户拿到中文缓存

错误显式传播(严格遵守 CLAUDE.md):
- sqlite3 异常不吞,向上抛 → 路由层包成 InterpretationCacheError(500)
- cache get 失败 → 抛 500(不降级为 provider 调用,避免缓存层故障被静默掩盖)
- cache set 失败 → 抛 500(不返回"成功但没缓存",验收要求缓存行为可靠)

线程池策略:
- 每次操作开短连接(with sqlite3.connect(...)),同步,由路由层 run_in_threadpool 包
- 构造时不开连接(避免跨线程持有)
"""

from __future__ import annotations

import sqlite3
from typing import Any

from .cache_key import CacheKey

# 建表语句(幂等,lifespan 启动时执行)
# i18n 改造:新增 language 列 + 加入 PRIMARY KEY
# 注:_drop_legacy_cache_if_needed 会检测老表(缺 language 列)并 drop,
# 老缓存丢失但可重新生成,符合 D2 决策"缓存可再生成,不冒险复用"。
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS interpretation_cache (
    content_hash   TEXT NOT NULL,
    module         TEXT NOT NULL,
    prompt_version INTEGER NOT NULL,
    target_date    TEXT NOT NULL DEFAULT '',
    prompt_hash    TEXT NOT NULL,
    provider       TEXT NOT NULL,
    model          TEXT NOT NULL,
    language       TEXT NOT NULL DEFAULT 'zh',
    interpretation TEXT NOT NULL,
    generated_at   TEXT NOT NULL,
    PRIMARY KEY (
        content_hash, module, prompt_version, target_date, prompt_hash,
        provider, model, language
    )
);
"""


class InterpretationCache:
    """SQLite AI 解读缓存。

    同步 I/O,每次操作开短连接。路由层应通过 run_in_threadpool 调用。
    """

    def __init__(self, db_path: str):
        """Args:
            db_path: SQLite 文件路径(由 config.DB_PATH 提供)
        """
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        """开短连接 + 设 busy_timeout(5s)缓解并发写锁冲突。

        WAL 模式下读不阻塞写,但并发写仍可能 lock → 默认立即抛 OperationalError。
        busy_timeout 让写操作等待最多 5 秒,减少 500 误报(设计文档 v2 再做 singleflight)。
        注:sqlite3.connect(timeout=5.0) 已内部设置 busy_timeout=5000ms,
        无需再执行 PRAGMA busy_timeout(Python sqlite3 模块行为)。
        """
        return sqlite3.connect(self._db_path, timeout=5.0)

    def init_schema(self) -> None:
        """建表(幂等)。lifespan 启动时调用。

        同时设置 WAL 模式(持久,提升并发读写性能,避免默认 DELETE 模式锁定)。

        Raises:
            sqlite3.Error: 建表失败(不吞,向上抛)
        """
        with self._connect() as conn:
            conn.execute("PRAGMA journal_mode=WAL")
            _drop_legacy_cache_if_needed(conn)
            conn.execute(CREATE_TABLE_SQL)
            conn.commit()

    def get(self, key: CacheKey) -> dict[str, Any] | None:
        """查缓存。

        Args:
            key: 八维度缓存键(content_hash/module/prompt_version/target_date/
                prompt_hash/provider/model/language)

        Returns:
            命中 → dict(provider, model, interpretation, generated_at)
            未命中 → None

        Raises:
            sqlite3.Error: 读失败(不吞,向上抛,路由层转 500)
        """
        td = key.target_date or ""
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT provider, model, interpretation, generated_at "
                "FROM interpretation_cache "
                "WHERE content_hash=? AND module=? AND prompt_version=? "
                "AND target_date=? AND prompt_hash=? "
                "AND provider=? AND model=? AND language=?",
                (key.content_hash, key.module, key.prompt_version, td,
                 key.prompt_hash, key.provider, key.model, key.language),
            ).fetchone()
        if row is None:
            return None
        return {
            "provider": row["provider"],
            "model": row["model"],
            "interpretation": row["interpretation"],
            "generated_at": row["generated_at"],
        }

    def set(self, key: CacheKey, interpretation: str, generated_at: str) -> None:
        """写缓存(INSERT OR REPLACE,同 key 覆盖,幂等)。

        Args:
            key: 八维度缓存键
            interpretation: AI 解读文本
            generated_at: ISO 8601 UTC 时间字符串

        Raises:
            sqlite3.Error: 写失败(不吞,向上抛,路由层转 500)
        """
        td = key.target_date or ""
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO interpretation_cache "
                "(content_hash, module, prompt_version, target_date, prompt_hash, "
                " provider, model, language, interpretation, generated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (key.content_hash, key.module, key.prompt_version, td,
                 key.prompt_hash, key.provider, key.model, key.language,
                 interpretation, generated_at),
            )
            conn.commit()

    def delete(self, key: CacheKey) -> None:
        """删除缓存行(用于清理被禁词污染的坏缓存)。

        Args:
            key: 八维度缓存键

        Raises:
            sqlite3.Error: 删失败(不吞,向上抛)
        """
        td = key.target_date or ""
        with self._connect() as conn:
            conn.execute(
                "DELETE FROM interpretation_cache "
                "WHERE content_hash=? AND module=? AND prompt_version=? "
                "AND target_date=? AND prompt_hash=? "
                "AND provider=? AND model=? AND language=?",
                (key.content_hash, key.module, key.prompt_version, td,
                 key.prompt_hash, key.provider, key.model, key.language),
            )
            conn.commit()


# i18n 改造:_EXPECTED_COLUMNS 同步加 "language",
# 否则 _drop_legacy_cache_if_needed 会误判新表为 legacy 而 drop。
_EXPECTED_COLUMNS = frozenset({
    "content_hash", "module", "prompt_version", "target_date",
    "prompt_hash", "provider", "model", "language",
    "interpretation", "generated_at",
})


def _drop_legacy_cache_if_needed(conn: sqlite3.Connection) -> None:
    """旧表 schema 不匹配(缺列/多列)时丢弃;缓存可再生成,不冒险复用。"""
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name='interpretation_cache'"
    ).fetchone()
    if row is None:
        return
    columns = {
        str(col[1])
        for col in conn.execute("PRAGMA table_info(interpretation_cache)").fetchall()
    }
    if columns != _EXPECTED_COLUMNS:
        conn.execute("DROP TABLE interpretation_cache")
