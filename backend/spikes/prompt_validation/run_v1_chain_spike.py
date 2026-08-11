#!/usr/bin/env python3
"""v1 prompt 系统链式调用 Spike(Stage 6)。

跑 M0 → M1-M7 链式调用,验证 v1 prompt 系统在 20 盘 × 8 模块上的端到端表现。

职责:
1. 排盘 + build_v1_chart → chart JSON
2. M0 调用 → 解析 JSON → 提取 structure_fingerprint / main_axis / core_loop
3. M1-M7 按依赖图调用(每个模块注入上游模块的输出)
4. 每步落盘:chart_json / rendered_prompt / llm_response / parsed_json
5. schema 校验:必填字段 + evidence 非空 + 禁词扫描
6. dry-run 模式:不调 AI,只验证 chart 构建 + prompt 渲染 + 上下文流转

用法:
    cd backend
    # dry-run(不调 AI,验证 chart + prompt + 链式注入逻辑)
    python -m spikes.prompt_validation.run_v1_chain_spike --dry-run

    # real API(需要 AI key,跑 1 盘 × 全链路 = 8 次 LLM 调用)
    AI_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-... \\
      python -m spikes.prompt_validation.run_v1_chain_spike --case-limit 1

    # 完整 20 盘 × 8 模块 = 160 次 LLM 调用(成本高,慎用)
    AI_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-... \\
      python -m spikes.prompt_validation.run_v1_chain_spike

依赖图:
    M0 → [structure_fingerprint, main_axis, core_loop, structure_type]
    M1 (needs M0) → [innate, trained, defensive, one_leverage]
    M2 (needs M0 + M1.innate + M1.defensive) → [threshold, switch_actions]
    M3 (needs M0) → [ideal_life_structure, environment_checklist]
    M4 (needs M0 + age + current_concern) → [health outputs]
    M5 (needs M0 + M1.innate + M3.ideal_life_structure + assets + preference) → [wealth outputs]
    M6 (needs M0 + M1.innate + M1.defensive + M2.threshold + M0.core_loop) → [leverage]
    M7 (needs M1.one_leverage + M2.switch_actions + M3.environment_checklist + M6.leverage) → [manual outputs]
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# 确保从 backend/ 目录运行时能找到 app 包
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.ai.client import AIClient, create_ai_client
from app.ai.forbidden_words import scan as scan_forbidden_words
from app.ai.prompts import render_prompt
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

from .fixtures import SPIKE_CASES, parse_birth

logger = logging.getLogger("spike.v1_chain")


# ---------- M4/M5 用户输入(Stage 6 spike 固定值,生产由 iOS Stage 8 收集) ----------

_M4_USER_INPUT: dict[str, Any] = {
    "age": 32,
    "current_concern": "睡眠质量差,工作日长期疲劳",
}

_M5_USER_INPUT: dict[str, Any] = {
    "assets_summary": "中等收入,有些积蓄,无房产",
    "preference": "平衡(中等风险)",
}


# dry-run 链式字段 placeholder(模拟 LLM 上游模块输出,让 M1-M7 prompt 能渲染)
# real API 模式下不用这些,用真实 LLM 输出
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
    """dry-run 模式:把所有链式字段填 placeholder(模拟上游 LLM 输出)。

    让 M1-M7 的 prompt 渲染能跑通,验证模板 + 占位符完整性。
    real API 模式不调本函数,用真实 LLM 输出。
    """
    for key, value in _DRY_RUN_PLACEHOLDERS.items():
        chain_ctx.setdefault(key, value)


# ---------- LLM JSON 输出解析 ----------

def parse_llm_json(text: str) -> dict[str, Any]:
    """从 LLM 文本响应中解析 JSON。

    LLM 输出即使 prompt 要求"不加 markdown 代码块围栏",偶尔还是会带 ```json ... ```
    或前后空白。本函数:
    1. 去 markdown fence(若存在)
    2. json.loads(text)
    3. 校验顶层是 dict

    Raises:
        ValueError: JSON 解析失败 / 顶层非 dict
    """
    cleaned = text.strip()
    # 去 markdown code fence(```json ... ``` 或 ``` ... ```)
    fence_match = re.match(r"^```(?:json)?\s*(.*?)\s*```$", cleaned, re.DOTALL)
    if fence_match:
        cleaned = fence_match.group(1).strip()
    # 截第一个 { 到最后一个 }(防 LLM 加前后语)
    first_brace = cleaned.find("{")
    last_brace = cleaned.rfind("}")
    if first_brace != -1 and last_brace != -1 and last_brace > first_brace:
        cleaned = cleaned[first_brace:last_brace + 1]
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError as e:
        raise ValueError(
            f"LLM 输出非合法 JSON: {e}(text 头 200 字: {cleaned[:200]!r})"
        ) from e
    if not isinstance(parsed, dict):
        raise ValueError(
            f"LLM 输出 JSON 顶层非 object(type={type(parsed).__name__})"
        )
    return parsed


# ---------- v1 模块 schema 校验 ----------

# 每个 module 必填的顶层字段(对齐 prompts.py M0-M7 模板的 JSON 输出 schema)
_MODULE_REQUIRED_FIELDS: dict[str, tuple[str, ...]] = {
    "m0_structure": (
        "main_axis", "core_loop", "structure_type",
        "capability_source", "structure_fingerprint",
    ),
    "m1_talent": ("innate", "trained", "defensive", "one_leverage"),
    "m2_high_low": (
        "high_config", "low_config", "threshold",
        "early_warnings", "switch_actions",
    ),
    "m3_system": (
        "operating_mode", "failure_environments",
        "ideal_life_structure", "stability_vs_volatility",
        "environment_checklist",
    ),
    "m4_health": (
        "battery_type", "imbalance_risks", "recovery_levers",
        "reset_7day", "weekly_maintenance", "medical_note",
    ),
    "m5_wealth": (
        "income_forms", "leaks", "strategies",
        "asset_ideas", "disclaimer",
    ),
    "m6_dynamics": (
        "energy_path", "leverage", "vulnerability", "upgrade_path",
    ),
    "m7_manual": (
        "true_leverage", "use_cases", "next_90_days",
        "falsification_signals",
    ),
}

# v1 §4 扩展禁词(生产 app/ai/forbidden_words.py 当前只含 ABSOLUTE_CONCLUSIONS,
# 不含寿元/绝症/必赚/稳赚/包治/血光/克夫/大凶/劫难/破财 等)。
# spike 用扩展列表做更严的校验,识别"v1 §4 禁止但生产未禁"的输出。
# 生产是否同步扩展由后续决策(暂不扩,避免影响老 module)。
_V1_EXTENDED_FORBIDDEN_WORDS: tuple[str, ...] = (
    "注定", "必然", "命中该", "逃不掉", "破财", "血光",
    "克夫", "大凶", "劫难", "寿元", "绝症", "必赚", "稳赚", "包治",
)


def validate_v1_module_output(module: str, parsed: dict[str, Any]) -> list[str]:
    """校验 LLM 输出 JSON 是否符合 v1 §3 schema。

    Returns:
        failures 列表(空 = 全过)
    """
    failures: list[str] = []

    # 1. 必填顶层字段
    required = _MODULE_REQUIRED_FIELDS.get(module, ())
    missing = [f for f in required if f not in parsed]
    if missing:
        failures.append(f"缺字段:{missing}")

    # 2. structure_fingerprint 长度(M0 必填,≤ 40 字)
    if module == "m0_structure":
        fp = parsed.get("structure_fingerprint", "")
        if not isinstance(fp, str) or not fp:
            failures.append("structure_fingerprint 为空或非 str")
        elif len(fp) > 40:
            failures.append(
                f"structure_fingerprint 长度 {len(fp)} 超 40 字: {fp!r}"
            )

    # 3. 数组字段长度约束
    array_constraints = {
        "m2_high_low": [("early_warnings", 3), ("switch_actions", 3)],
        "m3_system": [("environment_checklist", 5)],
        "m4_health": [
            ("imbalance_risks", 3), ("recovery_levers", 3),
            ("reset_7day", 7),
        ],
        "m5_wealth": [("income_forms", 6), ("asset_ideas", 3)],
        "m7_manual": [("use_cases", 3), ("falsification_signals", 2)],
    }
    for field, expected_len in array_constraints.get(module, []):
        value = parsed.get(field)
        if not isinstance(value, list):
            failures.append(
                f"{field} 非 list(类型={type(value).__name__})"
            )
        elif len(value) != expected_len:
            failures.append(
                f"{field} 长度 {len(value)} != 期望 {expected_len}"
            )

    # 4. 禁词扫描(双层)
    # 4a. 生产 ABSOLUTE_CONCLUSIONS(走 app.ai.forbidden_words.scan)
    text_blob = json.dumps(parsed, ensure_ascii=False)
    production_hits = scan_forbidden_words(text_blob)
    if production_hits:
        failures.append(f"生产禁词命中:{production_hits}")
    # 4b. v1 §4 扩展禁词(spike 本地列表)
    extended_hits = [w for w in _V1_EXTENDED_FORBIDDEN_WORDS if w in text_blob]
    if extended_hits:
        failures.append(f"v1 §4 扩展禁词命中:{extended_hits}")

    return failures


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


async def run_chain_for_case(
    *,
    case: dict[str, Any],
    case_id: str,
    engine: BaziEngine,
    ai_client: AIClient,
    output_dir: Path,
    dry_run: bool,
) -> dict[str, Any]:
    """跑一盘 × M0-M7 全链路。

    Returns:
        case_summary dict(写入 results.jsonl)
    """
    birth = parse_birth(case["birth_datetime"])
    case_dir = output_dir / case_id
    case_dir.mkdir(exist_ok=True)

    summary: dict[str, Any] = {
        "case_id": case_id,
        "category": case["category"],
        "birth": case["birth_datetime"],
        "gender": case["gender"],
        "provider": ai_client.provider,
        "model": ai_client.model,
        "dry_run": dry_run,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "modules": {},
    }

    try:
        engine_result = engine.calculate(
            birth=birth,
            gender=case["gender"],
            longitude=case["longitude"],
            zi_hour_rule=case["zi_hour_rule"],
        )
        chart_json = _build_chart_json(engine_result)
        (case_dir / "chart.json").write_text(chart_json, encoding="utf-8")
        summary["content_hash"] = engine_result["content_hash"]
        summary["day_master_strength"] = engine_result["day_master_strength"]
    except Exception as e:
        logger.error("[%s] 排盘失败", case_id, exc_info=True)
        summary["error"] = f"排盘失败: {type(e).__name__}: {e}"
        return summary

    # 链式调用上下文(逐步累积上游输出)
    chain_ctx: dict[str, Any] = {"chart": chart_json}
    module_statuses: dict[str, Any] = {}

    # dry-run 模式:把所有链式字段填 placeholder,让 M1-M7 渲染能跑通
    if dry_run:
        _apply_dry_run_placeholders(chain_ctx)

    # M0(基础,无 parent_fingerprint)
    m0_status = await _run_one_module(
        module="m0_structure",
        context=dict(chain_ctx),
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m0_structure"] = m0_status
    if not m0_status.get("ok"):
        summary["modules"] = module_statuses
        summary["error"] = f"M0 失败,链路中断: {m0_status.get('errors')}"
        return summary
    if not dry_run and m0_status.get("parsed"):
        parsed = m0_status["parsed"]
        chain_ctx["structure_fingerprint"] = parsed.get("structure_fingerprint", "")
        chain_ctx["main_axis"] = json.dumps(
            parsed.get("main_axis", {}), ensure_ascii=False,
        )
        chain_ctx["core_loop"] = json.dumps(
            parsed.get("core_loop", {}), ensure_ascii=False,
        )

    # M1(needs M0)
    m1_status = await _run_one_module(
        module="m1_talent",
        context=dict(chain_ctx),
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m1_talent"] = m1_status
    if not dry_run and m1_status.get("ok") and m1_status.get("parsed"):
        parsed = m1_status["parsed"]
        chain_ctx["innate"] = json.dumps(
            parsed.get("innate", []), ensure_ascii=False,
        )
        chain_ctx["defensive"] = json.dumps(
            parsed.get("defensive", []), ensure_ascii=False,
        )
        chain_ctx["one_leverage"] = parsed.get("one_leverage", "")

    # M2(needs M0 + M1.innate + M1.defensive)
    m2_status = await _run_one_module(
        module="m2_high_low",
        context=dict(chain_ctx),
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m2_high_low"] = m2_status
    if not dry_run and m2_status.get("ok") and m2_status.get("parsed"):
        chain_ctx["threshold"] = json.dumps(
            m2_status["parsed"].get("threshold", {}), ensure_ascii=False,
        )
        chain_ctx["switch_actions"] = json.dumps(
            m2_status["parsed"].get("switch_actions", []), ensure_ascii=False,
        )

    # M3(needs M0)
    m3_status = await _run_one_module(
        module="m3_system",
        context=dict(chain_ctx),
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m3_system"] = m3_status
    if not dry_run and m3_status.get("ok") and m3_status.get("parsed"):
        chain_ctx["ideal_life_structure"] = json.dumps(
            m3_status["parsed"].get("ideal_life_structure", {}),
            ensure_ascii=False,
        )
        chain_ctx["environment_checklist"] = json.dumps(
            m3_status["parsed"].get("environment_checklist", []),
            ensure_ascii=False,
        )

    # M4(needs M0 + 用户输入)
    m4_context = dict(chain_ctx)
    m4_context["age"] = _M4_USER_INPUT["age"]
    m4_context["current_concern"] = _M4_USER_INPUT["current_concern"]
    m4_status = await _run_one_module(
        module="m4_health",
        context=m4_context,
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m4_health"] = m4_status

    # M5(needs M0 + M1.innate + M3.ideal_life_structure + 用户输入)
    m5_context = dict(chain_ctx)
    m5_context["assets_summary"] = _M5_USER_INPUT["assets_summary"]
    m5_context["preference"] = _M5_USER_INPUT["preference"]
    m5_status = await _run_one_module(
        module="m5_wealth",
        context=m5_context,
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m5_wealth"] = m5_status

    # M6(needs M0 + M1.innate + M1.defensive + M2.threshold + M0.core_loop)
    m6_status = await _run_one_module(
        module="m6_dynamics",
        context=dict(chain_ctx),
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m6_dynamics"] = m6_status
    if not dry_run and m6_status.get("ok") and m6_status.get("parsed"):
        chain_ctx["leverage"] = json.dumps(
            m6_status["parsed"].get("leverage", {}), ensure_ascii=False,
        )

    # M7(needs M1.one_leverage + M2.switch_actions + M3.environment_checklist + M6.leverage)
    # M7 模板不含 {chart}(已在 chain_ctx 但 M7 render 不读)
    m7_status = await _run_one_module(
        module="m7_manual",
        context=dict(chain_ctx),
        case_dir=case_dir,
        ai_client=ai_client,
        dry_run=dry_run,
    )
    module_statuses["m7_manual"] = m7_status

    summary["modules"] = module_statuses
    return summary


async def _run_one_module(
    *,
    module: str,
    context: dict[str, Any],
    case_dir: Path,
    ai_client: AIClient,
    dry_run: bool,
) -> dict[str, Any]:
    """跑单个模块,落盘 prompt + response,返回 status dict。"""
    module_dir = case_dir / module
    module_dir.mkdir(exist_ok=True)

    start = time.perf_counter()
    try:
        rendered, parsed, failures = await _call_module(
            module=module, context=context,
            ai_client=ai_client, dry_run=dry_run,
        )
    except Exception as e:
        elapsed = (time.perf_counter() - start) * 1000
        logger.error(
            "[%s] %s 异常", case_dir.name, module, exc_info=True,
        )
        return {
            "ok": False,
            "elapsed_ms": round(elapsed, 1),
            "errors": [f"{type(e).__name__}: {e}"],
        }

    elapsed = (time.perf_counter() - start) * 1000
    (module_dir / "prompt.txt").write_text(rendered, encoding="utf-8")
    if parsed is not None:
        (module_dir / "response.json").write_text(
            json.dumps(parsed, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    return {
        "ok": len(failures) == 0,
        "elapsed_ms": round(elapsed, 1),
        "errors": failures,
        "has_parsed": parsed is not None,
        "parsed": parsed,
    }


# ---------- 主流程 ----------

async def run_spike(
    output_dir: Path,
    *,
    dry_run: bool = False,
    case_limit: int | None = None,
    ai_client: AIClient | None = None,
) -> None:
    """跑完整 spike。

    Args:
        output_dir: 输出目录
        dry_run: True=不调 AI,只验证 chart 构建 + prompt 渲染 + 链式流转
        case_limit: 只跑前 N 盘(None=全部 20)
        ai_client: 注入的 client(None=按当前 env 构造)
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    results_path = output_dir / "results.jsonl"

    fixed_now = datetime(2025, 1, 15, 12, 0, tzinfo=timezone.utc)
    engine = BaziEngine(now=fixed_now)

    if ai_client is not None:
        pass  # 调用方注入(测试 / 自定义 client)
    elif dry_run:
        # dry-run 用 placeholder(不会被调)
        ai_client = _DryRunPlaceholderClient()
    else:
        ai_client = create_ai_client(
            provider=AI_PROVIDER,
            anthropic_api_key=ANTHROPIC_API_KEY,
            anthropic_model=ANTHROPIC_MODEL,
            openai_api_key=OPENAI_API_KEY,
            openai_model=OPENAI_MODEL,
            openai_base_url=OPENAI_BASE_URL,
        )

    cases = SPIKE_CASES[:case_limit] if case_limit else SPIKE_CASES

    with open(results_path, "w", encoding="utf-8") as results_file:
        for idx, case in enumerate(cases):
            case_id = f"case_{idx:02d}"
            logger.info(
                "[%s] %s %s", case_id, case["category"],
                case.get("season_note", case.get("pattern_hint", "")),
            )
            summary = await run_chain_for_case(
                case=case, case_id=case_id,
                engine=engine, ai_client=ai_client,
                output_dir=output_dir, dry_run=dry_run,
            )
            results_file.write(
                json.dumps(summary, ensure_ascii=False) + "\n"
            )
            results_file.flush()
            _log_case_summary(summary)

    logger.info("结果写入: %s", results_path)


