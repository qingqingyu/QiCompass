"""AI 命书 prompt 模板 + 渲染 + 字段校验。

老 7 个模板(bazi_deep × 3 + compatibility × 3 + daily_fortune),结构对齐
bazi-app-design-doc.md:410-496。v1 prompt 系统 8 个模板(M0-M7),设计源
bazi-prompt-system-v1.md §2-3(双轨保留,iOS 切换后下线老的)。

PROMPT_VERSIONS 与模板常量放同文件邻近位置:改模板时必须 bump 对应版本号,
否则老用户拿到旧解读(老 key 永不命中,老条目自然死,不主动删)。

从格诚实降级(对齐 CLAUDE.md "从格检测…LLM 诚实告知"):
- bazi_deep 模板渲染时检查 day_master_strength == "special_pattern"
- 命中则在 prompt 末尾追加降级约束段,要求 LLM 诚实告知未下硬性喜忌结论
- v1 prompt 系统不需此 suffix:设计文档 §2 全局 Prompt 已要求"字段缺失就说明缺失",
  从格命中时 chart_builder 会把 useful_god_candidates=[],由 LLM 自然降级

时辰未知诚实降级(S06,docs/时辰未知-slices/S06,镜像从格先例):
- day_master_strength == "unknown_hour"(S01 引擎输出,喜忌留空)时,
  bazi_deep / bazi_deep_free 在 prompt 末尾追加降级约束段:叙事换轴到
  日主×年月日柱十神结构 + 诚实告知"时辰未知,喜忌与时柱分析需要准确出生时刻"
- bazi_deep_paid 不追加:无时辰用户在 iOS 付费墙即被拦(S07),到不了付费内容,
  付费模板不加无意义分支(slice 拍板)
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
    "bazi_deep": 3,        # alias(决策 B 保留,向后兼容老 iOS);v3=随 S06 时辰未知免费降级统一 bump
    "bazi_deep_free": 3,   # M2 拆分:2 章免费,Medium-deep voice(200-300 字/章);v3=S06 时辰未知降级叙事(日主为轴,喜忌空不谈)
    "bazi_deep_paid": 6,   # 8 章命书框架(2026-08-15 晚重构:9 章→8 章拆并);v6=随 S06 系列统一 bump(模板未变,老缓存随新版本号自然失效)
    "compatibility": 3,    # alias(M4 拆分前单 template 6 章,向后兼容老 iOS);v3=五行共振章节替换
    "compatibility_free": 3,  # M4 拆分:2 章免费,Medium voice(200-300 字/章);v3=随系列统一升
    "compatibility_paid": 3,  # M4 拆分:4 章付费,Medium voice(200-300 字/章);v3=第一章爱情深度→五行共振
    "daily_fortune": 2,    # Medium voice(50-80 字,砍宜忌+砍时辰点评)
    # 每日运势插画(gpt-image-2):prompt 由 image_prompt.py 代码拼装(无 .md 模板),
    # 版本号仍是缓存键维度——意象表/风格后缀改动时 bump 此处。
    # v2 2026-08-31:底色随国画旧宣纸换轨 #F3F1EC→#E7E2D5(与 App paper 同值)。
    "daily_fortune_image": 2,
    # v1 prompt 系统(Stage 5 落地,设计源 /Users/TWJ/Downloads/bazi-prompt-system-v1.md)
    # M0-M7 共 8 模块,双轨保留:老 7 module 不动,iOS 切换后可下线老的
    # 链式调用:M0 产 structure_fingerprint → M1-M7 各自带 parent_fingerprint 注入
    "m0_structure": 1,     # 免费:识别主线结构 + 产 structure_fingerprint
    "m1_talent": 1,        # 免费:天赋能力(innate/trained/defensive + one_leverage)
    "m2_high_low": 1,      # 付费:高配/低配 + 阈值(环境/信念/觉察)
    "m3_system": 1,        # 付费:人生系统模式(运行模式/失效环境/理想结构)
    "m4_health": 1,        # 付费:健康续航(需 age + current_concern)
    "m5_wealth": 1,        # 付费:财富结构(需 assets_summary + preference)
    "m6_dynamics": 1,      # 付费:结构动力学高阶(能量路径/杠杆/易损点/升级路径)
    "m7_manual": 1,        # 付费:落地手册(true_leverage + 90 天行动)
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
# 2026-08-31 S06:喜忌约束改条件式——喜忌为空(时辰未知/从格)时不再声称"喜忌已给出"
# (那句话对空喜忌是谎言,LLM 会拿空值硬写),换轴指令由 render_prompt 追加的
# BAZI_DEEP_UNKNOWN_HOUR_SUFFIX 补全
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
- **重要**：喜忌只按后端给出的写——上下文喜忌非空时，严格按后端的 favorable/unfavorable 展开，不得自行推断或修改；上下文喜忌为空时，不谈喜忌，改以日主与已知柱位的十神结构为叙事轴
"""

