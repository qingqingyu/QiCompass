"""prompt context 拍平辅助函数。

把 engine 返回值拍平成 prompt 占位符 dict,对齐 backend/app/ai/prompts.py 的 REQUIRED_FIELDS。

字段映射参考(逻辑与 iOS PromptContextBuilder 一致):
- bazi_deep:backend/spikes/prompt_validation/run_spike.py:75(已 20 盘验证)
- compatibility:ios/QiCompass/.../PromptContextBuilder+Compatibility.swift:34
- daily_fortune:ios/QiCompass/.../PromptContextBuilder.swift:280
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

# 直接复用 spike 函数(避免 38 字段映射重复)
# sys.path 在 main.py 已注入 backend/,此处 import 安全
from spikes.prompt_validation.run_spike import build_bazi_deep_context


# ---------- 共用映射 ----------

_ELEMENT_ZH = {"wood": "木", "fire": "火", "earth": "土", "metal": "金", "water": "水"}
_GENDER_ZH = {"male": "男", "female": "女"}
_CONTEXT_LABEL_ZH = {"general": "通用", "marriage": "婚姻", "business": "事业"}
_STRENGTH_LABEL_ZH = {
    "strong": "偏旺", "weak": "偏弱",
    "balanced": "中和", "special_pattern": "呈现从格特征",
}


def _element_to_zh(element: str) -> str:
    """五行英文 → 中文。未知值原样返回(不吞,便于排障)。"""
    return _ELEMENT_ZH.get(element, element)


def _format_element_balance(eb: dict[str, int]) -> str:
    """element_balance dict → '木:2 火:1 土:1 金:1 水:3' 格式。"""
    return (
        f"木:{eb['wood']} 火:{eb['fire']} 土:{eb['earth']} "
        f"金:{eb['metal']} 水:{eb['water']}"
    )


def _format_favorable(favorable: list[str]) -> str:
    """喜用五行 list → 中文逗号串。空(从格) → 显式占位。"""
    if not favorable:
        return "—(从格未下喜忌)"
    return ", ".join(_element_to_zh(e) for e in favorable)


def _format_synced_fortune(items: list[Any]) -> str:
    """流年同步 list → '- 2026:A「乙亥运 丙午年」 B「丁丑运 丙午年」→ 同步走强' 多行。

    与 iOS PromptContextBuilder+Compatibility.swift:118 formatSyncedFortune 对齐。
    """
    return "\n".join(
        f"- {sf.year}:A「{sf.person_a}」 B「{sf.person_b}」→ {sf.sync}"
        for sf in items
    )


# ---------- 深度解析 ----------

def build_bazi_context(
    chart: dict[str, Any],
    birth: datetime,
    gender: str,
    longitude: float,
    city: str | None = None,
) -> dict[str, Any]:
    """深度解析 context(对照 _BAZI_DEEP_REQUIRED_FIELDS,40 字段)。

    Thin wrapper 转调 spikes.run_spike.build_bazi_deep_context,然后:
    - 若 city 提供,覆盖 spike builder 硬编码的 "经度 xxx" 为真实城市名
      (对齐 iOS PromptContextBuilder:city 是城市名而非经度串,让 AI 话术自然)

    Args:
        chart: BaziEngine.calculate() 返回的 dict
        birth: 出生 datetime(aware)
        gender: "male" / "female"
        longitude: 经度
        city: 城市名(中文,如"北京");手动经度模式下为 None
    """
    context = build_bazi_deep_context(chart, birth, gender, longitude)
    if city:
        context["city"] = city
    return context


# ---------- 合盘 ----------

def _chart_to_prompt_fields(
    chart: dict[str, Any],
    birth: datetime,
    gender: str,
    longitude: float,
    city: str | None = None,
) -> dict[str, str]:
    """从 BaziEngine dict 提炼合盘 prompt 需要的 11 个单人字段。

    与 iOS ChartPromptContext + chartContext(from:) 对齐。
    city 给定用城市名(对齐 iOS),否则 fallback "经度 xxx"。
    """
    p = chart["pillars"]
    birth_str = birth.strftime("%Y-%m-%d %H:%M")
    return {
        "gender": _GENDER_ZH.get(gender, gender),
        "city": city if city else f"经度 {longitude}",
        "birth": birth_str,
        "day_master": p["day"]["gan"],
        "day_master_strength": _STRENGTH_LABEL_ZH.get(
            chart["day_master_strength"], chart["day_master_strength"],
        ),
        "favorable": _format_favorable(chart["favorable_elements"]),
        "year": f"{p['year']['gan']}{p['year']['zhi']}",
        "month": f"{p['month']['gan']}{p['month']['zhi']}",
        "day": f"{p['day']['gan']}{p['day']['zhi']}",
        "hour": f"{p['hour']['gan']}{p['hour']['zhi']}",
        "element_balance": _format_element_balance(chart["element_balance"]),
    }


def build_compat_context(
    chart_a: dict[str, Any],
    chart_b: dict[str, Any],
    compat_resp: Any,
    birth_a: datetime,
    birth_b: datetime,
    gender_a: str,
    gender_b: str,
    longitude_a: float,
    longitude_b: float,
    context_label_key: str = "general",
    city_a: str | None = None,
    city_b: str | None = None,
) -> dict[str, Any]:
    """合盘 context(对照 _COMPATIBILITY_REQUIRED_FIELDS,30 字段)。

    Args:
        chart_a / chart_b: 两人各自的 BaziEngine.calculate() 返回 dict
        compat_resp: compute_compatibility() 返回的 CompatibilityResponse
        birth_a / birth_b: 两人出生 datetime
        gender_a / gender_b: "male" / "female"
        longitude_a / longitude_b: 两人经度
        context_label_key: "general" / "marriage" / "business"
        city_a / city_b: 城市名(中文),手动经度模式下为 None
    """
    a = _chart_to_prompt_fields(chart_a, birth_a, gender_a, longitude_a, city_a)
    b = _chart_to_prompt_fields(chart_b, birth_b, gender_b, longitude_b, city_b)
    assessment = compat_resp.qualitative_assessment

    return {
        # 通用
        "context_label": _CONTEXT_LABEL_ZH.get(context_label_key, context_label_key),
        # A 盘
        "gender_a": a["gender"], "city_a": a["city"], "birth_a": a["birth"],
        "day_master_a": a["day_master"], "day_master_strength_a": a["day_master_strength"],
        "favorable_a": a["favorable"],
        "year_a": a["year"], "month_a": a["month"], "day_a": a["day"], "hour_a": a["hour"],
        "element_balance_a": a["element_balance"],
        # B 盘
        "gender_b": b["gender"], "city_b": b["city"], "birth_b": b["birth"],
        "day_master_b": b["day_master"], "day_master_strength_b": b["day_master_strength"],
        "favorable_b": b["favorable"],
        "year_b": b["year"], "month_b": b["month"], "day_b": b["day"], "hour_b": b["hour"],
        "element_balance_b": b["element_balance"],
        # 评估
        "five_elements_assessment": assessment.five_elements,
        "day_master_relation": assessment.day_master_relation,
        "zodiac_match": assessment.zodiac_match,
        "branch_harmony": assessment.branch_harmony,
        # 流年同步
        "synced_fortune_table": _format_synced_fortune(compat_resp.synced_fortune),
    }


# ---------- 每日运势 ----------

def _format_hour_pillars(hours: list[Any]) -> str:
    """12 时辰 → '- 子时(23:00-01:00):甲子 比肩 冲午(年支寅)...' 多行。

    与 iOS PromptContextBuilder.swift:307 hourPillarsStr 对齐。
    """
    lines: list[str] = []
    for hp in hours:
        line = f"- {hp.hour}时({hp.time_range}):{hp.pillar} {hp.relation}"
        if hp.chong:
            targets = (
                f"(冲{'、'.join(hp.chong_targets)})"
                if hp.chong_targets else ""
            )
            line += f" 冲{hp.chong}{targets}"
        lines.append(line)
    return "\n".join(lines)


def _format_day_chong(day_chong: str | None, targets: list[str]) -> str:
    """流日冲 → '午(冲年支寅)' / '午' / '无'。

    与 iOS PromptContextBuilder.swift:296 dayChongDisplay 对齐。
    """
    if not day_chong:
        return "无"
    suffix = f"(冲{'、'.join(targets)})" if targets else ""
    return f"{day_chong}{suffix}"


def build_daily_context(
    chart: dict[str, Any],
    daily_resp: Any,
    target_date: Any,
) -> dict[str, Any]:
    """每日运势 context(对照 REQUIRED_FIELDS['daily_fortune'],17 字段)。

    Args:
        chart: BaziEngine.calculate() 返回的 dict(拿 day_master / 喜忌)
        daily_resp: compute_daily_fortune() 返回的 DailyFortuneResponse
        target_date: 目标日期(date 对象)
    """
    # 拆 day_pillar 前后 1 字
    day_pillar = daily_resp.day_pillar
    day_stem = day_pillar[0]
    day_branch = day_pillar[1]
    # 通过 pillars 表反查五行(从 BaziEngine 的 pillars 同一份数据)
    # 这里 chart_payload 已含 day_master_element,但流日干/支五行需要重新查表
    # 简化:用 backend 的 GAN_ELEMENT / ZHI_ELEMENT
    from app.engine.pillars import GAN_ELEMENT, ZHI_ELEMENT  # noqa: WPS433
    day_stem_element = _element_to_zh(GAN_ELEMENT.get(day_stem, ""))
    day_branch_element = _element_to_zh(ZHI_ELEMENT.get(day_branch, ""))

    return {
        # 命主
        "day_master": chart["pillars"]["day"]["gan"],
        "day_master_element": _element_to_zh(chart["pillars"]["day"]["gan_element"]),
        "day_master_strength": _STRENGTH_LABEL_ZH.get(
            chart["day_master_strength"], chart["day_master_strength"],
        ),
        "favorable_elements": ", ".join(chart["favorable_elements"]) or "—",
        "unfavorable_elements": ", ".join(chart["unfavorable_elements"]) or "—",
        # 日期
        "date": f"{target_date.year}年{target_date.month}月{target_date.day}日",
        "lunar_date": daily_resp.lunar_date,
        # 流日柱
        "day_pillar": day_pillar,
        "day_stem": day_stem,
        "day_stem_element": day_stem_element,
        "day_branch": day_branch,
        "day_branch_element": day_branch_element,
        # 流日对日主关系
        "day_relation": daily_resp.day_relation_to_day_master,
        "day_chong": _format_day_chong(
            daily_resp.day_chong, daily_resp.day_chong_targets,
        ),
        # 12 时辰 + 黄历
        "hour_pillars_with_relations": _format_hour_pillars(daily_resp.hour_pillars),
        "huangli_yi": "、".join(daily_resp.huangli_yi) or "—",
        "huangli_ji": "、".join(daily_resp.huangli_ji) or "—",
    }
