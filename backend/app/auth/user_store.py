"""User 表 SQLite Store(PR2.5)。

表结构:
- PK = id(服务端生成的 UUID)
- apple_user_id UNIQUE(Apple sub,跨设备相同,登录去重键)
- email:首次登录 Apple 返回,后续不返
- created_at:首次插入时间
- last_login_at:每次登录更新

错误显式传播(对齐 entitlement/store.py):sqlite3 异常不吞,向上抛。
线程池策略:同步 sqlite3,每次操作短连接,路由层 run_in_threadpool 调用。
"""

from __future__ import annotations

import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

# 建表语句(幂等,lifespan 启动时执行)
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS qicompass_user (
    id              TEXT PRIMARY KEY,
    apple_user_id   TEXT NOT NULL UNIQUE,
    email           TEXT,
    created_at      TEXT NOT NULL,
    last_login_at   TEXT NOT NULL
);
"""

CREATE_INDEX_APPLE_USER_SQL = """
CREATE INDEX IF NOT EXISTS idx_user_apple_user_id
ON qicompass_user(apple_user_id);
"""


@dataclass(frozen=True)
class User:
    """User 行(只读)。"""

    id: str
    apple_user_id: str
    email: str | None
    created_at: str  # ISO 8601 UTC
    last_login_at: str


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class UserStore:
    """User 表 CRUD(对齐 entitlement/store.py 同步 sqlite3 模式)。"""

    def __init__(self, db_path: str):
        self._db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self._db_path, timeout=5.0)
        conn.row_factory = sqlite3.Row
        # WAL 减少读写锁冲突(与 InterpretationCache / EntitlementStore 一致)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=5000")
        return conn

    def init_schema(self) -> None:
        """lifespan 启动时调用,幂等建表。"""
        with self._connect() as conn:
            conn.execute(CREATE_TABLE_SQL)
            conn.execute(CREATE_INDEX_APPLE_USER_SQL)

    def upsert_by_apple_user_id(
        self, apple_user_id: str, email: str | None = None,
    ) -> User:
        """按 apple_user_id upsert。

        - 不存在 → 插入新行(id 服务端生成 UUID,created_at + last_login_at = now)
        - 已存在 → 更新 last_login_at = now;email 仅当传入非 None 时更新
          (Apple 首次登录返 email,后续不返,避免清空)

        Args:
            apple_user_id:Apple sub(稳定标识)
            email:Apple 返回的 email(None 时不动现有值)

        Returns:
            User(已存在的更新后或新插入)
        """
        now = _now_iso()
        with self._connect() as conn:
            existing = conn.execute(
                "SELECT * FROM qicompass_user WHERE apple_user_id = ?",
                (apple_user_id,),
            ).fetchone()

            if existing is None:
                # 新用户
                new_id = str(uuid.uuid4())
                conn.execute(
                    """INSERT INTO qicompass_user
                       (id, apple_user_id, email, created_at, last_login_at)
                       VALUES (?, ?, ?, ?, ?)""",
                    (new_id, apple_user_id, email, now, now),
                )
                return User(
                    id=new_id,
                    apple_user_id=apple_user_id,
                    email=email,
                    created_at=now,
                    last_login_at=now,
                )
            else:
                # 老用户:更新 last_login_at + email(若提供)
                new_email = email if email is not None else existing["email"]
                conn.execute(
                    """UPDATE qicompass_user
                       SET last_login_at = ?, email = ?
                       WHERE apple_user_id = ?""",
                    (now, new_email, apple_user_id),
                )
                return User(
                    id=existing["id"],
                    apple_user_id=apple_user_id,
                    email=new_email,
                    created_at=existing["created_at"],
                    last_login_at=now,
                )

    def get_by_id(self, user_id: str) -> User | None:
        """按服务端 id 查(JWT middleware 验签后用)。"""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM qicompass_user WHERE id = ?",
                (user_id,),
            ).fetchone()
            if row is None:
                return None
            return User(
                id=row["id"],
                apple_user_id=row["apple_user_id"],
                email=row["email"],
                created_at=row["created_at"],
                last_login_at=row["last_login_at"],
            )
