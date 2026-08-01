"""AI 缓存 provider/model 隔离与旧表重建测试。"""

from __future__ import annotations

import sqlite3
from dataclasses import replace

from app.ai.cache import InterpretationCache
from app.ai.cache_key import CacheKey


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
