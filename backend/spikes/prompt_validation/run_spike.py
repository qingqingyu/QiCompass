#!/usr/bin/env python3
"""Prompt 验证 Spike 驱动脚本(方案 §1.2)。

一次性脚本(不进生产)。职责:
1. 遍历 SPIKE_CASES(20 盘)
2. 调 BaziEngine.calculate() → 组装完整 bazi_deep context
3. 调 render_prompt() 生成完整 prompt
4. 调真实 AI provider API(不 mock)生成解读
5. 每盘落盘:input_context / rendered_prompt / llm_response / metadata
6. special_pattern 硬断言(方案 §1.4)
7. 输出 results.jsonl

用法:
    cd backend
    AI_PROVIDER=anthropic ANTHROPIC_API_KEY=sk-ant-... \
      python -m spikes.prompt_validation.run_spike
    AI_PROVIDER=openai OPENAI_API_KEY=sk-... \
      python -m spikes.prompt_validation.run_spike

    # dry-run(不调 AI,只验证 context 组装 + prompt 渲染)
    python -m spikes.prompt_validation.run_spike --dry-run

    # 指定输出目录
    python -m spikes.prompt_validation.run_spike --output-dir spikes/prompt_validation/output_v1
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# 确保从 backend/ 目录运行时能找到 app 包
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from app.ai.client import AIClient, create_ai_client
from app.ai.prompts import PROMPT_VERSIONS, render_prompt, validate_context
from app.config import (
    AI_PROVIDER,
    ANTHROPIC_API_KEY,
    ANTHROPIC_MODEL,
    OPENAI_API_KEY,
    OPENAI_MODEL,
)
from app.engine.bazi_engine import BaziEngine

from .fixtures import SPIKE_CASES, parse_birth

logger = logging.getLogger("spike.prompt_validation")


# ---------- 元素映射(与 iOS PromptContextBuilder 对齐) ----------

_ELEMENT_ZH = {"wood": "木", "fire": "火", "earth": "土", "metal": "金", "water": "水"}


def _element_to_zh(element: str) -> str:
    """五行英文 → 中文。未知值原样返回(不吞,便于排障)。"""
    return _ELEMENT_ZH.get(element, element)


def _gender_to_zh(gender: str) -> str:
    return "男" if gender == "male" else "女"


# ---------- context 构建(复刻 iOS PromptContextBuilder.build) ----------

def build_bazi_deep_context(
    engine_result: dict[str, Any],
    birth: datetime,
    gender: str,
    longitude: float,
) -> dict[str, Any]:
    """从 BaziEngine.calculate() 输出构建 bazi_deep prompt context。

    必须覆盖后端 REQUIRED_FIELDS["bazi_deep"] 全部 40 个字段。
    与 iOS PromptContextBuilder.build() 逻辑一致。
    """
    p = engine_result["pillars"]
    true_solar_time: datetime = engine_result["true_solar_time"]
    true_solar_str = true_solar_time.strftime("%Y-%m-%d %H:%M")

    # 神煞列表格式:name(position) 、 name(position)
    shensha_items = engine_result["shensha"]
    if shensha_items:
        shensha_list = "、".join(
            f"{s['name']}({s['position']})" for s in shensha_items
        )
    else:
        shensha_list = "无"

    # 五行统计
    eb = engine_result["element_balance"]
    element_balance = f"木:{eb['wood']} 火:{eb['fire']} 土:{eb['earth']} 金:{eb['metal']} 水:{eb['water']}"

    # 喜忌
    favorable = engine_result["favorable_elements"]
    unfavorable = engine_result["unfavorable_elements"]
    favorable_str = "、".join(_element_to_zh(e) for e in favorable) if favorable else ""
    unfavorable_str = "、".join(_element_to_zh(e) for e in unfavorable) if unfavorable else ""

    # 当前柱
    current_luck = engine_result.get("current_luck_pillar")
    current_luck_str = current_luck["gan_zhi"] if current_luck else "未排"
    current_year_str = engine_result.get("current_year_pillar") or "未排"

    return {
        "gender": _gender_to_zh(gender),
        "city": f"经度 {longitude}",
        "true_solar_time": true_solar_str,
        # 年柱
        "year_gan": p["year"]["gan"],
        "year_zhi": p["year"]["zhi"],
        "year_gan_element": _element_to_zh(p["year"]["gan_element"]),
        "year_zhi_element": _element_to_zh(p["year"]["zhi_element"]),
        "year_shishen_gan": p["year"]["shishen_gan"],
        "year_hide_gan": ", ".join(p["year"]["hide_gan"]),
        # 月柱
        "month_gan": p["month"]["gan"],
        "month_zhi": p["month"]["zhi"],
        "month_gan_element": _element_to_zh(p["month"]["gan_element"]),
        "month_zhi_element": _element_to_zh(p["month"]["zhi_element"]),
        "month_shishen_gan": p["month"]["shishen_gan"],
        "month_hide_gan": ", ".join(p["month"]["hide_gan"]),
        # 日柱
        "day_gan": p["day"]["gan"],
        "day_zhi": p["day"]["zhi"],
        "day_gan_element": _element_to_zh(p["day"]["gan_element"]),
        "day_shishen_zhi": ", ".join(p["day"]["shishen_zhi"]),
        "day_hide_gan": ", ".join(p["day"]["hide_gan"]),
        # 时柱
        "hour_gan": p["hour"]["gan"],
        "hour_zhi": p["hour"]["zhi"],
        "hour_gan_element": _element_to_zh(p["hour"]["gan_element"]),
        "hour_zhi_element": _element_to_zh(p["hour"]["zhi_element"]),
        "hour_shishen_gan": p["hour"]["shishen_gan"],
        "hour_hide_gan": ", ".join(p["hour"]["hide_gan"]),
        # 纳音
        "year_nayin": p["year"]["nayin"],
        "month_nayin": p["month"]["nayin"],
        "day_nayin": p["day"]["nayin"],
        "hour_nayin": p["hour"]["nayin"],
        # 命宫
        "ming_gong": engine_result["ming_gong"]["gan_zhi"],
        "ming_gong_nayin": engine_result["ming_gong"]["nayin"],
        # 神煞 / 五行
        "shensha_list": shensha_list,
        "element_balance": element_balance,
        # 喜忌
        "day_master_strength": engine_result["day_master_strength"],
        "favorable_elements": favorable_str,
        "unfavorable_elements": unfavorable_str,
        "tiaoshou_applied": str(engine_result["tiaoshou_applied"]),
        # 当前柱
        "current_luck_pillar": current_luck_str,
        "current_year_pillar": current_year_str,
    }


# ---------- special_pattern 硬断言(方案 §1.4) ----------

def assert_special_pattern_constraints(
    engine_result: dict[str, Any],
    rendered_prompt: str,
    case: dict[str, Any],
) -> list[str]:
    """对 special_pattern 样本逐条硬断言。返回失败列表(空=全过)。"""
    failures: list[str] = []

    # 1. 后端返回 day_master_strength == "special_pattern"
    if engine_result["day_master_strength"] != "special_pattern":
        failures.append(
            f"day_master_strength 期望 special_pattern,实际 {engine_result['day_master_strength']}"
        )

    # 2. favorable / unfavorable 为空
    if engine_result["favorable_elements"]:
        failures.append(
            f"favorable_elements 期望空,实际 {engine_result['favorable_elements']}"
        )
    if engine_result["unfavorable_elements"]:
        failures.append(
            f"unfavorable_elements 期望空,实际 {engine_result['unfavorable_elements']}"
        )

    # 3. 渲染后的 prompt 包含从格/专旺诚实降级约束
    if "从格" not in rendered_prompt and "专旺" not in rendered_prompt:
        failures.append("渲染 prompt 缺少从格/专旺诚实降级约束段")

    if "未下硬性喜忌结论" not in rendered_prompt:
        failures.append("渲染 prompt 缺少'未下硬性喜忌结论'诚实话术")

    return failures


# ---------- 主流程 ----------

def run_spike(
    output_dir: Path,
    dry_run: bool = False,
    ai_client: AIClient | None = None,
) -> None:
    """跑完整 20 盘 spike。

    Args:
        output_dir: 输出目录
        dry_run: True=不调 AI,只验证 context + prompt 渲染
        ai_client: 注入的 client(测试用);None=按当前 env 构造
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    results_path = output_dir / "results.jsonl"

    # 使用固定 now 确保确定性(当前流年/流日不随真实时间漂移)
    fixed_now = datetime(2025, 1, 15, 12, 0, tzinfo=timezone.utc)
    engine = BaziEngine(now=fixed_now)

    if ai_client is None:
        ai_client = create_ai_client(
            provider=AI_PROVIDER,
            anthropic_api_key=ANTHROPIC_API_KEY,
            anthropic_model=ANTHROPIC_MODEL,
            openai_api_key=OPENAI_API_KEY,
            openai_model=OPENAI_MODEL,
        )

    prompt_version = PROMPT_VERSIONS["bazi_deep"]
    all_results: list[dict[str, Any]] = []

    with open(results_path, "w", encoding="utf-8") as results_file:
        for idx, case in enumerate(SPIKE_CASES):
            case_id = f"case_{idx:02d}"
            logger.info("[%s] %s %s", case_id, case["category"], case.get("season_note", case.get("pattern_hint", "")))

            birth = parse_birth(case["birth_datetime"])
            result_entry: dict[str, Any] = {
                "case_id": case_id,
                "category": case["category"],
                "birth": case["birth_datetime"],
                "gender": case["gender"],
                "expected_strength": case["expected_strength"],
                "prompt_version": prompt_version,
                "provider": ai_client.provider,
                "model": ai_client.model,
                "timestamp": datetime.now(timezone.utc).isoformat(),
            }

            try:
                # 1. 排盘
                calc_start = time.perf_counter()
                engine_result = engine.calculate(
                    birth=birth,
                    gender=case["gender"],
                    longitude=case["longitude"],
                    zi_hour_rule=case["zi_hour_rule"],
                )
                calc_ms = (time.perf_counter() - calc_start) * 1000
                result_entry["calc_duration_ms"] = round(calc_ms, 1)
                result_entry["content_hash"] = engine_result["content_hash"]
                result_entry["day_master_strength"] = engine_result["day_master_strength"]
                result_entry["pattern_hint"] = engine_result.get("pattern_hint")

                # 2. 构建 context + 渲染 prompt
                context = build_bazi_deep_context(
                    engine_result, birth, case["gender"], case["longitude"]
                )
                validate_context("bazi_deep", context)
                rendered_prompt = render_prompt("bazi_deep", context)

                # 3. special_pattern 硬断言
                if case["category"] == "special_pattern":
                    sp_failures = assert_special_pattern_constraints(
                        engine_result, rendered_prompt, case
                    )
                    result_entry["special_pattern_assertions"] = {
                        "passed": len(sp_failures) == 0,
                        "failures": sp_failures,
                    }
                    if sp_failures:
                        logger.warning("[%s] special_pattern 断言失败: %s", case_id, sp_failures)

                # 4. 调用当前 provider(真实 API)
                if dry_run:
                    result_entry["llm_response"] = None
                    result_entry["request_duration_ms"] = 0
                    result_entry["error"] = None
                    logger.info("[%s] dry-run:跳过 AI provider 调用", case_id)
                else:
                    llm_start = time.perf_counter()
                    try:
                        llm_response = ai_client.interpret(rendered_prompt)
                        llm_ms = (time.perf_counter() - llm_start) * 1000
                        result_entry["llm_response"] = llm_response
                        result_entry["request_duration_ms"] = round(llm_ms, 1)
                        result_entry["error"] = None
                    except Exception as e:
                        llm_ms = (time.perf_counter() - llm_start) * 1000
                        result_entry["llm_response"] = None
                        result_entry["request_duration_ms"] = round(llm_ms, 1)
                        result_entry["error"] = f"{type(e).__name__}: {e}"
                        logger.exception(
                            "[%s] AI provider 调用失败 provider=%s model=%s error=%s",
                            case_id, ai_client.provider, ai_client.model, e,
                        )

                # 5. 落盘单盘文件
                case_dir = output_dir / case_id
                case_dir.mkdir(exist_ok=True)
                _write_json(case_dir / "input_context.json", context)
                _write_text(case_dir / "rendered_prompt.txt", rendered_prompt)
                _write_json(case_dir / "xiji_ground_truth.json", {
                    "day_master_strength": engine_result["day_master_strength"],
                    "favorable_elements": engine_result["favorable_elements"],
                    "unfavorable_elements": engine_result["unfavorable_elements"],
                    "pattern_hint": engine_result.get("pattern_hint"),
                    "tiaoshou_applied": engine_result["tiaoshou_applied"],
                    "element_balance": engine_result["element_balance"],
                    "shensha": engine_result["shensha"],
                    "expected_strength": case["expected_strength"],
                })
                if result_entry.get("llm_response"):
                    _write_text(case_dir / "llm_response.txt", result_entry["llm_response"])

            except Exception as e:
                result_entry["error"] = f"{type(e).__name__}: {e}"
                result_entry["calc_duration_ms"] = 0
                result_entry["request_duration_ms"] = 0
                logger.exception("[%s] 执行失败", case_id)

            all_results.append(result_entry)
            results_file.write(json.dumps(result_entry, ensure_ascii=False) + "\n")
            results_file.flush()

    # 汇总
    _print_summary(all_results, dry_run)
    logger.info("结果写入: %s", results_path)


