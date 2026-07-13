"""Prompt 验证 Spike 的 20 盘 fixture(方案 §1.1)。

样本池来源:`backend/tests/fixtures/xiji_cases.py`(45 普通盘 + 5 special_pattern)。
本文件按下表配额挑选 20 盘,所有数据匿名化(无姓名/联系方式)。

配额:
- 普通真实盘 15(覆盖四季 × 强弱分布)
- 专旺盘 2(现有 fixture 的 2 个)
- 从格盘 3(现有 fixture 的 3 个;从财/从杀第 4 盘待人工构造,当前 gap 记录)

构造的 extreme case 已在后端 `_detect_special_pattern()` 单元测试中确认命中。
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any


def _build_spike_cases() -> list[dict[str, Any]]:
    """20 盘验证集。字段匿名化:出生时间/性别/经度/时区/zi_hour_rule/预期。"""
    cases: list[dict[str, Any]] = []

    # ---------- 15 个普通盘(四季 × 强弱分布) ----------

    normal_spec: list[tuple[str, str, str, str]] = [
        # (birth_datetime, gender, expected_strength, season_note)
        # 春(spring, 月 2-4)
        ("1985-02-10T10:30:00+08:00", "female", "balanced", "春·初春"),
        ("1985-03-10T10:30:00+08:00", "male", "weak", "春·仲春"),
        ("1990-03-10T10:30:00+08:00", "male", "balanced", "春·仲春"),
        ("1995-04-10T10:30:00+08:00", "female", "strong", "春·暮春"),
        # 夏(summer, 月 5-7)
        ("1985-05-10T10:30:00+08:00", "male", "strong", "夏·初夏"),
        ("1985-07-10T10:30:00+08:00", "male", "strong", "夏·盛夏"),
        ("1990-06-10T10:30:00+08:00", "female", "strong", "夏·仲夏"),
        # 秋(autumn, 月 8-10)
        ("1985-09-10T10:30:00+08:00", "male", "strong", "秋·仲秋"),
        ("1990-10-10T10:30:00+08:00", "female", "strong", "秋·深秋"),
        ("1995-10-10T10:30:00+08:00", "female", "weak", "秋·深秋"),
        ("1990-09-10T10:30:00+08:00", "male", "weak", "秋·初秋"),
        # 冬(winter, 月 11-1)
        ("1985-12-10T10:30:00+08:00", "female", "balanced", "冬·仲冬"),
        ("1990-01-10T10:30:00+08:00", "male", "weak", "冬·深冬"),
        ("1990-12-10T10:30:00+08:00", "female", "weak", "冬·仲冬"),
        ("2000-01-10T10:30:00+08:00", "male", "balanced", "冬·初冬"),
    ]

    for birth, gender, strength, note in normal_spec:
        cases.append({
            "birth_datetime": birth,
            "gender": gender,
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
            "category": "normal",
            "expected_strength": strength,
            "season_note": note,
            "source": "xiji_cases.py 普通盘子集",
        })

    # ---------- 2 个专旺盘 ----------
    zhuanwang_spec: list[tuple[str, str, str]] = [
        # 专旺水:癸卯 癸亥 癸亥 壬子,water=7
        ("1903-12-01T00:30:00+08:00", "male", "zhuanwang_water"),
        # 专旺火:丙午 甲午 丙午 甲午,fire=6
        ("1906-07-01T12:30:00+08:00", "male", "zhuanwang_fire"),
    ]

    for birth, gender, hint in zhuanwang_spec:
        cases.append({
            "birth_datetime": birth,
            "gender": gender,
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
            "category": "special_pattern",
            "expected_strength": "special_pattern",
            "pattern_hint": hint,
            "source": "xiji_cases.py 专旺盘",
        })

    # ---------- 3 个从格盘 ----------
    # NOTE: 方案要求 4 盘从格(从火/从水/从土/从财或从杀各 1)。
    # 现有 fixture 只有 3 个(从火/从水/从土)。从财/从杀第 4 盘待人工构造。
    # 构造时需先跑 _detect_special_pattern() 确认命中 cong,再加入此处。
    cong_spec: list[tuple[str, str, str]] = [
        # 从格(火):丙午 丁酉 壬戌 丙午,日主壬水孤立,fire=5
        ("1906-09-15T12:30:00+08:00", "female", "cong_fire"),
        # 从格(水):壬子 壬寅 丙子 戊子,日主丙火孤立,water=5
        ("1912-03-01T00:30:00+08:00", "male", "cong_water"),
        # 从格(土):己未 戊辰 癸丑 戊午,日主癸水孤立,earth=6
        ("1919-05-01T12:30:00+08:00", "female", "cong_earth"),
    ]

    for birth, gender, hint in cong_spec:
        cases.append({
            "birth_datetime": birth,
            "gender": gender,
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
            "category": "special_pattern",
            "expected_strength": "special_pattern",
            "pattern_hint": hint,
            "source": "xiji_cases.py 从格盘",
        })

    return cases


SPIKE_CASES: list[dict[str, Any]] = _build_spike_cases()

# 配额断言(启动时校验,数量不对立即报错)
_NORMAL_COUNT = sum(1 for c in SPIKE_CASES if c["category"] == "normal")
_SPECIAL_COUNT = sum(1 for c in SPIKE_CASES if c["category"] == "special_pattern")
assert len(SPIKE_CASES) == 20, f"期望 20 盘,实际 {len(SPIKE_CASES)}"
assert _NORMAL_COUNT == 15, f"期望 15 普通盘,实际 {_NORMAL_COUNT}"
assert _SPECIAL_COUNT == 5, f"期望 5 special_pattern,实际 {_SPECIAL_COUNT}"


def parse_birth(birth_str: str) -> datetime:
    """ISO 8601 → datetime(aware)。"""
    return datetime.fromisoformat(birth_str)
