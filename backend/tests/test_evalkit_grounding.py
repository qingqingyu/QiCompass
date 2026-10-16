"""evalkit L2 接地校验层单测(S03)。

全部手写正反例,零 API 调用。核心立场:宁可漏报不可误报——
反例必须命中,正例(含易误报文本)必须全过。
"""

from __future__ import annotations

import pytest

from evalkit.checks.grounding import (
    check_chain_consistency,
    check_grounding,
    check_no_hard_geju,
    check_shensha_bounded,
    check_special_pattern_honesty,
    check_xiji_consistency,
)


def _engine(**overrides):
    base = {
        "favorable_elements": ["metal", "water"],
        "unfavorable_elements": ["fire", "earth"],
        "day_master_strength": "weak",
        "shensha": [
            {"name": "文昌", "position": "日柱", "source": "三命通会"},
            {"name": "驿马", "position": "年柱", "source": "三命通会"},
        ],
        "pattern_hint": None,
    }
    base.update(overrides)
    return base


def _special_engine():
    return _engine(
        favorable_elements=[], unfavorable_elements=[],
        day_master_strength="special_pattern", pattern_hint="cong_fire",
    )


# ===== 1. 喜忌一致性 =====


def test_xiji_recommending_favorable_passes():
    out = {"summary": "金有利,宜多用金水来增强专注。"}
    assert check_xiji_consistency("m1_talent", out, _engine()) == []


def test_xiji_recommending_unfavorable_fails():
    out = {"summary": "宜多用火,提升行动力。"}  # fire 在 unfavorable
    failures = check_xiji_consistency("m1_talent", out, _engine())
    assert any("喜忌矛盾" in f and "火" in f for f in failures)
    # failure 自带证据:命中片段 + ground truth
    assert any("「宜多用火」" in f and "unfavorable" in f for f in failures)


def test_xiji_avoiding_favorable_fails():
    out = {"summary": "忌金,少接触金属性环境。"}  # metal 在 favorable
    failures = check_xiji_consistency("m1_talent", out, _engine())
    assert any("喜忌矛盾" in f and "金" in f and "favorable" in f
               for f in failures)


def test_xiji_element_after_signal_passes():
    """信号在后:「水对你有利」(water favorable)→ 通过。"""
    out = {"summary": "多靠近北方,水对你有利。"}
    assert check_xiji_consistency("m1_talent", out, _engine()) == []


def test_xiji_ambiguous_sentence_skipped():
    """歧义句(同时含推荐与规避信号)不判:宁可漏报。"""
    out = {"summary": "身强宜用金,忌火但需辩证看。"}
    assert check_xiji_consistency("m1_talent", out, _engine()) == []


def test_xiji_money_word_not_element():
    """误报防御:「适合积累资金」的金在信号 2 字窗口外,不判为推荐金。"""
    out = {"summary": "适合积累资金,三年攒出安全垫。"}
    assert check_xiji_consistency("m5_wealth", out, _engine()) == []


def test_xiji_special_pattern_skips():
    """favorable 为空(special 盘)→ 本项跳过。"""
    out = {"summary": "宜多用火。"}
    assert check_xiji_consistency("m1_talent", out, _special_engine()) == []


def test_xiji_missing_keys_raise():
    with pytest.raises(KeyError):
        check_xiji_consistency("m1_talent", {"s": "x"}, {})


# ===== 2. 神煞不超界 =====


def test_shensha_hit_passes():
    out = {"note": "文昌入日柱,学习能力强。"}
    assert check_shensha_bounded("m1_talent", out, _engine()) == []


def test_shensha_out_of_list_fails():
    out = {"note": "天医星入命,适合医疗行业。"}
    failures = check_shensha_bounded("m1_talent", out, _engine())
    assert any("神煞越界" in f and "天医" in f for f in failures)


def test_shensha_in_list_not_hit_fails():
    out = {"note": "华盖坐命,适合独立钻研。"}  # 华盖在 20 清单但本盘未命中
    failures = check_shensha_bounded("m1_talent", out, _engine())
    assert any("神煞未命中" in f and "华盖" in f for f in failures)


def test_shensha_missing_key_raises():
    engine = _engine()
    del engine["shensha"]
    with pytest.raises(KeyError):
        check_shensha_bounded("m1_talent", {"n": "x"}, engine)


# ===== 3. 格局红线 =====


def test_geju_fuzzy_narrative_passes():
    out = {"note": "命局呈现偏印倾向,思维纵深。"}
    assert check_no_hard_geju("m1_talent", out, _engine()) == []


def test_geju_neutral_word_allowed():
    """单独"格局"二字是允许的中性表述。"""
    out = {"note": "整体格局偏流动,不追求稳定。"}
    assert check_no_hard_geju("m1_talent", out, _engine()) == []


def test_geju_hard_classification_fails():
    out = {"note": "此为偏印格,宜文职。"}
    failures = check_no_hard_geju("m1_talent", out, _engine())
    assert any("硬性格局" in f and "偏印格" in f for f in failures)


# ===== 4. special_pattern 诚实 =====


def test_special_honest_passes():
    out = {"note": "本盘不入常格,扶抑框架不适用,围绕从格特征做叙事。"}
    assert check_special_pattern_honesty("m1_talent", out, _special_engine()) == []


def test_special_fabricated_xiji_fails():
    out = {"note": "喜用火土,多补火。"}
    failures = check_special_pattern_honesty("m1_talent", out, _special_engine())
    assert any("编造喜忌" in f for f in failures)


def test_special_hidden_degradation_fails():
    out = {"note": "你的结构以行动力见长,执行力是核心。"}  # 只字未提降级
    failures = check_special_pattern_honesty("m1_talent", out, _special_engine())
    assert any("隐藏降级" in f for f in failures)


def test_special_check_skips_normal_chart():
    out = {"note": "执行力强。"}
    assert check_special_pattern_honesty("m1_talent", out, _engine()) == []


# ===== 5. 链式一致性 =====


def test_chain_verbatim_fingerprint_passes():
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "以「伤官生财循环驱动,外显创造力」为主线展开。"}
    assert check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=chain) == []


def test_chain_mutated_fingerprint_fails():
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "以「伤官生财循环带动,外显创造力」为主线展开。"}  # 改了一字
    failures = check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=chain)
    assert any("链式不一致" in f for f in failures)


def test_chain_no_reference_passes():
    """不引用 fingerprint 的输出不判(漏报可接受)。"""
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "你的核心能力来自快速迭代。"}
    assert check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=chain) == []


def test_chain_none_context_skips():
    out = {"note": "随便说什么"}
    assert check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=None) == []


def test_chain_m0_itself_skips():
    out = {"structure_fingerprint": "伤官生财循环驱动"}
    assert check_chain_consistency(
        "m0_structure", out, _engine(), chain_context={}) == []


# ===== 聚合 + 误报防御 =====


def test_aggregate_combines_all_checks():
    out = {
        "note": "此为偏印格。天医入命。",
    }
    failures = check_grounding("m1_talent", out, _engine())
    assert any("硬性格局" in f for f in failures)
    assert any("神煞越界" in f for f in failures)