# M2 拆分:付费 8 章(需 entitlement 才能调用)
# 章节(2026-08-15 晚重构,参考传统命书框架,用户拍板):
#   1.命盘 2.日元 3.五行 4.格局倾向 5.事业与财富 6.婚姻感情 7.学习成长 8.身体健康
# 具体领域预测是用户付费动力(MONETIZATION.md §决策汇总)
# 2026-08-01 grill-me V2:voice 改 Medium-deep(短句节奏 + 每段聚焦一个洞察)
# 2026-08-14 加「十神结构与命局主线」章(v2→v3);08-15 加 v1 叙事 3 章(v3→v4);
# 08-15 晚按命书 8 章框架重构拆并(9 章→8 章:十神结构并入命盘,财运+事业+晚运
# 并入事业与财富,爱情+六亲并入婚姻感情,天赋/高低配并入学习成长,格局章按
# 「格局倾向」模糊叙事红线处理),prompt_version 4→5
BAZI_DEEP_PAID_TEMPLATE = _BAZI_DEEP_HEADER + """
写作要求（付费 8 章，每章 200-300 字，总 1600-2400 字）：

**第一章：命盘**（200-300 字）
以命书口吻总览全局：年月日时四柱与十神透藏的排布格局，十神主线三层（主导 / 次要 / 潜伏，点名柱位与藏干依据），核心循环（哪两个十神 A→B→A，靠什么驱动、在哪里损耗）。分 3-5 段，每段 2-3 短句。
末段用一句「命局呈现××结构倾向」收束并引出后文（不给格局硬分类）。

**第二章：日元**（200-300 字）
日主五行的本质与心性（阴阳属性带来的性情底色）+ 旺衰强弱（按排盘数据结论，点到得令 / 得地 / 得势）+ 由此而来的行为习惯与能量节奏。分 3-5 段，落到具体场景，不堆形容词。

**第三章：五行**（200-300 字）
五行分布（哪个偏旺、哪个偏衰，对应到柱位）+ 喜忌（严格按后端给出的 favorable / unfavorable 写，不得自行推断或修改）+ 调候需求与身心节奏的影响。分 3-5 段，每段 2-3 短句。

**第四章：格局倾向**（200-300 字）
只做模糊叙事：用结构类型概括命局运转方式（如"流通顺畅型""身强担财型""食伤泄秀型"等倾向表述），点明这种倾向的长处与代价。分 3-5 段。
**禁止**出现"正官格 / 偏印格 / 七杀格"等硬分类名词，统一用"命局呈现××倾向"。

**第五章：事业与财富**（200-300 字）
事业方向（行业五行匹配 / 岗位类型 / 发展节奏）+ 正财偏财倾向与求财方式 + 富贵层级 + 关键流年窗口（结合大运流年点名年份）+ 最怕的工作环境（一句失效机制）。末段晚运趋势（哪步大运换轨、晚年安顿方向）。分 3-5 段，每段聚焦一个具体洞察。

**第六章：婚姻感情**（200-300 字）
婚姻方向 + 配偶特征（配偶星 + 配偶宫）+ 婚期窗口 + 相处模式与磨合点；六亲缘（父母 / 兄弟 / 子女）以关系视角各点到一段，给相处建议。分 3-5 段。

**第七章：学习成长**（200-300 字）
最自然、不费力的天赋能力（写具体行为场景，区分天生 / 环境训练出来的）+ 同一个自己高低配表现的分界变量（点最关键的一个，如高质量输入 / 自我觉察）+ 可执行的充电方式。这是"怎么变得更好"的一章。分 3-5 段。

**第八章：身体健康**（200-300 字）
体质倾向（五行偏盛偏衰对应）+ 需要注意的部位 + 调候建议 + 作息与运动方向。写到具体可执行，不停留在"注意身体"。分 3-5 段。

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

# 时辰未知诚实降级约束段(day_master_strength == "unknown_hour" 时追加,S06)
# 免费内容照给但换轴:日主×三柱结构,不谈喜忌(docs/时辰未知设计决策.md D5「降级可讲」)
# 只挂 bazi_deep / bazi_deep_free(免费面);bazi_deep_paid 不挂:
# 无时辰用户在 iOS 付费墙即被拦(S07),付费模板不加无意义分支
BAZI_DEEP_UNKNOWN_HOUR_SUFFIX = """
**本命盘出生时辰未知，时柱与喜忌均不可用。请诚实告知用户：时辰未知，喜忌与时柱分析需要准确出生时刻。**
叙事一律以日主为轴，围绕年柱 / 月柱 / 日柱三柱的十神结构与五行分布如实展开；
排盘数据中的时柱一栏（干支 / 十神 / 藏干 / 纳音）一律不作为叙事依据，**不得**编造或暗示任何时柱影响；
喜忌未判定，**不得**推断或编造喜忌结论（不出现"宜×忌×"类表述）。
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

