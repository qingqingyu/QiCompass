"""喜忌 50 命盘 fixture(决策 1 验收)。

45 个普通盘(strong/weak/balanced)+ 5 个 special_pattern 盘(专旺/从格)。
special_pattern 占 10%,符合决策 1b 验收标准。

经度统一 120.0(东八区中心,消除经度时差,只留 EoT 均时差)。
expected strength 由 BaziEngine(经真太阳时调整)实跑确认,非手算。

分布:
- strong: 22 | balanced: 9 | weak: 14 | special_pattern: 5
- 月份全覆盖(含子/丑/午/未调候月)

【标定说明】权重/阈值为初值(DELING=5/DEDI_MAIN=2/DEDI_RESIDUAL=1/DESHI=1,
STRONG>=6/WEAK<=3/ZHUANWANG>=6/CONG>=5)。50 盘分布达 90/10 目标。
后续若调整权重/阈值,需同步更新本 fixture 的 expected。
"""

from __future__ import annotations

# ---------- 45 个普通盘(扶抑+调候) ----------
# (birth_datetime, gender, expected_strength)

_NORMAL_CASES: list[tuple[str, str, str]] = [
    ("1985-01-10T10:30:00+08:00", "male", "strong"),
    ("1985-02-10T10:30:00+08:00", "female", "balanced"),
    ("1985-03-10T10:30:00+08:00", "male", "weak"),
    ("1985-04-10T10:30:00+08:00", "female", "strong"),
    ("1985-05-10T10:30:00+08:00", "male", "strong"),
    ("1985-06-10T10:30:00+08:00", "female", "weak"),
    ("1985-07-10T10:30:00+08:00", "male", "strong"),
    ("1985-08-10T10:30:00+08:00", "female", "strong"),
    ("1985-09-10T10:30:00+08:00", "male", "strong"),
    ("1985-10-10T10:30:00+08:00", "female", "weak"),
    ("1985-11-10T10:30:00+08:00", "male", "strong"),
    ("1985-12-10T10:30:00+08:00", "female", "balanced"),
    ("1990-01-10T10:30:00+08:00", "male", "weak"),
    ("1990-02-10T10:30:00+08:00", "female", "strong"),
    ("1990-03-10T10:30:00+08:00", "male", "balanced"),
    ("1990-04-10T10:30:00+08:00", "female", "weak"),
    ("1990-05-10T10:30:00+08:00", "male", "weak"),
    ("1990-06-10T10:30:00+08:00", "female", "strong"),
    ("1990-07-10T10:30:00+08:00", "male", "weak"),
    ("1990-08-10T10:30:00+08:00", "female", "balanced"),
    ("1990-09-10T10:30:00+08:00", "male", "weak"),
    ("1990-10-10T10:30:00+08:00", "female", "strong"),
    ("1990-11-10T10:30:00+08:00", "male", "weak"),
    ("1990-12-10T10:30:00+08:00", "female", "weak"),
    ("1995-01-10T10:30:00+08:00", "male", "strong"),
    ("1995-02-10T10:30:00+08:00", "female", "weak"),
    ("1995-03-10T10:30:00+08:00", "male", "weak"),
    ("1995-04-10T10:30:00+08:00", "female", "strong"),
    ("1995-05-10T10:30:00+08:00", "male", "balanced"),
    ("1995-06-10T10:30:00+08:00", "female", "balanced"),
    ("1995-07-10T10:30:00+08:00", "male", "weak"),
    ("1995-08-10T10:30:00+08:00", "female", "strong"),
    ("1995-09-10T10:30:00+08:00", "male", "balanced"),
    ("1995-10-10T10:30:00+08:00", "female", "weak"),
    ("1995-11-10T10:30:00+08:00", "male", "strong"),
    ("1995-12-10T10:30:00+08:00", "female", "strong"),
    ("2000-01-10T10:30:00+08:00", "male", "balanced"),
    ("2000-02-10T10:30:00+08:00", "female", "balanced"),
    ("2000-03-10T10:30:00+08:00", "male", "strong"),
    ("2000-04-10T10:30:00+08:00", "female", "strong"),
    ("2000-05-10T10:30:00+08:00", "male", "strong"),
    ("2000-06-10T10:30:00+08:00", "female", "strong"),
    ("2000-07-10T10:30:00+08:00", "male", "strong"),
    ("2000-08-10T10:30:00+08:00", "female", "strong"),
    ("2000-09-10T10:30:00+08:00", "male", "strong"),
]

# ---------- 5 个 special_pattern 盘(专旺/从格) ----------
# (birth_datetime, gender, expected_pattern_hint)
# 专旺:日主同气五行 >= 6;从格:日主孤立 + 某行 >= 5

_SPECIAL_CASES: list[tuple[str, str, str]] = [
    # 专旺水:癸卯 癸亥 癸亥 壬子,water=7
    ("1903-12-01T00:30:00+08:00", "male", "zhuanwang"),
    # 专旺火:丙午 甲午 丙午 甲午,fire=6
    ("1906-07-01T12:30:00+08:00", "male", "zhuanwang"),
    # 从格(火):丙午 丁酉 壬戌 丙午,日主壬水孤立,fire=5
    ("1906-09-15T12:30:00+08:00", "female", "cong"),
    # 从格(水):壬子 壬寅 丙子 戊子,日主丙火孤立,water=5
    ("1912-03-01T00:30:00+08:00", "male", "cong"),
    # 从格(土):己未 戊辰 癸丑 戊午,日主癸水孤立,earth=6
    ("1919-05-01T12:30:00+08:00", "female", "cong"),
]


def _build_cases() -> list[dict]:
    cases: list[dict] = []
    for birth, gender, strength in _NORMAL_CASES:
        cases.append({
            "birth_datetime": birth,
            "gender": gender,
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
            "expected": {"strength": strength},
        })
    for birth, gender, pattern in _SPECIAL_CASES:
        cases.append({
            "birth_datetime": birth,
            "gender": gender,
            "longitude": 120.0,
            "zi_hour_rule": "zi_next_day",
            "expected": {"strength": "special_pattern", "pattern_hint": pattern},
        })
    return cases


XIJI_CASES: list[dict] = _build_cases()
