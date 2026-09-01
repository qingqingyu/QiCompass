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
from ..core.true_solar_time import (
    compute_true_solar_time,
    day_pillar_candidate_wall_interval,
)
from ..engine.current import (
    build_current_day_pillar,
    build_current_hour_pillar,
    build_current_year_pillar,
    locate_current_luck_pillar,
)
from ..engine.branch_relations import compute_friends_and_clash
from ..engine.luck import build_luck_pillars
from ..engine.pillar_ambiguity import detect_pillar_ambiguity
from ..engine.pillars import (
    GAN_ELEMENT,
    build_auxiliary_gong,
    build_pillars,
    compute_element_balance,
    compute_year_zodiac,
)
from ..engine.shensha import compute_shensha
from ..engine.xiji import compute_xiji
from ..errors import BaziCalculationFailedError
from ..models.bazi import MetaBlock

logger = logging.getLogger(__name__)

# 本项目固定 sect=1(坑1:库默认 sect=2 早晚子时,与「默认 23:00 换日」冲突)
SECT = 1

# 时辰未知占位时刻(docs/时辰未知设计决策.md D3,2026-09-01 修订):
# 取候选墙钟区间的**中点**——否 [00:00,23:00) → 11:30 / 是 [23:00,24:00)
# → 23:30 / 不确定 [00:00,24:00) → 12:00。
# 为什么是中点而不是固定 12:00:D3 区间测试判日柱「确定」时,中点保证
# 占位时刻的真太阳时必落在该确定日柱的区间内(「是」+东偏 → 23:30 落
# setSect(1) 换日窗 → 次日日柱;「是」+西偏(如喀什)→ 真太阳时 20:24
# → 同日),即占位推出的日柱 == 区间测试判定的日柱,是区间中点的性质
# 而非巧合。「不确定」→ 12:00 离 23:00/00:00 两个换日边界最远(此态
# 日柱恒歧义置 null,占位只影响年/月/大运起排)。
def hour_unknown_placeholder(birth: datetime,
                             late_night: bool | None) -> datetime:
    """时辰未知时把时辰部分统一替换为候选区间中点占位(保墙钟日期与时区)。

    API 层在 resolve_wall_time **之前**先归一(时制边角 dst_flags 不被
    无意义的时辰噪声触发);引擎内再归一一次(幂等,保证直调引擎的
    调用方同样满足「同一日期任意时辰输入 → 同一输出」)。中点选取理由见
    上方模块注释(与 true_solar_time.day_pillar_candidate_wall_interval
    的三态区间一一对应)。
    """
    if late_night is False:
        hour, minute = 11, 30   # 否:[00:00,23:00) 中点
    elif late_night is True:
        hour, minute = 23, 30   # 是:[23:00,24:00) 中点(落换日窗)
    else:
        hour, minute = 12, 0    # 不确定:[00:00,24:00) 中点
    return birth.replace(hour=hour, minute=minute, second=0, microsecond=0)