def test_false_positive_defense_long_compliant_text():
    """一段完全合规的长文本跑全部五项 → 零 failure(防模式过宽)。"""
    out = {
        "innate": [
            {"name": "结构洞察", "behavior": "先搭框架再动手",
             "evidence": "偏印倾向(命局呈现偏印倾向,非硬分类)"},
        ],
        "defensive": [
            {"name": "过度准备", "looks_like": "迟迟不发布",
             "actual_cost": "错过反馈窗口"},
        ],
        "one_leverage": "结构洞察",
        "note": "金有利,宜多用金水。文昌入日柱,学习反馈快。"
                "资金安排上适合留出三个月缓冲,不追求重资产。"
                "整体格局偏轻,像水流一样绕过障碍。",
    }
    chain = {"m0_structure": {"structure_fingerprint": "印重身轻,以印化食"}}
    assert check_grounding(
        "m1_talent", out, _engine(), chain_context=chain) == []


def test_unknown_element_in_ground_truth_raises():
    engine = _engine(favorable_elements=["metal", "phlogiston"])
    out = {"s": "宜多用金。"}
    with pytest.raises(ValueError, match="未知五行"):
        check_xiji_consistency("m1_talent", out, engine)


def test_chinese_elements_in_ground_truth_accepted():
    """engine 实测输出中文五行('金'/'土'),直接可用(2026-08-18 实测校准)。"""
    engine = _engine(favorable_elements=["金", "土"],
                     unfavorable_elements=["水", "木", "火"])
    ok = {"s": "金有利,宜多用金。"}
    assert check_xiji_consistency("m1_talent", ok, engine) == []
    bad = {"s": "宜多用火,提升行动力。"}
    failures = check_xiji_consistency("m1_talent", bad, engine)
    assert any("喜忌矛盾" in f and "火" in f for f in failures)


def test_chain_m7_exempt_from_verbatim_check():
    """M7 不做逐字判(模板要求改写不复述):改写引用半个指纹也不 fail。"""
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "以「伤官生财循环驱动」为底色的落地手册,不复述分析。"}
    assert check_chain_consistency(
        "m7_manual", out, _engine(), chain_context=chain) == []


# ===== P1 修复回归(2026-08-19 review:非五行复合词误报 + 「不宜」死信号) =====

# (文本, 涉及的五行字)。对抗样本取自 review 实测会误报的措辞,
# 全部是日常复合词/成语,不是五行义。
_ADVERSARIAL_NON_WUXING = [
    ("适合金融行业或投资顾问方向", "金"),    # 金融
    ("增强金融素养,建立稳定现金流", "金"),  # 金融 / 现金流
    ("适合水产养殖与文旅结合的副业", "水"),  # 水产
    ("宜土地相关的长期持有资产", "土"),      # 土地
    ("适合木工手作类的个人品牌", "木"),      # 木工
    ("避免火中取栗式的短线操作", "火"),      # 成语,非五行火
]


@pytest.mark.parametrize("text,element", _ADVERSARIAL_NON_WUXING)
def test_xiji_non_wuxing_compound_not_flagged(text, element):
    """P1-1:非五行复合词里的五行字不得判为喜忌推荐/规避。

    目标五行同时压进 favorable 和 unfavorable:无论句子是推荐向还是
    规避向,该五行字都落在被扫描的集合里,判据真扫到了才算过关。
    """
    engine = _engine(favorable_elements=[element],
                     unfavorable_elements=[element])
    assert check_xiji_consistency("m5_wealth", {"summary": text}, engine) == []


@pytest.mark.parametrize("text,element", _ADVERSARIAL_NON_WUXING)
def test_special_pattern_non_wuxing_compound_not_flagged(text, element):
    """P1-1 最大暴露面:special_pattern 规则 1 遍历全部五行,同样不得误报。

    (m5_wealth 天然高频出现金融/现金流/水产/土地措辞,5 个 special 盘
    × 任何模块命中任一样本 = 误报"编造喜忌"。)
    """
    out = {"summary": text, "note": "本盘为从格,不入常格。"}
    failures = check_special_pattern_honesty("m5_wealth", out, _special_engine())
    assert failures == []


def test_special_pattern_real_fabrication_still_fails():
    """否决表只放行复合词:真五行推荐(「宜补火」)在 special 盘上必须仍被抓。"""
    out = {"note": "宜补火,多接触暖色环境。本盘为从格,不入常格。"}
    failures = check_special_pattern_honesty("m1_talent", out, _special_engine())
    assert any("编造喜忌" in f and "火" in f for f in failures)


def test_xiji_buyi_now_produces_failure():
    """P1-2:「不宜用金」(金 favorable)必须产出 failure。

    修复前 `宜` 是 `不宜` 的子串 → 句子被判"推荐+规避并存"的歧义句
    整句跳过,以「不宜」为唯一规避信号的判据静默失效。
    """
    out = {"summary": "不宜用金,改用银饰替代。"}
    failures = check_xiji_consistency("m1_talent", out, _engine())
    assert any("喜忌矛盾" in f and "金" in f and "favorable" in f
               for f in failures)


@pytest.mark.parametrize("sep", ["；", ";"], ids=["full-width", "half-width"])
def test_xiji_semicolon_splits_clause(sep):
    """全/半角分号都必须切句(2026-10-12 全量 run m7 实踩,真机是全角)。

    「…在喜用位<sep>水透出层为 0」:前半句推荐的是土金(favorable,正确),
    分号后是陈述句;修复前全角 ；(U+FF1B)不在切句集合 → 两句粘连,
    「喜用.{0,2}水」跨子句命中,把正确推荐误报成推荐忌神水。半角 ; 修复
    前就已被收录,参数化双向锁定——只锁全角则半角回退同样无人察觉。
    """
    engine = _engine(unfavorable_elements=["木", "水", "火"])
    out = {"summary": f"日主中和、喜土金,偏印属土在喜用位{sep}水透出层为 0"}
    assert check_xiji_consistency("m1_talent", out, engine) == []


@pytest.mark.parametrize("text", [
    "连续赶工一周,补水少,皮肤状态先报警",       # 生理饮水(m4 实踩)
    "现金储备要垫底,补水 0 的缓冲缺口",         # 流动性隐喻(m5 实踩)
])
def test_xiji_bushui_not_element_recommendation(text):
    """「补水」词义歧义:饮水/流动性隐喻不作五行推荐判(宁可漏报)。

    真五行推荐另有 宜/喜用/适合 信号词携带;把「补」加进水的非五行
    前缀否决表后,补水类复合词不再命中(代价:纯「补水」式推荐漏报,
    接受)。水同时压进 unfavorable,判据真扫到才算过关。
    """
    engine = _engine(unfavorable_elements=["水"])
    assert check_xiji_consistency("m4_health", {"s": text}, engine) == []


def test_special_pattern_bushui_not_fabrication():
    """special 盘同理:「补水少」不得判为编造喜忌。"""
    out = {"s": "连续多日高强度输出,同时补水少,注意饮水。本盘为从格,不入常格。"}
    assert check_special_pattern_honesty("m4_health", out, _special_engine()) == []


def test_xiji_bushui_with_signal_still_fails():
    """2026-10-13 review 修复:「补水」无条件否决把真违规一起放走——
    信号词直接挂在补水前(「宜补水」)是五行断言,必须仍被抓
    (修复前水为忌盘「宜补水」整句漏报)。"""
    engine = _engine(unfavorable_elements=["水"])
    out = {"s": "宜补水，滋养命局。"}
    failures = check_xiji_consistency("m0_structure", out, engine)
    assert any("喜忌矛盾" in f and "水" in f for f in failures)


def test_special_pattern_bushui_recommendation_fabrication_fails():
    """同上,special 盘:「适合补水」= 替引擎下喜忌结论(v7 从格条款
    明禁的写法,第一轮全量 run 实踩类别),不得被补水否决放走。"""
    out = {"s": "适合补水。本盘为从格，不入常格。"}
    failures = check_special_pattern_honesty(
        "m0_structure", out, _special_engine())
    assert any("编造喜忌" in f and "水" in f for f in failures)