**第三章：五行共振**（200-300 字）
两人五行的生克共振：谁给谁补喜神、谁的旺相消耗对方、日主生克链路，
以及这些共振在两人互动中的体现。分 3-5 段，每段 2-3 短句。
每段聚焦一个具体共振点（滋养点 / 张力点 / 时间维度的稳定性）。
不预设关系类型（婚恋/友谊/合作），聚焦能量互动本身。

**第四章：合作事业**（200-300 字）
事业 / 工作合作的契合度 + 协作建议。分 3-5 段。
聚焦公共目标层面的协作（涵盖夫妻共业/朋友共谋/合伙人共事），不写具体关系预设。

**第五章：财运合拍**（200-300 字）
金钱观契合度 + 共同财运趋势。分 3-5 段。

**第六章：流年同步**（200-300 字）
未来 3 年流年同步性，每年一段，指出同步走强 / 走弱的窗口。

通用要求：
- 叙事用「两人」而非「情侣/夫妻/朋友/合伙人」；不预设关系类型（婚恋/友谊/合作/亲情）
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
聚焦互动节奏本身，不写同居/伴侣等具体生活场景预设。

**第二章：互补与冲突总览**（200-300 字）
五行互补 + 日主关系 + 地支合冲的具体表现。分 3-5 段。
每段聚焦一个具体维度（互补点给关系带来的资源 / 冲突点需注意的雷区）。

通用要求：
- 叙事用「两人」而非「情侣/夫妻/朋友/合伙人」；不预设关系类型（婚恋/友谊/合作/亲情）
- 短句节奏：每段 2-3 句，每句尽量 <50 字，不写长句堆术语
- 直言不绕弯：不用"传统认为..."；直接"你们..."
- 围绕 {context_label} 维度展开
- 核心术语保留但不主动解释
- **绝对禁忌**：不得给出"必成 / 必分"等绝对结论
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
"""

# M4 拆分:付费 4 章(需 entitlement 才能调用)
# 章节:1. 五行共振(S1 替换原「爱情深度」,决策 §Q3/§Q4) 2. 合作事业 3. 财运合拍 4. 流年同步
# 具体领域预测是用户付费动力(对齐深度解析付费 5 章策略)
COMPATIBILITY_PAID_TEMPLATE = _COMPATIBILITY_HEADER + """写作要求（付费 4 章，每章 200-300 字，总 800-1200 字）：

