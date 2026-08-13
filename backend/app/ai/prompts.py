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

import logging
from functools import lru_cache
from pathlib import Path

from ..errors import InvalidInputError

logger = logging.getLogger(__name__)

# ---------- 外部模板文件根目录 ----------
# 结构:prompts/{lang}/{module}_v{version}.md
# i18n 决策 4(方案 B):模板/代码分离,加语言只加目录,git diff 清晰。
# Slice 1 已迁移:daily_fortune(zh + en)。
# Slice 2/3/4 将迁移:bazi_deep(_free/_paid)、compatibility(_free/_paid)。
PROMPTS_DIR = Path(__file__).parent / "prompts"

# ---------- prompt 版本号(改模板/换模型时 bump)----------
# 本模块是 PROMPT_VERSIONS 的单一事实源,路由层从此处导入
# 2026-08-01 grill-me 决策:bump 全部 1→2,V2 引入 Medium / Medium-deep voice
# (短句节奏 + 直言 actionable + 每段聚焦一个洞察),老 iOS 本地缓存按
# prompt_version 隔离自动失效。详见 bazi-app-design-doc.md §AI Voice 规范。
PROMPT_VERSIONS: dict[str, int] = {
    "bazi_deep": 2,        # alias(决策 B 保留,向后兼容老 iOS)
    "bazi_deep_free": 2,   # M2 拆分:2 章免费,Medium-deep voice(200-300 字/章)
    "bazi_deep_paid": 2,   # M2 拆分:5 章付费,Medium-deep voice(200-300 字/章)
    "compatibility": 2,    # alias(M4 拆分前单 template 6 章,向后兼容老 iOS)
    "compatibility_free": 2,  # M4 拆分:2 章免费,Medium voice(200-300 字/章)
    "compatibility_paid": 2,  # M4 拆分:4 章付费,Medium voice(200-300 字/章)
    "daily_fortune": 2,    # Medium voice(50-80 字,砍宜忌+砍时辰点评)
}

# ---------- 深度解析 ----------
# 共享 header(命主 + 四柱 + 神煞 + 五行 + 喜忌 + 大运流年)
# 三个 bazi_deep 模板(alias / _free / _paid)共用此 header
_BAZI_DEEP_HEADER = """你是一位精通中国传统四柱八字命理的大师。请基于以下排盘数据进行深度命书解读。

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
"""

# alias 模板(向后兼容,对齐 bazi-app-design-doc.md:410-438)
# 决策 B:M2 保留 module=bazi_deep 作 alias,内部生成综合版本
# iOS M3 跟上改用 _free / _paid 后,可删此 alias
# 2026-08-01 grill-me V2:voice 改 Medium-deep(短句节奏 + 直言 actionable)
BAZI_DEEP_TEMPLATE = _BAZI_DEEP_HEADER + """
写作要求（综合版本，约 300-500 字）：
1. 围绕日主旺衰 + 喜忌 + 神煞 + 大运流年走势，给出 actionable 洞察
2. 短句节奏：每段 2-3 句，每句尽量 <50 字，不写长句堆术语
3. 直言不绕弯：不用"传统认为..."、"古人云..."；直接"你是..."
4. 核心术语保留但不主动解释（日主 / 十神 / 喜忌 / 大运等术语直接用）
5. 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
6. **重要**：格局作为叙事概念模糊处理，用"命局呈现××倾向"，**不得**给出"正官格/偏印格"等硬性分类
7. **重要**：喜忌已由后端确定性给出，你必须严格按后端的 favorable/unfavorable 写，不得自行推断或修改
"""

