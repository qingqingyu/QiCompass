"""八字排盘主引擎 —— lunar_python 封装核心。

所有排盘逻辑集中在 BaziEngine.calculate(),路由层不直接调用 lunar_python。
- 强制 setSect(1)(坑1:库默认 sect=2 与产品决策冲突)
- 真太阳时调整后用于排盘
- contentHash 用输入时间(原值,非真太阳时)
- 同步 CPU-bound 函数,API 层用 run_in_threadpool 包
- 决策 1 喜忌(扶抑+调候+从格检测)+ 决策 2 神煞(《三命通会》20 个)在此集成
"""

from __future__ import annotations

import logging
import time
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
    GAN_ELEMENT,
    build_auxiliary_gong,
    build_pillars,
    compute_element_balance,
)
from ..engine.shensha import compute_shensha
from ..engine.xiji import compute_xiji
from ..errors import BaziCalculationFailedError

logger = logging.getLogger(__name__)

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
        content_hash: str | None = None
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

            # 3.5 contentHash(提前算,供后续日志关联;用输入时间,非真太阳时)
            content_hash = compute_content_hash(
                birth=birth, gender=gender,
                longitude=longitude, zi_hour_rule=zi_hour_rule,
            )

            # 3.6 喜忌(决策 1:扶抑+调候+从格检测 D3)
            xiji_start = time.perf_counter()
            xiji = compute_xiji(pillars, element_balance)
            xiji_elapsed_ms = (time.perf_counter() - xiji_start) * 1000
            # day_element 仅用于日志;build_pillars 已校验 gan ∈ GAN_ELEMENT,
            # compute_xiji 内部 _element_of_gan 也会再次校验,这里不重复抛错
            day_element = GAN_ELEMENT.get(pillars.day.gan)
            logger.info(
                "bazi.xiji content_hash=%s day_gan=%s day_element=%s month_zhi=%s "
                "strength=%s score=%d tiaoshou=%s pattern=%s elapsed_ms=%.2f",
                content_hash, pillars.day.gan, day_element, pillars.month.zhi,
                xiji.day_master_strength, xiji.score, xiji.tiaoshou_applied,
                xiji.pattern_hint, xiji_elapsed_ms,
            )

            # 3.7 神煞(决策 2:《三命通会》20 个查表)
            shensha_start = time.perf_counter()
            shensha_items = compute_shensha(pillars, gender)
            shensha_elapsed_ms = (time.perf_counter() - shensha_start) * 1000
            logger.info(
                "bazi.shensha content_hash=%s hit_count=%d elapsed_ms=%.2f",
                content_hash, len(shensha_items), shensha_elapsed_ms,
            )

            # 4. 大运(跳 index=0)
            luck_pillars = build_luck_pillars(ec, gender)

            # 5. 流年/流日/流时 + 当前大运
            # birth.tzinfo 非 None 由 compute_true_solar_time 已保证(第 1 步会抛 ValueError)
            now_local = self._now.astimezone(birth.tzinfo)
            current_year = build_current_year_pillar(now_local)
            current_day = build_current_day_pillar(now_local)
            current_hour = build_current_hour_pillar(now_local)
            current_luck = locate_current_luck_pillar(luck_pillars, now_local)

            # 6. calcRuleSnapshot(确定性,不含 calculated_at)
            calc_rule_snapshot = build_calc_rule_snapshot(
                sect=SECT, zi_hour_rule=zi_hour_rule,
                longitude=longitude, offset_minutes=solar_result.offset_minutes,
            )

            # 7. boundary_warning
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
                # 决策 1 喜忌(确定性规则引擎输出)
                "favorable_elements": xiji.favorable_elements,
                "unfavorable_elements": xiji.unfavorable_elements,
                "day_master_strength": xiji.day_master_strength,
                "tiaoshou_applied": xiji.tiaoshou_applied,
                "xiji_method": xiji.xiji_method,
                "pattern_hint": xiji.pattern_hint,
                # 决策 2 神煞(《三命通会》20 个查表)
                "shensha": [s.model_dump() for s in shensha_items],
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
            # 不静默吞:把 lunar_python / 规则引擎 / 任何异常向上抛为结构化错误
            if isinstance(e, BaziCalculationFailedError):
                if e.content_hash is None and content_hash is not None:
                    e.content_hash = content_hash
                raise
            raise BaziCalculationFailedError(
                f"排盘计算失败: {type(e).__name__}: {e}",
                content_hash=content_hash,
            ) from e


def _format_boundary_warning(boundary_crossed: set[str]) -> str | None:
    """把跨边界集合拼成人类可读 warning。无跨越 → None。"""
    if not boundary_crossed:
        return None
    ordered = [b for b in ("时辰", "日", "月", "年") if b in boundary_crossed]
    return "真太阳时调整导致跨越边界:" + "/".join(ordered)