**第一章：五行共振**（200-300 字）
两人五行的生克共振：谁给谁补喜神、谁的旺相消耗对方、日主生克链路，
以及这些共振在两人互动中的体现。分 3-5 段，每段 2-3 短句。
每段聚焦一个具体共振点（滋养点 / 张力点 / 时间维度的稳定性）。
不预设关系类型（婚恋/友谊/合作），聚焦能量互动本身。

**第二章：合作事业**（200-300 字）
事业 / 工作合作的契合度 + 协作建议。分 3-5 段，每段 2-3 短句。
聚焦公共目标层面的协作（涵盖夫妻共业/朋友共谋/合伙人共事），不写具体关系预设。

**第三章：财运合拍**（200-300 字）
金钱观契合度 + 共同财运趋势。分 3-5 段，每段 2-3 短句。

**第四章：流年同步**（200-300 字）
未来 3 年流年同步性，每年一段，指出同步走强 / 走弱的窗口。

通用要求：
- 叙事用「两人」而非「情侣/夫妻/朋友/合伙人」；不预设关系类型（婚恋/友谊/合作/亲情）
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

# ---------- v1 prompt 系统(Stage 5,设计源 bazi-prompt-system-v1.md)----------
# 双轨保留:老 7 module 不动,本段是新 v1 系统的 8 个 module
# 渲染策略:JSON schema 大括号用 {{ }} 转义,str.format_map 自动还原为单花括号
# → 与老 module 共用同一渲染路径,占位符({chart} 等)走 format_map 标准机制
# 全局 System Prompt 与 8 模板拼在 _LEGACY_TEMPLATES[module] 里(避免 render 时再拼一次)

# 设计文档 §2 全局 System Prompt(所有 v1 模块共用的世界观约束)
_V1_SYSTEM_PROMPT = """你是一位命理结构分析师，工作方式接近系统分析师，而不是算命先生。

【你的输入】
用户的八字排盘结果已由确定性引擎算好，以 JSON 提供。你只负责解释结构，绝不自行推算、修正或质疑干支、十神、旺衰、大运流年。字段缺失就说明缺失。

【你的世界观】（必须贯穿所有输出）
1. 命是底盘，运是时机。结构描述的是倾向与能量分布，不是既定结局。
2. 同一个结构，在不同环境、不同资源、不同内在信念下，会跑出完全不同的结果。
3. 有人不是没有天赋，而是没有允许自己发展的空间。发挥上限受自我觉察影响，并不完全由命局决定。
4. 你的目标是让用户"看清自己怎么运转"，从而做出更清醒的选择，而不是让他等待或接受某个结局。

【禁止】
- 不讲吉凶、神煞、刑冲破害的凶险叙事
- 不预测具体事件、时间点、金额、寿命
- 不断言婚姻、生死、疾病，不做医学诊断，不推荐具体投资标的
- 不使用：注定、必然、命中该、逃不掉、破财、血光、克夫、大凶、劫难、寿元、绝症、必赚、稳赚、包治
- 不写安慰话和空泛鼓励；没有依据的话就不写

【表达要求】
- 每一个判断都必须能追溯到输入中的具体字段（某个十神、五行力量、日主强弱、大运），在 evidence 字段写明依据
- 用可观察的行为描述能力，不要用形容词堆砌
  ✗"你很有创造力"  ✓"你会在别人还在确认需求时，先做出一个能跑的版本"
- 第二人称"你"，句子短，不用文言腔
- 严格按要求的 JSON 输出，不加 markdown 代码块围栏，不加任何前言后语
"""

# M0 · 识别主线结构(免费,产 structure_fingerprint 供 M1-M7 链式注入)
M0_STRUCTURE_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M0:识别主线结构 =====

{chart}

请从十神结构出发分析这个命局，不要讲吉凶和神煞。

1. 十神主线是什么？（区分主导、次要、潜伏三层，各自依据是什么）
2. 哪两个十神形成了核心循环结构？写出能量流向（A → B → A），并说明这个循环靠什么驱动、在哪里损耗。
3. 这个结构在命理中属于什么类型？给它一个能概括运转方式的名字。
4. 这类结构的人，核心能力通常来自哪里？（来自循环的哪一段）