# M2 拆分:免费 2 章(对齐 MONETIZATION.md §免费/付费内容分界)
# 章节:1. 性格底色 2. 事业方向
# 免费内容必须真有料,让用户感知"AI 真有料"才肯买(设计哲学 §诚实)
# 2026-08-01 grill-me V2:voice 改 Medium-deep(短句节奏 + 每段聚焦一个洞察)
BAZI_DEEP_FREE_TEMPLATE = _BAZI_DEEP_HEADER + """
写作要求（免费 2 章，每章 200-300 字，总 400-600 字）：

**第一章：性格底色**（200-300 字）
围绕日主本质 + 五行倾向 + 整体命局倾向，分 3-5 段，每段 2-3 短句。
每段聚焦一个具体 actionable 洞察。例如：日主心性、五行偏盛带来的行为模式、人际相处倾向。

**第二章：事业方向**（200-300 字）
围绕适合的职业领域 + 岗位类型 + 发展节奏，分 3-5 段，每段 2-3 短句。
每段聚焦一个具体方向，不空泛。例如：适合的行业五行属性、岗位类型（管理 / 创作 / 执行）、节奏建议（早发 / 大器晚成）。

通用要求：
- 短句节奏：每段 2-3 句，每句尽量 <50 字，不写长句堆术语
- 直言不绕弯：不用"传统认为..."、"古人云..."；直接"你是..."
- 核心术语保留但不主动解释：日主 / 十神 / 喜忌 等术语直接用
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
- **重要**：格局作为叙事概念模糊处理，用"命局呈现××倾向"，**不得**给出"正官格/偏印格"等硬性分类
- **重要**：喜忌已由后端确定性给出，你必须严格按后端的 favorable/unfavorable 写，不得自行推断或修改
"""

# M2 拆分:付费 5 章(需 entitlement 才能调用)
# 章节:3. 财运 4. 爱情 5. 健康 6. 六亲 7. 晚年
# 具体领域预测是用户付费动力(MONETIZATION.md §决策汇总)
# 2026-08-01 grill-me V2:voice 改 Medium-deep(短句节奏 + 每段聚焦一个洞察)
BAZI_DEEP_PAID_TEMPLATE = _BAZI_DEEP_HEADER + """
写作要求（付费 5 章，每章 200-300 字，总 1000-1500 字）：

**第一章：财运**（200-300 字）
正财 / 偏财倾向 + 富贵层级 + 流年财星触发年份。分 3-5 段，每段 2-3 短句。
每段聚焦一个具体洞察（正财稳度 / 偏财机缘 / 富贵层级 / 关键流年窗口）。

**第二章：爱情**（200-300 字）
婚姻方向 + 配偶特征 + 婚期窗口。分 3-5 段，每段 2-3 短句。

**第三章：健康**（200-300 字）
体质倾向 + 注意部位 + 调候建议。分 3-5 段，每段 2-3 短句。

**第四章：六亲**（200-300 字）
父母缘 / 兄弟缘 / 子女缘。分 3-5 段，每段聚焦一段关系。

**第五章：晚年**（200-300 字）
晚运倾向 + 中年转折点。分 3-5 段，每段聚焦一个时间窗口或趋势。

通用要求：
- 短句节奏：每段 2-3 句，每句尽量 <50 字，不写长句堆术语
- 直言不绕弯，不堆 5+ 字术语链（"伤官见官" 需拆开或换说法）
- 核心术语保留但不主动解释
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
- **重要**：格局作为叙事概念模糊处理，用"命局呈现××倾向"，**不得**给出"正官格/偏印格"等硬性分类
- **重要**：喜忌已由后端确定性给出，你必须严格按后端的 favorable/unfavorable 写，不得自行推断或修改
"""

# 从格诚实降级约束段(day_master_strength == "special_pattern" 时追加)
# M2 拆分后三个 bazi_deep module(alias / _free / _paid)共用此 suffix
BAZI_DEEP_SPECIAL_PATTERN_SUFFIX = """
**本命盘呈现从格特征，喜忌结论留空。请诚实告知用户：当前未下硬性喜忌结论，避免编造扶抑法喜忌。
可围绕命局呈现的从格倾向（如专旺/从强/从弱等）做叙事性描述，但不得给出确定性的"宜×忌×"结论。**
"""

