"""evalkit 本地 Web UI 服务(S06)。

三条铁律(与设计决策 Q2 对齐):
1. **只监听 127.0.0.1**——本地工具,绝不绑定 0.0.0.0
2. **无鉴权**——本地信任边界,不加用户体系
3. **不进生产镜像**——独立于 app.main,部署产物不含 evalkit/

启动:
    cd backend && ./eval.sh
    # 或: .venv/bin/uvicorn evalkit.server:app --host 127.0.0.1 --port 8899
"""

from __future__ import annotations

import asyncio
import json
import threading
from pathlib import Path
from typing import Any

from fastapi import BackgroundTasks, FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel

from . import store
from .runner import V1_MODULES, execute_run, resolve_selected_modules

app = FastAPI(title="evalkit", version="1")

STATIC_DIR = Path(__file__).parent / "static"

# 测试可通过 monkeypatch 本变量注入 tmp runs 目录
_RUNS_DIR: Path = store.RUNS_DIR


class _RunState:
    """单进程内存状态:同时只允许一个 run 在跑(409),进度供轮询。"""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.active_run_id: str | None = None
        self.progress: dict[str, Any] = {
            "running": False, "run_id": None,
            "case_id": None, "done": 0, "total": 0,
        }

    def try_start(self, run_id: str) -> bool:
        with self.lock:
            if self.active_run_id is not None:
                return False
            self.active_run_id = run_id
            self.progress = {
                "running": True, "run_id": run_id,
                "case_id": None, "done": 0, "total": 0,
            }
            return True

    def finish(self, run_id: str) -> None:
        with self.lock:
            if self.active_run_id == run_id:
                self.active_run_id = None
                self.progress["running"] = False

    def update(self, *, case_id: str, done: int, total: int) -> None:
        with self.lock:
            self.progress["case_id"] = case_id
            self.progress["done"] = done
            self.progress["total"] = total


_run_state = _RunState()


# ---------- 模型 ----------

class RunRequest(BaseModel):
    modules: list[str] | None = None
    case_limit: int | None = None
    no_cache: bool = False
    skip_judge: bool = False


class BaselineRequest(BaseModel):
    run_id: str


# ---------- 静态页 ----------

@app.get("/", include_in_schema=False)
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


# ---------- API ----------

def _require_run(run_id: str) -> dict[str, Any]:
    try:
        meta = store.read_meta(run_id, _RUNS_DIR)
    except RuntimeError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    return meta


@app.get("/api/runs")
def list_runs() -> list[dict[str, Any]]:
    try:
        baseline = store.read_baseline(_RUNS_DIR)
    except RuntimeError:
        baseline = None  # BASELINE 悬空时列表仍可用(详情页会显式报错)
    runs = []
    for run_id in store.list_runs(_RUNS_DIR):
        meta = store.read_meta(run_id, _RUNS_DIR)
        identity = meta.get("identity", {})
        runs.append({
            "run_id": run_id,
            "provider": identity.get("provider"),
            "model": identity.get("model"),
            "judge_model": identity.get("judge_model") or None,
            "rubric_version": identity.get("rubric_version", 0),
            "dry_run": meta.get("dry_run", False),
            "case_count": meta.get("case_count"),
            "counts": meta.get("counts"),
            "started_at": meta.get("started_at"),
            "cache_hits": meta.get("cache_hits"),
            "api_calls": meta.get("api_calls"),
            "is_baseline": run_id == baseline,
        })
    return runs


@app.get("/api/runs/progress")
def get_progress() -> dict[str, Any]:
    return _run_state.progress


@app.get("/api/runs/{run_id}")
def get_run(run_id: str) -> dict[str, Any]:
    meta = _require_run(run_id)
    entries = store.load_results(run_id, _RUNS_DIR)
    return {"meta": meta, "results": entries}


@app.get("/api/runs/{run_id}/diff")
def get_diff(run_id: str, baseline: str | None = None) -> dict[str, Any]:
    _require_run(run_id)
    baseline = baseline or store.read_baseline(_RUNS_DIR)
    if baseline is None:
        raise HTTPException(status_code=404, detail="未设置基线"
                                               "(POST /api/baseline 先设)")
    if baseline == run_id:
        raise HTTPException(status_code=400,
                            detail="baseline 与 current 是同一个 run")
    try:
        result = store.diff_runs(baseline, run_id, _RUNS_DIR)
    except RuntimeError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    return {
        "baseline": baseline,
        "current": run_id,
        "regressed": [list(k) for k in result.regressed],
        "fixed": [list(k) for k in result.fixed],
        "still_failing": [list(k) for k in result.still_failing],
        "unchanged": result.unchanged_count,
        "skipped": [list(k) for k in result.skipped],
        "new": [list(k) for k in result.new],
        "identity_diff": result.identity_diff,
    }


@app.get("/api/cases/{case_id}/{module}")
def get_case_module(case_id: str, module: str, run: str) -> dict[str, Any]:
    _require_run(run)
    run_dir = store.run_dir_for(run, _RUNS_DIR)
    module_dir = run_dir / case_id / module
    entry = None
    for e in store.load_results(run, _RUNS_DIR):
        if e["case_id"] == case_id and e["module"] == module:
            entry = e
            break
    if entry is None:
        raise HTTPException(
            status_code=404, detail=f"{run} 中没有 {case_id}/{module}")

    prompt = None
    response = None
    prompt_path = module_dir / "prompt.txt"
    response_path = module_dir / "response.json"
    if prompt_path.exists():
        prompt = prompt_path.read_text(encoding="utf-8")
    if response_path.exists():
        try:
            response = json.loads(response_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            response = {"_raw": response_path.read_text(encoding="utf-8")}
    return {"entry": entry, "prompt": prompt, "response": response}


@app.post("/api/runs")
def post_run(req: RunRequest, background: BackgroundTasks) -> dict[str, Any]:
    try:
        resolve_selected_modules(req.modules)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    placeholder = "pending"
    if not _run_state.try_start(placeholder):
        raise HTTPException(
            status_code=409,
            detail=f"已有 run 在跑({_run_state.active_run_id}),"
                   f"等它完成再触发(不并发烧钱)")

    background.add_task(_run_background, req)
    return {"status": "started"}


async def _run_background(req: RunRequest) -> None:
    """后台执行 run;失败显式记录,不留半开锁。"""
    run_id_holder = {"id": None}
    try:
        def _progress(case_id: str, done: int, total: int) -> None:
            _run_state.update(case_id=case_id, done=done, total=total)

        summary = await execute_run(
            modules=req.modules,
            case_limit=req.case_limit,
            no_cache=req.no_cache,
            skip_judge=req.skip_judge,
            runs_dir=_RUNS_DIR,
            progress_cb=_progress,
        )
        run_id_holder["id"] = summary["run_id"]
    finally:
        _run_state.finish(_run_state.active_run_id or "unknown")


@app.post("/api/baseline")
def post_baseline(req: BaselineRequest) -> dict[str, Any]:
    try:
        store.set_baseline(req.run_id, _RUNS_DIR)
    except RuntimeError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    return {"baseline": req.run_id}
