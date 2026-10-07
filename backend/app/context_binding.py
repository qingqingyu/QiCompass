"""context_token:context 与 content_hash 绑定的签发-验签(2026-10-07 安全收口)。

威胁模型(P0,已 PoC 实证):
/api/interpret 的权限检查只认 (content_hash, module, user_local_id),而渲染
prompt 的 context 完全由客户端提交、从不与 content_hash 对账——买一次盘 H
即可给任意其他命盘生成付费内容(3 张不同盘 context 全部 200 且真烧 LLM);
翻译端点同理可把「伪造原文」固化进受害者的目标语言共享缓存键。

修复思路(用户拍板 2026-10-07:HMAC token 锁核心字段 + 付费免费一刀切):
- 排盘端点(/api/bazi/calculate)对每个命盘签发自包含签名 token,claims 绑定
  「盘身份核心字段」(四柱/藏干/纳音/喜忌/日主强度/大运等纯透传值);
- interpret/translate 一刀切强制验签(免费模块同样验,否则翻译投毒关不死);
- 合盘/每日端点的 chart_payload 客户端自持、与 hash 无法对证 → 请求须携带
  各盘的 per-chart token(payload 族),服务端验证 token↔hash↔payload 三方
  一致后再签发合盘/每日 token,杜绝「拿假 payload 换合法签发」的循环信任。

绑定字段子集原则(「少而稳」):
- 只锁服务端在签发时能独立复现的字段(引擎输出透传 + 确定性格式化镜像);
- 排除设备/用户/语言相关字段:true_solar_time(设备时区格式化)、city/place、
  gender(展示转换)、name_a/name_b(用户输入且随语言本地化——
  PromptContextBuilder+Compatibility.swift selfReferenceYou)、birth 展示串、
  synced_fortune_table(内嵌两人称呼)、v1 链式字段(M1-M7 上游 LLM 输出)、
  daily 的 date(设备日历)。未锁字段的注入面由 validate_context 长度上限兜底。

token 格式(自包含 claims,服务端签发、无需查库):
    v1.<base64url(canonical_json(claims))>.<hmac_sha256_hex>
- secret 从 JWT_SECRET_KEY 派生(HMAC 域分隔,无新增必填 env;两秘密同源
  落地半径,轮换 JWT_SECRET_KEY 即同时轮换本 token——老 token 全失效,
  客户端重排盘即可重取,无孤儿化)。
- canonical_json = json.dumps(sort_keys, ensure_ascii=False, separators=(",",":"))

语言维度:context 在 wire 上恒为中文(术语转换由后端 translate_context 做,
见 interpret.py _prepare_prompt_and_key),绑定字段不含随语言本地化项,
故 token 与语言无关、三语请求共用。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import logging
from typing import Any

from .config import JWT_SECRET_KEY
from .engine.chart_builder import lookup_current_luck_start_age
from .engine.pillars import EN2ZH, GAN_ELEMENT, ZHI_ELEMENT
from .errors import ContextTokenInvalidError, ContextTokenRequiredError

logger = logging.getLogger(__name__)

_TOKEN_VERSION = "v1"
# iOS 端占位字面量(PromptContextBuilder.hourUnknownPlaceholder,时辰未知/柱歧义)
_HOUR_UNKNOWN_PLACEHOLDER = "时辰未知"
# v1 strength_label(iOS buildV1ChartJSON 同款,含 unknown_hour/兜底)
_STRENGTH_LABEL = {
    "strong": "偏旺", "weak": "偏弱", "balanced": "中和",
    "special_pattern": "从格特征", "unknown_hour": "时辰未知",
}
_COMPAT_CONTEXT_LABEL = {"general": "通用", "marriage": "婚姻", "business": "事业"}


def _secret() -> bytes:
    """token 签名密钥:从 JWT_SECRET_KEY 做 HMAC 域分隔派生。"""
    return hmac.new(
        JWT_SECRET_KEY.encode("utf-8"),
        b"qicompass-context-token-v1",
        hashlib.sha256,
    ).digest()


def _canon(obj: Any) -> str:
    """canonical JSON(两端逐字节一致性的唯一裁判)。"""
    return json.dumps(obj, sort_keys=True, ensure_ascii=False,
                      separators=(",", ":"))


def issue_token(*, content_hash: str, family: str, fields: dict) -> str:
    """签发自包含 token(仅服务端签发端点调用;测试辅助另见 tests fixtures)。"""
    claims = {"fam": family, "hash": content_hash, "fields": fields}
    body = base64.urlsafe_b64encode(
        _canon(claims).encode("utf-8")).decode("ascii")
    sig = hmac.new(_secret(), body.encode("ascii"), hashlib.sha256).hexdigest()
    return f"{_TOKEN_VERSION}.{body}.{sig}"


def verify_token(
    token: str | None, *, content_hash: str, family: str,
) -> dict:
    """验签并返回 claims。

    Raises:
        ContextTokenRequiredError: 未携带 token(403)
        ContextTokenInvalidError: 格式/签名/hash/族不匹配(403)
    """
    if not token or not token.strip():
        raise ContextTokenRequiredError(
            f"module 需要 context_token(排盘端点签发;family={family})",
            content_hash=content_hash)
    parts = token.strip().split(".")
    if len(parts) != 3 or parts[0] != _TOKEN_VERSION:
        raise ContextTokenInvalidError(
            "context_token 格式非法(期望 v1.<body>.<sig>)",
            content_hash=content_hash)
    _, body, sig = parts
    expected = hmac.new(_secret(), body.encode("ascii"),
                        hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, expected):
        raise ContextTokenInvalidError(
            "context_token 签名不匹配(伪造或 secret 已轮换,请重新排盘获取)",
            content_hash=content_hash)
    try:
        padded = body + "=" * (-len(body) % 4)
        claims = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as e:
        raise ContextTokenInvalidError(
            f"context_token claims 解码失败:{e}", content_hash=content_hash
        ) from e
    if not isinstance(claims, dict):
        raise ContextTokenInvalidError(
            "context_token claims 顶层非对象", content_hash=content_hash)
    if claims.get("fam") != family:
        raise ContextTokenInvalidError(
            f"context_token 族不匹配(期望 {family},实为 {claims.get('fam')!r})",
            content_hash=content_hash)
    if claims.get("hash") != content_hash:
        raise ContextTokenInvalidError(
            "context_token 与请求 content_hash 不符(token 属于其他命盘)",
            content_hash=content_hash)
    return claims


# ---------- 族定义:module → 验签族 ----------

# m7_manual 无 chart 字段(基于 M1-M6 结论),退化为「签名 + hash + 族」校验
# (仍要求攻击者取得该盘的合法签发;其 prompt 注入面由长度上限兜底)。
_MODULE_FAMILY: dict[str, str] = {
    "bazi_deep": "deep", "bazi_deep_free": "deep", "bazi_deep_paid": "deep",
    "compatibility": "compat",
    "compatibility_free": "compat", "compatibility_paid": "compat",
    "daily_fortune": "daily",
    **{m: "v1" for m in (
        "m0_structure", "m1_talent", "m2_high_low", "m3_system",
        "m4_health", "m5_wealth", "m6_dynamics", "m7_manual")},
}


# ---------- deep 族:bazi_deep 家族 context 核心字段 ----------

# = _BAZI_DEEP_REQUIRED_FIELDS 去掉 gender / city / true_solar_time
# (设备/用户相关,签发时不可复现;镜像 PromptContextBuilder.build)
_DEEP_BIND_FIELDS: tuple[str, ...] = (
    "year_gan", "year_zhi", "year_gan_element", "year_zhi_element",
    "year_shishen_gan", "year_hide_gan",
    "month_gan", "month_zhi", "month_gan_element", "month_zhi_element",
    "month_shishen_gan", "month_hide_gan",
    "day_gan", "day_zhi", "day_gan_element", "day_shishen_zhi",
    "day_hide_gan",
    "hour_gan", "hour_zhi", "hour_gan_element", "hour_zhi_element",
    "hour_shishen_gan", "hour_hide_gan",
    "year_nayin", "month_nayin", "day_nayin", "hour_nayin",
    "ming_gong", "ming_gong_nayin",
    "shensha_list", "element_balance",
    "day_master_strength", "favorable_elements", "unfavorable_elements",
    "tiaoshou_applied", "current_luck_pillar", "current_year_pillar",
)


def _pillar_or_none(pillars: dict, pos: str) -> dict | None:
    p = pillars.get(pos)
    return p if isinstance(p, dict) else None


def _deep_fields(result: dict) -> dict[str, Any]:
    """从引擎 snapshot 镜像 iOS PromptContextBuilder.build 的绑定字段。

    镜像规则(与 Swift 端逐条对应,漂移由 round-trip 测试锁定):
    - 柱缺失(时辰未知/歧义)→ 占位「时辰未知」;day 无 zhi_element/shishen_gan
      维度(与 REQUIRED_FIELDS 一致)
    - hide_gan / day_shishen_zhi: ", ".join
    - gan/zhi_element: EN2ZH 英文→中文
    - shensha_list: 空 → 「无」;否则 「、」join「名(柱)」
    - element_balance: 「木:x 火:x 土:x 金:x 水:x」
    - day_master_strength: None → "special_pattern"(从格诚实降级口径)
    - favorable/unfavorable: ", ".join(空列表 → 空串)
    - current_luck_pillar: None → 「未排」;current_year_pilar 同
    """
    ph = _HOUR_UNKNOWN_PLACEHOLDER
    pillars = result["pillars"]

    def _gan(pos: str) -> str:
        p = _pillar_or_none(pillars, pos)
        return p["gan"] if p else ph

    def _zhi(pos: str) -> str:
        p = _pillar_or_none(pillars, pos)
        return p["zhi"] if p else ph

    def _element(pos: str, key: str) -> str:
        p = _pillar_or_none(pillars, pos)
        return EN2ZH[p[key]] if p else ph

    def _shishen_gan(pos: str) -> str:
        p = _pillar_or_none(pillars, pos)
        return p["shishen_gan"] if p else ph

    def _hide_gan(pos: str) -> str:
        p = _pillar_or_none(pillars, pos)
        return ", ".join(p["hide_gan"]) if p else ph

    def _day_shishen_zhi() -> str:
        p = _pillar_or_none(pillars, "day")
        return ", ".join(p["shishen_zhi"]) if p else ph

    def _nayin(pos: str) -> str:
        p = _pillar_or_none(pillars, pos)
        return p["nayin"] if p else ph

    shensha = result.get("shensha") or []
    shensha_list = (
        "无" if not shensha
        else "、".join(f'{s["name"]}({s["position"]})' for s in shensha)
    )
    eb = result["element_balance"]
    clp = result.get("current_luck_pillar")
    strength = result.get("day_master_strength")

    fields: dict[str, Any] = {
        "year_gan": _gan("year"), "year_zhi": _zhi("year"),
        "year_gan_element": _element("year", "gan_element"),
        "year_zhi_element": _element("year", "zhi_element"),
        "year_shishen_gan": _shishen_gan("year"),
        "year_hide_gan": _hide_gan("year"),
        "month_gan": _gan("month"), "month_zhi": _zhi("month"),
        "month_gan_element": _element("month", "gan_element"),
        "month_zhi_element": _element("month", "zhi_element"),
        "month_shishen_gan": _shishen_gan("month"),
        "month_hide_gan": _hide_gan("month"),
        "day_gan": _gan("day"), "day_zhi": _zhi("day"),
        "day_gan_element": _element("day", "gan_element"),
        "day_shishen_zhi": _day_shishen_zhi(),
        "day_hide_gan": _hide_gan("day"),
        "hour_gan": _gan("hour"), "hour_zhi": _zhi("hour"),
        "hour_gan_element": _element("hour", "gan_element"),
        "hour_zhi_element": _element("hour", "zhi_element"),
        "hour_shishen_gan": _shishen_gan("hour"),
        "hour_hide_gan": _hide_gan("hour"),
        "year_nayin": _nayin("year"), "month_nayin": _nayin("month"),
        "day_nayin": _nayin("day"), "hour_nayin": _nayin("hour"),
        "ming_gong": result["ming_gong"]["gan_zhi"],
        "ming_gong_nayin": result["ming_gong"]["nayin"],
        "shensha_list": shensha_list,
        "element_balance": (
            f"木:{eb['wood']} 火:{eb['fire']} 土:{eb['earth']}"
            f" 金:{eb['metal']} 水:{eb['water']}"
        ),
        "day_master_strength": strength if strength else "special_pattern",
        "favorable_elements": ", ".join(result.get("favorable_elements") or []),
        "unfavorable_elements": ", ".join(
            result.get("unfavorable_elements") or []),
        "tiaoshou_applied": bool(result.get("tiaoshou_applied")),
        "current_luck_pillar": clp["gan_zhi"] if clp else "未排",
        "current_year_pillar": result.get("current_year_pillar") or "未排",
    }
    assert set(fields) == set(_DEEP_BIND_FIELDS), (
        "_deep_fields 与 _DEEP_BIND_FIELDS 漂移(提取/签发不一致 = 验签必炸)")
    return fields


# ---------- v1 族:M0-M7 的 chart JSON ----------

def _build_v1_chart_mirror(result: dict) -> dict | None:
    """镜像 iOS buildV1ChartJSON 的 chart 结构(canonical 比对用)。

    与 engine/chart_builder.build_v1_chart 的差异:后者对时辰未知盘会
    KeyError/TypeError(hour/day 为 None 时直接下标),而 iOS 端对缺失柱
    输出 null、unknown_hour 有专属 label——绑定必须跟 iOS 口径(客户端
    送什么、服务端就锁什么),故此处独立实现容忍版。日柱缺失(歧义盘,
    D5 全拦截,不应进入 v1 链)或 meta/current_year 缺失 → 返回 None
    (不签发 v1 token,对齐 iOS 端显式抛错 = 链路本就不可达)。
    """
    pillars = result["pillars"]
    day = _pillar_or_none(pillars, "day")
    meta = result.get("meta")
    cyp = result.get("current_year_pillar")
    if day is None or not meta or not cyp or len(cyp) != 2:
        return None

    def _pillar_dict(pos: str) -> dict | None:
        return _pillar_or_none(pillars, pos)

    strength = result.get("day_master_strength")
    strength_label = (
        _STRENGTH_LABEL.get(strength) if strength else "未判定"
    )
    if strength_label is None:
        return None  # 未知枚举 = 代码 bug,iOS 端同样显式抛错不进链

    def _split(gz: str) -> dict[str, str]:
        return {"stem": gz[0], "branch": gz[1]}

    luck_pillars = []
    for lp in result.get("luck_pillars") or []:
        if len(lp["gan_zhi"]) != 2:
            return None
        luck_pillars.append({
            "start_age": lp["start_age"],
            **_split(lp["gan_zhi"]),
        })

    clp = result.get("current_luck_pillar")
    current_luck: dict | None = None
    if clp is not None:
        if len(clp["gan_zhi"]) != 2:
            return None
        current_luck = {
            "start_age": lookup_current_luck_start_age(
                result.get("luck_pillars") or [],
                clp["start_year"], clp["end_year"]),
            **_split(clp["gan_zhi"]),
            "ten_god": None,
        }

    def _gz(p: dict | None) -> dict | None:
        # ten_gods 的天干十神:柱缺失 → null(iOS ?? NSNull)
        return p["shishen_gan"] if p else None

    def _zhis(p: dict | None) -> Any:
        return p["shishen_zhi"] if p else None

    return {
        "meta": meta,
        "pillars": {
            "year": _pillar_dict("year"),
            "month": _pillar_dict("month"),
            "day": day,
            "hour": _pillar_dict("hour"),
        },
        "day_master": {
            "stem": day["gan"],
            "element": EN2ZH[day["gan_element"]],
            "strength_score": None,
            "strength_label": strength_label,
        },
        "ten_gods": {
            "year_stem": _gz(_pillar_or_none(pillars, "year")),
            "month_stem": _gz(_pillar_or_none(pillars, "month")),
            "hour_stem": _gz(_pillar_or_none(pillars, "hour")),
            "hidden": {
                "year_branch": _zhis(_pillar_or_none(pillars, "year")),
                "month_branch": _zhis(_pillar_or_none(pillars, "month")),
                "day_branch": day["shishen_zhi"],
                "hour_branch": _zhis(_pillar_or_none(pillars, "hour")),
            },
        },
        # iOS 端透传 useful_god_candidates(不做从格清空;engine 对从格
        # 本就产空表,镜像跟 iOS 口径透传)
        "ten_god_weights": result.get("ten_god_weights") or {},
        "five_elements": _five_elements(result),
        "useful_god_candidates": result.get("useful_god_candidates") or [],
        "luck_pillars": luck_pillars,
        "current_luck": current_luck,
        "current_year": {**_split(cyp), "ten_god": None},
    }


def _five_elements(result: dict) -> dict[str, int]:
    eb = result["element_balance"]
    return {"木": eb["wood"], "火": eb["fire"], "土": eb["earth"],
            "金": eb["metal"], "水": eb["water"]}


# ---------- payload 族:合盘/每日端点的 per-chart 对账 ----------

def payload_fields(result: dict) -> dict[str, Any]:
    """per-chart token claims:ChartPayload 可对账字段 + element_balance。

    合盘/每日端点的 chart_payload 客户端自持,与 content_hash 单向不可逆,
    无法服务端复算——token 在排盘时签发,合盘/每日端点用「claims ↔ payload」
    对账关死伪造 payload。element_balance 不在 ChartPayload 里,但进 claims:
    合盘 context 的 element_balance_a/b 展示串由它派生(签发链携带)。

    luck_pillars 不进 claims/daily 端点按契约不填(models/daily_fortune.py
    ChartPayload docstring),若对账会把合法请求误杀;合盘侧流年同步表在
    context 绑定集之外(内嵌两人称呼,随语言本地化),无对账必要。
    """
    pillars = result["pillars"]

    def _ref(pos: str) -> dict | None:
        p = _pillar_or_none(pillars, pos)
        return {"gan": p["gan"], "zhi": p["zhi"]} if p else None

    four_pillars = {
        pos: _ref(pos) for pos in ("year", "month", "day", "hour")
        if _ref(pos) is not None
    }
    return {
        "day_master": _pillar_or_none(pillars, "day")["gan"]
        if _pillar_or_none(pillars, "day") else "",
        "day_master_element": _pillar_or_none(pillars, "day")["gan_element"]
        if _pillar_or_none(pillars, "day") else "",
        "day_master_strength": result.get("day_master_strength"),
        "favorable_elements": list(result.get("favorable_elements") or []),
        "unfavorable_elements": list(
            result.get("unfavorable_elements") or []),
        "four_pillars": four_pillars,
        "element_balance": result["element_balance"],
    }


def verify_payload_against_chart(
    token: str | None, *, chart_hash: str, chart_payload,
) -> dict:
    """合盘/每日端点入口:验证 per-chart token 与请求 payload 一致。

    Args:
        token: 客户端从排盘响应存档的 payload 族 token
        chart_hash: 请求引用的 content_hash(person_a_hash / chart_hash)
        chart_payload: ChartPayload(合盘)或 DailyFortuneRequest.chart_payload

    Returns:
        验签通过的 claims["fields"](含 element_balance,供下游合盘/每日
        token 派生)

    Raises:
        ContextTokenRequiredError / ContextTokenInvalidError
    """
    claims = verify_token(token, content_hash=chart_hash, family="payload")
    expected = claims["fields"]
    actual = {
        "day_master": chart_payload.day_master,
        "day_master_element": chart_payload.day_master_element,
        "day_master_strength": chart_payload.day_master_strength,
        "favorable_elements": list(chart_payload.favorable_elements),
        "unfavorable_elements": list(chart_payload.unfavorable_elements),
        "four_pillars": {
            pos: {"gan": p.gan, "zhi": p.zhi}
            for pos, p in chart_payload.four_pillars.items()
        },
    }
    for key, value in actual.items():
        if _canon(expected.get(key)) != _canon(value):
            raise ContextTokenInvalidError(
                f"chart_payload 与 context_token 不符(字段 {key};"
                f"token 属于该 hash 的真实排盘,payload 被篡改或错盘)",
                content_hash=chart_hash)
    return expected


# ---------- compat 族:合盘 context 核心字段 ----------

_COMPAT_BIND_FIELDS: tuple[str, ...] = (
    "context_label",
    "day_master_a", "day_master_strength_a", "favorable_a",
    "year_a", "month_a", "day_a", "hour_a", "element_balance_a",
    "day_master_b", "day_master_strength_b", "favorable_b",
    "year_b", "month_b", "day_b", "hour_b", "element_balance_b",
    "five_elements_assessment", "day_master_relation",
    "zodiac_match", "branch_harmony",
)


def _compat_person_fields(claims: dict, suffix: str) -> dict[str, Any]:
    """从 payload 族 claims 镜像 iOS ChartPromptContext 的绑定字段。"""
    ph = _HOUR_UNKNOWN_PLACEHOLDER
    fp = claims["four_pillars"]

    def _gz(pos: str) -> str:
        ref = fp.get(pos)
        return ref["gan"] + ref["zhi"] if ref else ph

    favorable = claims["favorable_elements"]
    eb = claims["element_balance"]
    strength = claims["day_master_strength"]
    return {
        f"day_master{suffix}": claims["day_master"] or ph,
        f"day_master_strength{suffix}":
            strength if strength else "special_pattern",
        # iOS:空喜忌(从格)→ 「—(从格未下喜忌)」
        f"favorable{suffix}":
            "—(从格未下喜忌)" if not favorable else ", ".join(favorable),
        f"year{suffix}": _gz("year"), f"month{suffix}": _gz("month"),
        f"day{suffix}": _gz("day"), f"hour{suffix}": _gz("hour"),
        f"element_balance{suffix}": (
            f"木:{eb['wood']} 火:{eb['fire']} 土:{eb['earth']}"
            f" 金:{eb['metal']} 水:{eb['water']}"
        ),
    }


def compat_fields(
    *,
    context: str,
    claims_a: dict,
    claims_b: dict,
    assessment,
) -> dict[str, Any]:
    """签发合盘 token 的绑定字段(镜像 buildCompatibility 的绑定子集)。

    未锁:name_a/name_b(用户输入+随语言本地化)、gender/city/birth 展示串、
    synced_fortune_table(内嵌称呼)。
    """
    fields: dict[str, Any] = {
        "context_label": _COMPAT_CONTEXT_LABEL.get(context, context),
        **_compat_person_fields(claims_a, "_a"),
        **_compat_person_fields(claims_b, "_b"),
        "five_elements_assessment": assessment.five_elements,
        "day_master_relation": assessment.day_master_relation,
        "zodiac_match": assessment.zodiac_match,
        "branch_harmony": assessment.branch_harmony,
    }
    assert set(fields) == set(_COMPAT_BIND_FIELDS), (
        "compat_fields 与 _COMPAT_BIND_FIELDS 漂移")
    return fields


# ---------- daily 族:每日运势 context 核心字段 ----------

_DAILY_BIND_FIELDS: tuple[str, ...] = (
    "day_master", "day_master_element", "day_master_strength",
    "favorable_elements", "unfavorable_elements",
    "day_pillar", "day_stem", "day_stem_element",
    "day_branch", "day_branch_element", "day_relation", "day_chong",
    "lunar_date", "huangli_yi", "huangli_ji",
    "hour_pillars_with_relations",
)
# claims 内附加维度(不在 context 里,单独比对)
_DAILY_CLAIM_EXTRA = ("target_date",)


def daily_fields(
    *, claims: dict, response, target_date_iso: str,
) -> dict[str, Any]:
    """签发每日 token 的绑定字段(镜像 buildDailyFortune 的绑定子集)。

    未锁:date(设备日历格式化「2026年10月7日」)。
    target_date 进 claims:同盘不同日的 token 不可互用(缓存键含日期)。
    """
    day_pillar = response.day_pillar
    day_stem, day_branch = day_pillar[0], day_pillar[1]
    # iOS:ElementColors.ofGan/ofZhi → elementToChinese;后端同源查表,
    # 未知字原样返回(iOS ?? dayStem 兜底同款)
    stem_el = GAN_ELEMENT.get(day_stem)
    branch_el = ZHI_ELEMENT.get(day_branch)
    day_stem_element = EN2ZH[stem_el] if stem_el else day_stem
    day_branch_element = EN2ZH[branch_el] if branch_el else day_branch

    if response.day_chong:
        targets = response.day_chong_targets
        day_chong = response.day_chong + (
            f"(冲{'、'.join(targets)})" if targets else "")
    else:
        day_chong = "无"

    hour_lines = []
    for hp in response.hour_pillars:
        line = f"- {hp.hour}时({hp.time_range}):{hp.pillar} {hp.relation}"
        if hp.chong:
            targets = hp.chong_targets
            line += f" 冲{hp.chong}" + (
                f"(冲{'、'.join(targets)})" if targets else "")
        hour_lines.append(line)

    favorable = claims["favorable_elements"]
    unfavorable = claims["unfavorable_elements"]
    strength = claims["day_master_strength"]
    fields: dict[str, Any] = {
        "day_master": claims["day_master"],
        "day_master_element": claims["day_master_element"],
        "day_master_strength":
            strength if strength else "special_pattern",
        "favorable_elements": ", ".join(favorable),
        "unfavorable_elements": ", ".join(unfavorable),
        "day_pillar": day_pillar,
        "day_stem": day_stem,
        "day_stem_element": day_stem_element,
        "day_branch": day_branch,
        "day_branch_element": day_branch_element,
        "day_relation": response.day_relation_to_day_master,
        "day_chong": day_chong,
        "lunar_date": response.lunar_date,
        "huangli_yi": "、".join(response.huangli_yi),
        "huangli_ji": "、".join(response.huangli_ji),
        "hour_pillars_with_relations": "\n".join(hour_lines),
        "target_date": target_date_iso,
    }
    assert set(fields) == set(_DAILY_BIND_FIELDS) | set(_DAILY_CLAIM_EXTRA), (
        "daily_fields 与 _DAILY_BIND_FIELDS 漂移")
    return fields


# ---------- interpret/translate 端点验签入口 ----------

def verify_interpret_context(
    token: str | None, *, module: str, content_hash: str, context: dict,
    target_date_iso: str | None = None,
) -> None:
    """interpret/translate 一刀切验签(P0 收口主闸,免费+付费)。

    Raises:
        ContextTokenRequiredError / ContextTokenInvalidError
    """
    family = _MODULE_FAMILY[module]
    claims = verify_token(token, content_hash=content_hash, family=family)
    expected = claims.get("fields")
    if not isinstance(expected, dict):
        raise ContextTokenInvalidError(
            "context_token claims 缺 fields", content_hash=content_hash)

    if family == "v1":
        if module == "m7_manual":
            return  # 无 chart 字段,签名+hash+族校验即全部可验证项
        chart = context.get("chart")
        if not isinstance(chart, str):
            raise ContextTokenInvalidError(
                "v1 模块 context.chart 缺失或非字符串(无法与 token 比对)",
                content_hash=content_hash)
        try:
            parsed = json.loads(chart)
        except json.JSONDecodeError as e:
            raise ContextTokenInvalidError(
                f"context.chart 非合法 JSON,无法验签:{e}",
                content_hash=content_hash) from e
        if _canon(parsed) != _canon(expected.get("chart")):
            raise ContextTokenInvalidError(
                "context.chart 与 token 不符(chart 被篡改或属于其他命盘)",
                content_hash=content_hash)
        return

    bind = (
        _DEEP_BIND_FIELDS if family == "deep"
        else _COMPAT_BIND_FIELDS if family == "compat"
        else _DAILY_BIND_FIELDS
    )
    extracted = {name: context.get(name) for name in bind}
    if _canon(extracted) != _canon({k: expected.get(k) for k in bind}):
        raise ContextTokenInvalidError(
            f"context 核心字段与 token 不符(family={family};"
            f"盘身被篡改或 token 属于其他命盘)",
            content_hash=content_hash)
    if family == "daily":
        if expected.get("target_date") != target_date_iso:
            raise ContextTokenInvalidError(
                f"daily token 日期不符(token={expected.get('target_date')!r}"
                f" 请求={target_date_iso!r};须重取当日 daily-fortune token)",
                content_hash=content_hash)


def build_chart_tokens(result: dict) -> dict[str, str]:
    """/api/bazi/calculate 签发:deep + v1 + payload 三族 token。

    v1 族对时辰未知/数据缺失盘不签发(iOS 端同场景显式抛错,v1 链不可达);
    客户端对老快照无 token 的迁移:重跑 calculate 即可(确定性,同 hash)。
    """
    h = result["content_hash"]
    tokens = {
        "deep": issue_token(
            content_hash=h, family="deep", fields=_deep_fields(result)),
        "payload": issue_token(
            content_hash=h, family="payload", fields=payload_fields(result)),
    }
    chart = _build_v1_chart_mirror(result)
    if chart is not None:
        tokens["v1"] = issue_token(
            content_hash=h, family="v1", fields={"chart": chart})
    return tokens