def test_xiji_signal_across_paren_not_recommendation():
    """信号词跨开括号进插入语 ≠ 推荐括号内的五行(2026-10-12 全量 run m6 实踩)。

    「回补(水行计数 0,天干无财)」:推荐语义落在回补-财星,括号内是数据
    陈述;修复前「补.{0,2}水」跨「(」命中,把陈述句误报成推荐忌神水。
    """
    engine = _engine(unfavorable_elements=["木", "水", "金"])
    out = {"s": "产出无法经财星回补(水行计数 0,天干无财),消耗没有结构性对冲"}
    assert check_xiji_consistency("m6_dynamics", out, engine) == []


def test_xiji_adjacent_recommendation_still_fails():
    """gap 收紧不伤正常命中:信号词与五行紧邻的推荐照旧抓。"""
    out = {"summary": "宜多用火,提升行动力。"}
    failures = check_xiji_consistency("m1_talent", out, _engine())
    assert any("喜忌矛盾" in f and "火" in f for f in failures)


# ===== 6. M0 结构纪律(2026-10-12 M0 质量批 S2) =====
#
# 样本盘 = plan 第 0 节真机截图盘(丙寅辛丑庚午庚辰,1987-01-21 08:00
# +08:00 male):真实引擎输出做 ground truth(确定性,同盘同结果)。
# 样本输出 = 后端缓存行原文照录(截图内容经 DB 核实为 EN 生成后 translate
# 译回的产物,见 plan S3 实施记录)。

from datetime import datetime, timedelta, timezone  # noqa: E402
from functools import lru_cache  # noqa: E402

from evalkit.checks.grounding import (  # noqa: E402
    check_branch_element_attribution,
    check_example_plagiarism,
    check_expansion_no_figures,
    check_flow_no_chain_symbols,
    check_headline_plain_language,
    check_layering_consistency,
    check_no_machine_field_names,
    check_present_god_not_missing,
    check_ten_god_category_attribution,
    collect_banned_register_warnings,
)


@lru_cache(maxsize=1)
def _sample_engine() -> dict:
    """样本盘引擎真值:七杀6/劫财6 并列最重,水0 木1,日主偏旺。"""
    from app.engine.bazi_engine import BaziEngine

    birth = datetime(1987, 1, 21, 8, 0, tzinfo=timezone(timedelta(hours=8)))
    return BaziEngine().calculate(
        birth=birth, gender="male", longitude=116.41,
        zi_hour_rule="zi_next_day",
    )


# 真机 M0 输出原文照录(每类问题的命中现场)
_SAMPLE_M0_OUTPUT = {
    "main_axis": {
        "dominant": "七杀",
        "secondary": "正印",
        "latent": "伤官与财星组(偏财、劫财)",
        "evidence": (
            "七杀:年干丙坐于日主之上,权重6,加上年支寅中暗藏七杀以及"
            "日支午的正官并入官杀家族。正印:权重4,现于月支丑与日支午的"
            "藏干,土数为2。潜在:伤官权重2在月支与时支,劫财权重6为月干,"
            "偏财权重3在年支——存在但多为暗藏或带争夺性。"
        ),
    },
    "core_loop": {
        "from": "七杀",
        "to": "正印",
        "flow": (
            "七杀(压力、外部要求)→ 正印(系统化,吸收为方法与资历)"
            "→ 回到七杀(方法使你能承受更大压力,承担带权柄的角色)"
            "→ 七杀 → 正印"
        ),
        "driver": (
            "日主庚偏旺,有比肩(权重5)与劫财(权重6)扶持,因此命局能够"
            "承受七杀而不被压垮;土支(丑月、辰时、午日)生助正印,"
            "使转化通道保持畅通。"
        ),
        "leak": (
            "此循环在水与木处泄漏:水为0,因此食伤桥梁(伤官/食神,食神=0)"
            "几乎不存在——转化后的印难以以可见的输出或作品形式展现;"
            "木(财)为1,因此由印至财的一段薄弱。能量也经由劫财(权重6)"
            "流失:资源与成果在尚未巩固之前,便在同辈之间被争夺或耗散。"
        ),
        "evidence": (
            "five_elements: 水0,木1;ten_god_weights: 食神0,伤官2,劫财6;"
            "月柱辛丑在正印的本支上见劫财。"
        ),
    },
    "structure_type": {
        "name": "杀印相生格(杀印相生格)",
        "one_line": "以外部压力为原材料,通过系统与资历将其转化为承载能力,但对外输出的可见成果很少。",
    },
    "capability_source": {
        "text": "核心能力来自转化环节:当压力到来(七杀)时,你将其导入结构——规则、流程、资质、领地(正印)。",
        "evidence": "七杀权重6在年干;正印权重4,有土2生助;水0且食神0。",
    },
    "structure_fingerprint": "吸收压力,将其转化为系统与资历;吸入强,输出弱;同辈争夺同一资源时巩固能力差。",
}


# ---- 6a. 复合格局名(A1) ----


@pytest.mark.parametrize("word", [
    "杀印相生格", "伤官配印格", "食神制杀格", "财滋弱杀格", "从革格",
])
def test_geju_composite_pattern_fails(word):
    """A1:复合格局名是固定词表漏网项,模式层必须命中。"""
    out = {"name": f"此为{word}"}
    failures = check_no_hard_geju("m0_structure", out, _sample_engine())
    assert any("硬性格局" in f and word in f for f in failures)


@pytest.mark.parametrize("text", [
    "别具一格的做事风格",          # 一格 / 风格
    "对交付规格要求高",            # 规格
    "个人性格偏内敛",              # 性格
    "像一张表格一样清晰",          # 表格
    "价格敏感度高",                # 价格
    "严格遵守约定",                # 严格
    "考试及格线附近",              # 及格
    "消费降格的现象",              # 降格
    "顶格处罚的案例",              # 顶格
    "整体格局偏流动",              # 格局(中性表述)
    "这个格局偏流动",              # 格局:前缀 2 字 + 格 + 局,负向前瞻排除
    "输出格式很干净",              # 格式
    "对你格外重要",                # 格外
    "生活有格调",                  # 格调
    "排成九宫格子",                # 格子
    "画一个九宫格。",              # 九宫格(句尾独立用法,后缀白名单)
    "他的行事出格",                # 出格
    "像格言一样凝练",              # 格言
    "休假三天后,精力是否回到满格",  # 满格(2026-10-12 全量 run m6 实踩)
    "它只保证你拆解时电池不掉格",    # 掉格(同族:m7 实踩)
    "从格前提不成立,你的结构在按正格的方式运转",  # 正格 = 从格的否定语域
    "本盘不入常格,从格特征,扶抑框架不适用",  # 常格 = 诚实降级措辞
    "日程网格化管理",              # 网格(2026-10-13 review 实踩)
    "字与字按空格分开",            # 空格
    "九宫格里排方格",              # 方格(贪婪吞长的 token 靠 endswith 救)
    "早上醒来没有满电感,电量从半格充到满格",  # 半格(2026-10-13 全量 run m4 实踩,电量条量词)
    "越规范的组织里你越显得格格不入",  # 格格不入(同 run m3 实踩,成语;
    # 第一枚格靠负向前瞻的「格」放行,贪婪吞到第二枚格的 token 靠 endswith
    # 「格格」放行,双侧缺一即误报)
])
def test_geju_daily_words_pass(text):
    """A1 反例:以「格」结尾的日常词不得误报(宁可漏报,白名单从宽)。"""
    out = {"note": text}
    assert check_no_hard_geju("m1_talent", out, _engine()) == []


