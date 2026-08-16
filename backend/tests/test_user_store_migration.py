"""UserStore 老表(apple_user_id 单 provider 时代)→ provider 模型迁移测试。

验收:
- 老表 + 数据 → init_schema 自动迁移,新列集合 + 数据保留(provider='apple')
- 空库 → init_schema 直接建新 schema
- init_schema 幂等(跑两遍不炸不丢数据)
- UNIQUE(provider, provider_user_id) 生效:同 provider 同 sub 去重,
  不同 provider 同 sub 共存(账号隔离的产品决策)
"""

from __future__ import annotations

import sqlite3

from app.auth.user_store import UserStore

# 老表 schema(PR2.5 原版,单 Apple provider 时代)
_LEGACY_CREATE_SQL = """
CREATE TABLE qicompass_user (
    id              TEXT PRIMARY KEY,
    apple_user_id   TEXT NOT NULL UNIQUE,
    email           TEXT,
    created_at      TEXT NOT NULL,
    last_login_at   TEXT NOT NULL
);
"""

_LEGACY_INDEX_SQL = """
CREATE INDEX IF NOT EXISTS idx_user_apple_user_id
ON qicompass_user(apple_user_id);
"""


def _create_legacy_db(db_path, rows: list[tuple[str, str, str, str, str]]) -> None:
    """手工建老 schema 表并插数据(模拟 PR2.5 时代的既有库)。"""
    conn = sqlite3.connect(db_path)
    conn.execute(_LEGACY_CREATE_SQL)
    conn.execute(_LEGACY_INDEX_SQL)
    conn.executemany(
        "INSERT INTO qicompass_user (id, apple_user_id, email, created_at, last_login_at) "
        "VALUES (?, ?, ?, ?, ?)",
        rows,
    )
    conn.commit()
    conn.close()


def _table_columns(db_path) -> set[str]:
    conn = sqlite3.connect(db_path)
    cols = {str(col[1]) for col in conn.execute("PRAGMA table_info(qicompass_user)")}
    conn.close()
    return cols


def test_legacy_table_migrated_data_preserved(tmp_path):
    """老表 2 行数据 → init_schema → provider 模型 + 数据全保留(provider='apple')。"""
    db_path = str(tmp_path / "legacy_user.db")
    _create_legacy_db(db_path, [
        ("id-1", "apple-sub-001", "a@example.com",
         "2026-07-01T00:00:00+00:00", "2026-07-01T00:00:00+00:00"),
        ("id-2", "apple-sub-002", None,
         "2026-07-02T00:00:00+00:00", "2026-07-02T00:00:00+00:00"),
    ])

    store = UserStore(db_path)
    store.init_schema()

    # 新列集合(无 apple_user_id,含 provider/provider_user_id)
    assert _table_columns(db_path) == {
        "id", "provider", "provider_user_id", "email", "created_at", "last_login_at",
    }

    # 数据保留
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        "SELECT * FROM qicompass_user ORDER BY id"
    ).fetchall()
    conn.close()
    assert len(rows) == 2
    assert rows[0]["id"] == "id-1"
    assert rows[0]["provider"] == "apple"
    assert rows[0]["provider_user_id"] == "apple-sub-001"
    assert rows[0]["email"] == "a@example.com"
    assert rows[1]["provider"] == "apple"
    assert rows[1]["provider_user_id"] == "apple-sub-002"


def test_fresh_db_creates_provider_schema_directly(tmp_path):
    """空库 → init_schema → 直接建 provider schema(不走迁移分支)。"""
    db_path = str(tmp_path / "fresh_user.db")
    store = UserStore(db_path)
    store.init_schema()
    assert _table_columns(db_path) == {
        "id", "provider", "provider_user_id", "email", "created_at", "last_login_at",
    }


def test_init_schema_idempotent(tmp_path):
    """init_schema 跑两遍不炸、数据不丢(幂等)。"""
    db_path = str(tmp_path / "idem_user.db")
    _create_legacy_db(db_path, [
        ("id-1", "apple-sub-001", "a@example.com",
         "2026-07-01T00:00:00+00:00", "2026-07-01T00:00:00+00:00"),
    ])
    store = UserStore(db_path)
    store.init_schema()
    store.init_schema()  # 第二遍:已是新 schema,应无操作

    conn = sqlite3.connect(db_path)
    count = conn.execute("SELECT COUNT(*) FROM qicompass_user").fetchone()[0]
    conn.close()
    assert count == 1


def test_migrated_user_can_log_in_again_via_upsert(tmp_path):
    """迁移后老 Apple 用户再登录 → 命中同一行(last_login_at 更新,id 不变)。"""
    db_path = str(tmp_path / "relogin_user.db")
    _create_legacy_db(db_path, [
        ("id-1", "apple-sub-001", "a@example.com",
         "2026-07-01T00:00:00+00:00", "2026-07-01T00:00:00+00:00"),
    ])
    store = UserStore(db_path)
    store.init_schema()

    user = store.upsert_by_provider("apple", "apple-sub-001", "a@example.com")
    assert user.id == "id-1"  # 命中迁移过来的老行,不是新 UUID
    assert user.provider == "apple"


def test_same_sub_different_provider_are_separate_accounts(tmp_path):
    """UNIQUE(provider, provider_user_id):同 sub 不同 provider → 两个独立账号
    (v1 账号隔离决策);同 provider 同 sub → 去重同一账号。"""
    db_path = str(tmp_path / "isolation_user.db")
    store = UserStore(db_path)
    store.init_schema()

    apple_user = store.upsert_by_provider("apple", "shared-sub-001", "a@example.com")
    google_user = store.upsert_by_provider("google", "shared-sub-001", "g@gmail.com")
    assert apple_user.id != google_user.id  # 两个账号

    # 同 provider 同 sub 再登录 → 同一账号
    apple_again = store.upsert_by_provider("apple", "shared-sub-001", None)
    assert apple_again.id == apple_user.id


def test_upsert_new_user_and_get_by_id_roundtrip(tmp_path):
    """常规 upsert + get_by_id 往返(新 schema 基本功)。"""
    db_path = str(tmp_path / "basic_user.db")
    store = UserStore(db_path)
    store.init_schema()

    created = store.upsert_by_provider("google", "google-sub-777", "user@gmail.com")
    fetched = store.get_by_id(created.id)
    assert fetched is not None
    assert fetched.provider == "google"
    assert fetched.provider_user_id == "google-sub-777"
    assert fetched.email == "user@gmail.com"

    assert store.get_by_id("nonexistent") is None
