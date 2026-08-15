"""promo 加长版 prompt(2026-08-13 用户决策:App 输出太短,宣传物料要长文)。

设计:
- **模板级换写作要求块**,不做"后文覆盖前文"式 suffix 追加:
  backend 7 个老模板都是 `HEADER + 写作要求块`,写作要求块以字面
  `写作要求（` 开头。promo 版 = 同一 HEADER(命主/四柱/评估数据)+ 本文件的
  加长版写作要求。这样 prompt 里**只有一套字数约束**,避免
  "每章 200-300 字"与"每章 1000-1500 字"打架导致 LLM 折中。
- **不动 backend/app/ai/prompts.py**:App 的 Medium voice(200-300 字/章、
  每日 50-80 字)是 2026-08-01 grill 产品决策,只对 promo 调用侧放宽。
- 从格诚实降级 suffix 逻辑与 render_prompt 对齐(bazi_deep 系列复制)。

篇幅(激进 ~5x):
- bazi_deep_paid:**五阶段叙事**(2026-08-15 晚定稿):主线结构 → 天赋能力 →
  高配低配 → 人生系统模式 → 大运流年时间轴 → 关系与婚姻 → 高阶结构动力学 →
  落地手册,每阶段 1000-1500 字,总 8000-12000 字。与 App 的命书 8 章框架
  (backend prompts.py v5)是两条轨道:App 走传统命书章节名,宣传走 v1 结构叙事
- bazi_deep_free:每章 1000-1500 字,3 章(十神结构 + 性格底色 + 事业方向)
- compatibility_free / _paid:每章 1000-1500 字
- daily_fortune:400-600 字

渲染入口:`render_prompt_with_length(module, context, length_tier)`。
"""

from __future__ import annotations

from app.ai.prompts import (
    _StrictFormatDict,
    _TEMPLATES,
    BAZI_DEEP_SPECIAL_PATTERN_SUFFIX,
    render_prompt,
    validate_context,
)

# 写作要求块在模板中的起始标记(7 个老模板均以此开头,仅出现一次)
_REQUIREMENTS_MARKER = "写作要求（"

# length_tier 取值
LENGTH_TIER_APP = "app"
LENGTH_TIER_PROMO = "promo"
LENGTH_TIERS = {LENGTH_TIER_APP, LENGTH_TIER_PROMO}

# 模板展示用标签
LENGTH_TIER_LABELS = {LENGTH_TIER_APP: "App 标准", LENGTH_TIER_PROMO: "加长版"}

# 加长版调用参数:bazi paid 9 章(自我认知 4 + 生活领域 5)上限 13500 字 → 32768
# token 上限 + 900s 超时(2026-08-14 16384→24576:6 章会截断;2026-08-15 加 3 章
# 后 9 章 × 1500 字 ≈ 20k-27k token,再上调至 32768;超时 420s→900s 同日:非流式
# 调用要整篇生成完才返回,z.ai 中转慢时要 >7 分钟,实测 421s ReadTimeout)。
# App 路径仍是 config 默认 1024 / 90s,不受影响。
PROMO_MAX_OUTPUT_TOKENS = 32768
PROMO_TIMEOUT_SECONDS = 900.0


# ---------- 深度解析 ----------

_BAZI_DEEP_PROMO_COMMON = """通用要求：
- **每章 1000-1500 字（中文字符计），不低于 1000 字**
- 每章分 5-8 段，每段讲透一个洞察；段内可展开推理，不赶节奏
- 章内可用 2-4 个**加粗小标题**组织内容（便于长文阅读）
- 每个判断落到盘面依据（某十神、某五行偏盛、日主旺衰、某步大运），像专业命理师复盘，不空泛
- 直言不绕弯：不用"传统认为..."、"古人云..."；直接"你是..."
- 核心术语直接用（日主 / 十神 / 喜忌 / 大运等），关键处可顺带一句白话点透，不写成科普文
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
- **重要**：格局作为叙事概念模糊处理，用"命局呈现××倾向"，**不得**给出"正官格/偏印格"等硬性分类
- **重要**：喜忌已由后端确定性给出，你必须严格按后端的 favorable/unfavorable 写，不得自行推断或修改
"""

