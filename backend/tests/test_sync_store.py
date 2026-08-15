"""UserChartSyncStore 单元测试(PR3.1 store 层 + S02 city_timezone 迁移)。

覆盖:
- 新库 init_schema → city_timezone 列存在,upsert/list roundtrip(有值/None 两态)
- **老库迁移**:S02 前建的表(无 city_timezone 列)→ init_schema ALTER 补列,
  老行可读(city_timezone 为 None),迁移幂等(重复 init_schema 不炸)
- upsert 语义:同 (user_id, content_hash) 二次推送更新字段、保留 created_at

(store 层直测 SQLite 文件,不走 HTTP —— sync 端点鉴权层不在本文件范围)
"""

from __future__ import annotations

import sqlite3

from app.sync.store import UserChartSyncStore

# S02 之前的建表语句(无 city_timezone 列)——迁移测试用它构造「老库」
OLD_CREATE_TABLE_SQL = """
CREATE TABLE user_chart_sync (
    id                  TEXT PRIMARY KEY,
    user_id             TEXT NOT NULL,
    content_hash        TEXT NOT NULL,
    alias               TEXT NOT NULL,
    schema_version      INTEGER NOT NULL,
    birth_solar_time    TEXT NOT NULL,
    gender              TEXT NOT NULL,
    city_longitude      REAL NOT NULL,
    zi_hour_rule        TEXT NOT NULL,
    calc_rule_snapshot  TEXT NOT NULL,
    payload             TEXT NOT NULL,
    created_at          TEXT NOT NULL,
    updated_at          TEXT NOT NULL,
    UNIQUE(user_id, content_hash)
);
"""


def _upsert_kwargs(**overrides):
    base = dict(
        user_id="user-1",
        content_hash="a" * 64,
        alias="本人",
        schema_version=1,
        birth_solar_time="1990-03-15T14:29:44",
        gender="male",
        city_longitude=116.4074,
        city_timezone="Asia/Shanghai",
        zi_hour_rule="zi_next_day",
        calc_rule_snapshot="snAPsh0t==",
        payload='{"pillars": {}}',
        created_at="2026-08-15T00:00:00+00:00",
    )
    base.update(overrides)
    return base


def _columns(db_path: str) -> set[str]:
    with sqlite3.connect(db_path) as conn:
        return {r[1] for r in conn.execute(
            "PRAGMA table_info(user_chart_sync)")}


def test_fresh_schema_has_city_timezone_roundtrip(tmp_path):
    """新库:city_timezone 列存在,有值/None 两态 roundtrip 不丢。"""
    db_path = str(tmp_path / "sync.db")
    store = UserChartSyncStore(db_path)
    store.init_schema()
    assert "city_timezone" in _columns(db_path)

    r1 = store.upsert(**_upsert_kwargs())
    assert r1.city_timezone == "Asia/Shanghai"

    r2 = store.upsert(**_upsert_kwargs(
        content_hash="b" * 64, city_timezone=None))  # 老客户端缺字段容忍
    assert r2.city_timezone is None

    rows = store.list_by_user("user-1")
    assert {r.content_hash: r.city_timezone for r in rows} == {
        "a" * 64: "Asia/Shanghai",
        "b" * 64: None,
    }


def test_old_db_without_city_timezone_migrated(tmp_path):
    """S02 迁移:老库(无 city_timezone)→ init_schema ALTER 补列。

    老行必须可读(city_timezone=None,不静默丢数据);
    迁移后 upsert 带时区可正常写入。"""
    db_path = str(tmp_path / "old.db")
    with sqlite3.connect(db_path) as conn:
        conn.execute(OLD_CREATE_TABLE_SQL)
        # 埋一行老数据(S02 前的 13 列格式)
        conn.execute(
            """INSERT INTO user_chart_sync VALUES
               ('id-1', 'user-1', ?, '本人', 1, '1990-03-15T14:29:44',
                'male', 116.4074, 'zi_next_day', 'snAPsh0t==',
                '{}', '2026-01-01T00:00:00+00:00',
                '2026-01-01T00:00:00+00:00')""",
            ("c" * 64,),
        )
    assert "city_timezone" not in _columns(db_path)

    store = UserChartSyncStore(db_path)
    store.init_schema()  # ← 迁移发生在此
    assert "city_timezone" in _columns(db_path)

    # 老行可读,city_timezone 容忍为 None(不静默丢行)
    rows = store.list_by_user("user-1")
    assert len(rows) == 1
    assert rows[0].content_hash == "c" * 64
    assert rows[0].city_timezone is None

    # 老行 upsert 补上时区(同 hash → UPDATE 路径)
    updated = store.upsert(**_upsert_kwargs(content_hash="c" * 64))
    assert updated.city_timezone == "Asia/Shanghai"
    assert updated.created_at == "2026-01-01T00:00:00+00:00"  # created_at 保留


def test_migration_idempotent_on_new_schema(tmp_path):
    """迁移幂等:新库(列已存在)重复 init_schema 不抛 duplicate column。"""
    store = UserChartSyncStore(str(tmp_path / "sync.db"))
    store.init_schema()
    store.init_schema()  # 二次启动
    assert "city_timezone" in _columns(store._db_path)


def test_upsert_same_hash_updates_and_keeps_created_at(tmp_path):
    """同 (user_id, content_hash) 二次推送:字段更新 + created_at 保留。"""
    store = UserChartSyncStore(str(tmp_path / "sync.db"))
    store.init_schema()
    store.upsert(**_upsert_kwargs())
    second = store.upsert(**_upsert_kwargs(alias="改名", city_longitude=121.4737))
    assert second.alias == "改名"
    assert second.city_longitude == 121.4737
    assert second.created_at == "2026-08-15T00:00:00+00:00"
    assert store.count_by_user("user-1") == 1  # 去重不插新行
