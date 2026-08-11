"""v1 prompt 系统 chart schema builder。

从 BaziEngine.calculate() 返回的 snapshot dict,挑出 v1 prompt 系统需要的字段,
组装为 bazi-prompt-system-v1.md §1 定义的 chart JSON schema。

不改 BaziEngine,作为适配层独立存在。调用方负责把输出 json.dumps 后塞进
render_prompt("m0_structure", {"chart": json.dumps(..., ensure_ascii=False, indent=2)})。

从格诚实降级(对齐 CLAUDE.md "从格检测…LLM 诚实告知"):
命中 day_master_strength == "special_pattern" 时:
- day_master.strength_label = "从格特征"
- useful_god_candidates = []
(LLM 看到空 list 自然降级,设计文档 §2 全局 Prompt 已要求"字段缺失就说明缺失")
"""

from __future__ import annotations

from typing import Any

from .pillars import EN2ZH  # 英文五行 → 中文

# day_master_strength(engine 返回值) → 中文 label(对齐设计文档示例"偏弱/偏旺/中和")
# 与 bazi_engine._STRENGTH_LABEL 同源,但那是私有不导出;此处独立维护一份
# (两处一致性由 test_v1_prompt_render.py 覆盖)
_STRENGTH_LABEL_ZH: dict[str, str] = {
    "strong": "偏旺",
    "weak": "偏弱",
    "balanced": "中和",
    "special_pattern": "从格特征",
}


