"""evalkit cases 单测:20 盘配额 + CASES_HASH 稳定性 + parse_birth 往返。

零 API 调用。
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone

from evalkit.cases import CASES, CASES_HASH, parse_birth


def test_quota_20_cases_15_normal_5_special():
    """配额断言:20 盘 = 15 普通 + 5 special_pattern(启动时已 assert,此处再验)。"""
    assert len(CASES) == 20
    normal = [c for c in CASES if c["category"] == "normal"]
    special = [c for c in CASES if c["category"] == "special_pattern"]
    assert len(normal) == 15
    assert len(special) == 5


def test_case_fields_complete():
    """每盘必填字段齐(birth_datetime/gender/longitude/zi_hour_rule/category)。"""
    for case in CASES:
        for field in ("birth_datetime", "gender", "longitude",
                      "zi_hour_rule", "category", "expected_strength",
                      "source"):
            assert field in case, f"缺字段 {field}: {case}"
        assert case["gender"] in ("male", "female")
        assert case["zi_hour_rule"] in ("zi_next_day", "zi_same_day")


def test_birth_datetimes_unique():
    """20 盘出生时间互不相同(重复会削弱用例覆盖)。"""
    births = [c["birth_datetime"] for c in CASES]
    assert len(set(births)) == 20


def test_cases_hash_stable():
    """CASES_HASH = 规范化 JSON 的 sha256(独立重算,验证实现正确且稳定)。"""
    canonical = json.dumps(
        CASES, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    expected = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    assert CASES_HASH == expected
    # 再次计算同值(无隐藏状态)
    canonical2 = json.dumps(
        CASES, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    assert hashlib.sha256(canonical2.encode("utf-8")).hexdigest() == CASES_HASH


def test_cases_hash_changes_when_cases_change():
    """用例集合变动 → hash 变(Q5:换用例集 = 新 run 身份)。"""
    mutated = [dict(c) for c in CASES]
    mutated[0]["birth_datetime"] = "1999-09-09T09:09:00+08:00"
    canonical = json.dumps(
        mutated, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    other = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    assert other != CASES_HASH


def test_parse_birth_roundtrip():
    """ISO 8601 → aware datetime → isoformat 往返一致。"""
    raw = "1985-02-10T10:30:00+08:00"
    dt = parse_birth(raw)
    assert isinstance(dt, datetime)
    assert dt.tzinfo is not None
    assert dt.isoformat() == raw


def test_parse_birth_all_cases_aware():
    """20 盘的 birth 全部能解析为 aware(排盘引擎只消费 aware 时刻)。"""
    for case in CASES:
        dt = parse_birth(case["birth_datetime"])
        assert dt.tzinfo is not None
    # 固定 now 的时区形态不受解析影响(冒烟)
    fixed = datetime(2025, 1, 15, 12, 0, tzinfo=timezone.utc)
    assert fixed.tzinfo is timezone.utc
