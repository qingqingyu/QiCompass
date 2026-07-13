"""合盘引擎:定性评估 + 流年同步性(确定性,不走 LLM,禁止数字分)。

四项评估全为定性中文短语,与 `xiji.py` / `shensha.py` 同级。LLM 只负责润色
合盘解读话术, 不得自行推断评估结论。

设计要点(对齐 CLAUDE.md "LLM 边界" 与 "错误显式传播"):
- 同步 CPU-bound 纯函数, API 层 `run_in_threadpool` 包(对齐 daily_fortune.py)
- 四项评估均不返回数字分, 不返回"必成/必分/必破财/注定"等绝对结论字样
- 从格(special_pattern)的喜忌为空 → 五行评估返回"信息不足", sync 返回"难以定性"
- context 只参与 hash + AI prompt 维度, **不**参与定性评估计算(不变量)
- 所有 lunar_python 异常向上抛为 BaziCalculationFailedError, 不吞错
"""

from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timezone

from lunar_python import Solar

from ..core.city_longitude import resolve_longitude
from ..engine.bazi_engine import BaziEngine
from ..engine.pillars import GAN_ELEMENT, ZHI_ELEMENT
from ..errors import BaziCalculationFailedError, BaziError
from ..models.bazi import BaziCalculateResponse, CalcRuleSnapshot, LuckPillar
from ..models.compatibility import (
    CompatibilityRequest,
    CompatibilityResponse,
    QualitativeAssessment,
    SyncedFortune,
)
from ..models.daily_fortune import ChartPayload, PillarRef

logger = logging.getLogger(__name__)

# 英→中五行映射(favorable/unfavorable 是中文, 流年五行需对比英文)
EN2ZH_ELEMENT: dict[str, str] = {
    "wood": "木", "fire": "火", "earth": "土", "metal": "金", "water": "水",
}

# ---------- 生肖(年支)合冲表 ----------

# 六合(6 对): 子丑 / 寅亥 / 卯戌 / 辰酉 / 巳申 / 午未
LIUHE: frozenset[frozenset[str]] = frozenset({
    frozenset({"子", "丑"}), frozenset({"寅", "亥"}),
    frozenset({"卯", "戌"}), frozenset({"辰", "酉"}),
    frozenset({"巳", "申"}), frozenset({"午", "未"}),
})

# 三合局(4 组, 每组 3 支): 申子辰 / 寅午戌 / 巳酉丑 / 亥卯未
SANHE: tuple[frozenset[str], ...] = (
    frozenset({"申", "子", "辰"}),
    frozenset({"寅", "午", "戌"}),
    frozenset({"巳", "酉", "丑"}),
    frozenset({"亥", "卯", "未"}),
)

# 六冲(6 对): 子午 / 丑未 / 寅申 / 卯酉 / 辰戌 / 巳亥
LIUCHONG: frozenset[frozenset[str]] = frozenset({
    frozenset({"子", "午"}), frozenset({"丑", "未"}),
    frozenset({"寅", "申"}), frozenset({"卯", "酉"}),
    frozenset({"辰", "戌"}), frozenset({"巳", "亥"}),
})

# 三刑(经典组合): 寅巳申 / 丑戌未 / 子卯
SANXING: tuple[frozenset[str], ...] = (
    frozenset({"寅", "巳", "申"}),
    frozenset({"丑", "戌", "未"}),
    frozenset({"子", "卯"}),
)

# 相害(6 对): 子未 / 丑午 / 寅巳 / 卯辰 / 申亥 / 酉戌
XIANGHAI: frozenset[frozenset[str]] = frozenset({
    frozenset({"子", "未"}), frozenset({"丑", "午"}),
    frozenset({"寅", "巳"}), frozenset({"卯", "辰"}),
    frozenset({"申", "亥"}), frozenset({"酉", "戌"}),
})


# ---------- 五行生克关系(从 xiji.py 复用概念) ----------

# 五行相生: 木→火→土→金→水→木
SHENG: dict[str, str] = {
    "wood": "fire", "fire": "earth", "earth": "metal",
    "metal": "water", "water": "wood",
}
# 五行相克: 木→土→水→火→金→木
KE: dict[str, str] = {
    "wood": "earth", "earth": "water", "water": "fire",
    "fire": "metal", "metal": "wood",
}


# ---------- 评估 1: 五行互补 ----------

