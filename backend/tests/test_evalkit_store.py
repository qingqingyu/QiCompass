"""evalkit store 单测(S04):run 身份 / verdict / 缓存 / diff / 基线。

用构造的 jsonl 与 tmp 目录,零 API 调用(runner 缓存重放用 stub client)。
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from evalkit.runner import execute_run
from evalkit.store import (
    build_run_identity,
    cache_get,
    cache_path,
    cache_put,
    compute_verdict,
    diff_runs,
    identity_digest,
    make_cache_key,
    make_run_id,
    read_baseline,
    set_baseline,
    write_meta,
)


def _identity(**overrides):
    base = build_run_identity(
        "anthropic", "model-a",
        modules=["m0_structure"], cases_hash="hash-x",
    )
    base.update(overrides)
    return base


# ===== Q5 run 身份 =====


def test_identity_same_dims_same_digest():
    assert identity_digest(_identity()) == identity_digest(_identity())
    assert make_run_id(_identity()).endswith(
        "-" + identity_digest(_identity())[:6])


def test_identity_any_dim_change_differs():
    base = identity_digest(_identity())
    variants = [
        _identity(provider="openai"),
        _identity(model="model-b"),
        _identity(rubric_version=2),
        _identity(judge_model="judge-x"),
        _identity(cases_hash="hash-y"),
        # prompt_versions 快照变(模块集不同 → 版本表不同)
        _identity(prompt_versions={"m0_structure": 2}),
    ]
    for v in variants:
        assert identity_digest(v) != base


def test_run_id_timestamp_sortable():
    run_id = make_run_id(_identity())
    stamp = run_id.split("-")[0]
    assert len(stamp) == 15  # YYYYMMDDTHHMMSS
    assert stamp.isdigit() or stamp[:8].isdigit()


# ===== verdict =====


@pytest.mark.parametrize("l1,l2,error,expected", [
    (None, None, None, "pass"),                       # dry-run
    ({"passed": True, "failures": []},
     {"passed": True, "failures": []}, None, "pass"),
    ({"passed": False, "failures": ["x"]}, None, None, "fail"),
    ({"passed": True, "failures": []},
     {"passed": False, "failures": ["y"]}, None, "fail"),
    ({"passed": True, "failures": []}, None,
     "排盘失败: Boom", "error"),                       # error 优先于 fail
    (None, None, "ValueError: x", "error"),
])
def test_verdict_three_states(l1, l2, error, expected):
    assert compute_verdict(l1=l1, l2=l2, error=error) == expected


@pytest.mark.parametrize("l3,expected", [
    ({"passed": True, "overall": 4.5}, "pass"),
    ({"passed": False, "overall": 3.9}, "warn"),
    (None, "pass"),  # judge_enabled 但 l3 null(如该盘裁判跳过)
])
def test_verdict_with_judge(l3, expected):
    assert compute_verdict(
        l1={"passed": True, "failures": []},
        l2={"passed": True, "failures": []},
        l3=l3, judge_enabled=True,
    ) == expected


def test_verdict_l1_fail_beats_low_judge_score():
    """L1/L2 确定性 fail 优先于 L3(warn 不能掩盖硬失败)。"""
    assert compute_verdict(
        l1={"passed": False, "failures": ["缺字段"]},
        l2={"passed": True, "failures": []},
        l3={"passed": True, "overall": 5.0}, judge_enabled=True,
    ) == "fail"


# ===== Q6 缓存 =====


def _key(**overrides):
    base = dict(
        case_id="case_00", module="m0_structure", prompt_version=1,
        provider="anthropic", model="model-a",
        rendered_prompt="prompt 内容", upstream_payload={"age": 32},
    )
    base.update(overrides)
    return make_cache_key(**base)


def test_cache_roundtrip_hit(tmp_path):
    key = _key()
    assert cache_get(key, tmp_path) is None  # 未命中
    cache_put(key, "LLM 响应文本", tmp_path)
    assert cache_get(key, tmp_path) == "LLM 响应文本"


def test_cache_key_prompt_change_misses(tmp_path):
    cache_put(_key(), "resp", tmp_path)
    assert cache_get(_key(rendered_prompt="prompt 内容 改"), tmp_path) is None


def test_cache_key_upstream_change_misses(tmp_path):
    cache_put(_key(), "resp", tmp_path)
    assert cache_get(_key(upstream_payload={"age": 33}), tmp_path) is None


def test_cache_key_model_change_misses(tmp_path):
    cache_put(_key(), "resp", tmp_path)
    assert cache_get(_key(model="model-b"), tmp_path) is None


def test_cache_corrupt_file_raises(tmp_path):
    key = _key()
    cache_put(key, "resp", tmp_path)
    cache_path(key, tmp_path).write_text("不是 JSON", encoding="utf-8")
    with pytest.raises(RuntimeError, match="缓存文件损坏"):
        cache_get(key, tmp_path)


# ===== Q7 基线 =====


def test_baseline_roundtrip(tmp_path):
    assert read_baseline(tmp_path) is None
    _write_run(tmp_path, "run-a", [_entry("c0", "m0", "pass")])
    set_baseline("run-a", tmp_path)
    assert read_baseline(tmp_path) == "run-a"


def test_set_baseline_missing_run_raises(tmp_path):
    with pytest.raises(RuntimeError, match="不能设为基线"):
        set_baseline("ghost", tmp_path)


def test_baseline_pointing_to_missing_run_raises(tmp_path):
    (tmp_path / "BASELINE").write_text("ghost-run\n", encoding="utf-8")
    with pytest.raises(RuntimeError, match="指向不存在"):
        read_baseline(tmp_path)


# ===== Q7 diff =====


def _entry(case, module, verdict):
    return {"case_id": case, "module": module, "verdict": verdict,
            "error": None}


def _write_run(runs_dir, run_id, entries, identity=None):
    run_dir = runs_dir / run_id
    run_dir.mkdir(parents=True)
    with open(run_dir / "results.jsonl", "w", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    write_meta(run_dir, {
        "run_id": run_id,
        "identity": identity or _identity(),
    })


def test_diff_four_classifications(tmp_path):
    _write_run(tmp_path, "base", [
        _entry("c0", "m0", "pass"),
        _entry("c0", "m1", "fail"),      # → fixed
        _entry("c1", "m0", "fail"),      # → still_failing
        _entry("c1", "m1", "pass"),      # → regressed
    ])
    _write_run(tmp_path, "curr", [
        _entry("c0", "m0", "pass"),      # → unchanged
        _entry("c0", "m1", "pass"),
        _entry("c1", "m0", "error"),     # error 也算非 pass
        _entry("c1", "m1", "fail"),
    ])
    result = diff_runs("base", "curr", tmp_path)
    assert result.regressed == [("c1", "m1")]
    assert result.fixed == [("c0", "m1")]
    assert result.still_failing == [("c1", "m0")]
    assert result.unchanged_count == 1
    assert result.skipped == [] and result.new == []


def test_diff_subset_run_not_regressed(tmp_path):
    """--modules 子集:baseline 有而 current 没有 → skipped,不误报退化。"""
    _write_run(tmp_path, "base", [
        _entry("c0", "m0", "pass"), _entry("c0", "m1", "pass"),
        _entry("c1", "m0", "pass"), _entry("c1", "m1", "pass"),
    ])
    _write_run(tmp_path, "curr", [
        _entry("c0", "m1", "pass"),
    ])
    result = diff_runs("base", "curr", tmp_path)
    assert result.regressed == []
    assert sorted(result.skipped) == [("c0", "m0"), ("c1", "m0"),
                                      ("c1", "m1")]


def test_diff_new_keys(tmp_path):
    _write_run(tmp_path, "base", [_entry("c0", "m0", "pass")])
    _write_run(tmp_path, "curr", [
        _entry("c0", "m0", "pass"), _entry("c9", "m7", "fail"),
    ])
    result = diff_runs("base", "curr", tmp_path)
    assert result.new == [("c9", "m7")]
    assert result.regressed == []


def test_diff_warn_counts_as_pass(tmp_path):
    """warn 视同 pass:baseline pass → current warn 不算 regressed(08-18 拍板)。"""
    _write_run(tmp_path, "base", [_entry("c0", "m0", "pass")])
    _write_run(tmp_path, "curr", [_entry("c0", "m0", "warn")])
    result = diff_runs("base", "curr", tmp_path)
    assert result.regressed == []
    assert result.unchanged_count == 1


def test_diff_identity_diff_reported(tmp_path):
    _write_run(tmp_path, "base", [_entry("c0", "m0", "pass")],
               identity=_identity())
    _write_run(tmp_path, "curr", [_entry("c0", "m0", "pass")],
               identity=_identity(model="model-b"))
    result = diff_runs("base", "curr", tmp_path)
    assert "model" in result.identity_diff


# ===== runner 缓存重放(零 API 重算判据) =====


_VALID_RESPONSES = {
    "m0_structure": {
        "main_axis": {}, "core_loop": {}, "structure_type": {},
        "capability_source": {}, "structure_fingerprint": "伤官生财测试指纹",
    },
    "m1_talent": {"innate": [], "trained": [], "defensive": [],
                  "one_leverage": "创造力"},
    "m2_high_low": {"high_config": {}, "low_config": {}, "threshold": {},
                    "early_warnings": ["a", "b", "c"],
                    "switch_actions": ["a", "b", "c"]},
    "m3_system": {"operating_mode": {}, "failure_environments": [],
                  "ideal_life_structure": {}, "stability_vs_volatility": {},
                  "environment_checklist": ["q1", "q2", "q3", "q4", "q5"]},
    "m4_health": {"battery_type": {}, "imbalance_risks": ["a", "b", "c"],
                  "recovery_levers": ["a", "b", "c"],
                  "reset_7day": [f"d{i}" for i in range(7)],
                  "weekly_maintenance": [], "medical_note": "一般建议"},
    "m5_wealth": {"income_forms": [{"form": f"f{i}", "rank": i}
                                   for i in range(1, 7)],
                  "leaks": [], "strategies": {},
                  "asset_ideas": ["a", "b", "c"], "disclaimer": "x"},
    "m6_dynamics": {"energy_path": {}, "leverage": {},
                    "vulnerability": {}, "upgrade_path": {}},
    "m7_manual": {"true_leverage": {}, "use_cases": ["a", "b", "c"],
                  "next_90_days": {}, "falsification_signals": ["a", "b"]},
}

_MODULE_MARKERS = [
    ("m0_structure", "模块 M0"), ("m1_talent", "模块 M1"),
    ("m2_high_low", "模块 M2"), ("m3_system", "模块 M3"),
    ("m4_health", "模块 M4"), ("m5_wealth", "模块 M5"),
    ("m6_dynamics", "模块 M6"), ("m7_manual", "模块 M7"),
]


class _StaticChainClient:
    """按 prompt 里的模块标记返回对应合法 JSON。"""

    provider = "stub"
    model = "stub-model"

    def __init__(self):
        self.calls = 0

    async def interpret(self, prompt: str, *, temperature: float = 0.6,
                        **kwargs) -> str:
        self.calls += 1
        for module, marker in _MODULE_MARKERS:
            if marker in prompt:
                return json.dumps(
                    _VALID_RESPONSES[module], ensure_ascii=False)
        raise RuntimeError(f"stub 无法识别 prompt 对应模块(prompt 头 200 字:"
                           f" {prompt[:200]!r})")


class _ExplodingClient(_StaticChainClient):
    """重放时应命中缓存,一旦被调说说明缓存失效链路 broken。"""

    async def interpret(self, prompt: str, **kwargs) -> str:
        raise RuntimeError("不应再调 API(应命中响应缓存)")


async def test_replay_from_cache_zero_api_calls(tmp_path):
    """缓存重放:同输入第二次 run 零 API 调用,判据全部重算。

    skip_judge=True:本测试只测生成缓存;S05 后真实 run 默认开裁判,
    不显式跳过会真调 JUDGE API(测试零真实调用红线)。
    """
    first = _StaticChainClient()
    summary_a = await execute_run(
        dry_run=False, case_limit=1, run_id="run-a",
        runs_dir=tmp_path, ai_client=first, skip_judge=True,
    )
    assert first.calls == 8  # 1 盘 × 8 模块
    assert summary_a["api_calls"] == 8
    assert summary_a["cache_hits"] == 0
    assert summary_a["pass"] == 8  # stub 输出 L1/L2 全过

    summary_b = await execute_run(
        dry_run=False, case_limit=1, run_id="run-b",
        runs_dir=tmp_path, ai_client=_ExplodingClient(), skip_judge=True,
    )
    assert summary_b["api_calls"] == 0
    assert summary_b["cache_hits"] == 8
    assert summary_b["pass"] == 8  # 判据用缓存响应重算,结论一致


async def test_no_cache_forces_full_api(tmp_path):
    first = _StaticChainClient()
    await execute_run(
        dry_run=False, case_limit=1, run_id="run-a",
        runs_dir=tmp_path, ai_client=first, skip_judge=True,
    )
    second = _StaticChainClient()
    summary = await execute_run(
        dry_run=False, case_limit=1, run_id="run-b",
        runs_dir=tmp_path, ai_client=second, no_cache=True,
        skip_judge=True,
    )
    assert second.calls == 8
    assert summary["cache_hits"] == 0