def test_geju_congge_allowed_on_special_pattern_chart():
    """从格 = _HONEST_WORDS 认可措辞,_special_pattern_suffix 模板明文
    要求从格盘这么写(20 盘语料 5 盘),不得被模式层误杀。"""
    out = {"note": "本命盘呈现从格特征,喜忌结论留空。"}
    assert check_no_hard_geju("m0_structure", out, _special_engine()) == []


def test_geju_congge_still_flagged_on_normal_chart():
    """普通盘写「从格」= 把身强身弱讲错,仍应拦。"""
    out = {"note": "此为从格,随势而动。"}
    failures = check_no_hard_geju("m0_structure", out, _engine())
    assert any("从格" in f for f in failures)


def test_geju_wordlist_hit_not_double_reported():
    """词表命中的单十神格名不被模式层重复报第二条。"""
    out = {"note": "此为正官格。"}
    failures = check_no_hard_geju("m1_talent", out, _engine())
    geju_hits = [f for f in failures if "正官格" in f]
    assert len(geju_hits) == 1


def test_geju_bugouge_daily_word_passes():
    """2026-10-14 v9 全量 run 实踩:「两项力量不够格当杠杆」误杀——
    够格/不够格是日常「资格」义,同 满格/掉格 族白名单。"""
    out = {"s": "你的另外两项力量不够格当杠杆,先把手上的做实。"}
    assert check_no_hard_geju("m7_manual", out, _engine()) == []


def test_geju_duplicate_token_reported_once():
    """同一 leaf 内同一复合格名出现两次(真机括注重复原文)只报一条。"""
    out = {"name": "杀印相生格(杀印相生格)"}
    failures = check_no_hard_geju("m0_structure", out, _sample_engine())
    pattern_hits = [
        f for f in failures if "杀印相生格" in f and "复合格名" in f]
    assert len(pattern_hits) == 1


# ---- 6b. 机器字段名外泄(A5) ----


def test_field_name_sample_evidence_fails():
    """A5:真机原文「five_elements: 水0…;ten_god_weights: …」两键都要命中。"""
    out = {"evidence": _SAMPLE_M0_OUTPUT["core_loop"]["evidence"]}
    failures = check_no_machine_field_names(
        "m0_structure", out, _sample_engine())
    assert any("five_elements" in f for f in failures)
    assert any("ten_god_weights" in f for f in failures)


@pytest.mark.parametrize("field", ["day_master", "luck_pillars", "shishen_zhi", "useful_god_candidates"])
def test_field_name_chart_keys_fails(field):
    """A5:chart 实际键(动态收集)逐个命中。"""
    out = {"e": f"据 {field} 显示偏旺"}
    failures = check_no_machine_field_names(
        "m0_structure", out, _sample_engine())
    assert any(field in f and "机器字段名外泄" in f for f in failures)


def test_field_name_english_prose_passes():
    """A5 反例:stem/branch/pillar 是 EN 合法英文词(无下划线),不误报。"""
    out = {"e": ("The month stem and branch are both Companion; "
                 "his luck pillars favor wood runs.")}
    assert check_no_machine_field_names(
        "m0_structure", out, _sample_engine()) == []


def test_field_name_glued_prefix_still_hits():
    """A5:CJK 紧贴写法「如five_elements:」(ASCII 词边界两侧 CJK 算边界)。"""
    out = {"e": "如five_elements:水0则食伤弱"}
    failures = check_no_machine_field_names(
        "m0_structure", out, _sample_engine())
    assert any("five_elements" in f for f in failures)


def test_field_name_gated_to_m0():
    """m1-m7 zh 模板尚未含禁令(plan S5),检查只对 m0 生效。"""
    out = {"e": "five_elements: 水0"}
    assert check_no_machine_field_names(
        "m1_talent", out, _sample_engine()) == []


# ---- 6c. 地支五行错置(B1) ----


def test_branch_element_sample_driver_fails():
    """B1:真机原文「土支(丑月、辰时、午日)」——午属火。"""
    out = {"driver": _SAMPLE_M0_OUTPUT["core_loop"]["driver"]}
    failures = check_branch_element_attribution(
        "m0_structure", out, _sample_engine())
    assert any("地支五行错置" in f and "午" in f and "火" in f
               for f in failures)


@pytest.mark.parametrize("text", [
    "土支(丑、辰)", "水支(亥、子)", "木支:寅卯皆旺", "火支(巳、午)",
    "金支:申酉当令",
])
def test_branch_element_correct_passes(text):
    out = {"s": text}
    assert check_branch_element_attribution(
        "m0_structure", out, _sample_engine()) == []


def test_branch_element_no_pattern_passes():
    """B1 反例:「资金支持」的 支 前是金字但后随非括号,不判。"""
    out = {"s": "本地分支机构不多,资金支持一般。"}
    assert check_branch_element_attribution(
        "m0_structure", out, _sample_engine()) == []


def test_branch_element_parallel_colon_listing_passes():
    """B1 反例:全角分号排比「土支:丑辰；火支:巳午」——冒号列举必须在
    全角分号停,把下一组的巳午吞进土支列举就是误报。"""
    out = {"s": "土支:丑辰；火支:巳午。"}
    assert check_branch_element_attribution(
        "m0_structure", out, _sample_engine()) == []


@pytest.mark.parametrize("sep", ["，", ","], ids=["full-width", "half-width"])
def test_branch_element_comma_parallel_listing_passes(sep):
    """B1 反例:逗号排比同病(2026-10-12 双 review 第 1 轮补,全角逗号是
    LLM zh 排比的自然标点):「土支:丑辰，火支:巳午」不停在逗号,巳午被
    吞进土支列举 → 误报。半/全角双向锁定。"""
    out = {"s": f"土支:丑辰{sep}火支:巳午。"}
    assert check_branch_element_attribution(
        "m0_structure", out, _sample_engine()) == []


# ---- 6d. 十神归类错置(B2) ----


def test_category_sample_latent_fails():
    """B2:真机原文「财星组(偏财、劫财)」——劫财属比劫。"""
    out = {"latent": _SAMPLE_M0_OUTPUT["main_axis"]["latent"]}
    failures = check_ten_god_category_attribution(
        "m0_structure", out, _sample_engine())
    assert any("十神归类错置" in f and "劫财" in f and "比劫" in f
               for f in failures)


@pytest.mark.parametrize("text", [
    "比劫(比肩、劫财)", "印星(正印、偏印)", "官杀(七杀、正官)",
    "财星类(正财、偏财)", "食伤家族(食神、伤官)",
])
def test_category_correct_passes(text):
    out = {"s": text}
    assert check_ten_god_category_attribution(
        "m0_structure", out, _sample_engine()) == []


def test_category_no_paren_passes():
    """B2 反例:无括号列举的日常提及不判。"""
    out = {"s": "财星权重低,比劫争财,印星生身。"}
    assert check_ten_god_category_attribution(
        "m0_structure", out, _sample_engine()) == []


# ---- 6e. flow 复述链条(A4) ----


def test_flow_sample_fails():
    """A4:真机原文 flow 含 4 个箭头,把链条复述一遍还多转一圈。"""
    failures = check_flow_no_chain_symbols(
        "m0_structure", _SAMPLE_M0_OUTPUT, _sample_engine())
    assert any("flow 复述链条" in f for f in failures)


def test_flow_single_arrow_passes():
    out = {"core_loop": {"flow": "压力 -> 方法,方法承载压力"}}
    assert check_flow_no_chain_symbols(
        "m0_structure", out, _sample_engine()) == []