def _assess_five_elements(
    a_favorable: list[str],
    a_unfavorable: list[str],
    b_favorable: list[str],
    b_unfavorable: list[str],
) -> str:
    """五行互补评估。

    算法: A 忌 ∩ B 喜 ∪ B 忌 ∩ A 喜 的大小。互补越多越好。
    从格/喜忌空 → "信息不足" 诚实降级。

    Returns:
        "互补佳" / "有一定互补" / "互补较弱" / "信息不足"
    """
    a_fav = set(a_favorable)
    a_unfav = set(a_unfavorable)
    b_fav = set(b_favorable)
    b_unfav = set(b_unfavorable)

    # 喜忌为空 → 从格 / 未下喜忌结论
    if not a_fav or not b_fav:
        return "信息不足"
    if not a_unfav or not b_unfav:
        return "信息不足"

    # 互补: A 忌的五行 B 喜 → B 命局多此五行, 自然补 A 所缺
    #       B 忌的五行 A 喜 → A 命局多此五行, 自然补 B 所缺
    mutual_supply = (a_unfav & b_fav) | (b_unfav & a_fav)
    count = len(mutual_supply)

    if count >= 2:
        return "互补佳"
    if count == 1:
        return "有一定互补"
    return "互补较弱"


# ---------- 评估 2: 日主关系 ----------

def _assess_day_master(a_day_gan: str, b_day_gan: str) -> str:
    """日主关系评估(A/B 日干五行生克对称映射)。

    算法: A 日干 + B 日干查五行生克关系。

    五行生克是对称关系: 两日干要么同气, 要么相生, 要么相克。
    不存在"单向"标签(相生是 A→B 或 B→A 都标"相生")。

    Returns:
        "同气" / "相生" / "相克"
    """
    a_elem = GAN_ELEMENT.get(a_day_gan)
    b_elem = GAN_ELEMENT.get(b_day_gan)
    if a_elem is None or b_elem is None:
        raise ValueError(
            f"未知天干: a={a_day_gan!r} b={b_day_gan!r}")

    # 同气
    if a_elem == b_elem:
        return "同气"

    # 相生: A→B 或 B→A
    a_generates_b = SHENG.get(a_elem) == b_elem
    b_generates_a = SHENG.get(b_elem) == a_elem
    if a_generates_b or b_generates_a:
        # 相生关系是对称标签: 无论 A→B 还是 B→A 都标「相生」
        return "相生"

    # 相克: A→B 或 B→A
    a_overcomes_b = KE.get(a_elem) == b_elem
    b_overcomes_a = KE.get(b_elem) == a_elem
    if a_overcomes_b or b_overcomes_a:
        return "相克"

    # 理论不会走到这里(五行关系只有同/生/克三类)
    raise ValueError(
        f"五行关系异常: a_elem={a_elem!r} b_elem={b_elem!r}")


# ---------- 评估 3: 生肖(年支)匹配 ----------

def _assess_zodiac(a_year_zhi: str, b_year_zhi: str) -> str:
    """生肖匹配评估(基于年支)。

    优先级: 六冲 > 三刑 > 相害 > 六合 > 三合 > 无特殊合冲。
    冲/刑/害为凶, 合为吉, 取**最强**关系(单标签, 不并存)。

    Returns:
        "六合" / "三合" / "六冲" / "三刑" / "相害" / "无特殊合冲"
    """
    pair = frozenset({a_year_zhi, b_year_zhi})

    # 同年支 → 无特殊(自身无合冲)
    if a_year_zhi == b_year_zhi:
        return "无特殊合冲"

    # 六冲(最凶)
    if pair in LIUCHONG:
        return "六冲"

    # 三刑(2 支命中三刑集合)
    for xing in SANXING:
        if pair <= xing:
            return "三刑"

    # 相害
    if pair in XIANGHAI:
        return "相害"

    # 六合(吉)
    if pair in LIUHE:
        return "六合"

    # 三合(需 3 支齐; 两支同属一三合局视为"半合", 标"三合"轻量吉)
    for sanhe in SANHE:
        if pair <= sanhe:
            return "三合"

    return "无特殊合冲"


# ---------- 评估 4: 地支合冲(全 16 对) ----------

