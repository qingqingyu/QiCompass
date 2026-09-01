"""规则快照(calcRuleSnapshot)——确定性。

关键约束(CLAUDE.md):同一输入永远同一输出。
→ 不含 calculated_at(时间戳会破坏完全确定性)
→ 时间戳进日志,不进快照
"""

from __future__ import annotations

from ..config import LUNAR_PYTHON_VERSION, SCHEMA_VERSION


def build_calc_rule_snapshot(sect: int, zi_hour_rule: str,
                              longitude: float,
                              offset_minutes: float,
                              birth_timezone: str | None = None,
                              hour_known: bool = True,
                              pillar_ambiguity: dict | None = None) -> dict:
    """构造 calcRuleSnapshot。

    Args:
        sect: lunar_python sect 参数(本项目固定 1)
        zi_hour_rule: 子时规则
        longitude: 真太阳时所用经度
        offset_minutes: 真太阳时偏移分钟数
        birth_timezone: 出生地 IANA 时区名(S02 契约,审计/展示用;可为 None)
        hour_known: 排盘是否含时柱(时辰未知 S01;缺此字段则补时辰前后
                    无法从快照分辨,「同一输入永远同一输出 + 快照可审计」被破坏)。
                    默认 True。S09 起每日运势链路接真实值(engine/daily_fortune
                    由 chart_payload.day_master_strength 推导,不再恒 True)
        pillar_ambiguity: 柱歧义标记(时辰未知 S02/D10,形如
                    {"year": bool, "month": bool, "day": bool})。hour_known
                    =false 时必传(全 False = 无歧义);默认 None =
                    已知时辰(老调用方零改动,快照不含该概念)。
                    例外:每日运势链路 hour_known=false 时也恒 None——该链路
                    无出生数据可判歧义,歧义盘按决策 D5 在客户端全拦不调
                    (S09 docs/时辰未知-slices/S09)

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
        "birth_timezone": birth_timezone,
        "hour_known": hour_known,
        "pillar_ambiguity": pillar_ambiguity,
    }
