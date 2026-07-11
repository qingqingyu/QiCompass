"""八字排盘主引擎 —— lunar_python 封装核心。

所有排盘逻辑集中在 BaziEngine.calculate(),路由层不直接调用 lunar_python。
- 强制 setSect(1)(坑1:库默认 sect=2 与产品决策冲突)
- 真太阳时调整后用于排盘
- contentHash 用输入时间(原值,非真太阳时)
- 同步 CPU-bound 函数,API 层用 run_in_threadpool 包
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any

from lunar_python import Solar

from ..core.calc_rule_snapshot import build_calc_rule_snapshot
from ..core.content_hash import compute_content_hash
from ..core.true_solar_time import compute_true_solar_time
from ..engine.current import (
    build_current_day_pillar,
    build_current_hour_pillar,
    build_current_year_pillar,
    locate_current_luck_pillar,
)
from ..engine.luck import build_luck_pillars
from ..engine.pillars import (
    build_auxiliary_gong,
    build_pillars,
    compute_element_balance,
)
from ..errors import BaziCalculationFailedError

# 本项目固定 sect=1(坑1:库默认 sect=2 早晚子时,与「默认 23:00 换日」冲突)
SECT = 1


class BaziEngine:
    """八字排盘引擎。同步 CPU-bound,API 层应放进线程池跑。

    Args:
        now: 用于计算 current_*_pillar 的「当前时间」。测试时注入固定值。
             None → datetime.now(timezone.utc)
    """

    def __init__(self, *, now: datetime | None = None):
        self._now = now if now is not None else datetime.now(timezone.utc)

    def calculate(self, *, birth: datetime, gender: str,
                  longitude: float, zi_hour_rule: str) -> dict[str, Any]:
        """主流程。返回结构化 dict(API 层转 BaziCalculateResponse)。

        Raises:
            BaziCalculationFailedError: lunar_python 内部异常(不吞,向上抛)
        """
        try:
            # 1. 真太阳时调整(用于排盘)
            solar_result = compute_true_solar_time(birth, longitude)
            adjusted = solar_result.adjusted

            # 2. lunar_python 排盘(用真太阳时调整后的时间)
            # lunar_python 按本地日历组件算,naive datetime 即可
            adjusted_naive = adjusted.replace(tzinfo=None)
            ec = Solar.fromDate(adjusted_naive).getLunar().getEightChar()
            ec.setSect(SECT)  # 强制(坑1)

            # 3. 四柱 + 命宫/身宫/胎元 + 五行
            pillars = build_pillars(ec)
            ming_gong, shen_gong, tai_yuan = build_auxiliary_gong(ec)
            element_balance = compute_element_balance(pillars)

            # 4. 大运(跳 index=0)
            luck_pillars = build_luck_pillars(ec, gender)

            # 5. 流年/流日/流时 + 当前大运
            now_local = self._now.astimezone(birth.tzinfo) if birth.tzinfo else self._now
            current_year = build_current_year_pillar(now_local)
            current_day = build_current_day_pillar(now_local)
            current_hour = build_current_hour_pillar(now_local)
            current_luck = locate_current_luck_pillar(luck_pillars, now_local)

            # 6. contentHash(用输入时间,非真太阳时)
            content_hash = compute_content_hash(
                birth=birth, gender=gender,
                longitude=longitude, zi_hour_rule=zi_hour_rule,
            )

            # 7. calcRuleSnapshot(确定性,不含 calculated_at)
            calc_rule_snapshot = build_calc_rule_snapshot(
                sect=SECT, zi_hour_rule=zi_hour_rule,
                longitude=longitude, offset_minutes=solar_result.offset_minutes,
            )

            # 8. boundary_warning
            boundary_warning = _format_boundary_warning(solar_result.boundary_crossed)

            return {
                "content_hash": content_hash,
                "true_solar_time": adjusted,
                "true_solar_offset_minutes": solar_result.offset_minutes,
                "pillars": pillars.model_dump(),
                "ming_gong": ming_gong.model_dump(),
                "shen_gong": shen_gong.model_dump(),
                "tai_yuan": tai_yuan.model_dump(),
                "element_balance": element_balance.model_dump(),
                # 决策 1 喜忌占位(后续 slice)
                "favorable_elements": [],
                "unfavorable_elements": [],
                "day_master_strength": None,
                "tiaoshou_applied": False,
                # 决策 2 神煞占位(独立 slice)
                "shensha": [],
                "luck_pillars": [lp.model_dump() for lp in luck_pillars],
                "current_luck_pillar": (
                    current_luck.model_dump() if current_luck else None
                ),
                "current_year_pillar": current_year,
                "current_day_pillar": current_day,
                "current_hour_pillar": current_hour,
                "calc_rule_snapshot": calc_rule_snapshot,
                "boundary_warning": boundary_warning,
            }
        except Exception as e:
            # 不静默吞:把 lunar_python / 任何异常向上抛为结构化错误
            if isinstance(e, BaziCalculationFailedError):
                raise
            raise BaziCalculationFailedError(
                f"排盘计算失败: {type(e).__name__}: {e}"
            ) from e


def _format_boundary_warning(boundary_crossed: set[str]) -> str | None:
    """把跨边界集合拼成人类可读 warning。无跨越 → None。"""
    if not boundary_crossed:
        return None
    ordered = [b for b in ("时辰", "日", "月", "年") if b in boundary_crossed]
    return "真太阳时调整导致跨越边界:" + "/".join(ordered)