def test_flow_prose_passes():
    out = {"core_loop": {"flow": "压力被吸收为方法,方法再承接更大压力"}}
    assert check_flow_no_chain_symbols(
        "m0_structure", out, _sample_engine()) == []


def test_flow_missing_field_passes():
    assert check_flow_no_chain_symbols("m0_structure", {}, _sample_engine()) == []


# ---- 6f. 分层与权重一致(A3) ----


def test_layering_sample_fails():
    """A3:七杀 6 = 劫财 6 并列最重,劫财被塞进 latent 必须命中。"""
    failures = check_layering_consistency(
        "m0_structure", _SAMPLE_M0_OUTPUT, _sample_engine())
    assert any("分层失真" in f and "劫财" in f and "并列最重" in f
               for f in failures)


def test_layering_tie_in_dominant_passes():
    """并列最高同处 dominant(写明并列最重)即合规。"""
    out = {"main_axis": {"dominant": "七杀与劫财(并列最重)",
                         "latent": "伤官"}}
    assert check_layering_consistency(
        "m0_structure", out, _sample_engine()) == []


def test_layering_inversion_fails():
    """dominant 层领衔权重低于 latent 层领衔权重 = 倒挂。"""
    out = {"main_axis": {"dominant": "正印", "latent": "劫财"}}
    failures = check_layering_consistency(
        "m0_structure", out, _sample_engine())
    assert any("正印" in f and "权重 4" in f for f in failures)


def test_layering_family_grouping_passes():
    """按十神家族分层不是倒挂(2026-10-12 全量 run 三条实踩)。

    dominant=「比劫(劫财 7…比肩仅 1…)」:比肩 1 是家族叙事说明,不是层
    成员判定;层的强弱由领衔十神(劫财 7)决定,不得按最低权重比对误杀。
    本检查只读 ten_god_weights,自备 ground truth 复现 case_05 盘面。
    """
    engine = {"ten_god_weights": {
        "比肩": 1, "劫财": 7, "食神": 0, "伤官": 6, "偏财": 0,
        "正财": 6, "七杀": 3, "正官": 2, "偏印": 4, "正印": 6,
    }}
    out = {"main_axis": {
        "dominant": "比劫(劫财权重 7 为最重,比肩仅 1)",
        "latent": "偏印(4)、七杀(3)、正官(2),官杀只藏不透",
    }}
    assert check_layering_consistency(
        "m0_structure", out, engine) == []


def test_layering_family_grouping_sample_cases_pass():
    """全量 run 实踩的另两形态:食伤家族主导 / 财星家族主导。"""
    cases = [
        ({"比肩": 1, "劫财": 5, "食神": 8, "伤官": 2, "偏财": 7,
          "正财": 5, "七杀": 1, "正官": 2, "偏印": 3, "正印": 0},
         "主导是食伤,食神权重 8 最重,伤官权重 2 为辅",
         "印星与官杀藏而不透:偏印 3、正官 2、七杀 1"),
        ({"比肩": 0, "劫财": 1, "食神": 5, "伤官": 6, "偏财": 8,
          "正财": 2, "七杀": 6, "正官": 2, "偏印": 1, "正印": 3},
         "财星(偏财与正财),偏财权重 8 为全盘最高,正财 2",
         "印星与比劫藏而力薄:正印 3、偏印 1、劫财 1"),
    ]
    for weights, dominant, latent in cases:
        out = {"main_axis": {"dominant": dominant, "latent": latent}}
        assert check_layering_consistency(
            "m0_structure", out, {"ten_god_weights": weights}) == []


def test_layering_en_output_skips():
    """提取不到中文十神名(EN 输出)跳过不判(宁可漏报)。"""
    out = {"main_axis": {"dominant": "Seven Killings",
                         "latent": "Hurting Officer"}}
    assert check_layering_consistency(
        "m0_structure", out, _sample_engine()) == []


def test_layering_latent_narrative_mention_not_members():
    """2026-10-13 review 修复:潜伏层长句里顺带提及的十神(压制者)不是
    层成员——「伤官…被七杀与劫财的强势压住」不得误报「并列最重落
    latent」。成员 = 首个十神(领衔)+ 干净括号列举,叙事提及不作数。"""
    out = {"main_axis": {
        "dominant": "七杀与劫财（并列最重）",
        "latent": "伤官权重 2，藏于丑辰，被七杀与劫财的强势压住未透出",
    }}
    assert check_layering_consistency(
        "m0_structure", out, _sample_engine()) == []


def test_layering_paren_member_enumeration_still_counts():
    """括号内全是十神名的列举 = 成员声明:并列最重的劫财被列进潜伏层
    仍要抓(真机夹具形态,防 2026-10-13 收紧过头变漏报)。"""
    out = {"main_axis": {"dominant": "七杀",
                         "latent": "伤官与财星组(偏财、劫财)"}}
    failures = check_layering_consistency(
        "m0_structure", out, _sample_engine())
    assert any("分层失真" in f and "劫财" in f for f in failures)


def test_layering_paren_enumeration_tolerates_separator_whitespace():
    """同上,顿号后带空格的排版变体(「偏财、 劫财」,英文训练影响的
    LLM 常见排版)不得把整列按混排丢弃——2026-10-13 三查第 3 轮:
    无 strip 时该形态漏报真违规。"""
    out = {"main_axis": {"dominant": "七杀",
                         "latent": "伤官与财星组(偏财、 劫财)"}}
    failures = check_layering_consistency(
        "m0_structure", out, _sample_engine())
    assert any("分层失真" in f and "劫财" in f for f in failures)


def test_layering_inversion_by_lead_not_narrative_mention():
    """倒挂比对按层领衔(首个十神)而非句内最高提及:潜伏层叙事里更重
    的十神(「被劫财 7 的压力抵消」)不作数,修复前此处误报倒挂。"""
    engine = {"ten_god_weights": {
        "比肩": 1, "劫财": 7, "食神": 0, "伤官": 6, "偏财": 0,
        "正财": 6, "七杀": 3, "正官": 2, "偏印": 4, "正印": 6,
    }}
    out = {"main_axis": {
        "dominant": "伤官权重 6 领衔的食伤层",
        "latent": "偏印 4 潜伏,常被劫财 7 的强势抵消",
    }}
    assert check_layering_consistency("m0_structure", out, engine) == []


# ---- 6g. 聚合:plan S2 验收(六条全部命中) ----


def test_aggregate_m0_sample_hits_all_six_categories():
    """样本输出喂聚合入口:A1/A3/A4/A5/B1/B2 六类 failure 全部命中。"""
    failures = check_grounding(
        "m0_structure", _SAMPLE_M0_OUTPUT, _sample_engine())
    markers = (
        "硬性格局",            # A1 复合格局名
        "分层失真",            # A3 并列最高落 latent
        "flow 复述链条",       # A4 箭头复述
        "机器字段名外泄",       # A5 字段名
        "地支五行错置",         # B1 午≠土
        "十神归类错置",         # B2 劫财≠财星
    )
    for marker in markers:
        assert any(marker in f for f in failures), f"缺 {marker} 命中"


# ===== 7. M0 白话结论层(v9 批,2026-10-14) =====
#
# 夹具:样本盘 2(癸酉乙卯辛丑戊戌)权重形态——偏财 8 = 正印 8 并列,
# 食神 6,比肩 5,偏印 3,劫财 2,七杀 1,正官 0,伤官 0。截图正例来自
# 用户真机 v7 输出原文,目标样例来自 plan §0.1。