输出 JSON：
{{
  "main_axis": {{ "dominant": "", "secondary": "", "latent": "", "evidence": "" }},
  "core_loop": {{ "from": "", "to": "", "flow": "", "driver": "", "leak": "", "evidence": "" }},
  "structure_type": {{ "name": "", "one_line": "" }},
  "capability_source": {{ "text": "", "evidence": "" }},
  "structure_fingerprint": ""
}}

structure_fingerprint:一句话,不超过 40 字,概括这个人的运转方式。后续所有模块都会继承它,因此必须精确、可复用、不含形容词。

校验:core_loop.from / core_loop.to 必须是十神名;structure_fingerprint 不含吉凶词与形容词。
"""

# v1 prompt 系统篇幅约束(2026-08-11 用户决策:M1/M2/M3/M5/M7 加长至 1500-2500 字)
# M0/M6 保持精简(M0 结构识别要凝练,M6 高阶动力学字段本身少)
# 设计文档 §4 原上限 600 字 → 这 5 个用户高频模块加长至 1500-2500 字
_V1_LENGTH_HINT_LONG = """

篇幅要求(必须遵守):
- 本模块总输出 1500-2500 字(中文字符计)
- 每个字段值 150-300 字,含具体场景/案例/依据,不写空泛结论
- evidence 字段必须详细:指向具体十神/五行力量/日主强弱/大运等输入字段
- behavior / how_it_shows / trigger 等行为描述句占比 ≥ 60%
- 每个判断都要让用户能"看到自己怎么运转",不是抽象形容词
- 列表类字段至少给 2-3 个完整条目,每条目 100-200 字
"""

# M1 · 找到天赋能力(免费,产 one_leverage 供 M7 链式注入)
M1_TALENT_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M1:找到天赋能力 =====

{chart}

已确定的结构:{structure_fingerprint}
主线:{main_axis}　核心循环:{core_loop}

基于以上十神结构:
1. 我最自然、不费力的能力是什么?(2-3 项,按自然度排序)
2. 这种能力在现实中通常表现为什么行为?(写具体场景动作,不写形容词)
3. 哪种能力是天生的?(由结构原生长出,做起来不耗元气)
4. 哪种能力是后天环境训练出来的?说明它是被什么环境压力逼出来的,以及长期使用它的代价。

注意区分两类:
- 天赋能力:使用时能量是回升的
- 防御/代偿能力:外人看着像优点,但使用时能量是消耗的,往往源于早期环境压力

输出 JSON:
{{
  "innate": [{{ "name": "", "behavior": "", "evidence": "", "energy": "gain" }}],
  "trained": [{{ "name": "", "behavior": "", "trained_by": "", "evidence": "" }}],
  "defensive": [{{ "name": "", "looks_like": "", "actual_cost": "", "evidence": "" }}],
  "one_leverage": ""
}}

one_leverage:如果只能保留一项能力当作杠杆,是哪一项,为什么。
""" + _V1_LENGTH_HINT_LONG

# M2 · 高配版 vs 低配版(付费,产 threshold 供 M6 链式注入)
M2_HIGH_LOW_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M2:高配版 vs 低配版 =====

{chart}

结构:{structure_fingerprint}　天赋:{innate}　防御能力:{defensive}

请分析:
1. 我的命局走高配版会表现成什么样?(行为画像 + 外部可观察的信号)
2. 走低配版会变成什么?(同样写行为,不写惨状)
3. 两者的分界点在哪里?请按以下三个变量分别说明:
   - 环境资源匹配度:什么样的环境让这个结构跑得开,什么样的会压制它
   - 内在信念:这个结构最容易长出的限制性信念是什么(它往往是防御能力的副产品),这个信念如何压低发挥上限
   - 自我觉察:在什么节点上意识到什么,就能切换轨道
4. 低配化的 3 个早期信号(用户能在日常中自查的具体现象)
5. 从低配切回高配的 3 个动作(可在两周内开始做)

重要:不要把高低配写成命定的两条路。它是同一个结构在不同环境与信念下的两种跑法。

