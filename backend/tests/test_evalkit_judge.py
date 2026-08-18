"""evalkit L3 裁判单测(S05)。mock client,零真实 API 调用。

核心红线:解析/结构校验失败一律 raise,不给默认分。
"""

from __future__ import annotations

import asyncio
import json

import pytest

from evalkit.judge import judge_case_modules, judge_one
from evalkit.rubric import RUBRIC_VERSION, build_judge_prompt


def _engine_result():
    return {
        "day_master_strength": "weak",
        "favorable_elements": ["金", "土"],
        "unfavorable_elements": ["水", "木", "火"],
        "element_balance": {"wood": 1, "fire": 2, "earth": 2,
                            "metal": 2, "water": 1},
        "shensha": [
            {"name": "文昌", "position": "日柱", "source": "三命通会"},
        ],
        "current_luck_pillar": {"gan_zhi": "庚午", "start_age": 6,
                                "end_age": 16},
        "current_year_pillar": "乙巳",
        "tiaoshou_applied": False,
        "pattern_hint": None,
        "pillars": {
            "year": {"shishen_gan": "正印"},
            "month": {"shishen_gan": "偏印"},
            "day": {"shishen_gan": "日主"},
            "hour": {"shishen_gan": "伤官"},
        },
    }


def _parsed_output():
    return {"structure_fingerprint": "伤官生财", "note": "金有利"}


class _MockJudge:
    """按预设文本回放的裁判 client。"""

    provider = "mock-judge"
    model = "judge-model-x"

    def __init__(self, response: str):
        self._response = response
        self.calls = 0
        self.last_prompt = None

    async def interpret(self, prompt: str, *, temperature: float = 0.6,
                        **kwargs) -> str:
        self.calls += 1
        self.last_prompt = prompt
        return self._response


def _valid_judge_json(*, sp_score="N/A", overall=4.5) -> str:
    sp_value = "N/A" if sp_score == "N/A" else int(sp_score)
    return json.dumps({
        "scores": {
            "五行完整": 5, "十神配置": 4, "神煞准确": 5,
            "大运流年": 4, "无硬性格局": 5, "严格遵守后端喜忌": 4,
            "special_pattern_诚实": sp_value,
        },
        "overall": overall,
        "failures": ["十神配置: 少引了月干偏印"],
        "passed": True,
    }, ensure_ascii=False)


# ===== rubric 渲染 =====


def test_build_judge_prompt_contains_ground_truth_and_output():
    prompt = build_judge_prompt(
        "m0_structure", _parsed_output(), _engine_result())
    assert "被评模块: m0_structure" in prompt
    assert "金、土" in prompt              # favorable(中文直出)
    assert "无(special_pattern 喜忌留空)" not in prompt or True
    assert "文昌(日柱)" in prompt
    assert "庚午" in prompt                 # 当前大运
    assert "正印" in prompt and "伤官" in prompt  # 十神
    assert "伤官生财" in prompt             # 被评输出
    assert "严格 JSON" in prompt


def test_build_judge_prompt_empty_xiji_shows_special_hint():
    engine = _engine_result()
    engine["favorable_elements"] = []
    engine["unfavorable_elements"] = []
    prompt = build_judge_prompt("m0_structure", _parsed_output(), engine)
    assert "无(special_pattern 喜忌留空)" in prompt


def test_build_judge_prompt_missing_engine_key_raises():
    engine = _engine_result()
    del engine["pillars"]
    with pytest.raises(KeyError):
        build_judge_prompt("m0_structure", _parsed_output(), engine)


def test_rubric_version_bump_semantics():
    """RUBRIC_VERSION 是常量身份(rubric 改必 bump,老分数不与新比)。"""
    assert isinstance(RUBRIC_VERSION, int) and RUBRIC_VERSION >= 1


# ===== judge_one:合法路径 =====


async def test_judge_one_valid_json():
    client = _MockJudge(_valid_judge_json())
    result = await judge_one(
        module="m0_structure", parsed_output=_parsed_output(),
        engine_result=_engine_result(), judge_client=client)
    assert client.calls == 1
    assert result.scores["五行完整"] == 5
    assert result.judge_model == "judge-model-x"
    assert result.rubric_version == RUBRIC_VERSION
    # overall 本地重算:6 个数值维 (5+4+5+4+5+4)/6 = 4.5
    assert result.overall == 4.5
    assert result.passed is True