def _write_json(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _write_text(path: Path, data: str) -> None:
    path.write_text(data, encoding="utf-8")


def _print_summary(results: list[dict[str, Any]], dry_run: bool) -> None:
    """打印汇总。"""
    total = len(results)
    errors = sum(1 for r in results if r.get("error"))
    success = total - errors

    normal = [r for r in results if r["category"] == "normal"]
    special = [r for r in results if r["category"] == "special_pattern"]

    # special_pattern 断言汇总
    sp_passed = sum(
        1 for r in special
        if r.get("special_pattern_assertions", {}).get("passed", False)
    )

    # 喜忌一致性(普通盘 day_master_strength 应 != "special_pattern")
    normal_misclassified = sum(
        1 for r in normal
        if r.get("day_master_strength") == "special_pattern"
    )

    print("\n" + "=" * 60)
    print(f"Spike 汇总 ({'dry-run' if dry_run else 'real API'})")
    print("=" * 60)
    print(f"总数: {total} | 成功: {success} | 失败: {errors}")
    print(f"普通盘: {len(normal)} | 误判为 special_pattern: {normal_misclassified}")
    print(f"Special pattern 盘: {len(special)} | 断言通过: {sp_passed}/{len(special)}")

    if not dry_run and success > 0:
        durations = [r["request_duration_ms"] for r in results if r.get("request_duration_ms", 0) > 0]
        if durations:
            print(f"AI provider 调用耗时: avg={sum(durations)/len(durations):.0f}ms min={min(durations):.0f}ms max={max(durations):.0f}ms")

    print("=" * 60)


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    )

    parser = argparse.ArgumentParser(description="Prompt 验证 Spike")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="不调 AI provider,只验证 context 组装 + prompt 渲染 + special_pattern 断言",
    )
    parser.add_argument(
        "--output-dir",
        type=str,
        default=None,
        help="输出目录(默认 spikes/prompt_validation/output_v{prompt_version})",
    )
    args = parser.parse_args()

    prompt_version = PROMPT_VERSIONS["bazi_deep"]
    output_dir = Path(args.output_dir) if args.output_dir else (
        Path(__file__).parent / f"output_v{prompt_version}"
    )

    run_spike(output_dir=output_dir, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
