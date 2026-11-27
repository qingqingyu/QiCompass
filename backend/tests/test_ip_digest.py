"""TASK-13:IP 带密钥摘要 + 三表迁移/清理的回归锚。"""
from __future__ import annotations

import hashlib
import hmac
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

from app.core.ip_digest import ip_digest


def test_same_ip_same_purpose_stable():
    assert ip_digest("1.2.3.4", "free-quota-ip-v1") == ip_digest("1.2.3.4", "free-quota-ip-v1")


def test_different_purpose_different_digest():
    assert ip_digest("1.2.3.4", "free-quota-ip-v1") != ip_digest("1.2.3.4", "ask-ip-v1")


def test_digest_no_plaintext_markers():
    for purpose in ("free-quota-ip-v1", "ask-ip-v1", "ask-mint-ip-v1"):
        value = ip_digest("2001:db8::1", purpose)
        assert "." not in value and ":" not in value


def test_feedback_hash_byte_compatible():
    """对抗面⑤:feedback 摘要字节级兼容锚——TASK-13 收编 core.ip_digest 前后
    逐字节一致(purpose/消息格式不变),存量 chapter_feedback 摘要零重洗。
    下方 expected 为收编前 _hash_ip 内联实现的独立复刻(非调用现实现)。"""
    from app.ai.feedback_store import _hash_ip
    from app.config import JWT_SECRET_KEY

    expected = hmac.new(
        JWT_SECRET_KEY.encode("utf-8"),
        b"chapter-feedback-ip-v1:" + "9.9.9.9".encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    assert _hash_ip("9.9.9.9") == expected


def test_quota_bucket_migration_idempotent(tmp_path: Path):
    import app.quota.store as quota_mod

    db = tmp_path / "q.db"
    conn = sqlite3.connect(db)
    conn.execute(quota_mod.CREATE_TABLE_SQL)
    conn.execute(quota_mod.CREATE_REFUND_TABLE_SQL)
    plain = "203.0.113.9"
    conn.execute("INSERT INTO free_llm_quota (bucket, day, count) VALUES (?, ?, 1)",
                 (f"ip:{plain}", "2026-11-01"))
    conn.execute("INSERT INTO free_llm_quota_refunds (bucket, day, count) VALUES (?, ?, 1)",
                 (f"ask-ip:{plain}", "2026-11-01"))
    conn.execute("INSERT INTO free_llm_quota VALUES ('user:u1', '2026-11-01', 3)")
    conn.commit()
    conn.close()

    store = quota_mod.FreeLLMQuotaStore(str(db))
    store.init_schema()
    store.init_schema()  # 幂等:二跑空集

    conn = sqlite3.connect(db)
    rows = dict(conn.execute("SELECT bucket, count FROM free_llm_quota"))
    refund_rows = [r[0] for r in conn.execute("SELECT bucket FROM free_llm_quota_refunds")]
    conn.close()
    # 明文行 → 精确摘要值(计数随行保留)
    assert rows == {
        f"ip:{ip_digest(plain, 'free-quota-ip-v1')}": 1,
        "user:u1": 3,  # user 桶不动
    }
    assert refund_rows == [f"ask-ip:{ip_digest(plain, 'ask-ip-v1')}"]


def test_quota_migration_merges_on_pk_conflict(tmp_path: Path):
    """撞键合并(2026-11-27 review):部署重叠窗口旧进程写回明文行,与既有
    摘要行同 (bucket, day) PK——迁移须合并计数而非 UPDATE 撞 UNIQUE 启动崩。"""
    import app.quota.store as quota_mod

    db = tmp_path / "q3.db"
    plain = "198.51.100.3"
    digest_bucket = f"ip:{ip_digest(plain, 'free-quota-ip-v1')}"
    conn = sqlite3.connect(db)
    conn.execute(quota_mod.CREATE_TABLE_SQL)
    conn.execute("INSERT INTO free_llm_quota VALUES (?, '2026-11-26', 2)",
                 (digest_bucket,))
    conn.execute("INSERT INTO free_llm_quota VALUES (?, '2026-11-26', 3)",
                 (f"ip:{plain}",))
    conn.commit()
    conn.close()

    quota_mod.FreeLLMQuotaStore(str(db)).init_schema()

    conn = sqlite3.connect(db)
    rows = dict(conn.execute("SELECT bucket, count FROM free_llm_quota"))
    conn.close()
    assert rows == {digest_bucket: 2 + 3}  # 计数相加,明文行消失


def test_purge_old_rows_keeps_recent(tmp_path: Path):
    import app.quota.store as quota_mod

    db = tmp_path / "q2.db"
    conn = sqlite3.connect(db)
    conn.execute(quota_mod.CREATE_TABLE_SQL)
    conn.execute(quota_mod.CREATE_REFUND_TABLE_SQL)
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    yesterday = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
    old = (datetime.now(timezone.utc) - timedelta(days=8)).strftime("%Y-%m-%d")
    for d in (today, yesterday, old):
        conn.execute("INSERT INTO free_llm_quota (bucket, day, count) VALUES (?, ?, 1)",
                     (f"ip:{ip_digest('203.0.113.9', 'free-quota-ip-v1')}", d))
    conn.commit()
    conn.close()

    store = quota_mod.FreeLLMQuotaStore(str(db))
    deleted = store.purge_old_rows(force=True)
    assert deleted == 1
    conn = sqlite3.connect(db)
    days = {r[0] for r in conn.execute("SELECT day FROM free_llm_quota")}
    conn.close()
    assert old not in days and {today, yesterday} <= days


def test_mint_migration_and_purge(tmp_path: Path):
    import app.ask.store as ask_mod

    db = tmp_path / "a.db"
    store = ask_mod.AskCreditsStore(str(db))
    store.init_schema()
    conn = sqlite3.connect(db)
    plain = "198.51.100.7"
    old = (datetime.now(timezone.utc) - timedelta(days=8)).strftime("%Y-%m-%d")
    conn.execute("INSERT INTO ask_trial_mints (ip, day, count) VALUES (?, ?, 2)", (plain, old))
    conn.commit()
    conn.close()

    store.init_schema()  # 迁移:明文 → 精确摘要值
    conn = sqlite3.connect(db)
    assert conn.execute("SELECT ip FROM ask_trial_mints").fetchall() == [
        (ip_digest(plain, "ask-mint-ip-v1"),)]
    conn.close()
    store.init_schema()  # 幂等:二跑空集
    store.purge_old_mints(force=True)  # 8 天前 → 清
    conn = sqlite3.connect(db)
    left = conn.execute("SELECT count(*) FROM ask_trial_mints").fetchone()[0]
    conn.close()
    assert left == 0


def test_mint_migration_merges_on_pk_conflict(tmp_path: Path):
    """撞键合并(同 quota 表):明文行与既有摘要行同 (ip, day) PK → 计数相加。"""
    import app.ask.store as ask_mod

    db = tmp_path / "a2.db"
    store = ask_mod.AskCreditsStore(str(db))
    store.init_schema()
    plain = "203.0.113.4"
    digest_ip = ip_digest(plain, "ask-mint-ip-v1")
    conn = sqlite3.connect(db)
    conn.execute("INSERT INTO ask_trial_mints VALUES (?, '2026-11-26', 4)", (digest_ip,))
    conn.execute("INSERT INTO ask_trial_mints VALUES (?, '2026-11-26', 1)", (plain,))
    conn.commit()
    conn.close()

    store.init_schema()  # 迁移

    conn = sqlite3.connect(db)
    rows = dict(conn.execute("SELECT ip, count FROM ask_trial_mints"))
    conn.close()
    assert rows == {digest_ip: 4 + 1}
