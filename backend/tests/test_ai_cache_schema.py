"""AI 缓存 provider/model 隔离与旧表重建测试。"""

from __future__ import annotations

import sqlite3
from dataclasses import replace

from app.ai.cache import InterpretationCache
from app.ai.cache_key import CacheKey


def _make_key(**overrides) -> CacheKey:
    """默认九维 CacheKey 工厂,测试用 kwargs 覆盖单字段。"""
    defaults = dict(
        content_hash="hash",
        module="bazi_deep",
        prompt_version=1,
        target_date=None,
        prompt_hash="prompt-hash",
        provider="anthropic",
        model="claude-test",
        parent_hash="",
        user_input_hash="",
    )
    defaults.update(overrides)
    return CacheKey(**defaults)


def test_legacy_cache_table_is_dropped_and_rebuilt(tmp_path):
    db_path = tmp_path / "legacy.db"
    with sqlite3.connect(db_path) as conn:
        conn.execute("""
            CREATE TABLE interpretation_cache (
                content_hash TEXT NOT NULL,
                module TEXT NOT NULL,
                prompt_version INTEGER NOT NULL,
                target_date TEXT NOT NULL DEFAULT '',
                prompt_hash TEXT NOT NULL,
                model TEXT NOT NULL,
                interpretation TEXT NOT NULL,
                generated_at TEXT NOT NULL,
                PRIMARY KEY (
                    content_hash, module, prompt_version,
                    target_date, prompt_hash
                )
            )
        """)
        conn.execute(
            "INSERT INTO interpretation_cache VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("hash", "bazi_deep", 1, "", "prompt", "old-model",
             "old text", "2026-01-01T00:00:00+00:00"),
        )

    cache = InterpretationCache(str(db_path))
    cache.init_schema()

    with sqlite3.connect(db_path) as conn:
        columns = {
            row[1] for row in conn.execute(
                "PRAGMA table_info(interpretation_cache)"
            ).fetchall()
        }
        count = conn.execute(
            "SELECT COUNT(*) FROM interpretation_cache"
        ).fetchone()[0]
    assert "provider" in columns
    assert count == 0


def test_cache_key_includes_provider_and_model(tmp_path):
    cache = InterpretationCache(str(tmp_path / "identity.db"))
    cache.init_schema()
    base_key = CacheKey(
        content_hash="hash",
        module="bazi_deep",
        prompt_version=1,
        target_date=None,
        prompt_hash="prompt-hash",
        provider="anthropic",
        model="claude-test",
    )
    cache.set(base_key, "anthropic text", "2026-01-01T00:00:00+00:00")

    assert cache.get(base_key)["interpretation"] == "anthropic text"
    assert cache.get(replace(base_key, provider="openai", model="gpt-test")) is None
    assert cache.get(replace(base_key, model="claude-other")) is None


# ===== v1 prompt 系统:parent_hash / user_input_hash 隔离 =====


def test_cache_key_parent_hash_isolates_m0_fingerprint(tmp_path):
    """同 chart 同 module,不同 parent_hash(M0 fingerprint 变化)→ 不同缓存条目。

    v1 链式调用场景:M0 重算后 structure_fingerprint 变了,M1-M7 必须跟着重跑,
    不能复用旧 M0 输出对应的 M1-M7 缓存。
    """
    cache = InterpretationCache(str(tmp_path / "parent.db"))
    cache.init_schema()
    key_a = _make_key(parent_hash="fingerprint_v1")
    key_b = _make_key(parent_hash="fingerprint_v2")

    cache.set(key_a, "M1 output for fingerprint_v1", "2026-01-01T00:00:00+00:00")
    assert cache.get(key_a)["interpretation"] == "M1 output for fingerprint_v1"
    # 不同 parent_hash → 隔离
    assert cache.get(key_b) is None