_BAZI_TEN_GOD_CHAPTER = """**第一章：十神结构与命局主线**（1000-1500 字）
从十神结构出发讲这个命局怎么运转。必须覆盖：
- 十神主线：主导 / 次要 / 潜伏三层，各自依据（哪个柱天干透出、哪个藏干潜伏，直接点名）
- 核心循环：哪两个十神形成「A → B → A」的能量循环，这个循环靠什么驱动、在哪里损耗
- 用一句话概括这个结构的运转方式，并用「命局呈现××结构倾向」表述（不得给格局硬分类）
- 这个结构如何决定了后面各章的表现（财运 / 性格 / 事业从这个结构的哪一段长出来）

注意：四柱十神与藏干以开头排盘数据为准，只解释不推算，不得自行改排。

"""

BAZI_DEEP_FREE_PROMO_REQUIREMENTS = """写作要求（免费 3 章 · 长文版，每章 1000-1500 字，总 3000-4500 字）：

""" + _BAZI_TEN_GOD_CHAPTER + """**第二章：性格底色**（1000-1500 字）
围绕日主本质 + 五行倾向 + 十神心性 + 整体命局倾向展开。建议覆盖：
思维方式与决策习惯、能量节奏（什么状态下高效）、人际相处模式、压力下的反应模式、自我修炼方向。
每个维度落到具体场景举例，并给盘面依据（承接第一章的十神主线）。

**第三章：事业方向**（1000-1500 字）
围绕适合的职业领域 + 岗位类型 + 发展节奏展开。建议覆盖：
行业五行属性匹配、岗位类型（管理 / 创作 / 执行 / 技术）、创业 vs 平台、
发展节奏（早发 / 大器晚成）、当前大运给出的时间窗口、需要避开的坑。

""" + _BAZI_DEEP_PROMO_COMMON

_BAZI_V1_STRUCTURE_CHAPTERS = """**第二阶段：天赋能力**（1000-1500 字）
最自然、不费力的能力 2-3 项（按自然度排序，每项写具体行为场景，不写形容词）。
区分三类：结构原生的天赋（用起来能量回升）、环境训练出来的能力（被什么压力逼出来的、长期使用的代价）、外人看着像优点的防御/代偿能力（实际消耗能量）。
末段落定：如果只能保留一项当杠杆，是哪一项，为什么。

**第三阶段：高配版与低配版**（1000-1500 字）
同一个结构的两种跑法（不是命定的两条路）。高配版行为画像 + 外部可观察信号；
低配版行为画像 + 可观察信号；分界点按三个变量展开：环境资源匹配度（什么环境让它跑得开/被压制）、内在信念（最易长出的限制性信念及其压低上限的机制）、自我觉察（在什么节点意识到什么就能切换轨道）。
给 3 个低配化早期信号（日常可自查）+ 3 个切回高配的动作（两周内可开始）。

**第四阶段：人生系统模式**（1000-1500 字）
把命局当系统：输入什么 / 怎么加工 / 输出什么 / 靠什么回血（承接第一阶段核心循环）。
最怕的环境要写失效机制（什么导致什么），不写"不适合"三个字。
适合的生活结构：时间节奏 / 协作密度 / 反馈周期 / 收入形态各自展开。
稳定型 vs 高变量型人生的判定 + 理由 + 前提条件。

**第五阶段：大运流年时间轴**（1000-1500 字）
逐段走大运：从当前大运起往后 3-4 步，每步大运给「主题一句话 + 这十年会发生什么 + 该做什么 / 该避什么」。
点名关键流年（结合大运流年干支与十神），时间窗口写具体（如"×运后十年""×× 年前后"），不空泛。
末段点当前所处大运的阶段位置（刚入运 / 运中 / 交运前夜）与节奏提示。

**第六阶段：关系与婚姻**（1000-1500 字）
婚姻方向、配偶画像（配偶星 + 配偶宫，写具体特征不是空话）、婚期窗口、相处模式与磨合点；
六亲缘（父母 / 兄弟 / 子女）以关系视角各展开一段，落到宫位与十神依据，给相处建议。
已有定论的写倾向，不确定的诚实说"需结合对方命盘"。

**高阶：结构动力学**（1000-1500 字）
能量循环完整链路（标注增益段与损耗段，什么导致什么，不用比喻代替机制）；
杠杆优势（投入一分撬动什么，为什么）；易损点（什么条件下这个结构会自我损耗 + 日常自查信号）；
升级路径（分阶段，每阶段进入条件与完成标志）。

**收尾：落地手册**（1000-1500 字）
不复述前文。三件事：① 真正的杠杆是哪一项能力，一句话说清，并说明为什么不是其他几项；
② 怎么用：3 个具体使用场景，每个写清楚该做什么动作；③ 未来 90 天只做一件事来放大杠杆，给可验证的完成标志。
最后认真回答：什么情况下这份分析应该被推翻（2 个反例信号）——提醒这是参考工具不是判决书。

"""

