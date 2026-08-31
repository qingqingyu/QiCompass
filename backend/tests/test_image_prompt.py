"""image_prompt.build_image_prompt 纯函数测试(S1)。

口径:同一输入同一 prompt(确定性)、意象词命中、no-text 约束、
契约外输入显式 InvalidInputError(不静默)。风格后缀实测自
designs/daily-fortune-art-20260830/ 三方向样图(2026-08-30)。
"""

import pytest

from app.ai.image_prompt import (
    GAN_ELEMENT_IMAGES,
    SHISHEN_MOODS,
    STYLE_SUFFIX,
    YI_MOTIFS,
    ZHI_SEASON_SCENES,
    build_image_prompt,
)
from app.ai.prompts import PROMPT_VERSIONS
from app.errors import InvalidInputError


def test_same_input_same_output():
    """确定性:两次调用逐字节相等(gpt-image-2 无 temperature,确定性全靠本表)。"""
    a = build_image_prompt("丙", "子", "偏印", ["嫁娶", "纳采"])
    b = build_image_prompt("丙", "子", "偏印", ["嫁娶", "纳采"])
    assert a == b


def test_element_and_scene_present():
    """丙→暖光意象 / 子→冬夜场景(V4 首屏样图同款输入)。"""
    prompt = build_image_prompt("丙", "子", "偏印", [])
    assert GAN_ELEMENT_IMAGES["丙"] in prompt
    assert ZHI_SEASON_SCENES["子"] in prompt


def test_shishen_mood_all_ten():
    """十神全表可拼(与 iOS YiJiAnchor 十神口径一致,缺一是契约漂移)。"""
    for shishen, mood in SHISHEN_MOODS.items():
        prompt = build_image_prompt("甲", "寅", shishen, [])
        assert mood in prompt, f"{shishen} 的基调词缺失"


def test_no_text_constraints_in_style_suffix():
    """防生图乱码的核心约束:显式 no text / no letters / no characters。"""
    for phrase in ("no text", "no letters", "no characters"):
        assert phrase in STYLE_SUFFIX
    assert STYLE_SUFFIX in build_image_prompt("壬", "亥", "正印", [])


def test_yi_motif_first_item_only():
    """母题取黄历宜首项;第二项不进 prompt(确定性,不受列表长度影响)。"""
    prompt = build_image_prompt("庚", "申", "正官", ["出行", "嫁娶"])
    assert YI_MOTIFS["出行"] in prompt
    assert YI_MOTIFS["嫁娶"] not in prompt


def test_yi_motif_unknown_omitted():
    """开放清单未命中 → 省略母题段(prompt 仍完整;设计如此,非吞错)。"""
    prompt = build_image_prompt("丁", "酉", "食神", ["某未知宜项"])
    for motif in YI_MOTIFS.values():
        assert motif not in prompt


def test_empty_yi_list_ok():
    """空宜列表合法(黄历宜可为空):无母题段,元素+场景+风格后缀仍齐。"""
    prompt = build_image_prompt("癸", "丑", "正印", [])
    assert GAN_ELEMENT_IMAGES["癸"] in prompt
    assert ZHI_SEASON_SCENES["丑"] in prompt
    assert STYLE_SUFFIX in prompt


@pytest.mark.parametrize("gan,zhi,shishen", [
    ("X", "子", "偏印"),      # 非天干
    ("丙", "Q", "偏印"),      # 非地支
    ("丙", "子", "某某神"),   # 非十神
])
def test_unknown_inputs_raise(gan, zhi, shishen):
    """契约外输入显式报错(引擎产物,吞掉会静默产出走样图)。"""
    with pytest.raises(InvalidInputError):
        build_image_prompt(gan, zhi, shishen, [])


def test_table_key_domains_locked():
    """契约域锁:三张查表的 key 集必须与引擎产物域完全一致
    (SHI_SHEN 10 值 / 十天干 / 十二地支)。删表项若只靠运行期
    InvalidInputError 暴露就太晚了,这里静态锁死。"""
    assert set(GAN_ELEMENT_IMAGES) == set("甲乙丙丁戊己庚辛壬癸")
    assert set(ZHI_SEASON_SCENES) == set("子丑寅卯辰巳午未申酉戌亥")
    assert set(SHISHEN_MOODS) == {
        "比肩", "劫财", "食神", "伤官", "偏财",
        "正财", "七杀", "正官", "偏印", "正印",
    }


def test_prompt_version_registered():
    """PROMPT_VERSIONS 漂移守卫:意象表/风格后缀改动必须 bump 此版本号。"""
    assert PROMPT_VERSIONS["daily_fortune_image"] == 2  # v2:底色换轨 #E7E2D5
