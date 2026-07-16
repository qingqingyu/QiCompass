"""AI 缓存 provider/model 隔离与旧表重建测试。"""

from __future__ import annotations

import sqlite3

from app.ai.cache import InterpretationCache


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
    common = dict(
        content_hash="hash",
        module="bazi_deep",
        prompt_version=1,
        target_date=None,
        prompt_hash="prompt-hash",
    )
    cache.set(
        **common,
        provider="anthropic",
        model="claude-test",
        interpretation="anthropic text",
        generated_at="2026-01-01T00:00:00+00:00",
    )

    assert cache.get(
        **common, provider="anthropic", model="claude-test"
    )["interpretation"] == "anthropic text"
    assert cache.get(
        **common, provider="openai", model="gpt-test"
    ) is None
    assert cache.get(
        **common, provider="anthropic", model="claude-other"
    ) is None
