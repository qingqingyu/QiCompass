"""章末「准 / 不准」反馈落表(2026-11-15 拍板:B6 极简 × B9 三拍退场)。

- 表:chapter_feedback(与 interpretation_cache 共用同一 SQLite 文件,
  不同表;CREATE TABLE IF NOT EXISTS 幂等,lifespan 启动时执行)
- prompt_version / provider / model / source_language:从 interpretation_cache
  同 (content_hash, module) 最新行 best-effort 反查(优先同 app_language 行)。
  用户读的是本地缓存,后端行可能已被清 → 反查 miss 落 NULL,不拒绝反馈
  (分析时按非空行切版本/模型;miss 行仍有总评价值)
- 幂等:同 (content_hash, module, client_ip, 日) 写前查重,重复直接返回
  DUPLICATE(客户端三拍动线只报一次,此闸兜双击/重放/重装重报)
- 防刷:同 IP 当日写入上限(config.FEEDBACK_DAILY_LIMIT,默认 100)——
  反馈端点免鉴权(尽量低门槛,匿名也可评),IP 是唯一可用的粗闸

错误显式传播(严格遵守 CLAUDE.md):
- sqlite3 异常不吞,向上抛 → 路由层包 500;反馈是旁路功能,不影响阅读
  主链路,但落库失败必须可见(日志 + 500),不是静默丢弃
- 线程池策略与 ai/cache.py 同款:每次操作开短连接,同步实现由路由层
  run_in_threadpool 包裹
"""

from __future__ import annotations

import enum
import sqlite3
from datetime import datetime, timezone
from typing import Any

# 建表语句(幂等,lifespan 启动时执行)
# prompt_version/provider/model 可空 = 反查 miss(best-effort 语义,非降级)
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS chapter_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    content_hash    TEXT NOT NULL,
    module          TEXT NOT NULL,
    verdict         TEXT NOT NULL CHECK (verdict IN ('accurate', 'inaccurate')),
    section         TEXT NOT NULL DEFAULT '',
    app_language    TEXT NOT NULL DEFAULT 'zh',
    prompt_version  INTEGER,
    provider        TEXT,
    model           TEXT,
    client_ip       TEXT NOT NULL DEFAULT '',
    created_at      TEXT NOT NULL
)
"""

# 幂等唯一索引(review 三查:SELECT dup 与 INSERT 之间存在并发竞态窗口,
# 两个同键请求可同时过 dup 检查 → 双行;表达式索引把日切片钉进唯一约束,
# INSERT 冲突由 record 捕获 IntegrityError 归并为 DUPLICATE,窗口彻底关闭)
CREATE_DEDUP_INDEX_SQL = """
CREATE UNIQUE INDEX IF NOT EXISTS idx_chapter_feedback_dedup
ON chapter_feedback (content_hash, module, client_ip, substr(created_at, 1, 10))
"""

# 幂等/日限查询都按 UTC 日切片(与 quota store 的日桶口径一致)
_LOOKUP_COLUMNS = "prompt_version, provider, model"


class FeedbackOutcome(str, enum.Enum):
    """record() 的三种结果(端点按值记日志;三者对客户端回应相同)。"""

    RECORDED = "recorded"
    DUPLICATE = "duplicate"
    RATE_LIMITED = "rate_limited"


class ChapterFeedbackStore:
    def __init__(self, db_path: str, *, daily_ip_limit: int = 100):
        self._db_path = db_path
        self._daily_ip_limit = daily_ip_limit

    def init_schema(self) -> None:
        """建表 + 唯一索引(幂等)。失败向上抛 → lifespan 启动报错(不吞)。"""
        with sqlite3.connect(self._db_path) as conn:
            conn.execute(CREATE_TABLE_SQL)
            conn.execute(CREATE_DEDUP_INDEX_SQL)

    def record(
        self,
        *,
        content_hash: str,
        module: str,
        verdict: str,
        section: str | None,
        app_language: str,
        client_ip: str,
    ) -> FeedbackOutcome:
        """落一条反馈;幂等与日限见模块 docstring。

        Raises:
            sqlite3.Error: 落库失败(显式上抛,不静默)
        """
        now = datetime.now(timezone.utc)
        today = now.strftime("%Y-%m-%d")

        with sqlite3.connect(self._db_path) as conn:
            # 幂等闸:同 (hash, module, ip, 日) 已有 → 不再落
            dup = conn.execute(
                "SELECT 1 FROM chapter_feedback "
                "WHERE content_hash=? AND module=? AND client_ip=? "
                "AND substr(created_at, 1, 10)=? LIMIT 1",
                (content_hash, module, client_ip, today),
            ).fetchone()
            if dup is not None:
                return FeedbackOutcome.DUPLICATE

            # 防刷闸:同 IP 当日条数
            ip_count = conn.execute(
                "SELECT COUNT(*) FROM chapter_feedback "
                "WHERE client_ip=? AND substr(created_at, 1, 10)=?",
                (client_ip, today),
            ).fetchone()[0]
            if ip_count >= self._daily_ip_limit:
                return FeedbackOutcome.RATE_LIMITED

            meta = self._latest_cache_meta(
                conn, content_hash=content_hash, module=module,
                language=app_language)

            try:
                conn.execute(
                    "INSERT INTO chapter_feedback "
                    "(content_hash, module, verdict, section, app_language, "
                    " prompt_version, provider, model, client_ip, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        content_hash, module, verdict, section or "",
                        app_language,
                        meta.get("prompt_version"),
                        meta.get("provider"),
                        meta.get("model"),
                        client_ip,
                        now.isoformat(),
                    ),
                )
            except sqlite3.IntegrityError as e:
                # 唯一索引冲突 = 并发窗口里另一连接刚落了同键行(三查 #2)
                # ——归并为 DUPLICATE;其余 IntegrityError(CHECK 违约等)不吞
                if "idx_chapter_feedback_dedup" not in str(e):
                    raise
                return FeedbackOutcome.DUPLICATE
        return FeedbackOutcome.RECORDED

    @staticmethod
    def _latest_cache_meta(
        conn: sqlite3.Connection,
        *,
        content_hash: str,
        module: str,
        language: str,
    ) -> dict[str, Any]:
        """反查 interpretation_cache 最新行取版本/模型(best-effort)。

        优先同 language 行(用户读的就是该语言版本);miss 再取任意语言
        最新行;全 miss → 空 dict(落 NULL)。查询失败**不吞**:反查是
        同库同线程的普通 SELECT,失败 = 库故障,与主写入同生死。
        """
        for lang_filter in (language, None):
            sql = (
                f"SELECT {_LOOKUP_COLUMNS} FROM interpretation_cache "
                "WHERE content_hash=? AND module=?"
            )
            params: list[Any] = [content_hash, module]
            if lang_filter is not None:
                sql += " AND language=?"
                params.append(lang_filter)
            sql += " ORDER BY generated_at DESC LIMIT 1"
            row = conn.execute(sql, params).fetchone()
            if row is not None:
                return {
                    "prompt_version": row[0],
                    "provider": row[1],
                    "model": row[2],
                }
        return {}
