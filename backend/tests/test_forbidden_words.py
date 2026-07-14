"""forbidden_words.scan 单元测试(纯函数,安全关键路径)。

US-COMP-04:后端禁词守卫。词表与客户端 ForbiddenWords.absoluteConclusions 一致。
"""

from __future__ import annotations

from app.ai.forbidden_words import ABSOLUTE_CONCLUSIONS, scan


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
    """词表数量 = 11(与客户端 ForbiddenWords.absoluteConclusions 一致)。"""
    assert len(ABSOLUTE_CONCLUSIONS) == 11
