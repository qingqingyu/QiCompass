"""Entitlement 表 SQLite Store(对齐 ai/cache.py 模式)。

表结构(对齐 MONETIZATION.md §后端 SQLite):
- PK = transaction_id(Apple JWS transactionId,全局唯一)
- module 字段存**基础名**(bazi_deep / compatibility),不存 _free/_paid
  因为 entitlement 是"用户买过该命盘付费内容",与具体 prompt 版本无关
- is_active:退款 / 撤销后置 0
- refunded_at / revoked_at:记录 deactivate 原因和时间

错误显式传播(对齐 ai/cache.py:11-14):
- sqlite3 异常不吞,向上抛 → 路由层包成 BaziError(500)
- insert 用 INSERT OR IGNORE 幂等(并发 redeem 不炸)
- deactivate 用 WHERE is_active=1 幂等(重复 webhook 不重复扣)

线程池策略:同步 sqlite3,每次操作短连接,路由层 run_in_threadpool 调用。
"""

from __future__ import annotations

import sqlite3
from typing import Any, Literal

# 建表语句(幂等,lifespan 启动时执行)
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS entitlement (
    transaction_id         TEXT PRIMARY KEY,
    product_id             TEXT NOT NULL,
    content_hash           TEXT NOT NULL,
    module                 TEXT NOT NULL,
    user_local_id          TEXT NOT NULL,
    purchased_at           TEXT NOT NULL,
    original_purchase_date TEXT NOT NULL,
    is_active              INTEGER NOT NULL DEFAULT 1,
    refunded_at            TEXT,
    revoked_at             TEXT
);
"""

CREATE_INDEX_LOOKUP_SQL = """
CREATE INDEX IF NOT EXISTS idx_entitlement_lookup
ON entitlement(content_hash, module, is_active);
"""

CREATE_INDEX_USER_SQL = """
CREATE INDEX IF NOT EXISTS idx_entitlement_user
ON entitlement(user_local_id, is_active);
"""


# 列集合校验:旧表 schema 不匹配时丢弃(对齐 ai/cache.py:189-203)
# 注:entitlement 表是 M2 新建的,无 legacy;但保留校验防御未来 schema 演化
_EXPECTED_COLUMNS = frozenset({
    "transaction_id", "product_id", "content_hash", "module", "user_local_id",
    "purchased_at", "original_purchase_date", "is_active",
    "refunded_at", "revoked_at",
})


def _drop_legacy_entitlement_if_needed(conn: sqlite3.Connection) -> None:
    """旧表 schema 不匹配(缺列/多列)时丢弃。

    entitlement 表是 M2 全新表,首次启动无 legacy,但保留校验防御未来字段演化。
    与 ai/cache.py:189-203 的策略一致:不冒险 migrate,直接 DROP 重建。
    """
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='entitlement'"
    ).fetchone()
    if row is None:
        return
    columns = {
        str(col[1])
        for col in conn.execute("PRAGMA table_info(entitlement)").fetchall()
    }
    if columns != _EXPECTED_COLUMNS:
        conn.execute("DROP TABLE entitlement")


class EntitlementStore:
    """Entitlement 表 CRUD + active 查询。

    同步 I/O,每次操作开短连接。路由层应通过 run_in_threadpool 调用。
    """

    def __init__(self, db_path: str):
        """Args:
            db_path: SQLite 文件路径(与 InterpretationCache 共用 config.DB_PATH)
        """
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        """开短连接 + busy_timeout=5s(对齐 ai/cache.py:58-66)。"""
        return sqlite3.connect(self._db_path, timeout=5.0)

    def init_schema(self) -> None:
        """建表 + 索引(幂等)。lifespan 启动时调用。

        与 InterpretationCache 共用同一 SQLite 文件,但不同表(entitlement vs
        interpretation_cache)。WAL 模式由 InterpretationCache.init_schema 设置
        (持久 PRAGMA),此处不重复设。

        Raises:
            sqlite3.Error: 建表失败(不吞,向上抛)
        """
        with self._connect() as conn:
            _drop_legacy_entitlement_if_needed(conn)
            conn.execute(CREATE_TABLE_SQL)
            conn.execute(CREATE_INDEX_LOOKUP_SQL)
            conn.execute(CREATE_INDEX_USER_SQL)
            conn.commit()

    def get_by_transaction(self, transaction_id: str) -> dict[str, Any] | None:
        """按 transaction_id 查单条(用于 redeem 幂等)。

        Returns:
            dict 包含全字段 + is_active 状态;未找到 → None

        Raises:
            sqlite3.Error: 读失败(不吞)
        """
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT transaction_id, product_id, content_hash, module, "
                "       user_local_id, purchased_at, original_purchase_date, "
                "       is_active, refunded_at, revoked_at "
                "FROM entitlement WHERE transaction_id=?",
                (transaction_id,),
            ).fetchone()
        if row is None:
            return None
        return dict(row)

    def get_active(
        self, *, content_hash: str, module: str, user_local_id: str,
    ) -> dict[str, Any] | None:
        """查命盘维度的有效 entitlement(用于 /api/interpret 拦截)。

        一个 (content_hash, module, user_local_id) 可能有多笔(用户改生辰重购),
        任意一笔 active 即视为有权。取最近一笔(purchased_at DESC LIMIT 1)。

        Args:
            content_hash: 命盘 hash
            module: 基础名(bazi_deep / compatibility,**不含** _free/_paid 后缀)
            user_local_id: 客户端生成的 UUID

        Returns:
            命中 active → dict;未命中 → None

        Raises:
            sqlite3.Error: 读失败(不吞)
        """
        with self._connect() as conn:
            conn.row_factory = sqlite3.Row
            row = conn.execute(
                "SELECT transaction_id, product_id, content_hash, module, "
                "       user_local_id, purchased_at, original_purchase_date, "
                "       is_active, refunded_at, revoked_at "
                "FROM entitlement "
                "WHERE content_hash=? AND module=? AND user_local_id=? "
                "  AND is_active=1 "
                "ORDER BY purchased_at DESC LIMIT 1",
                (content_hash, module, user_local_id),
            ).fetchone()
        if row is None:
            return None
        return dict(row)

    def insert(
        self, *, transaction_id: str, product_id: str, content_hash: str,
        module: str, user_local_id: str, purchased_at: str,
        original_purchase_date: str,
    ) -> bool:
        """写入 entitlement(INSERT OR IGNORE,同 PK 幂等)。

        Args:
            transaction_id: Apple JWS transactionId(全局唯一 PK)
            product_id: com.qicompass.deep_analysis.single / .compatibility.single
            content_hash: 命盘 hash
            module: 基础名(bazi_deep / compatibility)
            user_local_id: 客户端 UUID
            purchased_at: ISO 8601 UTC(后端写入时间)
            original_purchase_date: ISO 8601 UTC(Apple 返回的原始购买时间)

        Returns:
            True = 新插入;False = PK 已存在(幂等,未修改)

        Raises:
            sqlite3.Error: 写失败(不吞)
        """
        with self._connect() as conn:
            cursor = conn.execute(
                "INSERT OR IGNORE INTO entitlement "
                "(transaction_id, product_id, content_hash, module, user_local_id, "
                " purchased_at, original_purchase_date, is_active) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, 1)",
                (transaction_id, product_id, content_hash, module, user_local_id,
                 purchased_at, original_purchase_date),
            )
            conn.commit()
            return cursor.rowcount > 0

    def deactivate(
        self, *, transaction_id: str,
        reason: Literal["refund", "revoke"], at_iso: str,
    ) -> bool:
        """标记 entitlement 为 inactive(退款 / 撤销)。

        Args:
            transaction_id: 要 deactivate 的交易 ID
            reason: "refund"(Apple REFUND)或 "revoke"(Apple REVOKE)
            at_iso: ISO 8601 UTC 时间字符串

        Returns:
            True = 实际更新了行;False = 该 tx 不存在或已是 inactive(幂等)

        Raises:
            sqlite3.Error: 写失败(不吞)
            ValueError: reason 不在 {"refund", "revoke"}
        """
        if reason not in ("refund", "revoke"):
            raise ValueError(
                f"reason 必须是 'refund' 或 'revoke',收到 {reason!r}")
        column = "refunded_at" if reason == "refund" else "revoked_at"
        with self._connect() as conn:
            cursor = conn.execute(
                f"UPDATE entitlement SET is_active=0, {column}=? "
                "WHERE transaction_id=? AND is_active=1",
                (at_iso, transaction_id),
            )
            conn.commit()
            return cursor.rowcount > 0