BAZI_DEEP_PAID_PROMO_REQUIREMENTS = """写作要求（五阶段叙事 · 长文版，每阶段 1000-1500 字，总 8000-12000 字）：

""" + _BAZI_TEN_GOD_CHAPTER.replace(
    "第一章：十神结构与命局主线", "第一阶段：主线结构",
) + _BAZI_V1_STRUCTURE_CHAPTERS + _BAZI_DEEP_PROMO_COMMON

# ---------- 合盘 ----------

_COMPAT_PROMO_COMMON = """通用要求：
- **每章 1000-1500 字（中文字符计），不低于 1000 字**
- 每章分 5-8 段，每段讲透一个洞察；段内可展开推理，不赶节奏
- 章内可用 2-4 个**加粗小标题**组织内容（便于长文阅读）
- 每个判断落到两人盘面依据（五行互补 / 日主关系 / 地支合冲 / 生肖匹配），像专业命理师复盘
- 直言不绕弯：不用"传统认为..."；直接"你们..."
- 核心术语直接用，关键处可顺带一句白话点透，不写成科普文
- 围绕 {context_label} 维度展开
- **绝对禁忌**：不得给出"必成 / 必分 / 必破财"等绝对结论
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
"""

COMPATIBILITY_FREE_PROMO_REQUIREMENTS = """写作要求（免费 2 章 · 长文版，每章 1000-1500 字，总 2000-3000 字）：

**第一章：基础相处模式**（1000-1500 字）
两人日常互动的基调。建议覆盖：沟通模式（谁主导话锋、误解常发生在哪）、
决策风格（快慢 / 感性理性）、日常节奏契合度（作息 / 社交 / 消费习惯）、
冲突时的降温方式。每个维度给两人盘面依据。

**第二章：互补与冲突总览**（1000-1500 字）
五行互补 + 日主关系 + 地支合冲的具体表现。建议覆盖：
互补点给这段关系带来的资源（各自补什么）、冲突点的具体触发场景、
雷区清单（哪些话 / 哪些局面尽量避开）、把互补用起来的具体做法。

""" + _COMPAT_PROMO_COMMON

COMPATIBILITY_PAID_PROMO_REQUIREMENTS = """写作要求（付费 4 章 · 长文版，每章 1000-1500 字，总 4000-6000 字）：

**第一章：爱情深度**（1000-1500 字）
情感互动模式、亲密倾向、长期相处的趋势与经营建议。落到两人盘面依据。

**第二章：合作事业**（1000-1500 字）
事业 / 工作合作的契合度：分工建议（谁适合冲前台、谁适合守后方）、
决策与执行配合、合作中要立的规矩。

**第三章：财运合拍**（1000-1500 字）
金钱观契合度（储蓄 / 消费 / 投资偏好）、共同财运趋势、财务分工建议。

**第四章：流年同步**（1000-1500 字）
未来 3 年流年同步性，**每年至少一段**，指出同步走强 / 走弱的窗口，
并给每年的共同行动建议（适合一起做什么 / 一起避开什么）。

""" + _COMPAT_PROMO_COMMON