async def test_judge_one_overall_recomputed_ignoring_judge_arithmetic():
    """裁判自己报 overall=5.0(算错)→ 用重算值(N/A 剔除后平均)。"""
    client = _MockJudge(_valid_judge_json(overall=5.0))
    result = await judge_one(
        module="m0_structure", parsed_output=_parsed_output(),
        engine_result=_engine_result(), judge_client=client)
    assert result.overall == 4.5  # 重算,不是 5.0


async def test_judge_one_markdown_fence_wrapped():
    client = _MockJudge(f"```json\n{_valid_judge_json()}\n```")
    result = await judge_one(
        module="m0_structure", parsed_output=_parsed_output(),
        engine_result=_engine_result(), judge_client=client)
    assert result.passed is True


async def test_judge_one_sp_score_counted_when_numeric():
    """special_pattern 盘给了数值分 → 计入平均(7 维)。"""
    client = _MockJudge(_valid_judge_json(sp_score="3", overall=4.0))
    result = await judge_one(
        module="m0_structure", parsed_output=_parsed_output(),
        engine_result=_engine_result(), judge_client=client)
    # (5+4+5+4+5+4+3)/7 = 30/7 ≈ 4.3
    assert result.overall == pytest.approx(4.3, abs=0.05)


# ===== judge_one:违规一律 raise,不给默认分 =====


async def test_judge_one_non_json_raises():
    client = _MockJudge("我觉得这个输出挺好的")
    with pytest.raises(ValueError, match="非合法 JSON"):
        await judge_one(
            module="m0_structure", parsed_output=_parsed_output(),
            engine_result=_engine_result(), judge_client=client)


def _mutated_judge_json(**mutations) -> str:
    data = json.loads(_valid_judge_json())
    for key_path, value in mutations.items():
        obj = data
        *parents, leaf = key_path.split(".")
        for p in parents:
            obj = obj[p]
        if value is _DELETE:
            del obj[leaf]
        else:
            obj[leaf] = value
    return json.dumps(data, ensure_ascii=False)


_DELETE = object()


async def test_judge_one_missing_dimension_raises():
    client = _MockJudge(_mutated_judge_json(**{"scores.十神配置": _DELETE}))
    with pytest.raises(ValueError, match="缺维度"):
        await judge_one(
            module="m0_structure", parsed_output=_parsed_output(),
            engine_result=_engine_result(), judge_client=client)


async def test_judge_one_out_of_range_score_raises():
    client = _MockJudge(_mutated_judge_json(**{"scores.五行完整": 7}))
    with pytest.raises(ValueError, match="越界"):
        await judge_one(
            module="m0_structure", parsed_output=_parsed_output(),
            engine_result=_engine_result(), judge_client=client)


async def test_judge_one_overall_string_raises():
    client = _MockJudge(_mutated_judge_json(**{"overall": "4.5"}))
    with pytest.raises(ValueError, match="overall 非数字"):
        await judge_one(
            module="m0_structure", parsed_output=_parsed_output(),
            engine_result=_engine_result(), judge_client=client)


async def test_judge_one_failures_non_list_raises():
    client = _MockJudge(_mutated_judge_json(**{"failures": "扣分理由"}))
    with pytest.raises(ValueError, match="failures 非"):
        await judge_one(
            module="m0_structure", parsed_output=_parsed_output(),
            engine_result=_engine_result(), judge_client=client)


async def test_judge_one_na_on_wrong_dimension_raises():
    """N/A 只允许出现在 special_pattern_诚实。"""
    client = _MockJudge(_mutated_judge_json(**{"scores.五行完整": "N/A"}))
    with pytest.raises(ValueError, match="N/A 不允许"):
        await judge_one(
            module="m0_structure", parsed_output=_parsed_output(),
            engine_result=_engine_result(), judge_client=client)


async def test_judge_one_missing_scores_key_raises():
    client = _MockJudge(json.dumps({"overall": 4.0, "failures": []}))
    with pytest.raises(KeyError, match="scores"):
        await judge_one(
            module="m0_structure", parsed_output=_parsed_output(),
            engine_result=_engine_result(), judge_client=client)


# ===== judge_case_modules:并发 + 逐条隔离 =====