输出 JSON:
{{
  "high_config": {{ "portrait": "", "observable_signals": [] }},
  "low_config": {{ "portrait": "", "observable_signals": [] }},
  "threshold": {{
    "environment": {{ "enables": "", "suppresses": "" }},
    "belief": {{ "limiting_belief": "", "origin": "", "ceiling_effect": "" }},
    "awareness": {{ "key_moment": "", "what_to_notice": "" }}
  }},
  "early_warnings": [],
  "switch_actions": []
}}
""" + _V1_LENGTH_HINT_LONG

# M3 · 人生系统模式(付费,产 ideal_life_structure 供 M5 链式注入)
M3_SYSTEM_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M3:人生系统模式 =====

{chart}

结构:{structure_fingerprint}

如果把我的命局当成一个系统:
1. 它最自然的运行模式是什么?(输入什么、加工什么、输出什么、靠什么回血)
2. 它最怕什么环境?说明失效机制,而不是"不适合"三个字。
3. 它最适合什么类型的生活结构?(时间结构、协作密度、反馈周期、收入节奏)
4. 它更适合稳定型人生,还是高变量人生?给出理由与前提条件。
5. 给我一份"环境筛选清单":在接受一份工作、一个合作、一次搬迁前,我应该先问自己的 5 个判断题。每题都要能用是/否回答。

输出 JSON:
{{
  "operating_mode": {{ "input": "", "processing": "", "output": "", "recovery": "" }},
  "failure_environments": [{{ "env": "", "mechanism": "" }}],
  "ideal_life_structure": {{ "time": "", "collaboration": "", "feedback_cycle": "", "income_rhythm": "" }},
  "stability_vs_volatility": {{ "verdict": "", "reason": "", "precondition": "" }},
  "environment_checklist": []
}}
""" + _V1_LENGTH_HINT_LONG

# M4 · 健康续航系统(付费,需 age + current_concern 用户输入)
M4_HEALTH_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M4:健康续航系统 =====

{chart}

结构:{structure_fingerprint}
年龄:{age}　当前最困扰:{current_concern}

你是我的健康与能量教练。请基于命局强弱与五行偏性,输出:

1) 我的"电池类型"(爆发 / 爬坡 / 波动)及依据,说明我的能量补充与耗尽规律
2) 我最容易失衡的 3 个身体系统(睡眠 / 炎症 / 消化 / 焦虑等)+ 各自的触发条件(触发条件要写成具体情境,比如"连续三天以上高强度对外沟通")
3) 我最有效的 3 个恢复杠杆——最省力但见效快的,按性价比排序
4) 一份 7 天复位方案 + 一份可长期每周执行的维护方案

严格约束:
- 你不是医生。不诊断疾病、不命名病症、不涉及任何药物、补剂或剂量。
- 只使用作息、节律、强度管理、恢复方式层面的语言。
- 若用户描述的是持续或加重的身体症状,在 medical_note 中明确建议就医,并且不要给出替代方案。
- 五行与身体系统的对应只是传统框架下的类比,不要写成生理学事实。