def _v9_engine():
    """样本盘 2 权重形态(癸酉乙卯辛丑戊戌),挂在样本盘 1 的真排盘上
    (A5 聚合入口要 build_v1_chart,须完整引擎输出;权重才归本检查管)。
    必须浅拷贝后覆写:_sample_engine() 被 lru_cache 缓存,原地改写会把
    样本盘 2 权重泄漏给之后所有 _sample_engine() 调用方(测试间污染)。"""
    engine = dict(_sample_engine())
    engine["ten_god_weights"] = {
        "偏财": 8, "正印": 8, "食神": 6, "比肩": 5, "偏印": 3,
        "劫财": 2, "七杀": 1, "正官": 0, "伤官": 0,
    }
    return engine


# v7 截图问题形态复合(P1 术语+干支+数字 / P5 照抄示例 / P6 箭头 /
# P7 权重>0 写缺 / P2 结构名术语)
_SAMPLE_M0_V9_SCREENSHOT_OUTPUT = {
    "main_axis": {
        "headline": "偏财与正印并列主导,偏财重 8,天干月令透偏财(辛丑)",
        "body": "你先做出能跑的版本,再拿它去换空间;偏财重 8。",
        "dominant": "偏财、正印(并列最重)",
        "secondary": "食神",
        "latent": "比肩",
        "evidence": "偏财权重 8,月干乙木透出。",
    },
    "core_loop": {
        "headline": "抓机会 → 沉淀资历 → 抓更大的机会",
        "from": "偏财", "to": "正印",
        "flow": "正印生比肩 → 比肩生食神 → 食神生偏财",
        "driver": "日主辛金,月令卯木当令。",
        "leak": "官杀系统整体缺位,吸收与抓取两端等重,输出一多吸收就被压缩。",
        "evidence": "月柱乙卯。",
    },
    "structure_type": {"name": "印财对峙、食伤通关型", "one_line": "两端拉锯。"},
    "capability_source": {
        "headline": "最强在抓机会的时候;最弱在沉淀的时候。",
        "text": "机会来了你先上。",
        "evidence": "偏财权重 8。",
    },
    "structure_fingerprint": "财印并重,抓取与沉淀轮流主导",
}

# plan §0.1 目标样例(白话结论层合规形态)
_SAMPLE_M0_V9_TARGET_OUTPUT = {
    "main_axis": {
        "headline": "压力推着你走,你靠「学规矩、攒资历」接住它。",
        "body": "主导是七杀,也就是外部压力和硬要求;其次是正印,也就是"
                "体系、资质和靠山。藏着没发挥出来的,是表达力和赚钱能力。",
        "dominant": "七杀、劫财(并列最重)",
        "secondary": "正印",
        "latent": "伤官、偏财",
        "evidence": "七杀与劫财并列最重(各 6);日主庚金偏旺。",
    },
    "core_loop": {
        "headline": "扛压 → 沉淀 → 扛更大的压。",
        "from": "七杀", "to": "正印",
        "flow": "每次被逼着解决难题,你都会把它变成一套方法或一份资历,"
                "这又让你接得住下一个更重的担子。",
        "driver": "日主庚金偏旺,官杀旺而有印星化之。",
        "leak": "不爱表现:事情做成了也不太会讲出来。约 32 岁起的那十年,"
                "表达会变得容易;眼下可以先在小范围讲给同伴听。",
        "evidence": "月柱辛丑,日支午藏丁火正官。",
    },
    "structure_type": {"name": "被逼出来的专业型",
                       "one_line": "分量靠一件件扛下来的事攒出来。"},
    "capability_source": {
        "headline": "最强在「给你一个难题,并让你自己搭体系」的时候;"
                    "最弱在要你公开展示、自己推销自己的时候。",
        "text": "比如接手一个没人碰过的烂摊子,你会先把它拆成一块块"
                "可管的小事,一件件收口。",
        "evidence": "七杀权重 6,与劫财并列最重。",
    },
    "structure_fingerprint": "杀劫并列,以规矩和资历承压",
}


# ---- 7a. v9-1 结论层无术语 ----


def test_headline_screenshot_fails_three_ways():
    """截图正例:headline 同踩 术语+干支+数字(P1)。

    2026-10-16 v10:干支改接地匹配(只认本盘四柱/大运实际形态),原句
    「(乙卯)」不在样本盘 1(丙寅辛丑庚午庚辰,大运壬寅…庚戌)→ 换本盘
    月柱「辛丑」,断言同步。"""
    out = {"main_axis": _SAMPLE_M0_V9_SCREENSHOT_OUTPUT["main_axis"]}
    failures = check_headline_plain_language(
        "m0_structure", out, _v9_engine())
    assert any("结论层含术语" in f and "偏财" in f for f in failures)
    assert any("结论层含干支" in f and "辛丑" in f for f in failures)
    assert any("结论层含数字" in f for f in failures)


def test_headline_name_screenshot_fails():
    """截图正例:name「印财对峙、食伤通关型」——单字简称只在 name 判。"""
    out = {"structure_type": {"name": "印财对峙、食伤通关型"}}
    failures = check_headline_plain_language(
        "m0_structure", out, _v9_engine())
    assert any("结论层含术语" in f and "食伤" in f for f in failures)
    # 单字印/财在 name 里也算术语
    assert any("结论层含术语" in f and "印" in f and "财" in f
               for f in failures)


def test_headline_single_char_daily_word_passes():
    """反例:非 name 的 headline 里「财」是日常用词(指钱),不判
    (四条结论齐全,排除 v9-1 缺失项的干扰)。"""
    out = {
        "main_axis": {"headline": "钱跟着作品走,财气跟着名气涨。"},
        "core_loop": {"headline": "扛压 → 沉淀 → 扛更大的压。"},
        "capability_source": {"headline": "最强在从零搭体系的时候。"},
        "structure_type": {"name": "被逼出来的专业型"},
    }
    assert check_headline_plain_language(
        "m0_structure", out, _v9_engine()) == []


def test_headline_target_sample_passes():
    """plan §0.1 目标样例四条结论全过。"""
    assert check_headline_plain_language(
        "m0_structure", _SAMPLE_M0_V9_TARGET_OUTPUT, _v9_engine()) == []


def test_headline_missing_fails():
    """headline 缺失即 fail(v9 三层契约:结论句是第一层)。"""
    failures = check_headline_plain_language(
        "m0_structure", {"main_axis": {"dominant": "七杀"}}, _v9_engine())
    assert any("结论层缺失" in f and "main_axis.headline" in f
               for f in failures)


def test_headline_gated_to_m0():
    out = {"structure_type": {"name": "印财对峙"}}
    assert check_headline_plain_language(
        "m1_talent", out, _v9_engine()) == []


def test_headline_ganzhi_element_note_fails():
    """结论层干支含「干支+五行注记」形态(壬水)。"""
    out = {"main_axis": {"headline": "壬水生木,机会跟着来。"}}
    failures = check_headline_plain_language(
        "m0_structure", out, _v9_engine())
    assert any("结论层含干支" in f and "壬水" in f for f in failures)


# ---- 7b. v9-2 展开层无数字 ----


def test_expansion_screenshot_fails():
    """截图正例:body「偏财重 8」(P1 数字进正文)。"""
    out = {"main_axis": _SAMPLE_M0_V9_SCREENSHOT_OUTPUT["main_axis"]}
    failures = check_expansion_no_figures(
        "m0_structure", out, _v9_engine())
    assert any("展开层含数字" in f and "main_axis.body" in f
               for f in failures)


