"""每日运势插画 prompt 拼装(确定性,2026-08-30「一幅图」拍板)。

方向甲「五行小景」:流日天干→五行意象 / 地支→时序场景 / 十神→情绪基调 /
黄历宜首项→行为母题,全查表确定(同一输入同一 prompt,gpt-image-2 不吃
temperature,确定性完全由映射表保证)。风格后缀沿用 2026-08-30 三方向
样图验证过的 sumi-e 串(designs/daily-fortune-art-20260830/)。

不做 .md 模板文件(prompt 是代码拼装,无字段插值),但版本号仍进
PROMPT_VERSIONS——缓存键维度之一,意象表/风格串改动时 bump
"daily_fortune_image"。

显式错误:天干/地支/十神不在表内即 InvalidInputError(它们来自自家引擎,
契约内值;吞掉会静默产出走样图)。黄历宜是长开放清单,母题只是锦上添花,
未命中就省略 motif 段(设计如此,非吞错)。
"""

from __future__ import annotations

from ..errors import InvalidInputError

# ---------- 天干 → 五行意象 ----------
GAN_ELEMENT_IMAGES: dict[str, str] = {
    "甲": "a tall pine reaching upward",
    "乙": "a willow bending gently in the breeze",
    "丙": "warm sunlight glowing over distant rooftops",
    "丁": "a single lamp flame steady in the dark",
    "戊": "layered mountains under a wide sky",
    "己": "open fields of soft turned earth",
    "庚": "polished metal catching the light of a bright moon",
    "辛": "a thin blade of frost glittering at dawn",
    "壬": "a deep flowing river beneath drifting mist",
    "癸": "morning dew beading on still leaves",
}

# ---------- 地支 → 时序场景 ----------
ZHI_SEASON_SCENES: dict[str, str] = {
    "寅": "early spring dawn",
    "卯": "mid-spring morning light",
    "辰": "misty late-spring morning",
    "巳": "approaching midsummer brightness",
    "午": "bright midsummer noon",
    "未": "warm late-summer afternoon",
    "申": "quiet early-autumn dusk",
    "酉": "deep golden autumn evening",
    "戌": "dry late-autumn twilight",
    "亥": "settling into winter night",
    "子": "still winter night",
    "丑": "the last quiet hour before winter dawn",
}

# ---------- 十神 → 情绪基调(与 iOS YiJiAnchor 十神口径一致) ----------
SHISHEN_MOODS: dict[str, str] = {
    "比肩": "a mood of quiet companionship",
    "劫财": "a mood of bold forward movement",
    "食神": "a mood of easy abundance",
    "伤官": "a mood of free, flowing expression",
    "偏财": "a mood of open-handed opportunity",
    "正财": "a mood of patient accumulation",
    "七杀": "a mood of decisive clarity",
    "正官": "a mood of dignified order",
    "偏印": "a mood of quiet introspection",
    "正印": "a mood of gentle nourishment",
}

# ---------- 黄历宜(开放清单的策展子集)→ 行为母题;未命中则省略 ----------
YI_MOTIFS: dict[str, str] = {
    "嫁娶": "two wild geese flying together in the far sky",
    "纳采": "a pair of ribbons drifting down a stream",
    "订盟": "two stones resting side by side",
    "祭祀": "a single thin thread of incense smoke rising",
    "祈福": "a small lantern floating on still water",
    "斋醮": "an empty meditation mat in clear light",
    "出行": "a distant road disappearing into mist",
    "移徙": "a small boat crossing calm water",
    "入宅": "a warm doorway glowing faintly at dusk",
    "开市": "distant market stalls at first light",
    "交易": "two hands exchanging a small object",
    "修造": "freshly laid beams against the sky",
    "动土": "freshly turned earth in the foreground",
    "栽种": "new green shoots breaking the soil",
    "开光": "first light touching still water",
}

# ---------- 构图片段 + 风格后缀(2026-08-30 实测验证;改动须 bump PROMPT_VERSIONS)----------
COMPOSITION_HINT: str = "wide 3:2 landscape composition, generous negative space"
STYLE_SUFFIX: str = (
    "Zen ink wash painting (sumi-e) on cold gray rice paper, "
    "background exactly #F3F1EC cold gray, "
    "ink tones from #17161A to #77726A, "
    "at most ONE tiny vermilion red #A83226 seal accent, "
    "vast negative space, extremely minimalist, "
    "no text, no characters, no letters, no watermark, no border, no frame"
)


def build_image_prompt(day_gan: str, day_zhi: str, shishen: str, yi_list: list[str]) -> str:
    """拼装每日运势插画 prompt。

    Args:
        day_gan: 流日天干单字(如「丙」),来自 lunar_python 排盘。
        day_zhi: 流日地支单字(如「子」)。
        shishen: 流日对日主十神(如「偏印」),与 iOS YiJiAnchor 同口径。
        yi_list: 黄历宜列表(如["嫁娶","纳采"]);取首项查母题表,未命中省略。

    Returns:
        英文 prompt 单行:gpt-image-2 对英文指令服从度最好。

    Raises:
        InvalidInputError: 天干/地支/十神不在表内(引擎契约违约,显式报错不静默)。
    """
    element = GAN_ELEMENT_IMAGES.get(day_gan)
    if element is None:
        raise InvalidInputError(f"未知天干: {day_gan!r}")
    scene = ZHI_SEASON_SCENES.get(day_zhi)
    if scene is None:
        raise InvalidInputError(f"未知地支: {day_zhi!r}")
    mood = SHISHEN_MOODS.get(shishen)
    if mood is None:
        raise InvalidInputError(f"未知十神: {shishen!r}")

    parts = [
        f"{element} in {scene}",
        mood,
    ]
    if yi_list:
        motif = YI_MOTIFS.get(yi_list[0])
        if motif is not None:
            parts.append(motif)
    parts.append(COMPOSITION_HINT)

    return ", ".join(parts) + ". " + STYLE_SUFFIX
