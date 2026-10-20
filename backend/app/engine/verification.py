"""命局节点句引擎(生肖屏「只属于你」的过去节点,2026-10-19 拍板)。

事实源:docs/生肖屏节点句设计决策.md(D1-D10)。
- 四规则 rank(D1):天克地冲日柱(0) > 冲日支(1) > 冲月支(2) > 大运交接(3)
- 冷读排除窗(D2):17-19 / 21-23 岁(升学毕业)+ 2020-2022(疫情);空池不放宽
- 时间窗(D4):16 岁 ≤ 节点年 ≤ 上一完整公历年(只回望已完整过去的年份,不预言)
- 只取最强 1 个(D3);同强度取最近年份(记忆最新鲜)
零 LLM;纯函数,同一输入 + 同一 last_complete_year → 同一输出。
"""

from __future__ import annotations

from ..models.bazi import LuckPillar, PastNode
from .branch_relations import LIUCHONG
from .pillars import GAN_ELEMENT, WO_KE, year_pillar_ganzhi

# 冷读排除窗(D2):这些年份对几乎所有人都「有变动」,命中不算说中
_EXCLUDED_AGES: frozenset[int] = frozenset({17, 18, 19, 21, 22, 23})
_EXCLUDED_YEARS: frozenset[int] = frozenset({2020, 2021, 2022})

# 时间窗下限(D4):16 岁前的节点难验证且升学期噪声大
_MIN_AGE = 16

# rank 值(D1,越小越强)
_RANK_CHONG_DAY_PILLAR = 0
_RANK_CHONG_DAY_ZHI = 1
_RANK_CHONG_MONTH_ZHI = 2
_RANK_LUCK_TRANSITION = 3

_KIND_BY_RANK: dict[int, str] = {
    _RANK_CHONG_DAY_PILLAR: "chong_day_pillar",
    _RANK_CHONG_DAY_ZHI: "chong_day_zhi",
    _RANK_CHONG_MONTH_ZHI: "chong_month_zhi",
    _RANK_LUCK_TRANSITION: "luck_transition",
}


def _gan_overcomes_either(a_gan: str, b_gan: str) -> bool:
    """两天干五行相克(任一方向,D1「天克」口径)。

    WO_KE 是有向表(metal→wood…),五行相克为五元环,两干相克至多一个方向
    成立;未知干 → ValueError(错误显式传播,不静默吞)。
    """
    a_elem = GAN_ELEMENT.get(a_gan)
    b_elem = GAN_ELEMENT.get(b_gan)
    if a_elem is None or b_elem is None:
        raise ValueError(f"天干查表失败: {a_gan!r} / {b_gan!r}")
    return WO_KE.get(a_elem) == b_elem or WO_KE.get(b_elem) == a_elem


def _zhi_chong(a_zhi: str, b_zhi: str) -> bool:
    """两地支六冲(LIUCHONG 单一事实源,合盘/onboarding 同源)。"""
    return frozenset({a_zhi, b_zhi}) in LIUCHONG


def pick_past_node(
    *,
    birth_year: int,
    day_gan: str | None,
    day_zhi: str | None,
    month_zhi: str | None,
    luck_pillars: list[LuckPillar],
    last_complete_year: int,
) -> PastNode | None:
    """挑唯一过去节点(同年取最强规则,跨年 (rank asc, year desc) 取第一)。

    Args:
        birth_year: 出生公历年。age = 节点年 − 出生年(粗粒度不按立春切,
            文案用「约 N 岁」软化边界误差)
        day_gan / day_zhi: 日柱天干/地支;日柱歧义 → 双 None,rank 0/1 规则
            自然缺席(不猜)。两者必须同 None 或同非 None
        month_zhi: 月支;月柱歧义 → None,rank 2 缺席(月柱歧义时大运已
            级联置空,rank 3 同步缺席)
        luck_pillars: 大运列表(start_year 绝对公历年);空列表 → rank 3 缺席
        last_complete_year: 上一完整公历年(调用方传 now.year − 1;D4 不预言)

    Returns:
        PastNode,或 None(空池/候选全被排除窗吃掉——诚实留白,D2 不放宽)

    Raises:
        ValueError: 日柱参数半截(一 None 一非 None)或干支查表失败
    """
    if (day_gan is None) != (day_zhi is None):
        raise ValueError(
            f"日柱参数必须成对: day_gan={day_gan!r} day_zhi={day_zhi!r}")

    luck_start_years = {lp.start_year for lp in luck_pillars}
    best: tuple[int, int] | None = None  # (rank, year)

    for year in range(birth_year + _MIN_AGE, last_complete_year + 1):
        age = year - birth_year
        if age in _EXCLUDED_AGES or year in _EXCLUDED_YEARS:
            continue
        year_gz = year_pillar_ganzhi(year)
        if len(year_gz) != 2:
            raise ValueError(f"流年干支长度异常: {year_gz!r}")
        year_gan, year_zhi = year_gz[0], year_gz[1]

        # 同年只记最强一档(§2.1):rank0/1 互斥(else 关系),rank2/3 只在
        # 更强档缺席时参与
        rank: int | None = None
        if (day_gan is not None and day_zhi is not None
                and _zhi_chong(year_zhi, day_zhi)):
            rank = (
                _RANK_CHONG_DAY_PILLAR
                if _gan_overcomes_either(year_gan, day_gan)
                else _RANK_CHONG_DAY_ZHI
            )
        if rank is None and month_zhi is not None and _zhi_chong(
                year_zhi, month_zhi):
            rank = _RANK_CHONG_MONTH_ZHI
        if rank is None and year in luck_start_years:
            rank = _RANK_LUCK_TRANSITION

        if rank is None:
            continue
        if (best is None or rank < best[0]
                or (rank == best[0] and year > best[1])):
            best = (rank, year)

    if best is None:
        return None
    rank, year = best
    return PastNode(kind=_KIND_BY_RANK[rank], year=year, age=year - birth_year)