def test_cache_key_user_input_hash_isolates_m4_m5_inputs(tmp_path):
    """同 chart 同 module,不同 user_input_hash(M4/M5 用户输入变化)→ 不同缓存条目。

    v1 按需模块场景:用户改了 age/concern 或 assets/preference,M4/M5 必须重跑,
    不能复用别人/自己上次的输入对应的缓存。
    """
    cache = InterpretationCache(str(tmp_path / "user_input.db"))
    cache.init_schema()
    key_age30 = _make_key(
        module="m4_health", user_input_hash="age=30|concern=sleep",
    )
    key_age35 = _make_key(
        module="m4_health", user_input_hash="age=35|concern=sleep",
    )

    cache.set(key_age30, "M4 for age=30", "2026-01-01T00:00:00+00:00")
    assert cache.get(key_age30)["interpretation"] == "M4 for age=30"
    # 不同 user_input_hash → 隔离
    assert cache.get(key_age35) is None


def test_cache_key_old_modules_default_empty_hashes(tmp_path):
    """老模块(bazi_deep_*)parent_hash / user_input_hash 默认空串,行为不变。

    向后兼容:老调用方不传 parent_hash / user_input_hash → 默认空串,
    能正常读写缓存,且不与 v1 新模块(传非空 hash)冲突。
    """
    cache = InterpretationCache(str(tmp_path / "legacy.db"))
    cache.init_schema()
    key = _make_key()  # parent_hash="" / user_input_hash="" 默认

    cache.set(key, "legacy interpretation", "2026-01-01T00:00:00+00:00")
    assert cache.get(key)["interpretation"] == "legacy interpretation"


def test_legacy_seven_column_table_is_dropped_for_v1_migration(tmp_path):
    """Stage 2 之前的 7 列 schema 表必须被 DROP 重建为 9 列。

    _drop_legacy_cache_if_needed 检测 columns != _EXPECTED_COLUMNS → DROP,
    老缓存自然失效(配合 PROMPT_VERSIONS bump 是预期行为)。
    """
    db_path = tmp_path / "v1_migration.db"
    # 建老 schema(7 列,无 parent_hash / user_input_hash)
    with sqlite3.connect(db_path) as conn:
        conn.execute("""
            CREATE TABLE interpretation_cache (
                content_hash TEXT NOT NULL,
                module TEXT NOT NULL,
                prompt_version INTEGER NOT NULL,
                target_date TEXT NOT NULL DEFAULT '',
                prompt_hash TEXT NOT NULL,
                provider TEXT NOT NULL,
                model TEXT NOT NULL,
                interpretation TEXT NOT NULL,
                generated_at TEXT NOT NULL,
                PRIMARY KEY (
                    content_hash, module, prompt_version,
                    target_date, prompt_hash, provider, model
                )
            )
        """)
        conn.execute(
            "INSERT INTO interpretation_cache VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("hash", "bazi_deep", 1, "", "prompt", "anthropic",
             "claude-test", "old text", "2026-01-01T00:00:00+00:00"),
        )

    cache = InterpretationCache(str(db_path))
    cache.init_schema()  # 触发 _drop_legacy_cache_if_needed

    with sqlite3.connect(db_path) as conn:
        columns = {row[1] for row in conn.execute(
            "PRAGMA table_info(interpretation_cache)"
        ).fetchall()}
        count = conn.execute(
            "SELECT COUNT(*) FROM interpretation_cache"
        ).fetchone()[0]

    # 新 schema 两字段已加
    assert "parent_hash" in columns
    assert "user_input_hash" in columns
    # 老缓存被 DROP
    assert count == 0


def test_cache_key_hash_and_equality_includes_new_fields():
    """CacheKey 的 __hash__ / __eq__ 必须包含 parent_hash / user_input_hash。

    SingleflightCoalescer 用 CacheKey 作 dict key,如果新字段不参与 hash,
    会发生"不同 parent_hash 但被 singleflight 合并"的严重 bug。
    frozen dataclass 自动生成 __hash__,本测试是冒烟断言。
    """
    key_a = _make_key(parent_hash="A")
    key_b = _make_key(parent_hash="B")
    assert key_a != key_b, "不同 parent_hash 应不相等"
    assert hash(key_a) != hash(key_b), "不同 parent_hash 的 hash 应不同"

    key_c = _make_key(user_input_hash="X")
    key_d = _make_key(user_input_hash="Y")
    assert key_c != key_d, "不同 user_input_hash 应不相等"
    assert hash(key_c) != hash(key_d), "不同 user_input_hash 的 hash 应不同"
