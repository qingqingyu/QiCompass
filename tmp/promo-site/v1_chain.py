"""v1 prompt 系统(M0-M7 链式调用)— promo-site runner。

复用 backend/spikes/prompt_validation/run_v1_chain_spike.py 的 helper:
- `_call_module` 单 module 调用(render_prompt → AI → parse → validate,不写文件)
- `_build_chart_json` 构造 chart JSON(M0 输入)

链式数据流(对齐 iOS DeepAnalysisViewModel.runV1Chain):
  M0_structure(chart) → structure_fingerprint + main_axis + core_loop
  M1_talent → innate + defensive + one_leverage
  M2_high_low → threshold + switch_actions
  M3_system → ideal_life_structure + environment_checklist
  M4_health(用户输入 age + current_concern) → 不向下游传
  M5_wealth(用户输入 assets_summary + preference) → 不向下游传
  M6_dynamics → leverage
  M7_manual(基于 M1-M6 累积字段) → 终点

错误处理:
- M0 失败 → 中断链(M0 是基础,失败则后面无以为继)
- M1-M7 失败 → 记录 errors,继续跑下游(可能拿不到上游字段,但能跑通 prompt 渲染)

耗时:
- 每个 module 30-50s,全链 ~4-7 分钟
- 调用方应给前端一个 "运行中" 反馈(spinner / 进度提示)
"""

from __future__ import annotations

import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

# 自包含 sys.path 注入(若 main.py 已经注入则 idempotent)
_PROMO_ROOT = Path(__file__).resolve().parent
_BACKEND_ROOT = _PROMO_ROOT.parent.parent / "backend"
if str(_BACKEND_ROOT) not in sys.path:
    sys.path.insert(0, str(_BACKEND_ROOT))
# JWT_SECRET_KEY 占位符(若 main.py 已经设过则不覆盖)
if not os.environ.get("JWT_SECRET_KEY"):
    os.environ["JWT_SECRET_KEY"] = "promo-site-dev-not-used"

from spikes.prompt_validation.run_v1_chain_spike import (  # noqa: E402
    _build_chart_json,
    _call_module,
)

logger = logging.getLogger("promo-site.v1_chain")


# ---------- M4 / M5 用户输入 schema ----------

class V1UserInput:
    """M4_health / M5_wealth 需要的用户输入(prompt 模板规定必填)。

    promo 表单收集后,以此结构传入 run_v1_chain。
    """
    def __init__(
        self,
        m4_age: str = "",
        m4_current_concern: str = "",
        m5_assets_summary: str = "",
        m5_preference: str = "",
    ):
        self.m4_age = m4_age or "30"
        self.m4_current_concern = m4_current_concern or "目前工作压力大,睡眠一般"
        self.m5_assets_summary = m5_assets_summary or "主要是工资收入,有少量存款和一套自住房"
        self.m5_preference = m5_preference or "稳健型,优先保障,追求被动收入"


# ---------- 链式 runner ----------