# ---------- 合盘 ----------
# 对齐 bazi-app-design-doc.md:440-468 + 2026-08-01 grill-me V2 voice 改 Medium
# Slice M4(2026-08-09):拆分 _FREE(2 章) + _PAID(4 章),与深度解析同形态(MONETIZATION.md §合盘)
# 三个模板(alias / _free / _paid)共用此 header
_COMPATIBILITY_HEADER = """你是一位精通八字合婚/合盘的大师。请基于以下两人命盘进行 {context_label} 合盘解读。

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

"""

# alias 模板(向后兼容老客户端,对齐 BAZI_DEEP_TEMPLATE 模式)
# M4 拆分后 iOS 改用 _free / _paid,此 alias 可后续删除
COMPATIBILITY_TEMPLATE = _COMPATIBILITY_HEADER + """写作要求（6 章，每章 200-300 字，总 1200-1800 字）：

**第一章：基础相处模式**（200-300 字）
两人日常互动的基调。分 3-5 段，每段一个相处场景洞察。

**第二章：互补与冲突总览**（200-300 字）
五行互补 + 日主关系 + 地支合冲的具体表现。分 3-5 段。

**第三章：爱情深度**（200-300 字）
情感互动模式 + 长期相处的趋势。分 3-5 段。

**第四章：合作事业**（200-300 字）
事业 / 工作合作的契合度 + 协作建议。分 3-5 段。

**第五章：财运合拍**（200-300 字）
金钱观契合度 + 共同财运趋势。分 3-5 段。

**第六章：流年同步**（200-300 字）
未来 3 年流年同步性，每年一段，指出同步走强 / 走弱的窗口。

通用要求：
- 短句节奏：每段 2-3 句，每句尽量 <50 字，不写长句堆术语
- 直言不绕弯，不堆 5+ 字术语链
- 围绕 {context_label} 维度展开
- 流年同步：指出同步进好运 / 坏运的年份
- **绝对禁忌**：不得给出"必成 / 必分 / 必破财"等绝对结论
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
"""

# M4 拆分:免费 2 章(对齐 MONETIZATION.md §合盘 §免费/付费内容分界)
# 章节:1. 基础相处模式 2. 互补与冲突总览
# 免费内容必须真有料,让用户感知"AI 真有料"才肯买(对齐深度解析免费 2 章策略)
COMPATIBILITY_FREE_TEMPLATE = _COMPATIBILITY_HEADER + """写作要求（免费 2 章，每章 200-300 字，总 400-600 字）：

**第一章：基础相处模式**（200-300 字）
两人日常互动的基调。分 3-5 段，每段一个相处场景洞察。
每段聚焦具体 actionable 洞察（沟通模式 / 决策风格 / 日常节奏契合度）。

**第二章：互补与冲突总览**（200-300 字）
五行互补 + 日主关系 + 地支合冲的具体表现。分 3-5 段。
每段聚焦一个具体维度（互补点给关系带来的资源 / 冲突点需注意的雷区）。

通用要求：
- 短句节奏：每段 2-3 句，每句尽量 <50 字，不写长句堆术语
- 直言不绕弯：不用"传统认为..."；直接"你们..."
- 围绕 {context_label} 维度展开
- 核心术语保留但不主动解释
- **绝对禁忌**：不得给出"必成 / 必分"等绝对结论
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
"""