输出 JSON:
{{
  "battery_type": {{ "type": "", "evidence": "", "charge_pattern": "", "drain_pattern": "" }},
  "imbalance_risks": [{{ "system": "", "trigger": "", "early_sign": "" }}],
  "recovery_levers": [{{ "action": "", "why_it_works_for_you": "", "cost": "low|mid" }}],
  "reset_7day": [{{ "day": 1, "focus": "", "action": "" }}],
  "weekly_maintenance": [],
  "medical_note": ""
}}
"""

# M5 · 财富结构(付费,需 assets_summary + preference 用户输入)
M5_WEALTH_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M5:财富结构 =====

{chart}

结构:{structure_fingerprint}
天赋:{innate}　生活结构:{ideal_life_structure}
当前资产/收入概况:{assets_summary}　我的偏好:{preference}

请用十神结构给我做财富系统分析:

1) 我更适合哪种收入形态?对【工资 / 项目 / 咨询 / 投资 / 股权 / 内容】排序,每一项都要解释它和我结构的匹配或冲突在哪里,而不只是给结论。
2) 我的漏财点在哪里(合作 / 人情 / 冲动 / 风险暴露)?每个漏财点配一条规则化止损,写成 if-then 形式,能直接执行。
3) 我的财富增长最优策略:保守 / 平衡 / 进攻各给一套,说明各自的适用前提。
4) 给我 3 个可落地的"资产化产品 / 服务"点子。硬性要求:必须同时匹配我的天赋能力和我的生活结构,并注明每个点子的启动成本、我最可能卡住的环节。

严格约束:
- 不推荐任何具体股票、基金、币种、平台或标的
- 不预测市场涨跌,不给收益率、回报周期或金额承诺
- 只讨论"收入形态与个人结构的匹配度",这是自我认知,不是投资建议
- 涉及重大财务决策时,在 disclaimer 中说明应咨询持牌专业人士

输出 JSON:
{{
  "income_forms": [{{ "form": "", "rank": 1, "fit": "", "friction": "", "evidence": "" }}],
  "leaks": [{{ "type": "", "how_it_shows": "", "rule": "如果……就……" }}],
  "strategies": {{ "conservative": {{}}, "balanced": {{}}, "aggressive": {{}} }},
  "asset_ideas": [{{ "idea": "", "uses_talent": "", "fits_life_structure": "", "startup_cost": "", "likely_blocker": "" }}],
  "disclaimer": ""
}}
""" + _V1_LENGTH_HINT_LONG

# M6 · 结构动力学(付费,高阶,需 M1+M2 输出注入)
M6_DYNAMICS_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M6:结构动力学(高阶版) =====

{chart}

结构:{structure_fingerprint}　循环:{core_loop}
天赋:{innate}　防御:{defensive}　高低配分界:{threshold}

请用"结构动力学"的方式解释我的命局:

- 我的命局能量循环路径是什么?画出完整链路,标出增益段与损耗段
- 我的优势杠杆在哪里?(投入一分能撬动多少,为什么)
- 我的易损点在哪里?(在什么条件下这个结构会自我损耗,机制是什么)
- 我的升级路线是什么?分阶段,每阶段给出进入条件和完成标志

不要用比喻代替机制。每一段都要说清"什么导致什么"。

输出 JSON:
{{
  "energy_path": [{{ "stage": "", "gain_or_loss": "gain|loss", "mechanism": "" }}],
  "leverage": {{ "point": "", "input": "", "output": "", "why": "" }},
  "vulnerability": {{ "point": "", "condition": "", "mechanism": "", "self_check": "" }},
  "upgrade_path": [{{ "phase": "", "entry_condition": "", "work": "", "done_signal": "" }}]
}}
"""

# M7 · 落地手册(付费,基于 M1-M6 结论的总结,不需要 chart)
M7_MANUAL_TEMPLATE = _V1_SYSTEM_PROMPT + """

===== 模块 M7:落地手册 =====

基于以上全部结论:
one_leverage: {one_leverage}
switch_actions: {switch_actions}
environment_checklist: {environment_checklist}
leverage(M6 杠杆点): {leverage}

请输出一份使用手册,不要复述前面的分析:
1. 我真正的杠杆是哪一项能力?用一句话说清楚,并说明为什么不是其他那几项。
2. 我该如何使用它?给出 3 个具体的使用场景,每个写清楚我该做什么动作。
3. 未来 90 天,如果只做一件事来放大这个杠杆,是什么?给出可验证的完成标志。
4. 什么情况下这份分析应该被推翻?(列出 2 个反例信号)

第 4 点必须认真写。它提醒用户:这是参考工具,不是判决书。