# ---------- 每日运势 ----------

DAILY_FORTUNE_PROMO_REQUIREMENTS = """写作要求（长文版，**总 400-600 字**）：

- 今日倾向：流日对日主的生克影响（结合后端给出的喜忌），直言会发生什么，展开讲机制
- 行动建议：今日适合 / 不适合做什么，给 3-5 条具体可执行的（不空泛）
- 情绪 / 状态提示：基于流日对日主的关系（如偏官日容易紧绷、印星日适合学习）
- 时段节奏：可从 12 时辰中挑 2-3 个最值得注意的时辰点一句（好的或需避开的），**不要**逐一点评全部 12 时辰
- 通用黄历宜忌可自然融入行文，不输出列表格式

通用要求：
- **总字数 400-600 字**，不低于 400
- 分 4-6 段，可以一行一句，也可以成段展开
- 直言不绕弯：不用"传统认为..."；直接"今日你..."
- 核心术语保留（流日 / 偏官 / 喜忌等），关键处可顺带一句白话点透
- **重要**：喜忌已由后端确定性给出，你必须严格按后端的 favorable/unfavorable 写，不得自行推断或修改
- 不确定性保留：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
"""

# module → 加长版写作要求块(promo 表单实际用到的 5 个 module;
# v1 链 M0-M7 有自己的篇幅体系(1500-2500 字),不在此列)
PROMO_REQUIREMENTS: dict[str, str] = {
    "bazi_deep_free": BAZI_DEEP_FREE_PROMO_REQUIREMENTS,
    "bazi_deep_paid": BAZI_DEEP_PAID_PROMO_REQUIREMENTS,
    "compatibility_free": COMPATIBILITY_FREE_PROMO_REQUIREMENTS,
    "compatibility_paid": COMPATIBILITY_PAID_PROMO_REQUIREMENTS,
    "daily_fortune": DAILY_FORTUNE_PROMO_REQUIREMENTS,
}


def render_prompt_with_length(
    module: str, context: dict, length_tier: str,
) -> str:
    """按篇幅档渲染 prompt。

    Args:
        module: backend 注册的 module 名(此处仅老 7 模块中的 5 个有加长版)
        context: prompt 渲染负载(与 backend render_prompt 同一份)
        length_tier: "app"(App 标准,backend 原样) / "promo"(加长版)

    Returns:
        完整 prompt 字符串

    Raises:
        ValueError: length_tier 非法,或该 module 没有加长版(显式报错,不静默降级)
    """
    if length_tier == LENGTH_TIER_APP:
        return render_prompt(module, context)
    if length_tier != LENGTH_TIER_PROMO:
        raise ValueError(
            f"未知 length_tier: {length_tier!r}(必须 {LENGTH_TIER_APP} 或 {LENGTH_TIER_PROMO})"
        )
    if module not in PROMO_REQUIREMENTS:
        raise ValueError(
            f"module {module!r} 没有加长版写作要求"
            f"(可用: {sorted(PROMO_REQUIREMENTS)})"
        )

    template = _TEMPLATES[module]
    if _REQUIREMENTS_MARKER not in template:
        # backend 模板结构变了(split 标记丢失),显式报错而不是渲染出残缺 prompt
        raise ValueError(
            f"backend 模板 {module!r} 不含写作要求标记 {_REQUIREMENTS_MARKER!r},"
            "promo 换块机制失效,需同步检查 promo_prompts.py"
        )
    header = template.split(_REQUIREMENTS_MARKER, 1)[0]
    promo_template = header + PROMO_REQUIREMENTS[module]

    # 与 backend render_prompt 同一套校验 + 渲染路径
    validate_context(module, context)
    rendered = promo_template.format_map(_StrictFormatDict(context))

    # 从格诚实降级(与 backend render_prompt 的 bazi_deep 系列行为对齐)
    if (module in ("bazi_deep", "bazi_deep_free", "bazi_deep_paid")
            and context.get("day_master_strength") == "special_pattern"):
        rendered += BAZI_DEEP_SPECIAL_PATTERN_SUFFIX

    return rendered