def test_expansion_age_exempt_passes():
    """「约 32 岁起的那十年」是唯一例外(v9 大运写法)。"""
    out = {"core_loop": {"leak": "约 32 岁起的那十年,表达会变得容易。"}}
    assert check_expansion_no_figures(
        "m0_structure", out, _v9_engine()) == []


def test_expansion_target_sample_passes():
    assert check_expansion_no_figures(
        "m0_structure", _SAMPLE_M0_V9_TARGET_OUTPUT, _v9_engine()) == []


def test_expansion_fullwidth_digit_fails():
    """全角数字也是阿拉伯数字的排版变体,不豁免(年龄语境除外)。"""
    out = {"core_loop": {"leak": "吸收被压缩,付出３倍心力才缓解。"}}
    failures = check_expansion_no_figures(
        "m0_structure", out, _v9_engine())
    assert any("展开层含数字" in f for f in failures)


def test_expansion_missing_field_skips():
    assert check_expansion_no_figures(
        "m0_structure", {}, _v9_engine()) == []


def test_expansion_ganzhi_cite_fails():
    """样本盘实跑实踩:leak 写大运干支(丁未)/干支+五行注记(壬水/庚金)。
    v10 干支只在「约 X 岁起的那十年(某某运)」括注里合法——三句干支都
    在本盘接地集但都不在合法括注内,照报。"""
    cases = [
        {"core_loop": {"leak": "约四十六岁起的丁未运里,压力明显变多。"}},
        {"core_loop": {"leak": "那两步大运天干是壬水、癸水,表达会顺一些。"}},
        {"core_loop": {"leak": "约四十六岁起的那十年(庚金、戌土)帮身。"}},
    ]
    for out in cases:
        failures = check_expansion_no_figures(
            "m0_structure", out, _v9_engine())
        assert any("展开层含干支" in f for f in failures), out


def test_expansion_daily_words_with_branch_chars_pass():
    """反例:日常词里的地支字(中午/孩子/申请)不误判。"""
    out = {"core_loop": {
        "flow": "他中午刚过就提交了申请,孩子喝了热水也没上火。"}}
    assert check_expansion_no_figures(
        "m0_structure", out, _v9_engine()) == []


# ---- 7b-v10. 干支接地匹配 + 大运括注对账(2026-10-16,plan S2-1) ----
#
# 样本盘 1 真排盘:四柱 丙寅/辛丑/庚午/庚辰,大运 壬寅5/癸卯15/甲辰25/
# 乙巳35/丙午45/丁未55/戊申65/己酉75/庚戌85。「己」在大运(己酉)→
# 「己土」注记在接地集,「自己土气」须靠「自己」豁免放行。


def test_expansion_daily_ziji_words_pass():
    """反例(v10 接地匹配):review 实测 5 句误报全部放行。

    己未/己水/己金/子火 不在本盘接地集(己未非本盘干支对、己水己金
    五行不对、子非本盘字)天然不命中;「自己土气」的「己土」在集
    (大运己酉带己),靠「己」前是「自」的豁免放行。"""
    sentences = [
        "你自己未必意识到这一点",
        "你会先提升自己水平再出手",
        "你很少在自己金钱上算计",
        "你对自己土气的一面并不在意",
        "作品一下子火了以后你反而退后",
    ]
    for s in sentences:
        out = {"core_loop": {"leak": s}}
        assert check_expansion_no_figures(
            "m0_structure", out, _sample_engine()) == [], s


def test_expansion_chart_ganzhi_fails():
    """正例:展开层出现本盘干支对(庚午,日柱)照报——接地匹配只收窄
    误报面,真引用不放过。"""
    out = {"core_loop": {"leak": "日复一日硬扛,庚午帮你顶住压力。"}}
    failures = check_expansion_no_figures(
        "m0_structure", out, _sample_engine())
    assert any("展开层含干支" in f and "庚午" in f for f in failures)


def test_headline_luck_note_not_exempt():
    """正例:结论层不享受括注豁免——即使括注干支/岁数全对,结论层
    禁任何干支(plan S2-1.5)。"""
    out = {"main_axis": {
        "headline": "约 25 岁起的那十年(甲辰运),你开始发力。"}}
    failures = check_headline_plain_language(
        "m0_structure", out, _sample_engine())
    assert any("结论层含干支" in f and "甲辰" in f for f in failures)


def test_expansion_luck_note_valid_passes():
    """括注三态之放行:「约 25 岁起的那十年(甲辰运)」——甲辰是本盘
    大运且 start_age=25,干支合法落点,数字由年龄豁免,零 fail。
    全角/半角括号都收;繁体「歲/運」(zh-hant 一等输出语言)同样对账
    放行,不得误报。"""
    for note in ("约 25 岁起的那十年（甲辰运）,表达会变得容易。",
                 "约 25 岁起的那十年(甲辰运),表达会变得容易。",
                 "約 25 歲起的那十年（甲辰運）,表達會變得容易。"):
        out = {"core_loop": {"leak": note}}
        assert check_expansion_no_figures(
            "m0_structure", out, _sample_engine()) == [], note


def test_expansion_luck_note_age_mismatch_fails():
    """括注三态之错配:甲辰在盘但起运 25 岁,写「约 15 岁」→ fail。"""
    out = {"core_loop": {"leak": "约 15 岁起的那十年(甲辰运),表达会变得容易。"}}
    failures = check_expansion_no_figures(
        "m0_structure", out, _sample_engine())
    assert any("大运岁数与干支对不上" in f and "甲辰" in f
               for f in failures)


def test_expansion_luck_note_fabricated_fails():
    """括注三态之编造:庚子不在本盘大运(壬寅…庚戌)→ fail。"""
    out = {"core_loop": {"leak": "约 25 岁起的那十年(庚子运),表达会变得容易。"}}
    failures = check_expansion_no_figures(
        "m0_structure", out, _sample_engine())
    assert any("编造大运干支" in f and "庚子" in f for f in failures)


def test_expansion_luck_note_cn_age_passes():
    """中文数字年龄的合法括注(样本实见「约四十六岁」形态)同样对账
    放行:甲辰=25 岁运「约二十五岁」、癸卯=15 岁运「约十五岁」——
    「十几」类(十位省略)是样本实跑实踩的解析坑,初版被拒成 None
    误报「对不上」,此用例即其回归锁。"""
    for note in ("约二十五岁起的那十年(甲辰运),表达会变得容易。",
                 "约十五岁起的那十年(癸卯运),表达会变得容易。",
                 "约五岁起的那十年(壬寅运),表达会变得容易。"):
        out = {"core_loop": {"leak": note}}
        assert check_expansion_no_figures(
            "m0_structure", out, _sample_engine()) == [], note


def test_expansion_luck_note_cn_age_mismatch_fails():
    """中文数字错配:甲辰 25 岁,「约三十五岁」→ fail 对不上(解析正确
    前提下的真错配;不用「十五」——它对癸卯是合法对,见上例)。"""
    out = {"core_loop": {"leak": "约三十五岁起的那十年(甲辰运),表达会变得容易。"}}
    failures = check_expansion_no_figures(
        "m0_structure", out, _sample_engine())
    assert any("大运岁数与干支对不上" in f for f in failures)


# ---- 7c. v9-3 权重>0 不得写缺 ----


def test_present_god_missing_screenshot_fails():
    """截图正例(P7):七杀 1(藏于戌)被写成「官杀系统整体缺位」。"""
    out = {"core_loop": _SAMPLE_M0_V9_SCREENSHOT_OUTPUT["core_loop"]}
    failures = check_present_god_not_missing(
        "m0_structure", out, _v9_engine())
    assert any("权重>0写缺" in f and "官杀" in f for f in failures)


