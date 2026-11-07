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

import json
from typing import Any

from .pillars import EN2ZH, GAN_ELEMENT, ten_god  # 英文五行 → 中文;十干;日干+他干 → 十神

# day_master_strength(engine 返回值) → 中文 label(对齐设计文档示例"偏弱/偏旺/中和")
# 与 bazi_engine._STRENGTH_LABEL 同源但**不共用**,两者语义不同:
# - bazi_engine 那份用于 anchor sentence(整句谓语"命局整体呈现从格特征"),
#   用 .get(default) graceful degrade,因 anchor 是辅助显示
# - chart_builder 这份用于 prompt JSON 的 strength_label 字段(短标签),
#   用 strict raise,因 prompt 数据契约未知值必须显式暴露
# 措辞差异(从格特征 vs 呈现从格特征)源自此语义差异,非 bug
# 若 bazi_engine 加新 strength 取值,需同步更新此 dict(回归由
# test_v1_prompt_render.py::test_chart_builder_normal_strength_keeps_* 覆盖)
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
            # 运神:大运天干对日主的十神,确定性查表(2026-11-07 借鉴项①,
            # 修「LLM 自推十神」概率翻车面;表已上移 pillars.SHISHEN_GAN)
            "ten_god": ten_god(day_gan, gz[0]),
        })

    # ----- current_luck(可能为 None:用户未入运/已出运) -----
    # 显式校验 key 存在:违反"错误显式传播"原则的话,.get() 会把 schema 缺字段
    # 静默吞为 None → current_luck=None 输出。这里 key 缺失必须抛 KeyError。
    if "current_luck_pillar" not in snapshot:
        raise KeyError(
            "snapshot 缺 current_luck_pillar 字段(数据损坏或 schema 不完整)")
    clp = snapshot["current_luck_pillar"]
    current_luck: dict[str, Any] | None = None
    if clp is not None:
        gz = clp["gan_zhi"]
        if len(gz) != 2:
            raise ValueError(
                f"current_luck_pillar gan_zhi 长度异常: {gz!r}(期望 2 字符)")
        # CurrentPillar model 只有 start_year/end_year(不含 start_age),
        # 反查 luck_pillars 找匹配 start_age(无匹配 → None,LLM 看 start_year 推)
        start_age = lookup_current_luck_start_age(
            snapshot["luck_pillars"],
            clp["start_year"], clp["end_year"],
        )
        current_luck = {
            "start_age": start_age,
            "stem": gz[0],
            "branch": gz[1],
            # 当前大运运神,确定性查表(旧注释「后端没现成工具算 gan-vs-gan
            # 十神,留 None 让 LLM 自推」已过时:pillars.SHISHEN_GAN 即是表,
            # 且 LLM 自推有概率翻车前科,见 prompts.py 证据纪律注释)
            "ten_god": ten_god(day_gan, gz[0]),
        }

    # ----- current_year(字符串 "丙午" → stem "丙" + branch "午") -----
    # models/bazi.py:186 声明 current_year_pillar: str | None,引擎当前实现
    # 总是返回非 None 字符串,但 model 类型允许 None(防御性)。None 时显式
    # 抛 ValueError,而非 len(None) → TypeError(违反 build_v1_chart docstring
    # 承诺的 ValueError 契约)
    cyp_str = snapshot["current_year_pillar"]
    if cyp_str is None:
        raise ValueError(
            "current_year_pillar 为 None(snapshot 未含流年柱),"
            "chart_builder 暂不支持此场景")
    if len(cyp_str) != 2:
        raise ValueError(
            f"current_year_pillar 长度异常: {cyp_str!r}(期望 2 字符)")
    current_year = {
        "stem": cyp_str[0],
        "branch": cyp_str[1],
        # 流年天干对日主的十神,确定性查表(同 current_luck.ten_god)
        "ten_god": ten_god(day_gan, cyp_str[0]),
    }

    return {
        "meta": snapshot["meta"],
        # pillars 传完整 Pillar(含 gan_zhi/gan/zhi/gan_element/zhi_element/
        # hide_gan/shishen_gan/shishen_zhi/nayin/dishi/xunkong),不缩减为 stem/branch
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


def lookup_current_luck_start_age(
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


# ---------- v1 chart 运神注入(2026-11-07 借鉴项①,方案 B 后端注入)----------

def enrich_v1_chart_ten_gods(chart_json: str) -> str:
    """为 v1 chart 注入大运运神十神(luck_pillars / current_luck / current_year)。

    背景:大运十神不在 token 绑定契约里——客户端 chart 不带该键、镜像不动
    (动它 = iOS 锁步发版 + 旧 App 重排盘后新 token 与旧 chart 恒不匹配的
    403 死锁)。渲染前由后端从 chart 自身数据确定性推导注入,所有已装 App
    立即受益,且客户端永远无法伪造十神标签(安全边界仍是 token 验签,
    本函数不是闸门)。

    幂等:build_v1_chart 直出的 chart(已带值)再过本函数是字节级 no-op;
    已有**不等值** ten_god 显式抛 ValueError(该值按契约只可能来自服务端
    build_v1_chart,不等 = 表与 schema 漂移,代码 bug 不静默)。

    脏数据语义(本函数运行在 token 验签**之前**——渲染先于验签是既有次序,
    未验签 chart 可能含任意内容):
    - chart 非合法 JSON → json.JSONDecodeError 原样上抛;顶层非对象 →
      原样返回(两者均由调用方 defer-to-gate:zh 由验签 403,en 由
      _translate_chart_json 结构化 500)
    - day_master 缺失 / stem 非十干 → 整体原样返回,不猜(篡改盘由验签
      403 统一拒绝;时辰未知盘日主恒在,此分支纯防御)
    - luck 条目 stem 非十干 → 该条目跳过不填(同上,交验签拒绝)

    Returns:
        注入后的 chart JSON 字符串(ensure_ascii=False, indent=2,与
        build_v1_chart 调用方的序列化形态一致;无改动时原字符串直接返回)
    """
    data = json.loads(chart_json)
    if not isinstance(data, dict):
        # 顶层非对象(如深嵌套数组——test_deeply_nested_chart 同款构造):
        # 不是 v1 chart 语义,原样放行交 token 验签拒绝(defer-to-gate)
        return chart_json
    day_master = data.get("day_master")
    if not isinstance(day_master, dict):
        return chart_json
    day_gan = day_master.get("stem")
    if not isinstance(day_gan, str) or day_gan not in GAN_ELEMENT:
        return chart_json

    def _fill(entry: object) -> bool:
        """单条注入;返回是否有改动(脏 stem 跳过,见 docstring)。"""
        if not isinstance(entry, dict):
            return False
        stem = entry.get("stem")
        if not isinstance(stem, str) or stem not in GAN_ELEMENT:
            return False
        expected = ten_god(day_gan, stem)  # stem 已验 ∈ 十干,查表必中
        existing = entry.get("ten_god")
        if existing == expected:
            return False
        if existing is not None:
            raise ValueError(
                f"v1 chart ten_god 漂移:day_master={day_gan!r} "
                f"stem={stem!r} 已有 {existing!r} ≠ 表值 {expected!r}"
                "(build_v1_chart 与 SHISHEN_GAN 表不一致,代码 bug)")
        entry["ten_god"] = expected
        return True

    changed = False
    luck_pillars = data.get("luck_pillars")
    if isinstance(luck_pillars, list):
        for lp in luck_pillars:
            changed = _fill(lp) or changed
    for key in ("current_luck", "current_year"):
        if isinstance(data.get(key), dict):
            changed = _fill(data[key]) or changed
    if not changed:
        return chart_json
    return json.dumps(data, ensure_ascii=False, indent=2)
