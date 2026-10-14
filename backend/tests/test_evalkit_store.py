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
        # prompt_versions 快照变(版本表不同;用远离现值的数字,
        # 避免与 PROMPT_VERSIONS 真值撞值——2026-09-27 m0-m7 bump 2 后撞过)
        _identity(prompt_versions={"m0_structure": 999}),
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
    # v9 形态:四条结论句齐全(L2 v9-1「结论层缺失」判据)
    "m0_structure": {
        "main_axis": {"headline": "压力推着你走,测试结论。"},
        "core_loop": {"headline": "扛压 → 沉淀 → 扛更大的压。"},
        "structure_type": {"name": "测试专业型"},
        "capability_source": {"headline": "最强在测试的时候。"},
        "structure_fingerprint": "伤官生财测试指纹",
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


async def test_case_limit_below_one_raises(tmp_path):
    """case_limit 0/负数:函数级契约显式拒绝(0 是 falsy 会烧满 20 盘)。"""
    with pytest.raises(ValueError, match="case_limit 必须"):
        await execute_run(dry_run=True, case_limit=0, runs_dir=tmp_path)
    with pytest.raises(ValueError, match="case_limit 必须"):
        await execute_run(dry_run=True, case_limit=-1, runs_dir=tmp_path)


async def test_l2_check_exception_isolated_per_entry(tmp_path, monkeypatch):
    """L2 判据代码异常:按条目隔离记 error,不毁掉整轮 run(与生成侧同粒度)。"""
    import evalkit.runner as runner_mod

    def _boom(*args, **kwargs):
        raise ValueError("grounding 判据 bug(模拟)")

    monkeypatch.setattr(runner_mod, "check_grounding", _boom)

    class _M0Gen:
        provider, model = "stub", "stub-model"

        async def interpret(self, prompt: str, **kwargs) -> str:
            return json.dumps({
                "main_axis": {}, "core_loop": {}, "structure_type": {},
                "capability_source": {}, "structure_fingerprint": "指纹",
            }, ensure_ascii=False)

    summary = await execute_run(
        dry_run=False, case_limit=1, runs_dir=tmp_path,
        modules=["m0_structure"], ai_client=_M0Gen(), skip_judge=True,
    )
    # run 完成,该条目 verdict=error 且 error 带 L2 判据异常原因
    assert summary["error"] == 1
    entry = json.loads(
        (tmp_path / summary["run_id"] / "results.jsonl")
        .read_text(encoding="utf-8").splitlines()[0])
    assert entry["verdict"] == "error"
    assert "L2 判据异常" in entry["error"]
    assert "grounding 判据 bug" in entry["error"]
    assert entry["l2"] is None


async def test_run_dir_reuse_rejected(tmp_path):
    """复用已有 results.jsonl 的 run 目录 → 显式拒绝(w 模式会截断旧结果)。"""
    first = await execute_run(
        dry_run=True, case_limit=1, run_id="same-id", runs_dir=tmp_path)
    assert first["total"] == 8
    with pytest.raises(RuntimeError, match="复用会截断"):
        await execute_run(
            dry_run=True, case_limit=1, run_id="same-id", runs_dir=tmp_path)


def test_module_deps_cover_chain_field_producers():
    """MODULE_DEPS(依赖图第四处镜像)不变量锁(2026-10-11 双 review 修复)。

    MODULE_DEPS 与 REQUIRED_FIELDS / interpret._V1_SOURCE_WALK_DEPS /
    iOS ModuleID.dependencies 平行存在,不锁会在链字段加厚时漏更新
    (L1 加粗链条 m3/m4 实踩:漏更新让「m3 缺 m1/m2 的子集」过 CLI
    校验后在渲染层才炸 InvalidInputError,违背 fail-fast 契约)。
    不变量:每个模块 REQUIRED 链字段的**全部产出模块**
    (V1_CHAIN_PRODUCER)都须出现在它的 MODULE_DEPS 里;允许超集
    (m0/m7 的 chart 供给语义)。
    """
    from app.ai.prompts import REQUIRED_FIELDS, V1_CHAIN_PRODUCER
    from evalkit.runner import MODULE_DEPS

    for module, deps in MODULE_DEPS.items():
        producers = {
            V1_CHAIN_PRODUCER[field]
            for field in REQUIRED_FIELDS[module]
            if field in V1_CHAIN_PRODUCER
        }
        missing = producers - set(deps)
        assert not missing, (
            f"{module} 的 MODULE_DEPS 缺产出方 {sorted(missing)}"
            f"(REQUIRED 链字段的上游必须齐全,fail-fast 契约)"
        )


async def test_dry_run_smoke_renders_all_modules(tmp_path):
    """dry-run 冒烟锁(2026-10-11 双 review 修复回归锚)。

    dry-run 的 parsed 恒 None——run_chain_for_case 的 chain_broken 判据
    若不看 dry_run,M0 会被误判失败,M1-M7 全记「链路中断」error 条目、
    prompt 不再渲染(--dry-run CLI 退出码 1,dry-run 的声明用途「验证
    排盘 + chart 构建 + prompt 渲染 + 链式注入」整体失效)。锁:8 模块
    零 error + 每模块 prompt.txt 落盘(链式占位注入生效)。
    """
    summary = await execute_run(
        dry_run=True, case_limit=1, run_id="dry-smoke", runs_dir=tmp_path)
    assert summary["total"] == 8
    assert summary["pass"] == 8
    assert summary["error"] == 0
    for module in ("m0_structure", "m1_talent", "m2_high_low", "m3_system",
                   "m4_health", "m5_wealth", "m6_dynamics", "m7_manual"):
        prompt_path = (tmp_path / "dry-smoke" / "case_00" / module
                       / "prompt.txt")
        assert prompt_path.exists(), f"{module} 的 prompt 未渲染"
        # 链式占位注入生效:M1-M7 的 prompt 里能看到上游占位字段值
        if module != "m0_structure":
            assert "[dry-run placeholder]" in prompt_path.read_text(
                encoding="utf-8"), f"{module} 未注入链式占位字段"


async def test_call_module_retries_transient_and_raises_others(
        monkeypatch, tmp_path):
    """_call_module 瞬态网络重试(2026-10-10 L3 收口)的分支锁。

    - timeout / network 两类 reason:线性退避 5s/10s 重试,共 3 次尝试后成功
    - 其它 reason(rate_limit 等):首次失败即上抛——错误显式传播,
      不掩盖真实故障(对齐 CLAUDE.md 错误传播纪律)
    asyncio.sleep 打桩避免真实 15s 等待;use_cache=False 绕开磁盘缓存。
    """
    import evalkit.runner as runner_mod
    from app.errors import AIProviderError

    sleeps: list[float] = []

    async def _fake_sleep(seconds: float) -> None:
        sleeps.append(seconds)

    monkeypatch.setattr(runner_mod.asyncio, "sleep", _fake_sleep)

    class _FlakyClient:
        provider, model = "stub", "stub-model"

        def __init__(self):
            self.calls = 0

        async def interpret(self, prompt: str, **kwargs) -> str:
            self.calls += 1
            if self.calls <= 2:
                raise AIProviderError("proxy ConnectError",
                                      reason="network")
            return json.dumps(
                {"structure_fingerprint": "指纹"}, ensure_ascii=False)

    client = _FlakyClient()
    _, parsed, _, cached = await runner_mod._call_module(
        module="m0_structure", context={"chart": "{}"},
        ai_client=client, dry_run=False, case_id="retry-case",
        use_cache=False, runs_dir=tmp_path)
    assert client.calls == 3, "network 瞬断应重试到第 3 次"
    assert sleeps == [5.0, 10.0], "线性退避节奏 5s/10s"
    assert parsed == {"structure_fingerprint": "指纹"}
    assert cached is False

    class _RateLimitedClient:
        provider, model = "stub", "stub-model"

        async def interpret(self, prompt: str, **kwargs) -> str:
            raise AIProviderError("429", reason="rate_limit")

    with pytest.raises(AIProviderError):
        await runner_mod._call_module(
            module="m0_structure", context={"chart": "{}"},
            ai_client=_RateLimitedClient(), dry_run=False,
            case_id="retry-case", use_cache=False, runs_dir=tmp_path)


async def test_identity_reflects_module_subset(tmp_path):
    """子集 run 的身份 prompt_versions 只含选中模块(diff 不跨范围混淆)。"""
    summary = await execute_run(
        dry_run=True, case_limit=1, runs_dir=tmp_path, run_id="subset-run")
    full = summary["identity"]["prompt_versions"]
    assert set(full) == {
        "m0_structure", "m1_talent", "m2_high_low", "m3_system",
        "m4_health", "m5_wealth", "m6_dynamics", "m7_manual"}

    class _M0Gen:
        provider, model = "stub", "stub-model"

        async def interpret(self, prompt: str, **kwargs) -> str:
            return "{}"

    sub = await execute_run(
        dry_run=False, case_limit=1, runs_dir=tmp_path, run_id="subset-m0",
        modules=["m0_structure"], ai_client=_M0Gen(), skip_judge=True)
    assert set(sub["identity"]["prompt_versions"]) == {"m0_structure"}


async def test_unparseable_response_not_cached(tmp_path):
    """不可解析响应不进缓存(防毒缓存永久 fail):重跑会重新调 API 重试。"""
    from evalkit.store import cache_clear

    class _BadJsonClient:
        provider, model = "stub", "stub-model"

        def __init__(self):
            self.calls = 0

        async def interpret(self, prompt: str, **kwargs) -> str:
            self.calls += 1
            return "我不是 JSON"

    bad = _BadJsonClient()
    summary_a = await execute_run(
        dry_run=False, case_limit=1, runs_dir=tmp_path, run_id="bad-run-a",
        modules=["m0_structure"], ai_client=bad, skip_judge=True)
    assert summary_a["fail"] == 1
    assert "JSON 解析失败" in json.loads(
        (tmp_path / summary_a["run_id"] / "results.jsonl")
        .read_text(encoding="utf-8").splitlines()[0])["l1"]["failures"][0]

    bad2 = _BadJsonClient()
    summary_b = await execute_run(
        dry_run=False, case_limit=1, runs_dir=tmp_path, run_id="bad-run-b",
        modules=["m0_structure"], ai_client=bad2, skip_judge=True)
    # 未缓存 → 第二次仍真实调用(可自愈重试),而非命中毒缓存
    assert bad2.calls == 1
    assert summary_b["cache_hits"] == 0