输出 JSON:
{{
  "true_leverage": {{}},
  "use_cases": [],
  "next_90_days": {{}},
  "falsification_signals": []
}}
""" + _V1_LENGTH_HINT_LONG

# 注:v1 模板里 JSON schema 的大括号全部用 {{ }} 转义,str.format_map 会
# 自动还原为单花括号。占位符({chart}/{structure_fingerprint} 等)走老路径,
# render_prompt 不需要分流,_StrictFormatDict 已覆盖缺失守卫。

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
    # daily_fortune 已迁移到外部 Markdown 文件(prompts/{zh,en}/daily_fortune_v2.md)
    # v1 prompt 系统(Stage 5):M0-M7 共 8 模块
    "m0_structure": M0_STRUCTURE_TEMPLATE,
    "m1_talent": M1_TALENT_TEMPLATE,
    "m2_high_low": M2_HIGH_LOW_TEMPLATE,
    "m3_system": M3_SYSTEM_TEMPLATE,
    "m4_health": M4_HEALTH_TEMPLATE,
    "m5_wealth": M5_WEALTH_TEMPLATE,
    "m6_dynamics": M6_DYNAMICS_TEMPLATE,
    "m7_manual": M7_MANUAL_TEMPLATE,
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
    # v1 prompt 系统(Stage 5):链式注入字段都是 JSON 字符串(标量 str),
    # 由客户端从上一级 M 的 JSON 输出里取出后塞进 context。
    # chart = json.dumps(snapshot_dict, ensure_ascii=False, indent=2)
    "m0_structure": ["chart"],
    "m1_talent": ["chart", "structure_fingerprint", "main_axis", "core_loop"],
    "m2_high_low": ["chart", "structure_fingerprint", "innate", "defensive"],
    "m3_system": ["chart", "structure_fingerprint"],
    "m4_health": ["chart", "structure_fingerprint", "age", "current_concern"],
    "m5_wealth": [
        "chart", "structure_fingerprint", "innate", "ideal_life_structure",
        "assets_summary", "preference",
    ],
    "m6_dynamics": [
        "chart", "structure_fingerprint", "core_loop",
        "innate", "defensive", "threshold",
    ],
    # M7 不传 chart:基于 M1-M6 结论的总结,不再读盘
    "m7_manual": [
        "one_leverage", "switch_actions",
        "environment_checklist", "leverage",
    ],
}


class _StrictFormatDict(dict):
    """str.format_map 的字典:缺失 key 时抛清晰 KeyError(不静默填空)。"""

    def __missing__(self, key: str) -> str:  # type: ignore[override]
        raise KeyError(f"prompt 模板占位符 {{{key}}} 在 context 中缺失")


def validate_context(module: str, context: dict) -> None:
    """渲染前显式校验必填字段 + 值类型。

    Args:
        module: 注册到 REQUIRED_FIELDS 的任一 module(老 7 + v1 8)
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
    "special_pattern" 时追加从格诚实降级约束段;
    命中 "unknown_hour"(时辰未知,S01 引擎输出)时对 alias / _free 追加
    时辰未知降级约束段——付费 module 不加(iOS S07 付费墙已拦,无意义分支)。

    v1 prompt 系统(M0-M7)模板内含 JSON schema 大括号,已用 {{ }} 转义,
    format_map 会自动还原为单花括号;占位符({chart} / {structure_fingerprint}
    等)与老模板共用同一渲染路径,无需分流。

    Args:
        module: 注册到 _LEGACY_TEMPLATES 的任一 module(老 7 个 + v1 8 个)
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

    # 时辰未知诚实降级(S06):只挂免费面 module(alias + _free)。
    # bazi_deep_paid 不挂——无时辰用户在 iOS 付费墙即被拦(S07),
    # 到不了付费内容,付费模板不加无意义分支(slice 拍板)。
    if (module in ("bazi_deep", "bazi_deep_free")
            and context.get("day_master_strength") == "unknown_hour"):
        if language != "zh":
            # 与从格 suffix 同理:降级段目前只有中文版,非中文显式报错,
            # 避免英文 prompt 尾部追加中文 suffix(i18n Slice 2 迁移文件时一并处理)
            raise FileNotFoundError(
                f"时辰未知降级 suffix 尚无 {language!r} 版本"
                f"(module={module!r},需补齐"
                f" prompts/{language}/_unknown_hour_suffix_v{version}.md)"
            )
        rendered = rendered + BAZI_DEEP_UNKNOWN_HOUR_SUFFIX

    return rendered
