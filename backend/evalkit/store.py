"""evalkit store:run 持久化 + 响应缓存 + 跨 run diff(Q5/Q6/Q7)。

Q5 Run 身份:六维 (prompt_versions 快照, provider, model, rubric_version,
judge_model, cases_hash)。存整份 prompt_versions 快照而非单个版本号——
链式调用里 M7 的质量受 M1-M6 全部影响,只记 M7 自己的版本号无法解释变化。

Q6 响应缓存:**只存 LLM 原始响应文本,不存判据结果**——判据代码
(S02/S03)会频繁迭代,缓存了就等于每次改判据都要重新烧钱。缓存键含
渲染后 prompt 的 sha256 + 上游注入内容的 sha256(链式特有:M0 输出变了,
下游缓存必须失效)。设计参照 app/ai/cache_key.py 的 prompt_hash/parent_hash
思路,但独立实现(维度不同:evalkit 多 case_id,少 target_date 等)。

Q7 diff:四分类 regressed / fixed / still_failing / unchanged + skipped/new。
S05 引入 warn 后 warn 视同 pass 参与 diff(裁判分数抖动不能让 regressed
闪烁,设计决策 Q7 注)。
"""

from __future__ import annotations

import hashlib
import json
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Sequence

from app.ai.prompts import PROMPT_VERSIONS

RUNS_DIR = Path(__file__).parent / "runs"
CACHE_DIR_NAME = ".cache"
BASELINE_NAME = "BASELINE"

_PASS_LIKE = ("pass", "warn")  # warn 视同 pass(见模块 docstring / Q7 注)


# ---------- Q5 run 身份 ----------

def build_run_identity(
    provider: str, model: str, *,
    modules: Sequence[str],
    cases_hash: str,
    rubric_version: int = 0,
    judge_model: str = "",
) -> dict[str, Any]:
    """六维身份:任一维变 = 新 run,不与老 run 混比。"""
    return {
        "prompt_versions": {m: PROMPT_VERSIONS[m] for m in modules},
        "provider": provider,
        "model": model,
        "rubric_version": rubric_version,
        "judge_model": judge_model,
        "cases_hash": cases_hash,
    }


