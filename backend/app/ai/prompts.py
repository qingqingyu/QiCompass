"""AI 命书 prompt 模板 + 渲染 + 字段校验。

三个常量字符串模板,结构对齐 bazi-app-design-doc.md:410-496(设计文档原文 "..." 处
展开为完整字段引用,让 LLM 拿到完整信息而非省略)。

PROMPT_VERSIONS 与模板常量放同文件邻近位置:改模板时必须 bump 对应版本号,
否则老用户拿到旧解读(老 key 永不命中,老条目自然死,不主动删)。

从格诚实降级(对齐 CLAUDE.md "从格检测…LLM 诚实告知"):
- bazi_deep 模板渲染时检查 day_master_strength == "special_pattern"
- 命中则在 prompt 末尾追加降级约束段,要求 LLM 诚实告知未下硬性喜忌结论
"""

from __future__ import annotations

from ..errors import InvalidInputError

# ---------- prompt 版本号(改模板/换模型时 bump)----------
# 本模块是 PROMPT_VERSIONS 的单一事实源,路由层从此处导入
PROMPT_VERSIONS: dict[str, int] = {
    "bazi_deep": 1,
    "compatibility": 1,
    "daily_fortune": 1,
}

# ---------- 深度解析 ----------
# 对齐 bazi-app-design-doc.md:410-438
BAZI_DEEP_TEMPLATE = """你是一位精通中国传统四柱八字命理的大师。请基于以下排盘数据进行深度命书解读。

命主：{gender}，出生于 {city}，真太阳时 {true_solar_time}

四柱：
- 年柱：{year_gan}{year_zhi}（{year_gan_element}/{year_zhi_element}），十神 {year_shishen_gan}，藏干 {year_hide_gan}
- 月柱：{month_gan}{month_zhi}（{month_gan_element}/{month_zhi_element}），十神 {month_shishen_gan}，藏干 {month_hide_gan}
- 日柱：{day_gan}{day_zhi}（日主 {day_gan_element}），地支十神 {day_shishen_zhi}，藏干 {day_hide_gan}
- 时柱：{hour_gan}{hour_zhi}（{hour_gan_element}/{hour_zhi_element}），十神 {hour_shishen_gan}，藏干 {hour_hide_gan}

纳音：年 {year_nayin} / 月 {month_nayin} / 日 {day_nayin} / 时 {hour_nayin}
命宫：{ming_gong}（{ming_gong_nayin}）
神煞：{shensha_list}
五行统计：{element_balance}
日主旺衰：{day_master_strength}
喜用五行：{favorable_elements}
忌讳五行：{unfavorable_elements}
调候是否触发：{tiaoshou_applied}
当前大运：{current_luck_pillar}
当前流年：{current_year_pillar}

写作要求：
1. 日主旺衰、喜忌、神煞、大运流年走势
2. **重要：格局作为叙事概念模糊处理**，用"命局呈现××倾向"，**不得**给出"正官格/偏印格"等硬性分类
3. **重要：喜忌已由后端确定性给出，你必须严格按后端的 favorable/unfavorable 写**，不得自行推断或修改
4. 古朴典雅，引用术语配解释，面向有基础的海外华人用户
5. 约 300-500 字（MVP 压缩 30%）
"""

# 从格诚实降级约束段(day_master_strength == "special_pattern" 时追加)
BAZI_DEEP_SPECIAL_PATTERN_SUFFIX = """
**本命盘呈现从格特征，喜忌结论留空。请诚实告知用户：当前未下硬性喜忌结论，避免编造扶抑法喜忌。
可围绕命局呈现的从格倾向（如专旺/从强/从弱等）做叙事性描述，但不得给出确定性的"宜×忌×"结论。**
"""

# ---------- 合盘 ----------
# 对齐 bazi-app-design-doc.md:440-468
COMPATIBILITY_TEMPLATE = """你是一位精通八字合婚/合盘的大师。请基于以下两人命盘进行 {context_label} 合盘解读。

A 盘（{gender_a}，{city_a}，{birth_a}）：日主 {day_master_a}，{day_master_strength_a}，喜 {favorable_a}
- 年柱：{year_a} 月柱：{month_a} 日柱：{day_a} 时柱：{hour_a}
- 五行：{element_balance_a}

B 盘（{gender_b}，{city_b}，{birth_b}）：日主 {day_master_b}，{day_master_strength_b}，喜 {favorable_b}
- 年柱：{year_b} 月柱：{month_b} 日柱：{day_b} 时柱：{hour_b}
- 五行：{element_balance_b}

定性评估（后端已给，你负责展开）：
- 五行互补：{five_elements_assessment}
- 日主关系：{day_master_relation}
- 生肖匹配：{zodiac_match}
- 地支合冲：{branch_harmony}

流年同步性（未来 3 年）：
{synced_fortune_table}

写作要求：
1. 围绕 {context_label} 维度展开
2. 客观陈述五行互补、日主关系、地支合冲的具体表现
3. 流年同步性：指出同步进好运/坏运的年份
4. **绝对禁忌**：不得给出"必成 / 必分 / 必破财"等绝对结论
5. 约 400-500 字
"""

