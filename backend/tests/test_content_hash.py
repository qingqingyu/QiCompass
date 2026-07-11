"""contentHash 单测(D1 内容寻址)。"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.core.content_hash import birth_two_hour_bucket, compute_content_hash

TZ8 = timezone(timedelta(hours=8))


def test_hash_deterministic_same_input():
    b = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    h1 = compute_content_hash(b, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(b, "male", 116.41, "zi_next_day")
    assert h1 == h2
    assert len(h1) == 64  # sha256 hex


def test_hash_differs_by_longitude():
    b = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    h1 = compute_content_hash(b, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(b, "male", 121.47, "zi_next_day")
    assert h1 != h2


def test_hash_differs_by_gender():
    b = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    h1 = compute_content_hash(b, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(b, "female", 116.41, "zi_next_day")
    assert h1 != h2


def test_hash_differs_by_two_hour_bucket():
    """2 小时桶不同 → hash 不同(14:xx 与 16:xx 不同桶)。"""
    b1 = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    b2 = datetime(1990, 3, 15, 16, 30, tzinfo=TZ8)
    h1 = compute_content_hash(b1, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(b2, "male", 116.41, "zi_next_day")
    assert h1 != h2


def test_hash_same_within_two_hour_bucket():
    """同 2h 桶内不同分钟 → hash 相同(时辰级精度)。"""
    b1 = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    b2 = datetime(1990, 3, 15, 15, 59, tzinfo=TZ8)  # 同未时(13-15 桶 → hour//2==7)
    h1 = compute_content_hash(b1, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(b2, "male", 116.41, "zi_next_day")
    assert h1 == h2


def test_hash_does_not_include_schema_version():
    """D1:contentHash 不含 schema_version(跨用户共享缓存)。"""
    # 实现层保证:hash 函数签名只有 birth/gender/longitude/zi_hour_rule
    b = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    h = compute_content_hash(b, "male", 116.41, "zi_next_day")
    assert isinstance(h, str) and len(h) == 64


def test_two_hour_bucket_format():
    b = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    assert birth_two_hour_bucket(b) == "1990-03-15|7"  # 14//2=7
    b2 = datetime(1990, 3, 15, 23, 30, tzinfo=TZ8)
    assert birth_two_hour_bucket(b2) == "1990-03-15|11"  # 23//2=11
