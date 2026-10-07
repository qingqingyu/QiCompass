"""测试辅助:按测试 context/payload 直接签发 context_token(仅测试用)。

生产签发只发生在排盘/合盘/每日端点(从引擎输出来镜像 iOS 格式化);测试
的 fixture context 数值多为手造(与真实排盘无关),本 helper 从 context
自身抽取绑定字段签发——与「合法客户端存档回传」等价。
"""

from __future__ import annotations

import json

from app.context_binding import (
    _COMPAT_BIND_FIELDS,
    _DAILY_BIND_FIELDS,
    _DEEP_BIND_FIELDS,
    issue_token,
)


def token_for_context(
    *, content_hash: str, module: str, context: dict,
    target_date_iso: str | None = None,
) -> str:
    """按 module 族从 context 抽字段签发(v1 族解析 chart JSON)。"""
    if module.startswith("m"):
        if module == "m7_manual":
            # m7 验签只看签名+hash+族,chart 缺省签空 dict
            return issue_token(content_hash=content_hash, family="v1",
                               fields={"chart": {}})
        return issue_token(
            content_hash=content_hash, family="v1",
            fields={"chart": json.loads(context["chart"])})
    if module.startswith("bazi_deep"):
        return issue_token(
            content_hash=content_hash, family="deep",
            fields={k: context.get(k) for k in _DEEP_BIND_FIELDS})
    if module.startswith("compatibility"):
        return issue_token(
            content_hash=content_hash, family="compat",
            fields={k: context.get(k) for k in _COMPAT_BIND_FIELDS})
    if module == "daily_fortune":
        fields = {k: context.get(k) for k in _DAILY_BIND_FIELDS}
        fields["target_date"] = target_date_iso
        return issue_token(content_hash=content_hash, family="daily",
                           fields=fields)
    raise ValueError(f"unknown module {module!r}")


_DEFAULT_ELEMENT_BALANCE = {"wood": 1, "fire": 1, "earth": 1, "metal": 1,
                            "water": 1}


def payload_token_for(
    *, content_hash: str, chart_payload: dict,
    element_balance: dict | None = None,
) -> str:
    """按 ChartPayload 形状的 dict 签发 payload 族 token(合盘/每日端点对账用)。

    element_balance 不在 ChartPayload 里但进 claims(合盘 token 派生
    element_balance_a/b 展示串);测试默认给 1×5 占位。
    """
    four_pillars = {
        pos: {"gan": p["gan"], "zhi": p["zhi"]}
        for pos, p in (chart_payload.get("four_pillars") or {}).items()
    }
    fields = {
        "day_master": chart_payload["day_master"],
        "day_master_element": chart_payload["day_master_element"],
        "day_master_strength": chart_payload["day_master_strength"],
        "favorable_elements": list(
            chart_payload.get("favorable_elements") or []),
        "unfavorable_elements": list(
            chart_payload.get("unfavorable_elements") or []),
        "four_pillars": four_pillars,
        "element_balance": element_balance or dict(_DEFAULT_ELEMENT_BALANCE),
    }
    return issue_token(content_hash=content_hash, family="payload",
                       fields=fields)
