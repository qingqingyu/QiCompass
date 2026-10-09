"""LLM 调用结果监控 store(2026-10-09 监控闭环 A 档)。

表:
- llm_call_outcomes:(hour, provider, module, outcome) → count 计数表。
  hour 为 UTC 小时键(如 "2026-10-09T13",ISO 形态字符串字典序 = 时间
  序,BETWEEN 直接可用)——选小时而非日粒度:日键做不了滚动 24h/1h
  窗口,/api/health/llm 的近 1h 告警窗口需要真滚动。
- llm_last_error:单行表(id=1 恒等约束),最近一次 provider 调用失败
  快照(occurred_at/module/reason/message),供 health 端点直读。

口径:
- 只计**真烧 LLM 的 provider 调用**(由 MeteredAIClient 包装层记录;
  缓存命中不进 client 天然不计;interpret.py 的 v1 契约/翻译保真等
  pipeline 失败发生在 client 成功返回**之后**,不计入 provider 可用性
  ——那是输出质量问题,日志与配额退款口径里已有踪迹)。
- outcome = "success" | AIProviderError.reason(timeout/rate_limit/auth/
  http_error/network/bad_response/truncated/content_filter/no_api_key)
  | "unexpected"(client 未包到的异常,可用性兜底)。

实现:与 FreeLLMQuotaStore 同款 SQLite 短连接 + INSERT OR IGNORE 建零行
+ 原子自增,多 worker(uvicorn --workers)共库共享计数;历史行不清理
(小时粒度一年 ≈ 8760 行/module/outcome 组合,SQLite 无压力;免费配额
表同款不清理口径)。

 Raises:
    sqlite3.Error: 读写失败向上抛(错误显式传播;调用方 MeteredAIClient
        对 record 失败按「监控不反噬主路径」口径记日志放行,对齐
        _refund_daily_quota 退款失败只记日志的先例)。
"""

from __future__ import annotations

import sqlite3

CREATE_OUTCOMES_SQL = """
CREATE TABLE IF NOT EXISTS llm_call_outcomes (
    hour     TEXT NOT NULL,
    provider TEXT NOT NULL,
    module   TEXT NOT NULL,
    outcome  TEXT NOT NULL,
    count    INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (hour, provider, module, outcome)
);
"""

CREATE_LAST_ERROR_SQL = """
CREATE TABLE IF NOT EXISTS llm_last_error (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    occurred_at TEXT NOT NULL,
    provider    TEXT NOT NULL,
    module      TEXT NOT NULL,
    reason      TEXT NOT NULL,
    message     TEXT NOT NULL
);
"""

# message 截断上限:防异常文本超长(如 httpx 带完整响应体)撑大单行
_LAST_ERROR_MESSAGE_MAX = 500


def hour_key(now_utc) -> str:
    """datetime → UTC 小时键 "YYYY-MM-DDTHH"(监控窗口的粒度单位)。"""
    return now_utc.strftime("%Y-%m-%dT%H")


class LLMOutcomeStore:
    """llm_call_outcomes 计数 + llm_last_error 快照。"""

    def __init__(self, db_path: str):
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=5.0)

    def init_schema(self) -> None:
        """建表(幂等,老库零迁移)。 Raises: sqlite3.Error(不吞)。"""
        with self._connect() as conn:
            conn.execute(CREATE_OUTCOMES_SQL)
            conn.execute(CREATE_LAST_ERROR_SQL)
            conn.commit()

    def record(self, *, hour: str, provider: str, module: str,
               outcome: str) -> None:
        """(hour, provider, module, outcome) 计数 +1(原子自增)。

        Raises:
            sqlite3.Error: 写失败(向上抛,由调用方决定记录策略)
        """
        with self._connect() as conn:
            conn.execute(
                "INSERT OR IGNORE INTO llm_call_outcomes "
                "(hour, provider, module, outcome, count) "
                "VALUES (?, ?, ?, ?, 0)",
                (hour, provider, module, outcome),
            )
            conn.execute(
                "UPDATE llm_call_outcomes SET count = count + 1 "
                "WHERE hour = ? AND provider = ? AND module = ? "
                "AND outcome = ?",
                (hour, provider, module, outcome),
            )
            conn.commit()

    def get_counts(self, *, start_hour: str, end_hour: str) -> dict:
        """闭区间 [start_hour, end_hour] 内计数,返回
        {(provider, module, outcome): count}。

        Raises:
            sqlite3.Error: 读失败(向上抛,不吞)
        """
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT provider, module, outcome, SUM(count) "
                "FROM llm_call_outcomes "
                "WHERE hour >= ? AND hour <= ? "
                "GROUP BY provider, module, outcome",
                (start_hour, end_hour),
            ).fetchall()
        return {(p, m, o): int(c) for p, m, o, c in rows}

    def record_last_error(self, *, occurred_at: str, provider: str,
                          module: str, reason: str, message: str) -> None:
        """覆盖写最近一次失败快照(单行表)。

        Raises:
            sqlite3.Error: 写失败(向上抛,由调用方决定记录策略)
        """
        truncated = message[:_LAST_ERROR_MESSAGE_MAX]
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO llm_last_error "
                "(id, occurred_at, provider, module, reason, message) "
                "VALUES (1, ?, ?, ?, ?, ?) "
                "ON CONFLICT(id) DO UPDATE SET "
                "occurred_at = excluded.occurred_at, "
                "provider = excluded.provider, "
                "module = excluded.module, "
                "reason = excluded.reason, "
                "message = excluded.message",
                (occurred_at, provider, module, reason, truncated),
            )
            conn.commit()

    def get_last_error(self):
        """读最近失败快照;无记录返回 None。

        Raises:
            sqlite3.Error: 读失败(向上抛,不吞)
        """
        with self._connect() as conn:
            row = conn.execute(
                "SELECT occurred_at, provider, module, reason, message "
                "FROM llm_last_error WHERE id = 1",
            ).fetchone()
        if row is None:
            return None
        occurred_at, provider, module, reason, message = row
        return {
            "occurred_at": occurred_at,
            "provider": provider,
            "module": module,
            "reason": reason,
            "message": message,
        }
