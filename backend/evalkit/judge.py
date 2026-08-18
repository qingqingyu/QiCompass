"""evalkit L3 裁判 client(S05)。

复用 app/ai/client.create_ai_client()(只喂 JUDGE_* 参数,不新写 HTTP
client);严格 JSON 解析——解析/结构校验失败**显式 raise,不给默认分**:
给个默认 3 分会让坏掉的裁判看起来在正常工作,提供虚假安全感。

overall 由本地重算而非采信裁判算术:scores 是唯一事实源,N/A 维剔除后
取平均(保留 1 位小数);裁判自己的 overall 字段仍要求存在且为数字
(校验其结构完整性),但展示与 verdict 判定用重算值。
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from typing import Any

from app.ai.client import AIClient, create_ai_client
from app.config import (
    JUDGE_API_KEY,
    JUDGE_BASE_URL,
    JUDGE_MODEL,
    JUDGE_PROVIDER,
)

from .llm_json import parse_llm_json
from .rubric import RUBRIC_VERSION, build_judge_prompt, judge_score_keys

JUDGE_TEMPERATURE = 0.2  # 评分要稳,低温
PASS_THRESHOLD = 4.0

_SCORE_KEYS = judge_score_keys()
_NA_ALLOWED_KEYS = ("special_pattern_诚实",)


@dataclass
class JudgeResult:
    scores: dict[str, int | str]  # 7 键;special_pattern_诚实 可为 "N/A"
    overall: float                # 本地重算(N/A 剔除)
    failures: list[str]
    passed: bool                  # overall >= 4.0
    judge_provider: str
    judge_model: str
    rubric_version: int


def create_judge_client() -> AIClient:
    """按 JUDGE_* env 构造裁判 client(默认回落生成侧 AI_*)。

    openai 裁判走 JUDGE_BASE_URL(独立网关覆盖);anthropic 裁判走官方
    默认 endpoint(create_ai_client 对 anthropic 分支不消费 openai_base_url)。
    """
    return create_ai_client(
        provider=JUDGE_PROVIDER,
        anthropic_api_key=JUDGE_API_KEY if JUDGE_PROVIDER == "anthropic" else None,
        anthropic_model=JUDGE_MODEL,
        openai_api_key=JUDGE_API_KEY if JUDGE_PROVIDER == "openai" else None,
        openai_model=JUDGE_MODEL,
        openai_base_url=JUDGE_BASE_URL,
    )


def _validate_scores(scores: Any) -> dict[str, int | str]:
    if not isinstance(scores, dict):
        raise ValueError(f"裁判输出 scores 非 object(type={type(scores).__name__})")
    missing = [k for k in _SCORE_KEYS if k not in scores]
    if missing:
        raise ValueError(f"裁判输出 scores 缺维度: {missing}")
    unknown = [k for k in scores if k not in _SCORE_KEYS]
    if unknown:
        raise ValueError(f"裁判输出 scores 有未知维度: {unknown}")
    for key, value in scores.items():
        if value == "N/A":
            if key not in _NA_ALLOWED_KEYS:
                raise ValueError(
                    f"裁判输出 scores[{key!r}] = N/A 不允许"
                    f"(仅 {_NA_ALLOWED_KEYS} 可 N/A)"
                )
            continue
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValueError(
                f"裁判输出 scores[{key!r}] 非 1-5 整数(值 {value!r})")
        if not 1 <= value <= 5:
            raise ValueError(
                f"裁判输出 scores[{key!r}] 越界(值 {value!r},期望 1-5)")
    return scores


def _recompute_overall(scores: dict[str, int | str]) -> float:
    numeric = [v for v in scores.values() if isinstance(v, int)]
    if not numeric:
        raise ValueError("裁判输出全部维度为 N/A,无法计算 overall")
    return round(sum(numeric) / len(numeric), 1)


async def judge_one(
    *,
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
    judge_client: Any,
) -> JudgeResult:
    """单条裁判。解析/结构违规一律 raise,不给默认分。"""
    prompt = build_judge_prompt(module, parsed_output, engine_result)
    response = await judge_client.interpret(
        prompt, temperature=JUDGE_TEMPERATURE)
    parsed = parse_llm_json(response)

    scores = _validate_scores(parsed["scores"])
    # special_pattern 盘的诚实维度是红线,不允许裁判用 N/A 躲掉
    # (N/A 是给普通盘的;L2 虽兜底,但裁判侧也不应留下逃逸口)
    if (engine_result.get("day_master_strength") == "special_pattern"
            and scores["special_pattern_诚实"] == "N/A"):
        raise ValueError(
            "special_pattern 盘的「special_pattern_诚实」维度不适用 N/A"
            "(该盘必须评诚实度)")

    overall_reported = parsed.get("overall")
    if isinstance(overall_reported, bool) or not isinstance(
            overall_reported, (int, float)):
        raise ValueError(
            f"裁判输出 overall 非数字(值 {overall_reported!r})")

    failures = parsed.get("failures")
    if not isinstance(failures, list) or not all(
            isinstance(f, str) for f in failures):
        raise ValueError(
            f"裁判输出 failures 非 string 列表(值 {failures!r})")

    overall = _recompute_overall(scores)
    return JudgeResult(
        scores=scores,
        overall=overall,
        failures=failures,
        passed=overall >= PASS_THRESHOLD,
        judge_provider=judge_client.provider,
        judge_model=judge_client.model,
        rubric_version=RUBRIC_VERSION,
    )


async def judge_case_modules(
    items: list[tuple[str, dict[str, Any], dict[str, Any]]],
    *,
    judge_client: Any,
    limit: int = 4,
) -> dict[str, JudgeResult | str]:
    """同一盘的多个模块并发裁判(裁判之间无依赖,不同于生成阶段链式约束)。

    Args:
        items: [(module, parsed_output, engine_result), ...]
        limit: 信号量并发上限

    Returns:
        {module: JudgeResult} 或 {module: "错误描述"}(逐条隔离,
        单条裁判失败不拖垮整盘;runner 把失败条目的 verdict 记 error)
    """
    semaphore = asyncio.Semaphore(limit)

    async def _one(module: str, parsed: dict, engine: dict):
        async with semaphore:
            return await judge_one(
                module=module, parsed_output=parsed,
                engine_result=engine, judge_client=judge_client)

    raw = await asyncio.gather(
        *(_one(m, p, e) for m, p, e in items), return_exceptions=True)
    results: dict[str, JudgeResult | str] = {}
    for (module, _, _), outcome in zip(items, raw):
        if isinstance(outcome, Exception):
            results[module] = f"{type(outcome).__name__}: {outcome}"
        elif isinstance(outcome, BaseException):
            # CancelledError / KeyboardInterrupt 传播,不吞成"裁判失败"
            raise outcome
        else:
            results[module] = outcome
    return results
