"""对盘主测试:库层 20 + 封装层 10,共 30 用例。

库层:验证 lunar_python 1.4.8 与上游 LunarTest.py 期望一致。
封装层:验证 BaziEngine 正确封装 lunar_python(四柱 + 大运)。
"""

from __future__ import annotations

import re

import pytest
from lunar_python import Lunar, Solar

from app.engine.bazi_engine import BaziEngine
from tests.fixtures.eightchar_test_cases import EIGHTCHAR_CASES
from tests.fixtures.lunar_test_cases import LUNAR_CASES
from tests.fixtures.yun_test_cases import YUN_CASES

_BUILDERS = {"Solar": Solar, "Lunar": Lunar}
# 方法链白名单:只允许 obj.xxx().yyy()[i] 形式(防 eval 注入)
_CHAIN_RE = re.compile(r"^obj(?:\.[a-zA-Z_]\w*\(\))*(?:\[\d+\])?$")


def _eval_chain(obj, chain: str):
    """安全执行方法链(白名单校验,无 __builtins__)。"""
    if not _CHAIN_RE.match(chain):
        raise ValueError(f"非法方法链: {chain}")
    return eval(chain, {"__builtins__": {}}, {"obj": obj})


# ===== 库层对盘 20 用例 =====


@pytest.mark.parametrize(
    "case", LUNAR_CASES, ids=[c["name"] for c in LUNAR_CASES]
)
def test_lunar_lib_dui_pan(case):
    """库层:相同输入调 lunar_python,对比上游 LunarTest.py 期望。"""
    cls_name, method, args = case["build"]
    # fromYmdHms 需要 6 参数(含秒),fixture 提取时省略了秒=0,这里补齐
    if method == "fromYmdHms" and len(args) == 5:
        args = (*args, 0)
    obj = getattr(_BUILDERS[cls_name], method)(*args)
    for chain, expected in case["checks"]:
        actual = _eval_chain(obj, chain)
        assert actual == expected, (
            f"{case['name']}: {chain} 期望 {expected!r}, 实得 {actual!r}"
        )


# ===== 封装层四柱对盘 7 用例 =====


@pytest.mark.parametrize(
    "case", EIGHTCHAR_CASES, ids=[c["name"] for c in EIGHTCHAR_CASES]
)
def test_eightchar_pillars(case, fixed_now):
    """封装层四柱:对比 pillars.{year,month,day,hour}.gan_zhi。"""
    from datetime import datetime

    inp = case["input"]
    birth = datetime.fromisoformat(inp["birth_datetime"])
    engine = BaziEngine(now=fixed_now)
    result = engine.calculate(
        birth=birth,
        gender=inp["gender"],
        longitude=inp["longitude"],
        zi_hour_rule=inp["zi_hour_rule"],
    )
    pillars = result["pillars"]
    expected = case["expected_pillars"]
    for key in ("year", "month", "day", "hour"):
        actual_gz = pillars[key]["gan_zhi"]
        assert actual_gz == expected[key], (
            f"{case['name']}: 柱{key} 期望 {expected[key]}, 实得 {actual_gz}"
        )


# ===== 封装层大运对盘 3 用例 =====


@pytest.mark.parametrize("case", YUN_CASES, ids=[c["name"] for c in YUN_CASES])
def test_yun_first_luck_pillar(case, fixed_now):
    """封装层大运:验证 luck_pillars[0] (已跳 index=0 童限)。"""
    from datetime import datetime

    inp = case["input"]
    birth = datetime.fromisoformat(inp["birth_datetime"])
    engine = BaziEngine(now=fixed_now)
    result = engine.calculate(
        birth=birth,
        gender=inp["gender"],
        longitude=inp["longitude"],
        zi_hour_rule=inp["zi_hour_rule"],
    )
    luck = result["luck_pillars"]
    assert len(luck) > 0, f"{case['name']}: luck_pillars 为空"
    first = luck[0]
    expected = case["expected_first_luck"]
    for key in ("gan_zhi", "start_year", "end_year", "start_age", "end_age"):
        assert first[key] == expected[key], (
            f"{case['name']}: luck[0].{key} 期望 {expected[key]}, 实得 {first[key]}"
        )