# M4 拆分:付费 4 章(需 entitlement 才能调用)
# 章节:3. 爱情深度 4. 合作事业 5. 财运合拍 6. 流年同步
# 具体领域预测是用户付费动力(对齐深度解析付费 5 章策略)
COMPATIBILITY_PAID_TEMPLATE = _COMPATIBILITY_HEADER + """写作要求（付费 4 章，每章 200-300 字，总 800-1200 字）：

**第一章：爱情深度**（200-300 字）
情感互动模式 + 长期相处的趋势。分 3-5 段，每段 2-3 短句。
每段聚焦一个具体洞察（情感节奏 / 亲密倾向 / 长期走势）。

**第二章：合作事业**（200-300 字）
事业 / 工作合作的契合度 + 协作建议。分 3-5 段，每段 2-3 短句。

**第三章：财运合拍**（200-300 字）
金钱观契合度 + 共同财运趋势。分 3-5 段，每段 2-3 短句。

**第四章：流年同步**（200-300 字）
未来 3 年流年同步性，每年一段，指出同步走强 / 走弱的窗口。

通用要求：
- 短句节奏：每段 2-3 句，每句尽量 <50 字，不写长句堆术语
- 直言不绕弯，不堆 5+ 字术语链
- 围绕 {context_label} 维度展开
- 流年同步：指出同步进好运 / 坏运的年份
- **绝对禁忌**：不得给出"必成 / 必分 / 必破财"等绝对结论
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
"""

# ---------- 每日运势 ----------
# Slice 1 i18n 迁移:DAILY_FORTUNE_TEMPLATE 已迁移到外部 Markdown 文件
# - prompts/zh/daily_fortune_v2.md(中文版,与原硬编码内容一致)
# - prompts/en/daily_fortune_v2.md(英文版,术语用 Joey Yap 体系)
# 后续 Slice 2/3/4 同步迁移 bazi_deep / compatibility 系列。

# ---------- 模板注册表 ----------

# Slice 1 i18n 改造:_TEMPLATES → _LEGACY_TEMPLATES
# daily_fortune 已迁移到外部 Markdown 文件(prompts/{zh,en}/daily_fortune_v2.md)。
# 其他 module(bazi_deep / compatibility 系列)仍走硬编码常量,等 Slice 2/3/4 迁移。
# _load_template 加载失败时,中文 fallback 到此 dict;英文显式抛错(避免英文 prompt 误用中文)。
_LEGACY_TEMPLATES: dict[str, str] = {
    "bazi_deep": BAZI_DEEP_TEMPLATE,
    "bazi_deep_free": BAZI_DEEP_FREE_TEMPLATE,
    "bazi_deep_paid": BAZI_DEEP_PAID_TEMPLATE,
    "compatibility": COMPATIBILITY_TEMPLATE,
    "compatibility_free": COMPATIBILITY_FREE_TEMPLATE,
    "compatibility_paid": COMPATIBILITY_PAID_TEMPLATE,
    # daily_fortune 已迁移到文件,不在此处
}

# 各 module 必填字段清单(渲染前 validate_context 逐项检查)
# 注:bazi_deep / bazi_deep_free / bazi_deep_paid 共用同一份字段清单(共享 header)
_BAZI_DEEP_REQUIRED_FIELDS = [
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
]

# 注:compatibility / compatibility_free / compatibility_paid 共用同一份字段清单(共享 header)
_COMPATIBILITY_REQUIRED_FIELDS = [
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
]

