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
from ..models.bazi import MetaBlock

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
            lunar = Solar.fromDate(adjusted_naive).getLunar()
            ec = lunar.getEightChar()
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

            # 8. anchor sentence(2026-08-01 grill-me 决策 #13)
            # 后端确定性拼接(0 AI 成本),iOS 深度解析 Tab 顶部 instant 显示
            anchor_sentence = _build_anchor_sentence(
                day_gan=pillars.day.gan,
                day_gan_element=pillars.day.gan_element,
                day_master_strength=xiji.day_master_strength,
                favorable=xiji.favorable_elements,
                unfavorable=xiji.unfavorable_elements,
            )

            # 9. v1 prompt 系统:meta 块 + chart 注入字段
            meta_block = _build_meta_block(
                lunar=lunar,
                gender=gender,
                birth=birth,
                adjusted=adjusted,
                zi_hour_rule=zi_hour_rule,
            )

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
                # 决策 #13 anchor sentence
                "anchor_sentence": anchor_sentence,
                # v1 prompt 系统:M0 chart 注入字段
                "ten_god_weights": xiji.ten_god_weights,
                "useful_god_candidates": xiji.useful_god_candidates,
                "meta": meta_block.model_dump(),
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


# 2026-08-01 grill-me 决策 #13:chart anchor sentence 后端确定性拼接
# 覆盖 xiji.compute_xiji 全部 4 个返回值 + None 兜底(理论上 compute_xiji 必返回非 None,
# 但 BaziCalculateResponse.day_master_strength 类型为 str | None,这里显式列 None 防御)
_STRENGTH_LABEL: dict[str | None, str] = {
    "strong": "偏旺",
    "weak": "偏弱",
    "balanced": "中和",
    "special_pattern": "呈现从格特征",
    None: "旺衰未判定",
}


def _build_anchor_sentence(
    day_gan: str,
    day_gan_element: str,
    day_master_strength: str | None,
    favorable: list[str],
    unfavorable: list[str],
) -> str:
    """构建深度解析 Tab 顶部 anchor sentence(0 AI 成本,纯字符串拼接)。

    模板(用户 Q2 拍板 A 完整版):
      "你的日主是 {day_gan}（{day_gan_element}），命局整体 {label}，喜 {a/b}、忌 {x/y}。"

    **从格诚实降级**(对齐 CLAUDE.md "从格检测…LLM 诚实告知"):
    day_master_strength == "special_pattern" 时,只输出"呈现从格特征",
    不下硬性喜忌结论(避免编造扶抑法喜忌)。

    Args:
        day_gan: 日柱天干(如 "庚")
        day_gan_element: 日主五行(如 "金")
        day_master_strength: strong / weak / balanced / special_pattern / None
        favorable: 喜用五行 list(如 ["火", "土"])
        unfavorable: 忌讳五行 list(如 ["水", "金"])

    Returns:
        拼接好的 anchor sentence,始终非空(至少含日主 + 五行 + label)

    Note:
        用 .get(default="旺衰未判定") 而非 [] strict 查找 —— xiji 未来可能扩展新 strength
        取值(如极旺/极弱),strict 会让 anchor 生成抛 KeyError 中断整个排盘。anchor 是
        辅助显示,strength 扩展时 anchor 自动降级到"旺衰未判定"是可接受 graceful degrade。
        真正的契约违反(未知 strength)由 xiji 自身的 Literal 类型注解 + mypy 在编译期捕获。
    """
    label = _STRENGTH_LABEL.get(day_master_strength, "旺衰未判定")
    base = f"你的日主是 **{day_gan}**（{day_gan_element}），命局整体 **{label}**"

    # 从格诚实降级:不下硬性喜忌
    if day_master_strength == "special_pattern":
        return base + "。"

    # 防御:喜/忌任一为空(理论上普通盘不应为空,但保护)
    parts: list[str] = []
    if favorable:
        parts.append("**喜** " + "/".join(favorable))
    if unfavorable:
        parts.append("**忌** " + "/".join(unfavorable))

    if not parts:
        return base + "。"
    return base + "，" + "、".join(parts) + "。"


# v1 prompt 系统 §1 chart.meta 块
# zi_hour_rule API 字面值 → meta.late_zishi_rule 映射
# 当前 MVP 只支持 zi_next_day(对应 setSect(1) + day_change_at_23);
# zi_same_day 留作未来扩展占位,TypeSystem 已 Literal 约束。
# TODO(未来扩展 zi_same_day):若开放 zi_same_day,必须同时调整 SECT 常量
# (zi_same_day 对应 setSect(2) 早晚子时),且 BaziCalculateRequest Literal
# 需扩展;否则 meta 映射会与排盘规则脱钩。
_ZI_HOUR_RULE_TO_META: dict[str, str] = {
    "zi_next_day": "day_change_at_23",
    "zi_same_day": "zi_same_day",
}


def _build_meta_block(
    *,
    lunar: Any,
    gender: str,
    birth: datetime,
    adjusted: datetime,
    zi_hour_rule: str,
) -> MetaBlock:
    """构建 v1 prompt 系统 chart.meta 块(确定性,无 LLM)。

    字段说明:
    - locale: 固定 "zh-CN"(产品当前仅中文)
    - gender: 入参 male/female 透传
    - birth_local: 用户输入的出生时间(含时区 ISO 8601)
    - true_solar_time: 真太阳时调整后的本地时间(ISO 8601 naive)
    - late_zishi_rule: 从 zi_hour_rule 映射,v1 语义统一为 "day_change_at_23"
    - solar_term_boundary: 上一个节/气名 + "后"(从 lunar.getPrevJieQi() 取,
      返回 24 节气中的任一个;注意:非严格月界"节",含月中"气",供 LLM 上下文参考)

    Args:
        lunar: lunar_python Lunar 对象(用于节气查询)
        gender: "male" / "female"
        birth: 输入时间(offset-aware)
        adjusted: 真太阳时调整后时间(offset-aware,会剥离时区序列化)
        zi_hour_rule: "zi_next_day" / "zi_same_day"

    Raises:
        ValueError: zi_hour_rule 未在 _ZI_HOUR_RULE_TO_META 中(防御 — 应该不可达,
            BaziCalculateRequest 的 Literal 已约束;但显式抛错避免静默走默认值)
    """
    late_zishi_rule = _ZI_HOUR_RULE_TO_META.get(zi_hour_rule)
    if late_zishi_rule is None:
        raise ValueError(
            f"未知 zi_hour_rule: {zi_hour_rule!r},无法映射为 meta.late_zishi_rule"
        )

    # 节气边界:lunar.getPrevJieQi() 返回 JieQi 对象,getName() 拿节气名
    prev_jieqi = lunar.getPrevJieQi()
    if prev_jieqi is None:
        # 理论上不可达(任何日期都有前一个节气),防御抛错不静默
        raise ValueError(
            f"lunar.getPrevJieQi() 返回 None,无法计算 solar_term_boundary: {adjusted!r}"
        )
    solar_term_boundary = f"{prev_jieqi.getName()}后"

    # 微秒剥离对齐 BaziCalculateResponse.true_solar_time 的 field_serializer(去微秒)
    # iOS .iso8601 dateDecodingStrategy 不支持小数秒,两处必须保持一致
    return MetaBlock(
        locale="zh-CN",
        gender=gender,
        birth_local=birth.replace(microsecond=0).isoformat(),
        true_solar_time=adjusted.replace(microsecond=0, tzinfo=None).isoformat(),
        late_zishi_rule=late_zishi_rule,
        solar_term_boundary=solar_term_boundary,
    )