class BaziEngine:
    """八字排盘引擎。同步 CPU-bound,API 层应放进线程池跑。

    Args:
        now: 用于计算 current_*_pillar 的「当前时间」。测试时注入固定值。
             None → datetime.now(timezone.utc)
    """

    def __init__(self, *, now: datetime | None = None):
        self._now = now if now is not None else datetime.now(timezone.utc)

    def calculate(self, *, birth: datetime, gender: str,
                  longitude: float, zi_hour_rule: str,
                  dst_flags: frozenset[str] = frozenset(),
                  birth_timezone: str | None = None,
                  hour_known: bool = True,
                  late_night: bool | None = None) -> dict[str, Any]:
        """主流程。返回结构化 dict(API 层转 BaziCalculateResponse)。

        Args:
            birth: 出生绝对时刻(offset-aware)。钟面→绝对时刻的时区解释
                   在 API 层完成(app/core/tz_resolution,S02 契约),
                   引擎只消费 aware 时刻 —— 对盘 fixtures 直喂 aware 不变
            dst_flags: 时区解析边角(歧义/跳过/切换附近),并入 boundary_warning
            birth_timezone: 出生地 IANA 时区名(进 calc_rule_snapshot)
            hour_known: 是否知道出生时刻(docs/时辰未知设计决策.md)。False 时
                   时辰部分统一替换为候选区间中点占位喂 lunar_python
                   (否 11:30 / 是 23:30 / 不确定 12:00,见
                   hour_unknown_placeholder),响应 pillars.hour=null、
                   喜忌 unknown_hour、五行按已知柱计数;并做 D10 节气边界
                   双排盘比对(S02):年/月柱干支在 00:00 与 23:59 探针间
                   不一致 → 该柱亦置 null;日柱走 D3 区间测试
                   (true_solar_time.day_pillar_ambiguous,2026-09-01 修订,
                   拆掉旧「late_night != False 恒 unknown」与「offset < −60
                   西偏网」判据)→ 命中则日柱置 null;歧义状态进
                   pillar_ambiguity / calc_rule_snapshot / content_hash
            late_night: 「半夜出生」三态(True=是 / False=否 / None=不确定),
                   仅 hour_known=False 时参与:决定候选墙钟区间(D3 第 1 步)
                   与占位中点;日柱歧义 ⟺ 真太阳时候选区间内部严格包含一个
                   23:00 换日点(见 true_solar_time.day_pillar_ambiguous
                   场景表:西偏答「是」确定、东偏答「否」歧义)。
                   True 路径(hour_known=true)本参数被忽略且零改动

        Raises:
            BaziCalculationFailedError: lunar_python 内部异常(不吞,向上抛)
        """
        content_hash: str | None = None
        try:
            # 0. 时辰未知:候选区间中点占位归一(单一事实源 helper;API 层
            #    已归一,此处幂等执行,保证「同日期任意时辰输入 → 同一输出」)
            calc_birth = (birth if hour_known
                          else hour_unknown_placeholder(birth, late_night))

            # 0.5 D10 节气边界歧义检测(S02):仅时辰未知时发生(已知时辰
            #     零开销零改动)。年/月柱 = 00:00/23:59 双排盘比对;
            #     日柱 = D3 区间测试(late_night 三态 × offset,单一判据)
            pillar_ambiguity = (
                detect_pillar_ambiguity(
                    calc_birth=calc_birth, longitude=longitude,
                    late_night=late_night,
                ) if not hour_known else None
            )

            # 1. 真太阳时调整(用于排盘)
            solar_result = compute_true_solar_time(calc_birth, longitude)
            adjusted = solar_result.adjusted

            # 2. lunar_python 排盘(用真太阳时调整后的时间)
            # lunar_python 按本地日历组件算,naive datetime 即可
            adjusted_naive = adjusted.replace(tzinfo=None)
            lunar = Solar.fromDate(adjusted_naive).getLunar()
            ec = lunar.getEightChar()
            ec.setSect(SECT)  # 强制(坑1)

            # 3. 四柱 + 命宫/身宫/胎元 + 五行
            # 时辰未知:先按占位排满四柱拿年/月柱与辅助宫,再把未知柱显式
            # 置 null(占位时柱/歧义柱不冒充真实数据漏到响应)
            pillars = build_pillars(ec)
            day_pillar_unknown = (
                pillar_ambiguity is not None and pillar_ambiguity.day
            )
            if not hour_known:
                pillars.hour = None
                # D10 级联:歧义柱置 null(不猜,禁取任一探针侧结果)
                if pillar_ambiguity.year:
                    pillars.year = None
                if pillar_ambiguity.month:
                    pillars.month = None
                if day_pillar_unknown:
                    pillars.day = None
            ming_gong, shen_gong, tai_yuan = build_auxiliary_gong(ec)
            element_balance = compute_element_balance(pillars)

            # 3.1 生肖:年柱地支 → 英文生肖名(对齐 iOS Zodiac_*.imageset)
            # lunar_python 已按立春算 year.zhi,这里仅做查表(修正 iOS 客户端按公历年推算的立春边界 bug)
            # 年柱歧义(立春日 + 时辰未知,D10)→ 年支系派生(生肖/好朋友/
            # 需磨合)一并置 null,不猜(供 S08 生肖屏降级消费)
            if pillars.year is not None:
                year_branch_zodiac = compute_year_zodiac(pillars.year.zhi)

                # 3.2 生肖关系(2026-08-13 onboarding 反馈屏「好朋友 / 需磨合」):
                # 复用 branch_relations.py(合盘引擎同一事实源),地支 → 英文生肖名
                friends_zhi, clash_zhi = compute_friends_and_clash(
                    pillars.year.zhi,
                )
                year_branch_friends = [compute_year_zodiac(z) for z in friends_zhi]
                year_branch_clash = compute_year_zodiac(clash_zhi)
            else:
                year_branch_zodiac = None
                year_branch_friends = None
                year_branch_clash = None

            # 3.5 contentHash(提前算,供后续日志关联;用输入时间,非真太阳时。
            # 时辰未知时 birth 为区间中点占位归一值:时辰桶不参与,
            # 日期+late_night+歧义标记参与(S02))
            content_hash = compute_content_hash(
                birth=calc_birth, gender=gender,
                longitude=longitude, zi_hour_rule=zi_hour_rule,
                hour_known=hour_known, late_night=late_night,
                pillar_ambiguity=(
                    pillar_ambiguity.model_dump()
                    if pillar_ambiguity is not None else None
                ),
            )

            # 歧义审计留痕(S02):任一柱命中 → 记录终态与来源参数
            if pillar_ambiguity is not None and (
                pillar_ambiguity.year or pillar_ambiguity.month
                or pillar_ambiguity.day
            ):
                logger.info(
                    "bazi.pillar_ambiguity content_hash=%s year=%s month=%s "
                    "day=%s late_night=%s offset_minutes=%.2f",
                    content_hash, pillar_ambiguity.year,
                    pillar_ambiguity.month, pillar_ambiguity.day,
                    late_night, solar_result.offset_minutes,
                )

            # 3.6 喜忌(决策 1:扶抑+调候+从格检测 D3;时辰未知 → unknown_hour)
            xiji_start = time.perf_counter()
            xiji = compute_xiji(pillars, element_balance)
            xiji_elapsed_ms = (time.perf_counter() - xiji_start) * 1000
            # day_element 仅用于日志;build_pillars 已校验 gan ∈ GAN_ELEMENT,
            # compute_xiji 内部 _element_of_gan 也会再次校验,这里不重复抛错
            day_gan = pillars.day.gan if pillars.day is not None else None
            day_element = GAN_ELEMENT.get(day_gan) if day_gan else None
            month_zhi = pillars.month.zhi if pillars.month is not None else None
            logger.info(
                "bazi.xiji content_hash=%s day_gan=%s day_element=%s month_zhi=%s "
                "strength=%s score=%d tiaoshou=%s pattern=%s elapsed_ms=%.2f",
                content_hash, day_gan, day_element, month_zhi,
                xiji.day_master_strength, xiji.score, xiji.tiaoshou_applied,
                xiji.pattern_hint, xiji_elapsed_ms,
            )
            if day_pillar_unknown:
                # 审计留痕:日柱为何置 null(D3 区间测试命中,判据单一事实源
                # true_solar_time.day_pillar_ambiguous;命中输入与终态见
                # bazi.pillar_ambiguity 日志)。真太阳时候选区间用绝对分钟,
                # 允许跨午夜(不平移回绕)
                wall_start, wall_end = day_pillar_candidate_wall_interval(
                    late_night,
                )
                logger.info(
                    "bazi.day_pillar_unknown content_hash=%s late_night=%s "
                    "offset_minutes=%.2f "
                    "true_solar_interval=[%.1f,%.1f) "
                    "contains_changeover=True",
                    content_hash, late_night, solar_result.offset_minutes,
                    wall_start + solar_result.offset_minutes,
                    wall_end + solar_result.offset_minutes,
                )

            # 3.7 神煞(决策 2:《三命通会》20 个查表)
            shensha_start = time.perf_counter()
            shensha_items = compute_shensha(pillars, gender)
            shensha_elapsed_ms = (time.perf_counter() - shensha_start) * 1000
            logger.info(
                "bazi.shensha content_hash=%s hit_count=%d elapsed_ms=%.2f",
                content_hash, len(shensha_items), shensha_elapsed_ms,
            )

            # 4. 大运(跳 index=0)。时辰未知时干支序列照给(依赖表:不依赖时柱;
            #    起运年龄按区间中点占位换算,弱依赖误差 ±2-3 个月,v1 接受不加
            #    标注,docs/时辰未知设计决策.md D3 依赖表)。**月柱歧义例外**(S02/D10
            #    级联):大运从月柱起排,月柱 unknown → 干支序列置 unknown
            #    (空列表,不猜),current_luck_pillar 随之自然为 None
            if pillar_ambiguity is not None and pillar_ambiguity.month:
                luck_pillars = []
            else:
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
                birth_timezone=birth_timezone,
                hour_known=hour_known,
                pillar_ambiguity=(
                    pillar_ambiguity.model_dump()
                    if pillar_ambiguity is not None else None
                ),
            )

            # 7. boundary_warning(真太阳时跨边界 + 时区解析边角,不静默吞)
            boundary_warning = _format_boundary_warning(
                solar_result.boundary_crossed, dst_flags,
            )

            # 8. anchor sentence(2026-08-01 grill-me 决策 #13)
            # 后端确定性拼接(0 AI 成本),iOS 深度解析 Tab 顶部 instant 显示
            # 日柱歧义 → 日主无,anchor 是日主句,整体置 None(不硬造)
            if pillars.day is None:
                anchor_sentence = None
            else:
                anchor_sentence = _build_anchor_sentence(
                    day_gan=pillars.day.gan,
                    day_gan_element=pillars.day.gan_element,
                    day_master_strength=xiji.day_master_strength,
                    favorable=xiji.favorable_elements,
                    unfavorable=xiji.unfavorable_elements,
                )

            # 9. v1 prompt 系统:meta 块 + chart 注入字段
            # 时辰未知 → meta=None:birth_local/true_solar_time 都是时辰精确
            # 字段,基于占位的值属假精度,不漏到响应(降级 prompt 上下文由
            # S06 按章节策略另行定义)
            if hour_known:
                meta_block = _build_meta_block(
                    lunar=lunar,
                    gender=gender,
                    birth=birth,
                    adjusted=adjusted,
                    zi_hour_rule=zi_hour_rule,
                )
            else:
                meta_block = None

            return {
                "content_hash": content_hash,
                # 时辰未知:真太阳时含时辰信息,占位值不漏到响应
                "true_solar_time": adjusted if hour_known else None,
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
                # 决策 2 神煞(《三命通会》20 个查表,按可用柱)
                "shensha": [s.model_dump() for s in shensha_items],
                # 时辰未知:神煞按可用柱查(时/日/月/年柱系查表基准缺失的
                # 条目自然不出),显式标注不静默
                "shensha_incomplete": any(
                    p is None
                    for p in (pillars.year, pillars.month,
                              pillars.day, pillars.hour)
                ),
                # 决策 #13 anchor sentence
                "anchor_sentence": anchor_sentence,
                # v1 prompt 系统:M0 chart 注入字段
                "ten_god_weights": xiji.ten_god_weights,
                "useful_god_candidates": xiji.useful_god_candidates,
                "meta": meta_block.model_dump() if meta_block is not None else None,
                # 生肖(英文,对齐 iOS Zodiac_*.imageset):lunar_python 已按立春算
                # 年柱歧义(立春日 + 时辰未知,D10)→ null,不猜(供 S08 降级)
                "year_branch_zodiac": year_branch_zodiac,
                # 生肖关系(2026-08-13 onboarding 反馈屏):好朋友 3 + 需磨合 1;
                # 年柱歧义时随年支系派生一并置 null
                "year_branch_friends": year_branch_friends,
                "year_branch_clash": year_branch_clash,
                # 时辰未知 S02/D10:柱歧义标记(None = 已知时辰老路径,不变)
                "pillar_ambiguity": (
                    pillar_ambiguity.model_dump()
                    if pillar_ambiguity is not None else None
                ),
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


def _format_boundary_warning(boundary_crossed: set[str],
                             dst_flags: frozenset[str] | set[str] = frozenset(),
                             ) -> str | None:
    """把跨边界集合 + 时区边角拼成人类可读 warning。两者皆空 → None。

    dst_flags 语义(docs/城市搜索设计决策.md Q5,错误显式传播):
    - dst_ambiguous: 钟面在秋令时回拨段重复出现,已按较早的一次解释
    - dst_nonexistent: 钟面在春令时跳过段不存在,已按切换前偏移解释
    - dst_transition: 出生时间处于时制切换点附近
    """
    parts: list[str] = []
    if boundary_crossed:
        ordered = [b for b in ("时辰", "日", "月", "年") if b in boundary_crossed]
        parts.append("真太阳时调整导致跨越边界:" + "/".join(ordered))
    dst_notes: list[str] = []
    if "dst_ambiguous" in dst_flags:
        dst_notes.append("该时间在当年重复出现过(夏令时回拨),已按较早的一次解释")
    if "dst_nonexistent" in dst_flags:
        dst_notes.append("该时间在当年不存在(夏令时跳过),已按切换前偏移解释")
    if "dst_transition" in dst_flags:
        dst_notes.append("出生时间处于时制切换点附近")
    if dst_notes:
        # 中文文案标点对齐 anchor sentence(全角标点)
        parts.append("；".join(dst_notes) + "，请核对原始出生记录")
    return " ".join(parts) if parts else None


# 2026-08-01 grill-me 决策 #13:chart anchor sentence 后端确定性拼接
# 覆盖 xiji.compute_xiji 全部 4 个返回值 + None 兜底(理论上 compute_xiji 必返回非 None,
# 但 BaziCalculateResponse.day_master_strength 类型为 str | None,这里显式列 None 防御)
_STRENGTH_LABEL: dict[str | None, str] = {
    "strong": "偏旺",
    "weak": "偏弱",
    "balanced": "中和",
    "special_pattern": "呈现从格特征",
    "unknown_hour": "时辰未知,旺衰未判定",
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
        day_master_strength: strong / weak / balanced / special_pattern /
                             unknown_hour / None(日柱歧义时调用方直接置
                             anchor=None,不会进本函数)
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

    # 时辰未知降级(D4):旺衰/喜忌均未判定,不走「命局整体」句式
    # (日主本身已知,anchor 仍给日主半句)
    if day_master_strength == "unknown_hour":
        return (
            f"你的日主是 **{day_gan}**（{day_gan_element}），"
            "出生时辰未知，旺衰与喜忌未判定。"
        )

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