def _assess_branch_harmony(
    a_pillars: dict[str, PillarRef], b_pillars: dict[str, PillarRef],
) -> str:
    """四柱地支合冲扫描(4×4=16 对)。

    统计 16 对里的合/冲/刑/害次数(不去重, 每对独立柱位关系), 按规则打标签:
    - 多冲少合: 冲次数 >= 2 且 冲 > 合
    - 多合少冲: 合次数 >= 2 且 合 > 冲
    - 多刑多害: 刑+害 >= 3
    - 一冲一合: 冲 = 1 且 合 = 1
    - 略有冲刑害: 上述均不匹配但有冲/刑/害(单冲无合 / 单刑 / 单害 / 冲合均势等)
    - 无冲无刑: 冲+刑+害 = 0(纯中性或纯合)

    Args:
        a_pillars/b_pillars: {year, month, day, hour} 四柱, 每柱含 zhi

    Returns:
        "无冲无刑" / "一冲一合" / "多冲少合" / "多合少冲" / "多刑多害" / "略有冲刑害"
    """
    a_zhis = [a_pillars[k].zhi for k in ("year", "month", "day", "hour")]
    b_zhis = [b_pillars[k].zhi for k in ("year", "month", "day", "hour")]

    he_count = 0       # 合(六合 + 三合半)
    chong_count = 0    # 冲(六冲)
    xing_count = 0     # 刑
    hai_count = 0      # 害

    # 16 对独立柱位关系(不去重: 年对年/月/日/时 是 4 条独立关系)
    for a_z in a_zhis:
        for b_z in b_zhis:
            if a_z == b_z:
                # 同地支不算合冲(自身无关系)
                continue
            pair = frozenset({a_z, b_z})

            if pair in LIUHE:
                he_count += 1
                continue
            if pair in LIUCHONG:
                chong_count += 1
                continue
            if pair in XIANGHAI:
                hai_count += 1
                continue
            # 三合半合
            for sanhe in SANHE:
                if pair <= sanhe:
                    he_count += 1
                    break
            else:
                # 三刑(2 支命中三刑集合)
                for xing in SANXING:
                    if pair <= xing:
                        xing_count += 1
                        break

    # 标签优先级(从重到轻)
    if chong_count >= 2 and chong_count > he_count:
        return "多冲少合"
    if he_count >= 2 and he_count > chong_count:
        return "多合少冲"
    if (xing_count + hai_count) >= 3:
        return "多刑多害"
    if chong_count == 1 and he_count == 1:
        return "一冲一合"
    if chong_count == 0 and xing_count == 0 and hai_count == 0:
        return "无冲无刑"
    # 兜底: 有冲/刑/害但不匹配上述标签(单冲无合 / 单刑 / 单害 / 冲合均势等)。
    # 不再误判为"无冲无刑",用"略有冲刑害"诚实呈现。
    return "略有冲刑害"


# ---------- 流年同步性 ----------

def _build_year_pillar_for_future(year: int) -> str:
    """未来某年的流年干支(立春切换, 对齐 current.py:18)。

    用 Solar(year, 2, 4, 12, 0, 0) 构造立春日, 取 getYearInGanZhiByLiChun()。
    spike 已验证 2030/2031 等未来年份均稳定。
    """
    solar = Solar.fromYmdHms(year, 2, 4, 12, 0, 0)
    return solar.getLunar().getYearInGanZhiByLiChun()


def _luck_pillar_for_year(
    luck_pillars: list[LuckPillar], year: int,
) -> LuckPillar | None:
    """在 luck_pillars 里定位年份 Y 所在大运。

    复用 locate_current_luck_pillar 思路: start_year <= year <= end_year。
    返回 None 表示未找到(已出运或未入运), 字符串字段留空。
    """
    for lp in luck_pillars:
        if lp.start_year <= year <= lp.end_year:
            return lp
    return None


def _is_favorable_for(
    year_gz: str, favorable: list[str],
) -> bool | None:
    """流年干支五行是否落在 favorable 列表里。

    返回:
        True: 天干或地支五行落在 favorable
        False: 都不落在 favorable(中性或忌)
        None: favorable 为空(从格/信息不足)
    """
    if not favorable:
        return None
    if len(year_gz) != 2:
        raise ValueError(f"流年干支长度异常: {year_gz!r}")
    gan, zhi = year_gz[0], year_gz[1]
    gan_elem = GAN_ELEMENT.get(gan)
    zhi_elem = ZHI_ELEMENT.get(zhi)
    if gan_elem is None or zhi_elem is None:
        raise ValueError(
            f"流年干支查表失败: gz={year_gz!r} gan={gan!r} zhi={zhi!r}")
    gan_zh = EN2ZH_ELEMENT.get(gan_elem)
    zhi_zh = EN2ZH_ELEMENT.get(zhi_elem)
    return gan_zh in favorable or zhi_zh in favorable