REQUIRED_FIELDS: dict[str, list[str]] = {
    "bazi_deep": _BAZI_DEEP_REQUIRED_FIELDS,
    "bazi_deep_free": _BAZI_DEEP_REQUIRED_FIELDS,
    "bazi_deep_paid": _BAZI_DEEP_REQUIRED_FIELDS,
    "compatibility": _COMPATIBILITY_REQUIRED_FIELDS,
    "compatibility_free": _COMPATIBILITY_REQUIRED_FIELDS,
    "compatibility_paid": _COMPATIBILITY_REQUIRED_FIELDS,
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


@lru_cache(maxsize=None)
def _load_template(module: str, language: str, version: int) -> str:
    """加载模板并内存缓存。

    i18n 决策 4(方案 B):模板存外部 Markdown 文件,按 (module, language, version) 寻址。

    fallback 策略(严格区分 zh / 非 zh):
    - 优先读 prompts/{language}/{module}_v{version}.md
    - 中文(zh)文件不存在时,fallback 到 _LEGACY_TEMPLATES[module](Slice 1 过渡期,
      其他 module 未文件化),log warning
    - 非中文(如 en)文件不存在时,**显式抛 FileNotFoundError**(绝不静默 fallback
      到中文,避免英文 prompt 误用中文模板)

    Args:
        module: 7 module 之一
        language: "zh" / "en"(未来扩展)
        version: prompt_version 数字

    Returns:
        模板字符串(含 {xxx} 占位符,由 str.format_map 填充)

    Raises:
        FileNotFoundError: 模板文件缺失且无法 fallback
    """
    primary_path = PROMPTS_DIR / language / f"{module}_v{version}.md"
    if primary_path.exists():
        return primary_path.read_text(encoding="utf-8")

    # 文件不存在时的处理
    if language == "zh" and module in _LEGACY_TEMPLATES:
        # 中文 fallback 到硬编码常量(Slice 1 阶段过渡,等 Slice 2/3/4 迁移)
        logger.warning(
            "prompt 模板 module=%s v%s 缺 zh 文件版,fallback 到 _LEGACY_TEMPLATES"
            "(后续 slice 迁移到 prompts/zh/)",
            module, version,
        )
        return _LEGACY_TEMPLATES[module]

    # 非中文或缺中文硬编码 → 显式抛错(避免英文 prompt 误用中文)
    raise FileNotFoundError(
        f"prompt 模板缺失: module={module!r} language={language!r} version=v{version}"
        f"(需在 prompts/{language}/{module}_v{version}.md 补齐)"
    )


def render_prompt(module: str, context: dict, language: str = "zh") -> str:
    """渲染 prompt:先校验必填字段,按 language 加载模板,再 str.format_map 填充。

    bazi_deep 系列(alias / _free / _paid)命中 day_master_strength ==
    "special_pattern" 时追加从格诚实降级约束段。

    Args:
        module: 五 module 之一(bazi_deep / bazi_deep_free / bazi_deep_paid /
            compatibility / daily_fortune)
        context: prompt 渲染负载(必须含 REQUIRED_FIELDS[module] 所有字段)
        language: 目标语言代码(默认 "zh" 向后兼容;i18n 决策 9)

    Returns:
        完整 provider-neutral prompt 字符串(目标语言)

    Raises:
        FileNotFoundError: 目标 language 的模板文件缺失(且非 zh 能 fallback)
        InvalidInputError: context 缺字段或值类型非法
        ValueError: module 未注册
    """
    validate_context(module, context)
    version = PROMPT_VERSIONS[module]
    template = _load_template(module, language, version)
    # str.format_map 用 _StrictFormatDict:即使 validate_context 漏了某个字段
    # (模板有占位符但 REQUIRED_FIELDS 没列),也会抛清晰 KeyError 而非静默填空
    rendered = template.format_map(_StrictFormatDict(context))

    # 从格诚实降级(bazi_deep 系列三个 module 共用同一份 suffix)
    if (module in ("bazi_deep", "bazi_deep_free", "bazi_deep_paid")
            and context.get("day_master_strength") == "special_pattern"):
        if language != "zh":
            # 从格降级 suffix 目前只有中文版(Slice 2 迁移)。
            # 非中文请求显式报错,避免英文 prompt 尾部追加中文 suffix。
            raise FileNotFoundError(
                f"从格降级 suffix 尚无 {language!r} 版本"
                f"(module={module!r},需 Slice 2 补齐"
                f" prompts/{language}/_special_pattern_suffix_v{version}.md)"
            )
        # TODO(Slice 2):先在 prompts/zh/_special_pattern_suffix_v{version}.md 落地文件,
        # 再改成 rendered += _load_template("_special_pattern_suffix", language, version)
        # (届时 zh 也走文件路径,删除此处的硬编码 BAZI_DEEP_SPECIAL_PATTERN_SUFFIX 拼接)
        rendered = rendered + BAZI_DEEP_SPECIAL_PATTERN_SUFFIX

    return rendered
