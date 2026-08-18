#!/usr/bin/env python3
"""evalkit runner:编排 排盘 → v1 链式生成(M0-M7)→ 判据 → 缓存/落盘/diff。

提炼自 spikes/prompt_validation/run_v1_chain_spike.py(async 用法正确的那条线;
老 run_spike.py 的同步调用 async bug 见其 docstring 标注)。判据层:
L1 确定性(checks/deterministic)/ L2 接地(checks/grounding)/ L3 裁判(S05)。

用法:
    cd backend
    # dry-run(不调 AI,验证排盘 + chart 构建 + prompt 渲染 + 链式注入)
    python -m evalkit.runner --dry-run

    # real API(需 AI key;--case-limit 1 = 1 盘 × 8 模块 = 8 次调用)
    set -a; source .env; set +a
    python -m evalkit.runner --case-limit 1

    # 跑完自动与 runs/BASELINE 对比;有 regressed → 退出码 1
    python -m evalkit.runner

依赖图(与 app/ai/prompts.py REQUIRED_FIELDS 对齐;上游输出写回 chain_ctx):
    M0 → [structure_fingerprint, main_axis, core_loop]
    M1 (M0) → [innate, defensive, one_leverage]
    M2 (M0 + M1) → [threshold, switch_actions]
    M3 (M0) → [ideal_life_structure, environment_checklist]
    M4 (M0 + 用户输入)
    M5 (M0 + M1 + M3 + 用户输入)
    M6 (M0 + M1 + M2) → [leverage]
    M7 (M1 + M2 + M3 + M6,不传 chart)
    M4/M5 的输出不写回 chain_ctx(无下游)。改 M2 模板 → 缓存只失效
    M2 及下游 M6/M7;改 M5 → 只失效 M5(无下游)。
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# 确保从 backend/ 目录运行时能找到 app 包(对齐 spike 的做法)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.ai.client import AIClient, create_ai_client
from app.ai.prompts import PROMPT_VERSIONS, REQUIRED_FIELDS, render_prompt
from app.config import (
    AI_PROVIDER,
    ANTHROPIC_API_KEY,
    ANTHROPIC_MODEL,
    OPENAI_API_KEY,
    OPENAI_BASE_URL,
    OPENAI_MODEL,
    resolve_temperature,
)
from app.engine.bazi_engine import BaziEngine
from app.engine.chart_builder import build_v1_chart

from .cases import CASES, CASES_HASH, parse_birth
from .checks.deterministic import check_deterministic
from .checks.grounding import check_grounding
from .judge import JudgeResult, create_judge_client, judge_case_modules
from .llm_json import parse_llm_json
from .rubric import RUBRIC_VERSION
from .store import (
    RUNS_DIR,
    build_run_identity,
    cache_get,
    cache_put,
    compute_verdict,
    diff_runs,
    make_cache_key,
    make_run_id,
    read_baseline,
)

logger = logging.getLogger("evalkit.runner")

V1_MODULES: tuple[str, ...] = (
    "m0_structure", "m1_talent", "m2_high_low", "m3_system",
    "m4_health", "m5_wealth", "m6_dynamics", "m7_manual",
)

# 链式依赖(上游模块粒度)。--modules 子集漏了任一上游 → 显式报错,
# 不静默注入空值(空 fingerprint 会让下游 prompt 渲染出无意义内容)。
MODULE_DEPS: dict[str, tuple[str, ...]] = {
    "m0_structure": (),
    "m1_talent": ("m0_structure",),
    "m2_high_low": ("m0_structure", "m1_talent"),
    "m3_system": ("m0_structure",),
    "m4_health": ("m0_structure",),
    "m5_wealth": ("m0_structure", "m1_talent", "m3_system"),
    "m6_dynamics": ("m0_structure", "m1_talent", "m2_high_low"),
    "m7_manual": ("m1_talent", "m2_high_low", "m3_system", "m6_dynamics"),
}

# 确定性:固定 now,当前大运/流年不随真实时间漂移
_FIXED_NOW = datetime(2025, 1, 15, 12, 0, tzinfo=timezone.utc)


# ---------- M4/M5 用户输入(spike 固定值;生产由 iOS Stage 8 收集) ----------

_M4_USER_INPUT: dict[str, Any] = {
    "age": 32,
    "current_concern": "睡眠质量差,工作日长期疲劳",
}

_M5_USER_INPUT: dict[str, Any] = {
    "assets_summary": "中等收入,有些积蓄,无房产",
    "preference": "平衡(中等风险)",
}


# dry-run 链式字段 placeholder(模拟上游 LLM 输出,让 M1-M7 渲染能跑通)
_DRY_RUN_PLACEHOLDERS: dict[str, str] = {
    "structure_fingerprint": "[dry-run placeholder] 伤官生财循环驱动,外显创造力",
    "main_axis": '{"dominant":"伤官","secondary":"财","latent":"印","evidence":"dry-run"}',
    "core_loop": '{"from":"伤官","to":"财","flow":"dry-run","driver":"dry-run","leak":"dry-run","evidence":"dry-run"}',
    "innate": '[{"name":"创造力","behavior":"dry-run","evidence":"dry-run","energy":"gain"}]',
    "defensive": '[{"name":"讨好","looks_like":"dry-run","actual_cost":"dry-run","evidence":"dry-run"}]',
    "one_leverage": "[dry-run placeholder] 创造力",
    "threshold": '{"environment":{"enables":"自主权","suppresses":"微观管理"},"belief":{"limiting_belief":"dry-run","origin":"dry-run","ceiling_effect":"dry-run"},"awareness":{"key_moment":"dry-run","what_to_notice":"dry-run"}}',
    "switch_actions": '["动作1","动作2","动作3"]',
    "ideal_life_structure": '{"time":"灵活","collaboration":"低密度","feedback_cycle":"短","income_rhythm":"项目制"}',
    "environment_checklist": '["q1","q2","q3","q4","q5"]',
    "leverage": '{"point":"dry-run","input":"dry-run","output":"dry-run","why":"dry-run"}',
}


def _apply_dry_run_placeholders(chain_ctx: dict[str, Any]) -> None:
    """dry-run 模式:把所有链式字段填 placeholder(模拟上游 LLM 输出)。"""
    for key, value in _DRY_RUN_PLACEHOLDERS.items():
        chain_ctx.setdefault(key, value)


# ---------- 模块选择 ----------

def resolve_selected_modules(spec: list[str] | None) -> list[str]:
    """解析 --modules:校验合法值 + 上游齐全,返回按链式顺序排列的列表。

    Raises:
        ValueError: 未知 module / 重复 / 缺上游(CLI 层转退出码 2)
    """
    if not spec:
        return list(V1_MODULES)
    unknown = [m for m in spec if m not in V1_MODULES]
    if unknown:
        raise ValueError(
            f"未知 module: {unknown}(合法值: {list(V1_MODULES)})"
        )
    if len(set(spec)) != len(spec):
        raise ValueError(f"--modules 有重复: {spec}")
    missing = {dep for m in spec for dep in MODULE_DEPS[m]} - set(spec)
    if missing:
        raise ValueError(
            f"--modules 缺上游: {sorted(missing)}"
            f"(被选模块的上游必须一起跑,不静默注入空值)"
        )
    # 按链式顺序(M0 → M7)排列
    return [m for m in V1_MODULES if m in set(spec)]


# ---------- 链式调用编排 ----------

def _build_chart_json(engine_result: dict[str, Any]) -> str:
    """build_v1_chart + json.dumps(ensure_ascii=False, indent=2)。"""
    chart_dict = build_v1_chart(engine_result)
    return json.dumps(chart_dict, ensure_ascii=False, indent=2)


async def _call_module(
    *,
    module: str,
    context: dict[str, Any],
    ai_client: Any,
    dry_run: bool,
    case_id: str,
    use_cache: bool,
    runs_dir: Path,
    engine_result: dict[str, Any] | None = None,
) -> tuple[str, dict[str, Any] | None, list[str], bool]:
    """单模块调用:render → (缓存 | LLM) → parse → validate。

    Returns:
        (rendered_prompt, parsed_json, validation_failures, cached)
        dry_run 模式下 parsed_json=None,failures=[],cached=False

    缓存键含渲染后 prompt sha256 + 上游注入内容 sha256:只改某模块模板
    → 只该模块(及输出注入下游的模块)miss,其余命中。
    """
    rendered = render_prompt(module, context)
    if dry_run:
        return rendered, None, [], False

    upstream_payload = {
        k: context[k] for k in REQUIRED_FIELDS[module] if k != "chart"
    }
    key = make_cache_key(
        case_id=case_id, module=module,
        prompt_version=PROMPT_VERSIONS[module],
        provider=ai_client.provider, model=ai_client.model,
        rendered_prompt=rendered, upstream_payload=upstream_payload,
    )

    cached = False
    if use_cache:
        response = cache_get(key, runs_dir)
        if response is not None:
            cached = True
    if not cached:
        temperature = resolve_temperature(module)
        response = await ai_client.interpret(
            rendered, temperature=temperature)

    try:
        parsed = parse_llm_json(response)
    except ValueError as e:
        # 不可解析的响应不进缓存(毒缓存会让该格永久 fail 不自愈);
        # cached=True 只可能来自旧版缓存残留/手改缓存文件——按实际来源给文案
        hint = ("该响应来自缓存,建议 cache_clear 后重跑"
                if cached else "响应未进缓存,重跑可重试")
        return rendered, None, [
            f"JSON 解析失败: {e}({hint})"], cached
    if not cached and use_cache:
        cache_put(key, response, runs_dir)

    # 走 module-agnostic 聚合入口(check_deterministic):runner 不再直接
    # 调 validate_v1_module_output,避免双入口漂移(未知 module 防护生效)
    failures = check_deterministic(
        module, parsed, engine_result if engine_result is not None else {})
    return rendered, parsed, failures, cached


async def _run_one_module(
    *,
    module: str,
    context: dict[str, Any],
    case_dir: Path,
    ai_client: Any,
    dry_run: bool,
    case_id: str,
    use_cache: bool,
    runs_dir: Path,
    engine_result: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """跑单个模块,落盘 prompt + response,返回 status dict。

    status: {ok, elapsed_ms, failures(L1 质量), error(异常,与 fail 区分),
              parsed, cached}
    """
    module_dir = case_dir / module
    module_dir.mkdir(parents=True, exist_ok=True)

    start = time.perf_counter()
    rendered: str | None = None
    parsed: dict[str, Any] | None = None
    failures: list[str] = []
    error: str | None = None
    cached = False
    try:
        rendered, parsed, failures, cached = await _call_module(
            module=module, context=context,
            ai_client=ai_client, dry_run=dry_run,
            case_id=case_id, use_cache=use_cache, runs_dir=runs_dir,
            engine_result=engine_result,
        )
    except Exception as e:
        logger.error("[%s] %s 异常", case_id, module, exc_info=True)
        error = f"{type(e).__name__}: {e}"

    elapsed_ms = round((time.perf_counter() - start) * 1000, 1)
    if rendered is not None:
        (module_dir / "prompt.txt").write_text(rendered, encoding="utf-8")
    if parsed is not None:
        (module_dir / "response.json").write_text(
            json.dumps(parsed, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    return {
        "ok": error is None and not failures,
        "elapsed_ms": elapsed_ms,
        "failures": failures,
        "error": error,
        "parsed": parsed,
        "cached": cached,
    }


class _CountingClient:
    """包一层真实 client 统计 API 调用数(写进 meta.json)。"""

    def __init__(self, inner: Any):
        self._inner = inner
        self.calls = 0
        self.provider = inner.provider
        self.model = inner.model

    async def interpret(self, prompt: str, **kwargs: Any) -> str:
        self.calls += 1
        return await self._inner.interpret(prompt, **kwargs)


class _DryRunPlaceholderClient:
    """dry-run 时占位,不实际被调;provider/model 为占位字符串。

    若被误调(说明编排逻辑漏了 dry_run 分流),显式抛 RuntimeError,
    让 evalkit 立即崩而不是静默继续。
    """

    provider = "dry-run"
    model = "placeholder"

    async def interpret(self, *args: Any, **kwargs: Any) -> str:
        raise RuntimeError(
            "_DryRunPlaceholderClient 不应被实际调用"
            "(检查 dry_run 分流逻辑)"
        )


async def run_chain_for_case(
    *,
    case: dict[str, Any],
    case_id: str,
    engine: BaziEngine,
    ai_client: Any,
    case_dir: Path,
    dry_run: bool,
    selected_modules: list[str],
    use_cache: bool,
    runs_dir: Path,
    judge_client: Any | None = None,
) -> list[dict[str, Any]]:
    """跑一盘 × 选中模块全链路,返回每 (case, module) 一条的 entries。

    错误显式传播:排盘失败 / 渲染失败 / API 失败分别记进对应 entry 的
    error 字段,M0 失败则链路中断(下游 entries 记 error,不当成功)。
    """
    case_dir.mkdir(parents=True, exist_ok=True)
    common = {
        "case_id": case_id,
        "category": case["category"],
        "expected_strength": case["expected_strength"],
        "provider": ai_client.provider,
        "model": ai_client.model,
    }

    # 排盘(任何模块都需要 chart)
    try:
        birth = parse_birth(case["birth_datetime"])
        engine_result = engine.calculate(
            birth=birth,
            gender=case["gender"],
            longitude=case["longitude"],
            zi_hour_rule=case["zi_hour_rule"],
        )
        chart_json = _build_chart_json(engine_result)
        (case_dir / "chart.json").write_text(chart_json, encoding="utf-8")
    except Exception as e:
        logger.error("[%s] 排盘失败", case_id, exc_info=True)
        return [
            {**common, "module": m, "prompt_version": PROMPT_VERSIONS[m],
             "elapsed_ms": 0.0, "l1": None, "l2": None, "l3": None,
             "cached": False, "verdict": "error",
             "error": f"排盘失败: {type(e).__name__}: {e}"}
            for m in selected_modules
        ]

    # 链式上下文(逐步累积上游输出)
    chain_ctx: dict[str, Any] = {"chart": chart_json}
    if dry_run:
        _apply_dry_run_placeholders(chain_ctx)

    entries: list[dict[str, Any]] = []
    chain_broken = False
    # 已完成模块的 parsed 输出(L2 链式一致性需要上游结论做 ground truth)
    chain_outputs: dict[str, dict[str, Any]] = {}

    for module in V1_MODULES:
        if module not in selected_modules:
            continue

        if chain_broken:
            entries.append({
                **common, "module": module,
                "prompt_version": PROMPT_VERSIONS[module],
                "elapsed_ms": 0.0, "l1": None, "l2": None, "l3": None,
                "cached": False, "verdict": "error",
                "error": "链路中断:M0 失败,下游未执行",
            })
            continue

        # M4/M5 追加固定用户输入
        context = dict(chain_ctx)
        if module == "m4_health":
            context["age"] = _M4_USER_INPUT["age"]
            context["current_concern"] = _M4_USER_INPUT["current_concern"]
        elif module == "m5_wealth":
            context["assets_summary"] = _M5_USER_INPUT["assets_summary"]
            context["preference"] = _M5_USER_INPUT["preference"]

        status = await _run_one_module(
            module=module, context=context, case_dir=case_dir,
            ai_client=ai_client, dry_run=dry_run,
            case_id=case_id, use_cache=use_cache, runs_dir=runs_dir,
            engine_result=engine_result,
        )

        # L1 接线:dry-run 无输出可判;异常(error)无输出可判 → l1 均为 null
        l1 = None
        if not dry_run and status["error"] is None:
            l1 = {"passed": not status["failures"],
                  "failures": status["failures"]}
        # L2 接线:有 parsed 输出才判(解析失败/异常 → null)。
        # 判据代码自身异常按条目隔离(与生成侧同粒度):不毁掉整轮已付费 run,
        # 但显式记 error(不吞,CLI 退出码 1 可见)
        l2 = None
        l2_error: str | None = None
        if not dry_run and status["error"] is None and status["parsed"] is not None:
            try:
                grounding_failures = check_grounding(
                    module, status["parsed"], engine_result,
                    chain_context=dict(chain_outputs),
                )
            except Exception as e:
                logger.error(
                    "[%s] %s L2 判据异常", case_id, module, exc_info=True)
                l2_error = f"L2 判据异常: {type(e).__name__}: {e}"
            else:
                l2 = {"passed": not grounding_failures,
                      "failures": grounding_failures}

        entry_error = status["error"] or l2_error
        verdict = compute_verdict(
            l1=l1, l2=l2, error=entry_error, judge_enabled=False)
        entries.append({
            **common, "module": module,
            "prompt_version": PROMPT_VERSIONS[module],
            "elapsed_ms": status["elapsed_ms"],
            "l1": l1, "l2": l2, "l3": None,
            "cached": status["cached"],
            "verdict": verdict,
            "error": entry_error,
        })

        parsed = status["parsed"]
        if status["ok"] and not dry_run and parsed is not None:
            _write_back_chain_ctx(chain_ctx, module, parsed)
            chain_outputs[module] = parsed
        elif module == "m0_structure" and not status["ok"]:
            chain_broken = True

    # L3 接线:只裁判 L1/L2 都过的条目(verdict=="pass" 的生成条目;
    # L2 fail / error 的裁判是浪费);同盘各模块并发(信号量限流在
    # judge_case_modules 内),逐条隔离失败。
    if judge_client is not None and chain_outputs:
        eligible = {e["module"] for e in entries if e["verdict"] == "pass"}
        to_judge = [(m, p) for m, p in chain_outputs.items() if m in eligible]
        judged: dict[str, Any] = {}
        if to_judge:
            judged = await judge_case_modules(
                [(m, p, engine_result) for m, p in to_judge],
                judge_client=judge_client,
            )
        for entry in entries:
            module = entry["module"]
            if module not in judged:
                continue
            outcome = judged[module]
            if isinstance(outcome, JudgeResult):
                entry["l3"] = {
                    "scores": outcome.scores,
                    "overall": outcome.overall,
                    "failures": outcome.failures,
                    "passed": outcome.passed,
                    "judge_provider": outcome.judge_provider,
                    "judge_model": outcome.judge_model,
                    "rubric_version": outcome.rubric_version,
                }
                entry["verdict"] = compute_verdict(
                    l1=entry["l1"], l2=entry["l2"], l3=entry["l3"],
                    error=entry["error"], judge_enabled=True)
            else:
                # 裁判解析/结构失败:不给默认分,显式记 error(CLI 退出码 1)
                entry["error"] = f"裁判失败: {outcome}"
                entry["verdict"] = "error"

    return entries


def _write_back_chain_ctx(
    chain_ctx: dict[str, Any], module: str, parsed: dict[str, Any],
) -> None:
    """把上游模块输出写回 chain_ctx(依赖图见模块 docstring)。"""
    if module == "m0_structure":
        chain_ctx["structure_fingerprint"] = parsed.get(
            "structure_fingerprint", "")
        chain_ctx["main_axis"] = json.dumps(
            parsed.get("main_axis", {}), ensure_ascii=False)
        chain_ctx["core_loop"] = json.dumps(
            parsed.get("core_loop", {}), ensure_ascii=False)
    elif module == "m1_talent":
        chain_ctx["innate"] = json.dumps(
            parsed.get("innate", []), ensure_ascii=False)
        chain_ctx["defensive"] = json.dumps(
            parsed.get("defensive", []), ensure_ascii=False)
        chain_ctx["one_leverage"] = parsed.get("one_leverage", "")
    elif module == "m2_high_low":
        chain_ctx["threshold"] = json.dumps(
            parsed.get("threshold", {}), ensure_ascii=False)
        chain_ctx["switch_actions"] = json.dumps(
            parsed.get("switch_actions", []), ensure_ascii=False)
    elif module == "m3_system":
        chain_ctx["ideal_life_structure"] = json.dumps(
            parsed.get("ideal_life_structure", {}), ensure_ascii=False)
        chain_ctx["environment_checklist"] = json.dumps(
            parsed.get("environment_checklist", []), ensure_ascii=False)
    elif module == "m6_dynamics":
        chain_ctx["leverage"] = json.dumps(
            parsed.get("leverage", {}), ensure_ascii=False)
    # m4_health / m5_wealth / m7_manual:输出不写回(无下游)


# ---------- 主流程 ----------

async def execute_run(
    *,
    dry_run: bool = False,
    case_limit: int | None = None,
    modules: list[str] | None = None,
    run_id: str | None = None,
    runs_dir: Path | None = None,
    ai_client: Any | None = None,
    no_cache: bool = False,
    skip_judge: bool = False,
    judge_client: Any | None = None,
    progress_cb: Any = None,
) -> dict[str, Any]:
    """跑一次完整评测,落盘 runs/<run_id>/,并与基线 diff(若已设置)。

    Args:
        dry_run: 不调 AI(排盘 + 渲染 + 链式注入验证)
        case_limit: 只跑前 N 盘
        modules: 选中模块(None=全部 8 个;上游必须齐全)
        run_id / runs_dir: 测试注入(默认按身份生成 / evalkit/runs/)
        ai_client: 测试注入的 client(None=按 env 构造 / dry-run 占位)
        no_cache: 忽略并绕过响应缓存,强制全量调 API(换模型/验证抖动用)
        skip_judge: 跳过 L3 裁判(真实 run 默认开裁判)
        judge_client: 测试注入的裁判 client(None 且未跳过 = 按 JUDGE_* env 构造)

    Returns:
        summary(run_id / 计数 / 缓存命中 / diff 结果)
    """
    runs_dir = runs_dir if runs_dir is not None else RUNS_DIR
    selected = resolve_selected_modules(modules)

    if case_limit is not None and case_limit < 1:
        # 0 是 falsy 会被当"全部"烧满 20 盘,负数会从尾部静默丢盘——
        # 函数级契约统一拒绝(CLI 与 HTTP 层各自还有一道前置校验)
        raise ValueError(f"case_limit 必须 ≥ 1(得到 {case_limit};不传 = 全部)")

    if ai_client is not None:
        client = _CountingClient(ai_client)
    elif dry_run:
        client = _CountingClient(_DryRunPlaceholderClient())
    else:
        client = _CountingClient(create_ai_client(
            provider=AI_PROVIDER,
            anthropic_api_key=ANTHROPIC_API_KEY,
            anthropic_model=ANTHROPIC_MODEL,
            openai_api_key=OPENAI_API_KEY,
            openai_model=OPENAI_MODEL,
            openai_base_url=OPENAI_BASE_URL,
        ))

    # L3:真实 run 默认开裁判;身份带 rubric/judge 维度(换裁判 = 新 run)。
    # 裁判调用也过 _CountingClient(成本口径:api_calls 之外单列 judge_calls,
    # UI 与 meta 都要能如实反映"开裁判时成本≈翻倍")。
    # skip_judge 是唯一真值源:显式跳过时注入的 judge_client 也置 None,
    # 不允许参数注入绕过布尔标志(否则 meta 谎报 judge_enabled 且照烧钱)
    judge_enabled = (not dry_run) and (not skip_judge)
    if not judge_enabled:
        judge_client = None
    elif judge_client is None:
        judge_client = create_judge_client()
    judge_counter: _CountingClient | None = None
    if judge_client is not None:
        judge_counter = _CountingClient(judge_client)
        judge_client = judge_counter
    # 身份的 prompt_versions 维用 selected(子集 run 与全量 run 身份不同,
    # diff 的 identity_diff 会显式提示"对比跨了覆盖范围差异",不靠 skipped 兜底)
    if judge_client is not None:
        identity = build_run_identity(
            client.provider, client.model,
            modules=selected, cases_hash=CASES_HASH,
            rubric_version=RUBRIC_VERSION, judge_model=judge_client.model,
        )
    else:
        identity = build_run_identity(
            client.provider, client.model,
            modules=selected, cases_hash=CASES_HASH,
        )
    run_id = run_id or make_run_id(identity)
    run_dir = runs_dir / run_id
    if (run_dir / "results.jsonl").exists():
        # 复用 run 目录会被 "w" 模式静默截断旧结果——显式拒绝
        raise RuntimeError(
            f"run 目录已存在 results.jsonl: {run_dir}"
            f"(复用会截断旧结果;请删除该目录或让它用新 run_id)")
    run_dir.mkdir(parents=True, exist_ok=True)

    use_cache = (not dry_run) and (not no_cache)
    started_at = datetime.now(timezone.utc)
    cases = CASES[:case_limit] if case_limit else CASES

    if progress_cb is not None:
        # 首帧回调:让轮询方(server UI)拿到真实 run_id,而不是一直 pending
        progress_cb(case_id=None, done=0,
                    total=len(cases) * len(selected), run_id=run_id)

    engine = BaziEngine(now=_FIXED_NOW)
    results_path = run_dir / "results.jsonl"
    verdict_counts = {"pass": 0, "warn": 0, "fail": 0, "error": 0}
    cache_hits = 0

    with open(results_path, "w", encoding="utf-8") as results_file:
        for idx, case in enumerate(cases):
            case_id = f"case_{idx:02d}"
            logger.info(
                "[%s] %s %s", case_id, case["category"],
                case.get("season_note", case.get("pattern_hint", "")),
            )
            entries = await run_chain_for_case(
                case=case, case_id=case_id, engine=engine,
                ai_client=client, case_dir=run_dir / case_id,
                dry_run=dry_run, selected_modules=selected,
                use_cache=use_cache, runs_dir=runs_dir,
                judge_client=judge_client,
            )
            for entry in entries:
                results_file.write(
                    json.dumps(entry, ensure_ascii=False) + "\n")
                verdict_counts[entry["verdict"]] += 1
                if entry.get("cached"):
                    cache_hits += 1
            results_file.flush()
            if progress_cb is not None:
                # S06 server 进度轮询:每盘完成回调一次(盘粒度足够)
                progress_cb(
                    case_id=case_id,
                    done=sum(verdict_counts.values()),
                    total=len(cases) * len(selected),
                )

    finished_at = datetime.now(timezone.utc)
    total = sum(verdict_counts.values())
    meta = {
        "run_id": run_id,
        "identity": identity,
        "dry_run": dry_run,
        "modules": selected,
        "case_count": len(cases),
        "judge_enabled": judge_client is not None,
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "api_calls": client.calls,
        "judge_calls": judge_counter.calls if judge_counter else 0,
        "cache_hits": cache_hits,
        "elapsed_ms": round(
            (finished_at - started_at).total_seconds() * 1000, 1),
        "counts": {"total": total, **verdict_counts},
    }
    (run_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    summary: dict[str, Any] = {
        "run_id": run_id, "run_dir": run_dir, "dry_run": dry_run,
        "identity": identity,
        "total": total, **verdict_counts,
        "api_calls": client.calls, "cache_hits": cache_hits,
        "judge_calls": meta["judge_calls"],
    }

    # 与基线 diff(只在真实 run 后;dry-run 无判据,diff 无意义)
    if not dry_run:
        try:
            baseline = read_baseline(runs_dir)
        except RuntimeError as e:
            summary["diff_error"] = str(e)
            return summary
        if baseline is None:
            summary["baseline"] = None
        else:
            summary["baseline"] = baseline
            diff = diff_runs(baseline, run_id, runs_dir)
            summary["diff"] = {
                "regressed": diff.regressed,
                "fixed": diff.fixed,
                "still_failing": diff.still_failing,
                "unchanged": diff.unchanged_count,
                "skipped": diff.skipped,
                "new": diff.new,
                "identity_diff": diff.identity_diff,
            }
    return summary


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    parser = argparse.ArgumentParser(
        prog="evalkit.runner",
        description="evalkit:prompt 回归评测机(v1 链式 M0-M7)",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="不调 AI,只验证排盘 + chart 构建 + prompt 渲染 + 链式流转",
    )
    parser.add_argument(
        "--case-limit", type=int, default=None,
        help="只跑前 N 盘(默认全部 20)",
    )
    parser.add_argument(
        "--modules", type=str, default=None,
        help="逗号分隔的模块列表(如 m0_structure,m1_talent);"
             "跳过的上游模块会显式报错",
    )
    parser.add_argument(
        "--output-dir", type=str, default=None,
        help="run 输出目录(默认 evalkit/runs/<run_id>)",
    )
    parser.add_argument(
        "--no-cache", action="store_true",
        help="绕过响应缓存强制全量调 API(换模型/验证温度抖动时用)",
    )
    parser.add_argument(
        "--skip-judge", action="store_true",
        help="跳过 L3 裁判(真实 run 默认开裁判;需 JUDGE_* 或 AI_* env)",
    )
    args = parser.parse_args()

    modules_list: list[str] | None = None
    if args.modules:
        modules_list = [m.strip() for m in args.modules.split(",") if m.strip()]
    try:
        # 提前校验(--modules 缺上游是 CLI 错误,退出码 2)
        resolve_selected_modules(modules_list)
    except ValueError as e:
        print(f"ERROR: {e}")
        sys.exit(2)

    if args.output_dir:
        output_dir = Path(args.output_dir)
        run_id = output_dir.name
        runs_dir = output_dir.parent
    else:
        run_id, runs_dir = None, None

    try:
        summary = asyncio.run(execute_run(
            dry_run=args.dry_run,
            case_limit=args.case_limit,
            modules=modules_list,
            run_id=run_id,
            runs_dir=runs_dir,
            no_cache=args.no_cache,
            skip_judge=args.skip_judge,
        ))
    except Exception as e:
        # CLI 自身错误(缺 key / 模块校验等)统一退出码 2
        print(f"ERROR: {type(e).__name__}: {e}")
        sys.exit(2)

    print("=" * 64)
    print(f"run: {summary['run_id']}")
    print(f"模式: {'dry-run(不调 AI)' if summary['dry_run'] else 'real API'}")
    print(f"条目: {summary['total']}(pass={summary['pass']} "
          f"warn={summary['warn']} fail={summary['fail']} "
          f"error={summary['error']})")
    print(f"API 调用: {summary['api_calls']}"
          + (f"(缓存命中 {summary['cache_hits']})"
             + (f",裁判 {summary['judge_calls']} 次"
                if summary["judge_calls"] else "")
             if not summary["dry_run"] else ""))
    print("=" * 64)

    if "diff_error" in summary:
        print(f"ERROR(diff): {summary['diff_error']}")
        sys.exit(2)

    diff = summary.get("diff")
    if summary.get("baseline") is None and not summary["dry_run"]:
        print("基线: 未设置(首个 run 可用 python -m evalkit.store "
              "--set-baseline <run_id> 设为基线)")
    elif diff is not None:
        if diff["identity_diff"]:
            print("⚠️ 与基线的 run 身份有差异(退化可能是环境差异而非模板问题):")
            for dim, (b, c) in diff["identity_diff"].items():
                print(f"  {dim}: {b} → {c}")
        print(f"vs 基线 {summary['baseline']}: regressed={len(diff['regressed'])} "
              f"fixed={len(diff['fixed'])} still_failing={len(diff['still_failing'])} "
              f"unchanged={diff['unchanged']}")
        for case_id, module in diff["regressed"]:
            print(f"  REGRESSED  {case_id} / {module}")

    if summary["fail"] == 0 and summary["error"] == 0 and (
            diff is None or not diff["regressed"]):
        print(f"结果: PASS({summary['pass']}/{summary['total']})")
        sys.exit(0)
    else:
        print(f"结果: FAIL(fail={summary['fail']} error={summary['error']}"
              + (f" regressed={len(diff['regressed'])}" if diff else "") + ")")
        sys.exit(1)


if __name__ == "__main__":
    main()