def test_present_god_wording_outside_lexicon_passes():
    out = {"s": "七杀仅 1,藏于时支戌中不透,几乎没有存在感"}
    # 「没有」后是「存」不触发透露守卫;「存在感」不等于「不存在」词表
    # → 期望不误报(宁可漏报立场:词表之外的写法不追)
    assert check_present_god_not_missing(
        "m0_structure", out, _v9_engine()) == []


def test_present_god_zero_weight_missing_passes():
    """权重 0 写「缺」是合规措辞(三分法之「缺」)。"""
    out = {"s": "正官为 0,此盘正官缺失,名分感要自己挣。"}
    assert check_present_god_not_missing(
        "m0_structure", out, _v9_engine()) == []


def test_present_god_hidden_wording_passes():
    """「没有透出」不判——v10 起「没有」整个移出词表(2026-10-16:
    比较句「没有X重」/否定动词「没有压垮」两用,判不了,宁可漏报),
    原「透露」守卫分支随之删除。"""
    out = {"s": "正财没有透出,藏在年支里,收入要靠时间攒。"}
    assert check_present_god_not_missing(
        "m0_structure", out, _v9_engine()) == []


def test_present_god_meiyou_comparisons_pass():
    """反例(v10 词表移除「没有」):review 实测 3 类误报全放行。
    句中神名换成本盘权重 >0 的神(_v9_engine:偏财 8/七杀 1/劫财 2),
    旧词表下三句全报——「十神名后 6 字窗口出现『没有』」。"""
    sentences = [
        "偏财没有七杀那么重,看机会的手感还在。",   # 比较句
        "七杀的压力没有压垮你,反而变成动力。",       # 否定后面的动词
        "劫财的锋芒没有用上,机会总差半步。",         # 藏而不用,不是缺
    ]
    for s in sentences:
        out = {"s": s}
        assert check_present_god_not_missing(
            "m0_structure", out, _v9_engine()) == [], s


def test_present_god_negated_missing_passes():
    """否定提及(「不算缺失」)不是指控。"""
    out = {"s": "七杀只有 1,不算缺失,它是藏在时支里的硬要求。"}
    assert check_present_god_not_missing(
        "m0_structure", out, _v9_engine()) == []


def test_present_god_far_window_passes():
    """超过 6 字窗口的「缺」不归到该十神头上(远距另有所指)。"""
    out = {"s": "官杀系统在漫长岁月的磨炼里被反复使用,整体缺位感并不存在"}
    # 「缺位感并不存在」前 2 字含「不」→ 否定守卫;整句不判
    assert check_present_god_not_missing(
        "m0_structure", out, _v9_engine()) == []


def test_present_god_gated_to_m0():
    out = {"s": "官杀系统整体缺位。"}
    assert check_present_god_not_missing(
        "m1_talent", out, _v9_engine()) == []


# ---- 7d. v9-4 工程腔禁用词(只统计不判 fail) ----


def test_banned_register_collects_warning():
    out = {"core_loop": {"flow": "转化通道保持畅通,但输出链有损耗。"}}
    warnings = collect_banned_register_warnings("m0_structure", out)
    assert any("通道" in w for w in warnings)
    assert any("输出链" in w for w in warnings)


def test_banned_register_not_in_failures():
    """词表命中只进 warnings,聚合 failures 不受影响(plan S2-4)。
    部分输出会让 v9-1 报「结论层缺失」,属另一检查的职责——本条只断言
    工程腔词不进 failures。"""
    out = {"core_loop": {"flow": "转化通道保持畅通。"}}
    failures = check_grounding("m0_structure", out, _v9_engine())
    assert all("工程腔" not in f for f in failures)
    assert collect_banned_register_warnings("m0_structure", out)


def test_banned_register_gated_to_m0():
    out = {"s": "通道畅通。"}
    assert collect_banned_register_warnings("m1_talent", out) == []


# ---- 7e. v9-5 照抄示例 ----


def test_plagiarism_screenshot_fails():
    """截图正例(P5):「先做出能跑的版本」照搬共享 header ✓ 示例。"""
    out = {"main_axis": _SAMPLE_M0_V9_SCREENSHOT_OUTPUT["main_axis"]}
    failures = check_example_plagiarism(
        "m0_structure", out, _v9_engine())
    assert any("照抄示例" in f and "能跑的版本" in f for f in failures)


def test_plagiarism_v9_sample_phrases_fail():
    out = {"structure_type": {"name": "想到就做的作品型"}}
    failures = check_example_plagiarism(
        "m0_structure", out, _v9_engine())
    assert any("想到就做的作品型" in f for f in failures)


def test_plagiarism_target_sample_passes():
    assert check_example_plagiarism(
        "m0_structure", _SAMPLE_M0_V9_TARGET_OUTPUT, _v9_engine()) == []


def test_plagiarism_gated_to_m0():
    out = {"s": "先做出能跑的版本。"}
    assert check_example_plagiarism("m1_talent", out, _v9_engine()) == []


# ---- 7f. 回归:A3/A4 在 v9 新形态下 ----


def test_layering_v9_dominant_shape_passes():
    """v9 dominant 只写十神名(「偏财、正印(并列最重)」)+ 括号是
    标注不是成员列举——首个十神领衔仍正确判定。"""
    out = {"main_axis": {"dominant": "偏财、正印(并列最重)",
                         "latent": "比肩、劫财"}}
    assert check_layering_consistency(
        "m0_structure", out, _v9_engine()) == []


def test_layering_v9_tie_in_latent_fails():
    out = {"main_axis": {"dominant": "偏财、正印(并列最重)",
                         "latent": "正印、比肩"}}
    failures = check_layering_consistency(
        "m0_structure", out, _v9_engine())
    assert any("分层失真" in f and "正印" in f for f in failures)


def test_flow_v9_headline_arrows_not_judged():
    """A4 只读 flow;headline 的白话箭头(「扛压 → 沉淀 → …」)不误判。"""
    out = {"core_loop": {
        "headline": "扛压 → 沉淀 → 扛更大的压",
        "flow": "每次被逼着解决难题,你都会把它变成一套方法或一份资历。",
    }}
    assert check_flow_no_chain_symbols(
        "m0_structure", out, _v9_engine()) == []


# ---- 7g. 聚合:plan S2 验收(v9 四条全部命中) ----


def test_aggregate_m0_v9_screenshot_hits_all_four():
    """截图问题形态喂聚合入口:1/2/3/5 四类 failure 全部命中。"""
    failures = check_grounding(
        "m0_structure", _SAMPLE_M0_V9_SCREENSHOT_OUTPUT, _v9_engine())
    markers = (
        "结论层含术语",       # v9-1(P1+P2)
        "展开层含数字",       # v9-2(P1)
        "权重>0写缺",         # v9-3(P7)
        "照抄示例",           # v9-5(P5)
    )
    for marker in markers:
        assert any(marker in f for f in failures), f"缺 {marker} 命中"


def test_aggregate_m0_v9_target_sample_only_expected_hits():
    """目标样例跑聚合:v9 四项零命中(允许 A3 类既有判据按需另判)。
    本例权重七杀 6=劫财 6,dominant/latent 排序正确 → 全绿。"""
    failures = check_grounding(
        "m0_structure", _SAMPLE_M0_V9_TARGET_OUTPUT, _sample_engine())
    v9_markers = ("结论层", "展开层含数字", "权重>0写缺", "照抄示例")
    assert not any(m in f for f in failures for m in v9_markers)