class _DryRunPlaceholderClient:
    """dry-run 时占位,不实际被调;provider/model 为占位字符串。

    若被误调(说明编排逻辑漏了 dry_run 分流),显式抛 RuntimeError,
    让 spike 立即崩而不是静默继续。
    """

    provider = "dry-run"
    model = "placeholder"

    async def interpret(self, *args: Any, **kwargs: Any) -> str:
        raise RuntimeError(
            "_DryRunPlaceholderClient 不应被实际调用"
            "(检查 dry_run 分流逻辑)"
        )


def _log_case_summary(summary: dict[str, Any]) -> None:
    """单盘结果日志。"""
    case_id = summary["case_id"]
    if summary.get("error"):
        logger.warning("[%s] ERROR: %s", case_id, summary["error"])
        return
    modules = summary.get("modules", {})
    ok_count = sum(1 for m in modules.values() if m.get("ok"))
    total = len(modules)
    logger.info("[%s] modules ok: %d/%d", case_id, ok_count, total)
    for module, status in modules.items():
        if not status.get("ok"):
            logger.warning(
                "[%s] %s FAILED: %s",
                case_id, module, status.get("errors"),
            )


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    parser = argparse.ArgumentParser(description="v1 prompt 系统链式 spike")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="不调 AI,只验证 chart 构建 + prompt 渲染 + 链式流转",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=None,
        help="输出目录(默认 spikes/prompt_validation/output_v1_chain)",
    )
    parser.add_argument(
        "--case-limit",
        type=int,
        default=None,
        help="只跑前 N 盘(默认全部 20)",
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir) if args.output_dir else (
        Path(__file__).parent / "output_v1_chain"
    )

    import asyncio
    asyncio.run(run_spike(
        output_dir=output_dir,
        dry_run=args.dry_run,
        case_limit=args.case_limit,
    ))


if __name__ == "__main__":
    main()
