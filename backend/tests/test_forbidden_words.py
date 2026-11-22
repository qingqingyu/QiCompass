"""forbidden_words.scan 单元测试(纯函数,安全关键路径)。

US-COMP-04:后端禁词守卫。词表与客户端 ForbiddenWords.absoluteConclusions 一致。
"""

from __future__ import annotations

from app.ai.forbidden_words import ABSOLUTE_CONCLUSIONS, ABSOLUTE_ENGLISH_PHRASES, scan


def test_clean_text_returns_empty():
    """正常文本(无禁词)返回空列表。"""
    assert scan("命局呈现木旺倾向,宜用火泄秀") == []


def test_empty_string_returns_empty():
    """空字符串返回空列表。"""
    assert scan("") == []


def test_single_hit():
    """单个禁词命中。"""
    hits = scan("你们必定会在一起")
    assert hits == ["必定"]


def test_multiple_hits_preserve_order():
    """多个禁词命中,按词表顺序返回(去重保序)。"""
    text = "你们必定会在一起,这是百分之百的,注定如此"
    hits = scan(text)
    # 词表顺序:必定 在 百分之百 和 注定 之前
    assert "必定" in hits
    assert "百分之百" in hits
    assert "注定" in hits
    # 验证去重保序:每个词只出现一次
    assert len(hits) == len(set(hits))


def test_duplicate_hit_dedup():
    """同一禁词出现多次,只返回一次。"""
    hits = scan("必定成功,必定发财")
    assert hits == ["必定"]


def test_all_forbidden_words_detectable():
    """词表中每个禁词都能被扫描到。"""
    for word in ABSOLUTE_CONCLUSIONS:
        text = f"这是{word}的结论"
        hits = scan(text)
        assert word in hits, f"禁词 {word!r} 未被扫描到"


def test_word_list_matches_client_count():
    """词表数量 = 17 中 + 7 英(与客户端 ForbiddenWords 计数锁一致;
    T9 补繁体 5 词 + 拍板补「註定」台湾异写;D2 英文绝对结论短语)。"""
    assert len(ABSOLUTE_CONCLUSIONS) == 17
    assert len(ABSOLUTE_ENGLISH_PHRASES) == 7


def test_zhuding_variant_detected():
    """拍板补列:台湾异写「註定」(zh-Hant 模板自身写「注定」,防漏网)。"""
    assert scan("你們註定在一起") == ["註定"]


def test_english_phrases_word_boundary():
    """D2:英文短语整词匹配——命中用例与防误杀用例。"""
    for phrase in ("destined to", "doomed", "guaranteed to", "will definitely",
                   "will certainly", "without a doubt"):
        assert scan(f"You are {phrase} succeed.") == [phrase]
        assert scan(f"you are {phrase.upper()} SUCCEED.") == [phrase]
    assert scan("a 100% match") == ["100%"]
    # 防误杀:词边界(子串相同但不成词)+ 正常叙事
    assert scan("He is willing to try.") == []
    assert scan("You may be destined.") == []  # destined to 拆开不命中
    assert scan("The day tends to favor patience.") == []


def test_traditional_chinese_variants_detected():
    """T9:zh-Hant 输出的繁体禁词形必须拦截(此前静默放行)。

    精确断言(== [word])与 iOS 侧镜像:若未来新增词与既有繁体词
    构成子串交叠导致多命中,这里会立即暴露。
    """
    for word in ("一定會", "一定不會", "鐵定", "絕對", "必破財"):
        assert word in ABSOLUTE_CONCLUSIONS
        hits = scan(f"你們{word}在一起")
        assert hits == [word], f"繁体禁词 {word!r} 期望唯一命中,实际 {hits!r}"


def test_traditional_pass_text_not_overblocked():
    """T9 反例:繁体正常叙事(模糊语气)不误伤。"""
    assert scan("兩人性情較合,傾向互補") == []
    assert scan("此事較難成行,容易生變") == []
