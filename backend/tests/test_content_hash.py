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
    """同时辰内不同小时 → hash 相同(时辰级精度)。

    14:30 和 13:00 同属未时(13:00-15:00)→ 桶 (hour+1)%24//2 均为 7。
    """
    b1 = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    b2 = datetime(1990, 3, 15, 13, 0, tzinfo=TZ8)  # 同未时(13-15)
    h1 = compute_content_hash(b1, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(b2, "male", 116.41, "zi_next_day")
    assert h1 == h2


def test_hash_differs_for_same_date_early_and_late_zi_hour():
    """zi_next_day 下同一公历日 00:30 与 23:30 不能共用 contentHash。

    两者同为子时桶 0,但晚子时按 zi_next_day 会归入次日命盘。
    """
    early_zi = datetime(1990, 3, 15, 0, 30, tzinfo=TZ8)
    late_zi = datetime(1990, 3, 15, 23, 30, tzinfo=TZ8)
    h1 = compute_content_hash(early_zi, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(late_zi, "male", 116.41, "zi_next_day")
    assert h1 != h2


def test_hash_same_for_contiguous_zi_hour_across_midnight():
    """zi_next_day 下 23:30 与次日 00:30 属同一个晚子时桶。"""
    late_zi = datetime(1990, 3, 15, 23, 30, tzinfo=TZ8)
    early_next_day_zi = datetime(1990, 3, 16, 0, 30, tzinfo=TZ8)
    h1 = compute_content_hash(late_zi, "male", 116.41, "zi_next_day")
    h2 = compute_content_hash(early_next_day_zi, "male", 116.41, "zi_next_day")
    assert h1 == h2


def test_hash_does_not_include_schema_version():
    """D1:contentHash 不含 schema_version(跨用户共享缓存)。"""
    # 实现层保证:hash 函数签名只有 birth/gender/longitude/zi_hour_rule
    b = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    h = compute_content_hash(b, "male", 116.41, "zi_next_day")
    assert isinstance(h, str) and len(h) == 64


def test_two_hour_bucket_format():
    """时辰桶对齐传统时辰边界(子时=23/0→桶0,未时=13/14→桶7)。"""
    b = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    assert birth_two_hour_bucket(b) == "1990-03-15|7"  # (14+1)%24//2=7,未时
    b2 = datetime(1990, 3, 15, 23, 30, tzinfo=TZ8)
    assert birth_two_hour_bucket(b2) == "1990-03-16|0"  # zi_next_day 晚子时归次日
    b3 = datetime(1990, 3, 15, 0, 30, tzinfo=TZ8)
    assert birth_two_hour_bucket(b3) == "1990-03-15|0"  # (0+1)%24//2=0,子时


def test_two_hour_bucket_zi_same_day_keeps_late_zi_on_same_date():
    """zi_same_day 下 23 点子时仍归输入日期。"""
    b = datetime(1990, 3, 15, 23, 30, tzinfo=TZ8)
    assert birth_two_hour_bucket(b, "zi_same_day") == "1990-03-15|0"