async def run_v1_chain(
    *,
    client: Any,
    chart: dict[str, Any],
    user_input: V1UserInput | None = None,
    stop_on_m0_failure: bool = True,
) -> list[dict[str, Any]]:
    """跑 M0-M7 全链路,返回各 module 状态列表。

    Args:
        client: AIClient 实例(已经选好 provider + key)
        chart: BaziEngine.calculate() 返回的 dict
        user_input: M4/M5 用户输入;None 用默认占位
        stop_on_m0_failure: M0 失败是否中断链(默认 True,对齐 iOS)

    Returns:
        [{module, ok, parsed, errors, elapsed_ms}, ...] 按 M0-M7 顺序
    """
    if user_input is None:
        user_input = V1UserInput()

    # 构造 chart JSON(M0 必需)
    chart_json = _build_chart_json(chart)
    chain_ctx: dict[str, Any] = {"chart": chart_json}
    statuses: list[dict[str, Any]] = []

    # ---------- M0(基础,失败中断) ----------
    s = await _call_and_record("m0_structure", chain_ctx, client, statuses)
    if s["parsed"]:
        p = s["parsed"]
        chain_ctx["structure_fingerprint"] = p.get("structure_fingerprint", "")
        chain_ctx["main_axis"] = json.dumps(p.get("main_axis", {}), ensure_ascii=False)
        chain_ctx["core_loop"] = json.dumps(p.get("core_loop", {}), ensure_ascii=False)
    elif stop_on_m0_failure and not s["ok"]:
        logger.warning("v1_chain M0 失败,中断链 errors=%s", s["errors"])
        return statuses

    # ---------- M1 ----------
    s = await _call_and_record("m1_talent", chain_ctx, client, statuses)
    if s["parsed"]:
        p = s["parsed"]
        chain_ctx["innate"] = json.dumps(p.get("innate", []), ensure_ascii=False)
        chain_ctx["defensive"] = json.dumps(p.get("defensive", []), ensure_ascii=False)
        chain_ctx["one_leverage"] = p.get("one_leverage", "")

    # ---------- M2 ----------
    s = await _call_and_record("m2_high_low", chain_ctx, client, statuses)
    if s["parsed"]:
        p = s["parsed"]
        chain_ctx["threshold"] = json.dumps(p.get("threshold", {}), ensure_ascii=False)
        chain_ctx["switch_actions"] = json.dumps(p.get("switch_actions", []), ensure_ascii=False)

    # ---------- M3 ----------
    s = await _call_and_record("m3_system", chain_ctx, client, statuses)
    if s["parsed"]:
        p = s["parsed"]
        chain_ctx["ideal_life_structure"] = json.dumps(p.get("ideal_life_structure", {}), ensure_ascii=False)
        chain_ctx["environment_checklist"] = json.dumps(p.get("environment_checklist", []), ensure_ascii=False)

    # ---------- M4(需 age + current_concern 用户输入) ----------
    m4_ctx = dict(chain_ctx)
    m4_ctx["age"] = user_input.m4_age
    m4_ctx["current_concern"] = user_input.m4_current_concern
    s = await _call_and_record("m4_health", m4_ctx, client, statuses)
    # M4 不向下游传字段

    # ---------- M5(需 assets_summary + preference 用户输入) ----------
    m5_ctx = dict(chain_ctx)
    m5_ctx["assets_summary"] = user_input.m5_assets_summary
    m5_ctx["preference"] = user_input.m5_preference
    s = await _call_and_record("m5_wealth", m5_ctx, client, statuses)
    # M5 不向下游传字段

    # ---------- M6 ----------
    s = await _call_and_record("m6_dynamics", chain_ctx, client, statuses)
    if s["parsed"]:
        chain_ctx["leverage"] = json.dumps(s["parsed"].get("leverage", {}), ensure_ascii=False)

    # ---------- M7(基于 M1-M6 累积字段,不读 chart) ----------
    m7_ctx = {k: v for k, v in chain_ctx.items() if k != "chart"}
    s = await _call_and_record("m7_manual", m7_ctx, client, statuses)

    logger.info(
        "v1_chain 完成 ok_count=%s/%s",
        sum(1 for x in statuses if x["ok"]),
        len(statuses),
    )
    return statuses


async def _call_and_record(
    module: str,
    context: dict[str, Any],
    client: Any,
    statuses: list[dict[str, Any]],
) -> dict[str, Any]:
    """调 _call_module 并把结果追加到 statuses(返回 status 便于链上判断)。"""
    import time
    start = time.perf_counter()
    try:
        _rendered, parsed, failures = await _call_module(
            module=module,
            context=dict(context),
            ai_client=client,
            dry_run=False,
        )
    except Exception as e:
        elapsed_ms = round((time.perf_counter() - start) * 1000, 1)
        logger.error("v1.%s 异常: %s", module, e, exc_info=True)
        status = {
            "module": module,
            "ok": False,
            "parsed": None,
            "errors": [f"{type(e).__name__}: {e}"],
            "elapsed_ms": elapsed_ms,
        }
        statuses.append(status)
        return status

    elapsed_ms = round((time.perf_counter() - start) * 1000, 1)
    status = {
        "module": module,
        "ok": len(failures) == 0,
        "parsed": parsed,
        "errors": failures,
        "elapsed_ms": elapsed_ms,
    }
    statuses.append(status)
    logger.info(
        "v1.%s ok=%s elapsed_ms=%s failures=%s",
        module, status["ok"], elapsed_ms, failures,
    )
    return status


# ---------- module 元信息(供模板展示) ----------

MODULE_META: dict[str, dict[str, str]] = {
    "m0_structure":     {"title": "M0 · 结构",         "desc": "主线结构 + 核心循环识别"},
    "m1_talent":        {"title": "M1 · 天赋",         "desc": "天赋能力 + 高/低配版"},
    "m2_high_low":      {"title": "M2 · 高配/低配",    "desc": "高配/低配版本 + 阈值 + 切换动作"},
    "m3_system":        {"title": "M3 · 系统",         "desc": "人生系统模式 + 理想生活结构"},
    "m4_health":        {"title": "M4 · 健康",         "desc": "健康续航(需用户输入年龄 + 关注点)"},
    "m5_wealth":        {"title": "M5 · 财富",         "desc": "财富结构(需用户输入资产 + 偏好)"},
    "m6_dynamics":      {"title": "M6 · 动力学",       "desc": "结构动力学高阶 + 杠杆点"},
    "m7_manual":        {"title": "M7 · 手册",         "desc": "落地手册(基于 M1-M6 总结)"},
}