def identity_digest(identity: dict[str, Any]) -> str:
    """身份摘要 sha256(规范化 JSON;dict 顺序不影响)。"""
    canonical = json.dumps(
        identity, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def make_run_id(identity: dict[str, Any]) -> str:
    """时间戳(到秒,可排序)+ 身份摘要短 hash(同身份可辨认)。"""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    return f"{stamp}-{identity_digest(identity)[:6]}"


# ---------- verdict 判定 ----------

def compute_verdict(
    *,
    l1: dict[str, Any] | None,
    l2: dict[str, Any] | None,
    l3: dict[str, Any] | None = None,
    error: str | None = None,
    judge_enabled: bool = False,
) -> str:
    """三态(S04)/四态(S05 接裁判后):pass / warn / fail / error。

    - error(跑挂)与 fail(质量问题)区分
    - L1/L2 任一 fail → fail(确定性判据优先)
    - L3:judge_enabled 且 l3 非 null → overall >= 4.0 pass,< 4.0 warn
    """
    if error is not None:
        return "error"
    for layer in (l1, l2):
        if layer is not None and not layer.get("passed", False):
            return "fail"
    if judge_enabled and l3 is not None:
        return "pass" if l3.get("passed", False) else "warn"
    return "pass"


# ---------- run 落盘 / 读取 ----------

def run_dir_for(run_id: str, runs_dir: Path | None = None) -> Path:
    return (runs_dir or RUNS_DIR) / run_id


def write_meta(run_dir: Path, meta: dict[str, Any]) -> None:
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "meta.json").write_text(
        json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")


def read_meta(run_id: str, runs_dir: Path | None = None) -> dict[str, Any]:
    path = run_dir_for(run_id, runs_dir) / "meta.json"
    if not path.exists():
        raise RuntimeError(f"run 不存在或缺 meta.json: {run_id}(路径 {path})")
    return json.loads(path.read_text(encoding="utf-8"))


def load_results(run_id: str, runs_dir: Path | None = None) -> list[dict[str, Any]]:
    """读 results.jsonl(每行一个 (case, module) 条目)。损坏行显式报错。"""
    path = run_dir_for(run_id, runs_dir) / "results.jsonl"
    if not path.exists():
        raise RuntimeError(f"run 不存在或缺 results.jsonl: {run_id}(路径 {path})")
    entries: list[dict[str, Any]] = []
    for lineno, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip():
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError as e:
            raise RuntimeError(
                f"results.jsonl 第 {lineno} 行损坏(run={run_id}): {e}"
            ) from e
    return entries


def list_runs(runs_dir: Path | None = None) -> list[str]:
    """run_id 列表(按名字倒序 = 时间倒序)。"""
    base = runs_dir or RUNS_DIR
    if not base.exists():
        return []
    return sorted(
        (p.name for p in base.iterdir()
         if p.is_dir() and (p / "meta.json").exists()),
        reverse=True,
    )


# ---------- Q6 响应缓存 ----------

@dataclass(frozen=True)
class CacheKeyData:
    case_id: str
    module: str
    prompt_version: int
    provider: str
    model: str
    prompt_sha256: str
    upstream_sha256: str

    def digest(self) -> str:
        canonical = json.dumps(
            self.__dict__, ensure_ascii=False, sort_keys=True,
            separators=(",", ":"))
        return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def make_cache_key(
    *,
    case_id: str,
    module: str,
    prompt_version: int,
    provider: str,
    model: str,
    rendered_prompt: str,
    upstream_payload: dict[str, Any],
) -> CacheKeyData:
    upstream_canonical = json.dumps(
        upstream_payload, ensure_ascii=False, sort_keys=True,
        separators=(",", ":"))
    return CacheKeyData(
        case_id=case_id,
        module=module,
        prompt_version=prompt_version,
        provider=provider,
        model=model,
        prompt_sha256=hashlib.sha256(
            rendered_prompt.encode("utf-8")).hexdigest(),
        upstream_sha256=hashlib.sha256(
            upstream_canonical.encode("utf-8")).hexdigest(),
    )


def cache_path(key: CacheKeyData, runs_dir: Path | None = None) -> Path:
    return (runs_dir or RUNS_DIR) / CACHE_DIR_NAME / f"{key.digest()}.json"


def cache_get(key: CacheKeyData, runs_dir: Path | None = None) -> str | None:
    """命中返回缓存的 LLM 原始响应文本;未命中返回 None。

    缓存文件损坏 → 显式 raise 并指出路径,不静默当 miss(静默重调会烧钱)。
    """
    path = cache_path(key, runs_dir)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        response = data["response"]
        if not isinstance(response, str):
            raise RuntimeError(f"response 字段非 str: {type(response).__name__}")
        return response
    except (json.JSONDecodeError, KeyError, RuntimeError) as e:
        raise RuntimeError(
            f"响应缓存文件损坏: {path}({type(e).__name__}: {e})。"
            f"排查后删除该文件,不要让它静默当 miss 重新烧钱"
        ) from e


def cache_put(
    key: CacheKeyData, response: str, runs_dir: Path | None = None,
) -> None:
    path = cache_path(key, runs_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"key": key.__dict__, "response": response}
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def cache_clear(runs_dir: Path | None = None) -> int:
    """清空缓存(换模型/验证抖动前用)。返回删除的文件数。"""
    cache_dir = (runs_dir or RUNS_DIR) / CACHE_DIR_NAME
    if not cache_dir.exists():
        return 0
    count = 0
    for p in cache_dir.glob("*.json"):
        p.unlink()
        count += 1
    return count


# ---------- Q7 基线 ----------

def baseline_path(runs_dir: Path | None = None) -> Path:
    return (runs_dir or RUNS_DIR) / BASELINE_NAME


def read_baseline(runs_dir: Path | None = None) -> str | None:
    """读基线 run_id;未设置返回 None。指向不存在的 run → raise。"""
    path = baseline_path(runs_dir)
    if not path.exists():
        return None
    run_id = path.read_text(encoding="utf-8").strip()
    if not run_id:
        raise RuntimeError(f"BASELINE 文件为空: {path}")
    if not run_dir_for(run_id, runs_dir).exists():
        raise RuntimeError(
            f"BASELINE 指向不存在的 run: {run_id}(路径 {path})。"
            f"先跑该 run 或重新 --set-baseline"
        )
    return run_id


def set_baseline(run_id: str, runs_dir: Path | None = None) -> None:
    run_dir = run_dir_for(run_id, runs_dir)
    if not (run_dir / "results.jsonl").exists():
        raise RuntimeError(
            f"不能设为基线:run 不存在或缺 results.jsonl: {run_id}(路径 {run_dir})")
    baseline_path(runs_dir).parent.mkdir(parents=True, exist_ok=True)
    baseline_path(runs_dir).write_text(run_id + "\n", encoding="utf-8")


# ---------- Q7 跨 run diff ----------

@dataclass
class DiffResult:
    regressed: list[tuple[str, str]] = field(default_factory=list)
    fixed: list[tuple[str, str]] = field(default_factory=list)
    still_failing: list[tuple[str, str]] = field(default_factory=list)
    unchanged_count: int = 0
    skipped: list[tuple[str, str]] = field(default_factory=list)
    new: list[tuple[str, str]] = field(default_factory=list)
    identity_diff: dict[str, tuple[str, str]] = field(default_factory=dict)


def _entry_key(entry: dict[str, Any]) -> tuple[str, str]:
    return (entry["case_id"], entry["module"])


def _is_pass_like(verdict: str | None) -> bool:
    return verdict in _PASS_LIKE


def diff_runs(
    baseline_run_id: str,
    current_run_id: str,
    runs_dir: Path | None = None,
) -> DiffResult:
    """按 (case_id, module) 对齐两个 run,产出四分类 + skipped/new。

    跑 --modules / --case-limit 子集时,baseline 有而 current 没有的键归
    skipped 不计 regressed——否则跑子集会误报一片红,人会开始无视红色。
    """
    base_entries = load_results(baseline_run_id, runs_dir)
    curr_entries = load_results(current_run_id, runs_dir)
    base_map = {_entry_key(e): e for e in base_entries}
    curr_map = {_entry_key(e): e for e in curr_entries}

    result = DiffResult()
    for key, base in base_map.items():
        curr = curr_map.get(key)
        if curr is None:
            result.skipped.append(key)
            continue
        base_pass = _is_pass_like(base.get("verdict"))
        curr_pass = _is_pass_like(curr.get("verdict"))
        if base_pass and curr_pass:
            result.unchanged_count += 1
        elif base_pass and not curr_pass:
            result.regressed.append(key)
        elif not base_pass and curr_pass:
            result.fixed.append(key)
        else:
            result.still_failing.append(key)
    for key in curr_map:
        if key not in base_map:
            result.new.append(key)

    # 身份差异一并返回(UI 提示"本次对比跨了 model 变更"类混淆因素)
    base_meta = read_meta(baseline_run_id, runs_dir)
    curr_meta = read_meta(current_run_id, runs_dir)
    base_identity = base_meta.get("identity", {})
    curr_identity = curr_meta.get("identity", {})
    for dim in sorted(set(base_identity) | set(curr_identity)):
        b, c = base_identity.get(dim), curr_identity.get(dim)
        if b != c:
            result.identity_diff[dim] = (json.dumps(b, ensure_ascii=False,
                                                    sort_keys=True),
                                         json.dumps(c, ensure_ascii=False,
                                                    sort_keys=True))
    return result


# ---------- CLI(python -m evalkit.store) ----------

def _print_diff(result: DiffResult, baseline_run_id: str,
                current_run_id: str) -> None:
    print("=" * 64)
    print(f"diff: {current_run_id}(current) vs {baseline_run_id}(baseline)")
    if result.identity_diff:
        print("⚠️ run 身份有差异(混淆因素,退化可能是环境差异而非模板问题):")
        for dim, (b, c) in result.identity_diff.items():
            print(f"  {dim}: {b} → {c}")
    print(f"regressed: {len(result.regressed)}  fixed: {len(result.fixed)}  "
          f"still_failing: {len(result.still_failing)}  "
          f"unchanged: {result.unchanged_count}")
    if result.skipped:
        print(f"skipped: {len(result.skipped)}(current 子集未覆盖,不计退化)")
    if result.new:
        print(f"new: {len(result.new)}")
    for case_id, module in result.regressed:
        print(f"  REGRESSED  {case_id} / {module}")
    print("=" * 64)


def main() -> None:
    args = sys.argv[1:]
    runs_dir = RUNS_DIR
    try:
        if len(args) == 3 and args[0] == "--diff":
            result = diff_runs(args[1], args[2], runs_dir)
            _print_diff(result, args[1], args[2])
            sys.exit(1 if result.regressed else 0)
        if len(args) == 2 and args[0] == "--set-baseline":
            set_baseline(args[1], runs_dir)
            print(f"基线已设置: {args[1]}(runs/BASELINE)")
            sys.exit(0)
    except RuntimeError as e:
        print(f"ERROR: {e}")
        sys.exit(2)
    print("用法: python -m evalkit.store --diff <baseline> <current> | "
          "python -m evalkit.store --set-baseline <run_id>")
    sys.exit(2)


if __name__ == "__main__":
    main()