# ---------- 每日运势 ----------
# 对齐 bazi-app-design-doc.md:470-496
DAILY_FORTUNE_TEMPLATE = """你是一位精通流日推断的命理师。请基于以下信息为命主解读今日运势。

命主：日主 {day_master}（{day_master_element}），{day_master_strength}
命局喜：{favorable_elements}
命局忌：{unfavorable_elements}

今日：{date}（农历 {lunar_date}）
今日流日柱：{day_pillar}（流日天干 {day_stem} 属 {day_stem_element}，流日地支 {day_branch} 属 {day_branch_element}）
流日对日主关系：{day_relation}
流日冲：{day_chong}

12 时辰（按 zi_hour_rule 排序）：
{hour_pillars_with_relations}

通用黄历宜：{huangli_yi}
通用黄历忌：{huangli_ji}

写作要求：
1. 今日总览：流日对日主的生克影响（结合后端给出的喜忌），是否冲克命局、是否有贵人扶持
2. 个性化宜忌（结合命主命局，**不是通用黄历的复述**）：3-5 条
3. 情绪/状态提示：基于流日对日主的关系
4. 12 时辰强弱：简短点评（一句话/时辰）
5. 约 200-300 字 + 12 句时辰点评
"""

# ---------- 模板注册表 ----------

_TEMPLATES: dict[str, str] = {
    "bazi_deep": BAZI_DEEP_TEMPLATE,
    "compatibility": COMPATIBILITY_TEMPLATE,
    "daily_fortune": DAILY_FORTUNE_TEMPLATE,
}

# 各 module 必填字段清单(渲染前 validate_context 逐项检查)
REQUIRED_FIELDS: dict[str, list[str]] = {
    "bazi_deep": [
        "gender", "city", "true_solar_time",
        "year_gan", "year_zhi", "year_gan_element", "year_zhi_element",
        "year_shishen_gan", "year_hide_gan",
        "month_gan", "month_zhi", "month_gan_element", "month_zhi_element",
        "month_shishen_gan", "month_hide_gan",
        "day_gan", "day_zhi", "day_gan_element", "day_shishen_zhi", "day_hide_gan",
        "hour_gan", "hour_zhi", "hour_gan_element", "hour_zhi_element",
        "hour_shishen_gan", "hour_hide_gan",
        "year_nayin", "month_nayin", "day_nayin", "hour_nayin",
        "ming_gong", "ming_gong_nayin",
        "shensha_list", "element_balance",
        "day_master_strength",
        "favorable_elements", "unfavorable_elements",
        "tiaoshou_applied",
        "current_luck_pillar", "current_year_pillar",
    ],
    "compatibility": [
        "context_label",
        "gender_a", "city_a", "birth_a", "day_master_a",
        "day_master_strength_a", "favorable_a",
        "year_a", "month_a", "day_a", "hour_a", "element_balance_a",
        "gender_b", "city_b", "birth_b", "day_master_b",
        "day_master_strength_b", "favorable_b",
        "year_b", "month_b", "day_b", "hour_b", "element_balance_b",
        "five_elements_assessment", "day_master_relation",
        "zodiac_match", "branch_harmony",
        "synced_fortune_table",
    ],
    "daily_fortune": [
        "day_master", "day_master_element", "day_master_strength",
        "favorable_elements", "unfavorable_elements",
        "date", "lunar_date",
        "day_pillar", "day_stem", "day_stem_element",
        "day_branch", "day_branch_element",
        "day_relation", "day_chong",
        "hour_pillars_with_relations",
        "huangli_yi", "huangli_ji",
    ],
}


class _StrictFormatDict(dict):
    """str.format_map 的字典:缺失 key 时抛清晰 KeyError(不静默填空)。"""

    def __missing__(self, key: str) -> str:  # type: ignore[override]
        raise KeyError(f"prompt 模板占位符 {{{key}}} 在 context 中缺失")


def validate_context(module: str, context: dict) -> None:
    """渲染前显式校验必填字段 + 值类型。

    Args:
        module: 三 module 之一
        context: prompt 渲染负载

    Raises:
        InvalidInputError(422): 缺字段或值类型非法(非标量),message 含详情
        ValueError: module 未注册(代码 bug,非用户错误)
    """
    if module not in REQUIRED_FIELDS:
        raise ValueError(f"未知 module: {module}(代码 bug,需注册到 REQUIRED_FIELDS)")
    required = REQUIRED_FIELDS[module]
    missing = [f for f in required if f not in context]
    if missing:
        raise InvalidInputError(
            f"prompt 渲染缺字段:{missing}(module={module})")
    # 值类型校验:str.format_map 会对非字符串值调 str(),dict/list 会污染 prompt
    # (如 ["a","b"] → "['a', 'b']")。只允许标量类型。
    for field in required:
        value = context[field]
        if not isinstance(value, (str, int, float, bool)):
            raise InvalidInputError(
                f"prompt 渲染字段 {field} 类型非法:{type(value).__name__},"
                f"期望 str/int/float/bool(module={module})")


def render_prompt(module: str, context: dict) -> str:
    """渲染 prompt:先校验必填字段,再 str.format_map 填充。

    bazi_deep 模块命中 day_master_strength == "special_pattern" 时
    追加从格诚实降级约束段。

    Args:
        module: 三 module 之一
        context: prompt 渲染负载(必须含 REQUIRED_FIELDS[module] 所有字段)

    Returns:
        完整 prompt 字符串(可直接送 Claude messages API)
    """
    validate_context(module, context)
    template = _TEMPLATES[module]
    # str.format_map 用 _StrictFormatDict:即使 validate_context 漏了某个字段
    # (模板有占位符但 REQUIRED_FIELDS 没列),也会抛清晰 KeyError 而非静默填空
    rendered = template.format_map(_StrictFormatDict(context))

    # 从格诚实降级(仅 bazi_deep)
    if module == "bazi_deep" and context.get("day_master_strength") == "special_pattern":
        rendered = rendered + BAZI_DEEP_SPECIAL_PATTERN_SUFFIX

    return rendered
