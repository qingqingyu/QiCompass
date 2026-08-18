#!/usr/bin/env python3
"""evalkit runner:编排 排盘 → v1 链式生成(M0-M7)→ 判据 → 落盘。

提炼自 spikes/prompt_validation/run_v1_chain_spike.py(async 用法正确的那条线;
老 run_spike.py 的同步调用 async bug 见其 docstring 标注)。判据层:
L1 确定性(S02)/ L2 接地(S03)/ L3 裁判(S05)在各自 slice 接线。

用法:
    cd backend
    # dry-run(不调 AI,验证排盘 + chart 构建 + prompt 渲染 + 链式注入)
    python -m evalkit.runner --dry-run

    # real API(需 AI key;--case-limit 1 = 1 盘 × 8 模块 = 8 次调用)
    set -a; source .env; set +a
    python -m evalkit.runner --case-limit 1

依赖图(与 app/ai/prompts.py REQUIRED_FIELDS 对齐;上游输出写回 chain_ctx):
    M0 → [structure_fingerprint, main_axis, core_loop]
    M1 (M0) → [innate, defensive, one_leverage]
    M2 (M0 + M1) → [threshold, switch_actions]
    M3 (M0) → [ideal_life_structure, environment_checklist]
    M4 (M0 + 用户输入)
    M5 (M0 + M1 + M3 + 用户输入)
    M6 (M0 + M1 + M2) → [leverage]
    M7 (M1 + M2 + M3 + M6,不传 chart)
    M4/M5 的输出不写回 chain_ctx(无下游)。
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
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
from app.ai.prompts import PROMPT_VERSIONS, render_prompt
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
from .checks.deterministic import validate_v1_module_output
from .llm_json import parse_llm_json

logger = logging.getLogger("evalkit.runner")

RUNS_DIR = Path(__file__).parent / "runs"

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


# ---------- run 身份(Q5 六维) ----------

def build_run_identity(
    provider: str, model: str, *,
    rubric_version: int = 0, judge_model: str = "",
) -> dict[str, Any]:
    """六维身份:任一维变 = 新 run。S05 接裁判后 rubric/judge 为真实值。"""
    return {
        "prompt_versions": {m: PROMPT_VERSIONS[m] for m in V1_MODULES},
        "provider": provider,
        "model": model,
        "rubric_version": rubric_version,
        "judge_model": judge_model,
        "cases_hash": CASES_HASH,
    }


def make_run_id(identity: dict[str, Any]) -> str:
    """时间戳(可排序)+ 身份摘要短 hash(同身份可辨认)。"""
    canonical = json.dumps(
        identity, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
    )
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:6]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M")
    return f"{stamp}-{digest}"


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
    ai_client: AIClient,
    dry_run: bool,
) -> tuple[str, dict[str, Any] | None, list[str]]:
    """单模块调用:render_prompt → LLM → parse → validate。

    Returns:
        (rendered_prompt, parsed_json, validation_failures)
        dry_run 模式下 parsed_json=None,failures=[]
    """
    rendered = render_prompt(module, context)
    if dry_run:
        return rendered, None, []

    temperature = resolve_temperature(module)
    response = await ai_client.interpret(rendered, temperature=temperature)

    try:
        parsed = parse_llm_json(response)
    except ValueError as e:
        return rendered, None, [f"JSON 解析失败: {e}"]

    failures = validate_v1_module_output(module, parsed)
    return rendered, parsed, failures


async def _run_one_module(
    *,
    module: str,
    context: dict[str, Any],
    case_dir: Path,
    ai_client: AIClient,
    dry_run: bool,
) -> dict[str, Any]:
    """跑单个模块,落盘 prompt + response,返回 status dict。

    status: {ok, elapsed_ms, failures(schema/禁词类质量问题),
              error(异常类,与 fail 区分), parsed}
    """
    module_dir = case_dir / module
    module_dir.mkdir(parents=True, exist_ok=True)

    start = time.perf_counter()
    rendered: str | None = None
    parsed: dict[str, Any] | None = None
    failures: list[str] = []
    error: str | None = None
    try:
        rendered, parsed, failures = await _call_module(
            module=module, context=context,
            ai_client=ai_client, dry_run=dry_run,
        )
    except Exception as e:
        logger.error("[%s] %s 异常", case_dir.name, module, exc_info=True)
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
             "elapsed_ms": 0.0, "ok": False, "l1": None,
             "error": f"排盘失败: {type(e).__name__}: {e}"}
            for m in selected_modules
        ]

    # 链式上下文(逐步累积上游输出)
    chain_ctx: dict[str, Any] = {"chart": chart_json}
    if dry_run:
        _apply_dry_run_placeholders(chain_ctx)

    entries: list[dict[str, Any]] = []
    chain_broken = False

    for module in V1_MODULES:
        if module not in selected_modules:
            continue

        if chain_broken:
            entries.append({
                **common, "module": module,
                "prompt_version": PROMPT_VERSIONS[module],
                "elapsed_ms": 0.0, "ok": False, "l1": None,
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
        )
        # L1 接线:dry-run 无输出可判;异常(error)无输出可判 → l1 均为 null
        l1 = None
        if not dry_run and status["error"] is None:
            l1 = {"passed": not status["failures"],
                  "failures": status["failures"]}
        entries.append({
            **common, "module": module,
            "prompt_version": PROMPT_VERSIONS[module],
            "elapsed_ms": status["elapsed_ms"],
            "l1": l1,
            "ok": status["ok"],
            "error": status["error"],
        })

        parsed = status["parsed"]
        if status["ok"] and not dry_run and parsed is not None:
            _write_back_chain_ctx(chain_ctx, module, parsed)
        elif module == "m0_structure" and not status["ok"]:
            chain_broken = True

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
) -> dict[str, Any]:
    """跑一次完整评测,落盘 runs/<run_id>/。

    Args:
        dry_run: 不调 AI(排盘 + 渲染 + 链式注入验证)
        case_limit: 只跑前 N 盘
        modules: 选中模块(None=全部 8 个;上游必须齐全)
        run_id / runs_dir: 测试注入(默认按身份生成 / evalkit/runs/)
        ai_client: 测试注入的 client(None=按 env 构造 / dry-run 占位)

    Returns:
        summary(run_id / 总数 / ok / fail / error 计数)
    """
    runs_dir = runs_dir if runs_dir is not None else RUNS_DIR
    selected = resolve_selected_modules(modules)

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

    identity = build_run_identity(client.provider, client.model)
    run_id = run_id or make_run_id(identity)
    run_dir = runs_dir / run_id
    run_dir.mkdir(parents=True, exist_ok=True)

    started_at = datetime.now(timezone.utc)
    cases = CASES[:case_limit] if case_limit else CASES

    engine = BaziEngine(now=_FIXED_NOW)
    results_path = run_dir / "results.jsonl"
    total = ok_count = fail_count = error_count = 0

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
            )
            for entry in entries:
                results_file.write(
                    json.dumps(entry, ensure_ascii=False) + "\n")
                total += 1
                if entry["error"] is not None:
                    error_count += 1
                elif entry["ok"]:
                    ok_count += 1
                else:
                    fail_count += 1
            results_file.flush()

    finished_at = datetime.now(timezone.utc)
    meta = {
        "run_id": run_id,
        "identity": identity,
        "dry_run": dry_run,
        "modules": selected,
        "case_count": len(cases),
        "started_at": started_at.isoformat(),
        "finished_at": finished_at.isoformat(),
        "api_calls": client.calls,
        "elapsed_ms": round(
            (finished_at - started_at).total_seconds() * 1000, 1),
        "counts": {"total": total, "ok": ok_count,
                   "fail": fail_count, "error": error_count},
    }
    (run_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")

    return {
        "run_id": run_id, "run_dir": run_dir, "dry_run": dry_run,
        "total": total, "ok": ok_count,
        "fail": fail_count, "error": error_count,
        "api_calls": client.calls,
    }


def _log_case_summary(case_id: str, entries: list[dict[str, Any]]) -> None:
    ok = sum(1 for e in entries if e["ok"])
    logger.info("[%s] modules ok: %d/%d", case_id, ok, len(entries))


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

    summary = asyncio.run(execute_run(
        dry_run=args.dry_run,
        case_limit=args.case_limit,
        modules=modules_list,
        run_id=run_id,
        runs_dir=runs_dir,
    ))

    print("=" * 64)
    print(f"run: {summary['run_id']}")
    print(f"模式: {'dry-run(不调 AI)' if summary['dry_run'] else 'real API'}")
    print(f"条目: {summary['total']}(ok={summary['ok']} "
          f"fail={summary['fail']} error={summary['error']})")
    print(f"API 调用: {summary['api_calls']}")
    print("=" * 64)
    if summary["fail"] == 0 and summary["error"] == 0:
        print(f"结果: PASS({summary['ok']}/{summary['total']})")
        sys.exit(0)
    else:
        print(f"结果: FAIL(fail={summary['fail']} "
              f"error={summary['error']})")
        sys.exit(1)


if __name__ == "__main__":
    main()