def _sync_label(
    a_favorable: list[str], b_favorable: list[str], year_gz: str,
) -> str:
    """单年同步性标签。

    一利一不利统称"运势分化"(不细分节奏差异, MVP 简化)。

    Returns:
        "同步走强" / "同步承压" / "运势分化" / "难以定性"
    """
    a_good = _is_favorable_for(year_gz, a_favorable)
    b_good = _is_favorable_for(year_gz, b_favorable)

    # 任一方从格/喜忌空 → 难以定性
    if a_good is None or b_good is None:
        return "难以定性"

    if a_good and b_good:
        return "同步走强"
    if (not a_good) and (not b_good):
        return "同步承压"
    # 一利一不利
    # 方案 A 主标签"运势分化"; 若需细分(一方承压一方平稳)由后端日志补充
    return "运势分化"


# ---------- compatibility_hash ----------

def compute_compatibility_hash(a_hash: str, b_hash: str, context: str) -> str:
    """合盘缓存键 hash。

    公式: sha256(utf8len(h1):h1|utf8len(h2):h2|utf8len(ctx):ctx)
    其中 h1=min(a,b), h2=max(a,b), utf8len 按 UTF-8 字节数计。

    用 UTF-8 字节长度前缀消除分隔符歧义: 即使 hash 或 context 含 ``|`` 字符,
    也不会发生碰撞歧义。**必须用 UTF-8 字节数**(而非 Unicode 码点数/字形簇数):
    Python ``len(str)`` 按码点、Swift ``String.count`` 按字形簇, 两者在 ZWJ 拼接
    emoji / 肤色调修饰等场景下不一致 → 跨平台 hash 分歧 → iOS 预查 cache miss。
    UTF-8 字节数两端定义唯一, 锁死跨平台一致性。

    - min/max 规范化 → A/B 顺序无关
    - context 参与: 同对夫妻不同 context 各自独立缓存
    - 不加 calc_rule_version: content_hash 已编码各自规则, 冗余
    """
    h1, h2 = min(a_hash, b_hash), max(a_hash, b_hash)
    payload = (
        f"{len(h1.encode('utf-8'))}:{h1}"
        f"|{len(h2.encode('utf-8'))}:{h2}"
        f"|{len(context.encode('utf-8'))}:{context}"
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


# ---------- 主流程 ----------

def compute_compatibility(
    req: CompatibilityRequest, *, now: datetime | None = None,
) -> CompatibilityResponse:
    """主流程。返回 CompatibilityResponse。

    Raises:
        BaziCalculationFailedError: lunar_python 内部异常(不吞, 向上抛)
        ValueError: chart_payload 字段非法 / 查表缺失
    """
    try:
        now = now if now is not None else datetime.now(timezone.utc)
        a_payload = req.chart_payload_a
        b_payload: ChartPayload
        b_full_response = None  # 模式 B 排好的完整 B 盘响应

        # 1. 取 A/B 排盘
        if req.person_b_hash is not None:
            # 模式 A: B 已存档, 从 payload 取
            if req.chart_payload_b is None:
                # model_validator 已校验, 此处不静默
                raise ValueError(
                    "模式 A (person_b_hash) 下 chart_payload_b 必填")
            b_payload = req.chart_payload_b
            b_hash = req.person_b_hash
        else:
            # 模式 B: 后端现排 B
            assert req.person_b is not None  # model_validator 已校验
            pb = req.person_b
            longitude = resolve_longitude(pb.city, pb.longitude)

            engine = BaziEngine(now=now)
            b_result = engine.calculate(
                birth=pb.birth_datetime, gender=pb.gender,
                longitude=longitude, zi_hour_rule=pb.zi_hour_rule,
            )
            # BaziEngine.calculate 返回 dict, 转为 BaziCalculateResponse
            b_full_response = BaziCalculateResponse(**b_result)
            # 把 B 排盘结果转为 ChartPayload(供后续评估用)
            b_payload = ChartPayload(
                day_master=b_result["pillars"]["day"]["gan"],
                day_master_element=b_result["pillars"]["day"]["gan_element"],
                day_master_strength=b_result["day_master_strength"],
                favorable_elements=b_result["favorable_elements"],
                unfavorable_elements=b_result["unfavorable_elements"],
                four_pillars={
                    pos: {
                        "gan": b_result["pillars"][pos]["gan"],
                        "zhi": b_result["pillars"][pos]["zhi"],
                    } for pos in ("year", "month", "day", "hour")
                },
                luck_pillars=[
                    LuckPillar(**lp) for lp in b_result["luck_pillars"]
                ],
                calc_rule_snapshot=CalcRuleSnapshot(
                    **b_result["calc_rule_snapshot"]),
            )
            b_hash = b_result["content_hash"]

        # 2. 定性评估(四个内部纯函数)
        a_day_gan = a_payload.day_master
        b_day_gan = b_payload.day_master
        a_year_zhi = a_payload.four_pillars["year"].zhi
        b_year_zhi = b_payload.four_pillars["year"].zhi

        assessment = QualitativeAssessment(
            five_elements=_assess_five_elements(
                a_payload.favorable_elements, a_payload.unfavorable_elements,
                b_payload.favorable_elements, b_payload.unfavorable_elements,
            ),
            day_master_relation=_assess_day_master(a_day_gan, b_day_gan),
            zodiac_match=_assess_zodiac(a_year_zhi, b_year_zhi),
            branch_harmony=_assess_branch_harmony(
                a_payload.four_pillars, b_payload.four_pillars),
        )

        # 3. 流年同步 3 年
        synced: list[SyncedFortune] = []
        for offset in (1, 2, 3):
            year = now.year + offset
            year_gz = _build_year_pillar_for_future(year)
            a_luck = _luck_pillar_for_year(a_payload.luck_pillars, year)
            b_luck = _luck_pillar_for_year(b_payload.luck_pillars, year)
            a_str = f"{a_luck.gan_zhi}运 {year_gz}年" if a_luck else f"无运 {year_gz}年"
            b_str = f"{b_luck.gan_zhi}运 {year_gz}年" if b_luck else f"无运 {year_gz}年"
            sync = _sync_label(
                a_payload.favorable_elements, b_payload.favorable_elements,
                year_gz,
            )
            synced.append(SyncedFortune(
                year=year, person_a=a_str, person_b=b_str, sync=sync))

        # 4. compatibility_hash
        comp_hash = compute_compatibility_hash(
            req.person_a_hash, b_hash, req.context)

        # 5. calc_rule_snapshot: 模式 A 用 A payload 的(可能为 None); 模式 B 用 B 的。
        # 模式 A 若 payload 未带 → None(不塞占位值,避免破坏"同输入同输出"确定性契约)。
        if b_full_response is not None:
            calc_rule_snapshot = b_full_response.calc_rule_snapshot
        elif a_payload.calc_rule_snapshot is not None:
            calc_rule_snapshot = a_payload.calc_rule_snapshot
        else:
            calc_rule_snapshot = None

        logger.info(
            "compatibility.ok a_hash=%s b_hash=%s context=%s comp_hash=%s "
            "five_elements=%s day_master=%s zodiac=%s branch=%s",
            req.person_a_hash, b_hash, req.context, comp_hash,
            assessment.five_elements, assessment.day_master_relation,
            assessment.zodiac_match, assessment.branch_harmony,
        )

        return CompatibilityResponse(
            compatibility_hash=comp_hash,
            person_a_chart=None,  # 始终 None, 客户端用本地存档
            person_b_chart=b_full_response,  # 模式 A None, 模式 B 完整
            qualitative_assessment=assessment,
            synced_fortune=synced,
            calc_rule_snapshot=calc_rule_snapshot,
        )
    except (BaziError, ValueError):
        # 已是结构化错误或 ValueError, 原样向上抛。
        # 例如城市查表失败应保留 CITY_NOT_FOUND/404,不能包装成排盘 500。
        raise
    except Exception as e:
        # 不吞: 把 lunar_python / 内部异常向上抛为结构化错误
        raise BaziCalculationFailedError(
            f"合盘计算失败: {type(e).__name__}: {e}",
            content_hash=None,
        ) from e
