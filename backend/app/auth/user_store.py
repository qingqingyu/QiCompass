"""User 表 SQLite Store(PR2.5 起,provider 化改造支持 Apple/Google 多登录方式)。

表结构:
- PK = id(服务端生成的 UUID)
- provider + provider_user_id 联合 UNIQUE(登录去重键:
  apple sub / google sub 各自命名空间,同一人在不同 provider 是两个账号)
- email:Apple 仅首次登录返回,Google 每次都返
- created_at:首次插入时间
- last_login_at:每次登录更新

v1 产品决策(2026-08-16):不做 email 跨 provider 自动合并——同一人先用 Apple
再用 Google 登录会得到两个独立账号,entitlement 不互通(简单 + 安全,
避免私密转发 email 误判同人)。

错误显式传播(对齐 entitlement/store.py):sqlite3 异常不吞,向上抛。
线程池策略:同步 sqlite3,每次操作短连接,路由层 run_in_threadpool 调用。

迁移:老表(qicompass_user 含 apple_user_id 列,单 provider 时代)在 init_schema
时自动重建为 provider 模型,老数据全部迁移为 provider='apple'(模式对齐
entitlement/store.py 的 PRAGMA table_info 检测 + 重建先例)。
"""

from __future__ import annotations

import sqlite3
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

# 建表语句(幂等,lifespan 启动时执行)
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS qicompass_user (
    id                TEXT PRIMARY KEY,
    provider          TEXT NOT NULL,
    provider_user_id  TEXT NOT NULL,
    email             TEXT,
    created_at        TEXT NOT NULL,
    last_login_at     TEXT NOT NULL,
    UNIQUE(provider, provider_user_id)
);
"""

CREATE_INDEX_PROVIDER_SQL = """
CREATE INDEX IF NOT EXISTS idx_user_provider_user_id
ON qicompass_user(provider, provider_user_id);
"""


@dataclass(frozen=True)
class User:
    """User 行(只读)。"""

    id: str
    provider: str  # "apple" | "google"
    provider_user_id: str  # Apple sub / Google sub
    email: str | None
    created_at: str  # ISO 8601 UTC
    last_login_at: str


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _migrate_legacy_apple_table_if_needed(conn: sqlite3.Connection) -> None:
    """老表(含 apple_user_id 列)→ provider 模型重建。

    步骤:检测 apple_user_id 列 → 建临时新表 → 拷数据(provider='apple')→
    DROP 老表 → 改名。老数据零丢失(对齐 entitlement/store.py 迁移先例:
    PRAGMA table_info 检测 schema,不匹配则重建)。
    """
    row = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='qicompass_user'"
    ).fetchone()
    if row is None:
        return  # 空库,CREATE TABLE 直接建新 schema

    columns = {
        str(col[1])
        for col in conn.execute("PRAGMA table_info(qicompass_user)").fetchall()
    }
    if "apple_user_id" not in columns:
        return  # 已是 provider 模型(幂等)

    conn.execute("""
        CREATE TABLE qicompass_user_new (
            id                TEXT PRIMARY KEY,
            provider          TEXT NOT NULL,
            provider_user_id  TEXT NOT NULL,
            email             TEXT,
            created_at        TEXT NOT NULL,
            last_login_at     TEXT NOT NULL,
            UNIQUE(provider, provider_user_id)
        );
    """)
    # 老表 apple_user_id NOT NULL,拷贝时 provider 固定 'apple' 不丢行
    conn.execute("""
        INSERT INTO qicompass_user_new
            (id, provider, provider_user_id, email, created_at, last_login_at)
        SELECT id, 'apple', apple_user_id, email, created_at, last_login_at
        FROM qicompass_user
    """)
    conn.execute("DROP TABLE qicompass_user")
    conn.execute("ALTER TABLE qicompass_user_new RENAME TO qicompass_user")


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
        """lifespan 启动时调用,幂等建表(含老表迁移)。"""
        with self._connect() as conn:
            _migrate_legacy_apple_table_if_needed(conn)
            conn.execute(CREATE_TABLE_SQL)
            conn.execute(CREATE_INDEX_PROVIDER_SQL)

    def upsert_by_provider(
        self, provider: str, provider_user_id: str, email: str | None = None,
    ) -> User:
        """按 (provider, provider_user_id) upsert。

        - 不存在 → 插入新行(id 服务端生成 UUID,created_at + last_login_at = now)
        - 已存在 → 更新 last_login_at = now;email 仅当传入非 None 时更新
          (Apple 首次登录返 email 后续不返,避免清空;Google 每次都返)

        Args:
            provider:登录方式("apple" / "google")
            provider_user_id:provider 侧稳定标识(Apple sub / Google sub)
            email:provider 返回的 email(None 时不动现有值)

        Returns:
            User(已存在的更新后或新插入)
        """
        now = _now_iso()
        with self._connect() as conn:
            existing = conn.execute(
                "SELECT * FROM qicompass_user WHERE provider = ? AND provider_user_id = ?",
                (provider, provider_user_id),
            ).fetchone()

            if existing is None:
                # 新用户
                new_id = str(uuid.uuid4())
                conn.execute(
                    """INSERT INTO qicompass_user
                       (id, provider, provider_user_id, email, created_at, last_login_at)
                       VALUES (?, ?, ?, ?, ?, ?)""",
                    (new_id, provider, provider_user_id, email, now, now),
                )
                return User(
                    id=new_id,
                    provider=provider,
                    provider_user_id=provider_user_id,
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
                       WHERE provider = ? AND provider_user_id = ?""",
                    (now, new_email, provider, provider_user_id),
                )
                return User(
                    id=existing["id"],
                    provider=provider,
                    provider_user_id=provider_user_id,
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
                provider=row["provider"],
                provider_user_id=row["provider_user_id"],
                email=row["email"],
                created_at=row["created_at"],
                last_login_at=row["last_login_at"],
            )