def build_v1_chart(snapshot: dict[str, Any]) -> dict[str, Any]:
    """从 BaziEngine snapshot 构建 v1 prompt 系统 chart JSON。

    Args:
        snapshot: BaziEngine.calculate() 返回值(必须含 meta/pillars/element_balance/
            day_master_strength/ten_god_weights/useful_god_candidates/luck_pillars/
            current_luck_pillar/current_year_pillar 字段)

    Returns:
        符合 bazi-prompt-system-v1.md §1 schema 的 dict:
        meta / pillars / day_master / ten_gods / ten_god_weights /
        five_elements / useful_god_candidates / luck_pillars /
        current_luck / current_year

    Raises:
        KeyError: snapshot 缺关键字段(代码 bug,显式暴露不静默填空)
        ValueError: gan_zhi 长度异常 / 未知 strength / 未知五行(显式暴露不一致)
    """
    pillars_dict = snapshot["pillars"]
    day_pillar = pillars_dict["day"]

    # ----- day_master(stem + 中文 element + 中文 strength_label) -----
    day_gan = day_pillar["gan"]
    day_gan_element_en = day_pillar["gan_element"]
    day_gan_element_zh = EN2ZH.get(day_gan_element_en)
    if day_gan_element_zh is None:
        # 不静默 fallback:未知五行暴露代码 bug 而非污染 prompt
        raise ValueError(
            f"未知 day gan_element: {day_gan_element_en!r},无法映射中文五行")
    strength = snapshot["day_master_strength"]
    strength_label = _STRENGTH_LABEL_ZH.get(strength)
    if strength_label is None:
        raise ValueError(
            f"未知 day_master_strength: {strength!r},无法映射中文 label")
    day_master = {
        "stem": day_gan,
        "element": day_gan_element_zh,
        # strength_score: BaziEngine.calculate() 没透传 xiji.score
        # (score 是 _compute_fuyi_score 算出的日主旺衰分数,见 xiji.py:156)
        # 留 None 让 LLM 走 strength_label 判断,而非误导性的数字
        "strength_score": None,
        "strength_label": strength_label,
    }

    # ----- ten_gods(年/月/时天干十神 + 各柱地支藏干十神) -----
    # 日柱 shishen_gan lunar_python 固定返回"日主"字面值(非十神),设计文档 §1
    # 示例也只列 year_stem/month_stem/hour_stem → 不输出 day_stem
    ten_gods = {
        "year_stem": pillars_dict["year"]["shishen_gan"],
        "month_stem": pillars_dict["month"]["shishen_gan"],
        "hour_stem": pillars_dict["hour"]["shishen_gan"],
        "hidden": {
            "year_branch": pillars_dict["year"]["shishen_zhi"],
            "month_branch": pillars_dict["month"]["shishen_zhi"],
            "day_branch": pillars_dict["day"]["shishen_zhi"],
            "hour_branch": pillars_dict["hour"]["shishen_zhi"],
        },
    }

    # ----- five_elements(英文 key → 中文 key,值保留 0-8 字数) -----
    # 设计文档示例值(30/18/14/12/26 加和 100)是占位示意,实际 ElementBalance
    # 是 8 字离散计数(每行 0-8)。LLM 看 0-8 整数反而更直观(直接对应 8 字分布)
    eb = snapshot["element_balance"]
    five_elements = {
        "木": eb["wood"],
        "火": eb["fire"],
        "土": eb["earth"],
        "金": eb["metal"],
        "水": eb["water"],
    }

    # ----- useful_god_candidates(从格命中时清空,诚实降级) -----
    is_special = (strength == "special_pattern")
    useful_god_candidates = (
        [] if is_special else list(snapshot["useful_god_candidates"])
    )

    # ----- luck_pillars(拆 gan_zhi "戊寅" → stem "戊" + branch "寅") -----
    luck_pillars_v1 = []
    for lp in snapshot["luck_pillars"]:
        gz = lp["gan_zhi"]
        if len(gz) != 2:
            raise ValueError(
                f"luck_pillar gan_zhi 长度异常: {gz!r}(期望 2 字符天干+地支)")
        luck_pillars_v1.append({
            "start_age": lp["start_age"],
            "stem": gz[0],
            "branch": gz[1],
        })

    # ----- current_luck(可能为 None:用户未入运/已出运) -----
    clp = snapshot.get("current_luck_pillar")
    current_luck: dict[str, Any] | None = None
    if clp is not None:
        gz = clp["gan_zhi"]
        if len(gz) != 2:
            raise ValueError(
                f"current_luck_pillar gan_zhi 长度异常: {gz!r}(期望 2 字符)")
        # CurrentPillar model 只有 start_year/end_year(不含 start_age),
        # 反查 luck_pillars 找匹配 start_age(无匹配 → None,LLM 看 start_year 推)
        start_age = _lookup_current_luck_start_age(
            snapshot["luck_pillars"],
            clp["start_year"], clp["end_year"],
        )
        current_luck = {
            "start_age": start_age,
            "stem": gz[0],
            "branch": gz[1],
            # ten_god:流年/大运天干对日主的十神,确定性可推。
            # 后端没现成工具函数算 gan-vs-gan 十神,留 None 让 LLM 自推
            # (LLM 命理基础知识,根据 day_master.stem + current_luck.stem 100% 准确算)
            "ten_god": None,
        }

    # ----- current_year(字符串 "丙午" → stem "丙" + branch "午") -----
    cyp_str = snapshot["current_year_pillar"]
    if len(cyp_str) != 2:
        raise ValueError(
            f"current_year_pillar 长度异常: {cyp_str!r}(期望 2 字符)")
    current_year = {
        "stem": cyp_str[0],
        "branch": cyp_str[1],
        "ten_god": None,  # 同 current_luck.ten_god:留空让 LLM 自推
    }

    return {
        "meta": snapshot["meta"],
        # pillars 传完整 Pillar(含 gan/zhi/gan_element/zhi_element/hide_gan/
        # shishen_gan/shishen_zhi/nayin/dishi/xunkong),不缩减为 stem/branch
        # 设计文档 §1 示例是简化,完整信息对 LLM 更友好
        "pillars": pillars_dict,
        "day_master": day_master,
        "ten_gods": ten_gods,
        "ten_god_weights": snapshot["ten_god_weights"],
        "five_elements": five_elements,
        "useful_god_candidates": useful_god_candidates,
        "luck_pillars": luck_pillars_v1,
        "current_luck": current_luck,
        "current_year": current_year,
    }


def _lookup_current_luck_start_age(
    luck_pillars: list[dict[str, Any]],
    start_year: int,
    end_year: int,
) -> int | None:
    """反查 luck_pillars 找匹配 start_year/end_year 的 start_age。

    CurrentPillar model 只含 start_year/end_year(年份区间),不含 start_age。
    通过年份区间反查 luck_pillars 拿到对应的起始年龄。

    Returns:
        匹配的 start_age,或 None(理论上 current_luck_pillar 来自 luck_pillars
        定位结果,一定有匹配;None 是防御)
    """
    for lp in luck_pillars:
        if lp["start_year"] == start_year and lp["end_year"] == end_year:
            return lp["start_age"]
    return None