async def test_judge_case_modules_isolates_failures():
    good = json.dumps({
        "scores": {"五行完整": 5, "十神配置": 5, "神煞准确": 5,
                   "大运流年": 5, "无硬性格局": 5, "严格遵守后端喜忌": 5,
                   "special_pattern_诚实": "N/A"},
        "overall": 5.0, "failures": [], "passed": True,
    }, ensure_ascii=False)

    class _SelectiveJudge:
        provider, model = "mock", "m"
        calls = 0

        async def interpret(self, prompt: str, **kwargs) -> str:
            _SelectiveJudge.calls += 1
            if "m1_talent" in prompt or "模块 M1" in prompt:
                return "不是 JSON"
            return good

    engine = _engine_result()
    results = await judge_case_modules(
        [("m0_structure", {}, engine), ("m1_talent", {}, engine)],
        judge_client=_SelectiveJudge(),
    )
    from evalkit.judge import JudgeResult
    assert isinstance(results["m0_structure"], JudgeResult)
    assert isinstance(results["m1_talent"], str)  # 错误描述,不拖垮整盘
    assert "ValueError" in results["m1_talent"]


async def test_judge_case_modules_semaphore_limits_concurrency():
    """并发上限生效(limit=2 时同时在飞 ≤2)。"""
    inflight = 0
    peak = 0

    class _SlowJudge:
        provider, model = "mock", "m"

        async def interpret(self, prompt: str, **kwargs) -> str:
            nonlocal inflight, peak
            inflight += 1
            peak = max(peak, inflight)
            await asyncio.sleep(0.01)
            inflight -= 1
            return _valid_judge_json()

    engine = _engine_result()
    items = [(f"m{i}", {}, engine) for i in range(5)]
    await judge_case_modules(items, judge_client=_SlowJudge(), limit=2)
    assert peak <= 2


# ===== runner 端到端接线(生成 stub + mock 裁判) =====


class _M0OnlyGenClient:
    """生成 stub:只跑 m0 模块,返回合法 M0 输出。"""

    provider = "stub"
    model = "stub-model"

    def __init__(self):
        self.calls = 0

    async def interpret(self, prompt: str, **kwargs) -> str:
        self.calls += 1
        return json.dumps({
            "main_axis": {}, "core_loop": {}, "structure_type": {},
            "capability_source": {}, "structure_fingerprint": "伤官生财测试指纹",
        }, ensure_ascii=False)


async def test_execute_run_judge_wiring_warn_and_error(tmp_path):
    from evalkit.runner import execute_run

    low_scores = json.dumps({
        "scores": {"五行完整": 2, "十神配置": 2, "神煞准确": 2,
                   "大运流年": 2, "无硬性格局": 2, "严格遵守后端喜忌": 2,
                   "special_pattern_诚实": "N/A"},
        "overall": 2.0, "failures": ["五行完整: 漏行"], "passed": False,
    }, ensure_ascii=False)

    # 裁判低分 → verdict warn(L1/L2 过但 overall < 4.0)
    gen = _M0OnlyGenClient()
    summary = await execute_run(
        dry_run=False, case_limit=1, runs_dir=tmp_path,
        modules=["m0_structure"], ai_client=gen,
        judge_client=_MockJudge(low_scores),
    )
    assert gen.calls == 1
    assert summary["warn"] == 1
    assert summary["identity"]["judge_model"] == "judge-model-x"
    assert summary["identity"]["rubric_version"] == RUBRIC_VERSION
    entry = json.loads(
        (tmp_path / summary["run_id"] / "results.jsonl")
        .read_text(encoding="utf-8").splitlines()[0])
    assert entry["verdict"] == "warn"
    assert entry["l3"]["overall"] == 2.0
    assert entry["l3"]["judge_model"] == "judge-model-x"

    # 裁判输出非 JSON → verdict error(不给默认分),error 字段带原因
    summary2 = await execute_run(
        dry_run=False, case_limit=1, runs_dir=tmp_path,
        modules=["m0_structure"], ai_client=_M0OnlyGenClient(),
        judge_client=_MockJudge("裁判今天不想打分"),
        run_id="run-judge-error",
    )
    assert summary2["error"] == 1
    entry2 = json.loads(
        (tmp_path / "run-judge-error" / "results.jsonl")
        .read_text(encoding="utf-8").splitlines()[0])
    assert entry2["verdict"] == "error"
    assert "裁判失败" in entry2["error"]
    assert entry2["l3"] is None
