"""规则快照(calcRuleSnapshot)——确定性。

关键约束(CLAUDE.md):同一输入永远同一输出。
→ 不含 calculated_at(时间戳会破坏完全确定性)
→ 时间戳进日志,不进快照
"""

from __future__ import annotations

from ..config import LUNAR_PYTHON_VERSION, SCHEMA_VERSION


def build_calc_rule_snapshot(sect: int, zi_hour_rule: str,
                              longitude: float,
                              offset_minutes: float) -> dict:
    """构造 calcRuleSnapshot。

    Args:
        sect: lunar_python sect 参数(本项目固定 1)
        zi_hour_rule: 子时规则
        longitude: 真太阳时所用经度
        offset_minutes: 真太阳时偏移分钟数

    Returns:
        dict,可直接作为响应字段
    """
    return {
        "library": f"lunar_python {LUNAR_PYTHON_VERSION}",
        "sect": sect,
        "zi_hour_rule": zi_hour_rule,
        "true_solar_longitude": round(longitude, 6),
        "true_solar_offset_minutes": round(offset_minutes, 2),
        "schema_version": SCHEMA_VERSION,
    }
