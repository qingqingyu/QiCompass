"""evalkit server 单测(S06)。FastAPI TestClient,零真实 API 调用。

POST /api/runs 的后台执行用 monkeypatch 替换 execute_run,
不真跑生成链路。
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from evalkit import server
from evalkit.store import write_meta


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(server, "_RUNS_DIR", tmp_path)
    return TestClient(server.app)


def _seed_run(runs_dir: Path, run_id: str, entries, identity=None):
    run_dir = runs_dir / run_id
    run_dir.mkdir(parents=True)
    with open(run_dir / "results.jsonl", "w", encoding="utf-8") as f:
        for e in entries:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    write_meta(run_dir, {
        "run_id": run_id, "dry_run": False, "case_count": 1,
        "counts": {"total": len(entries), "pass": len(entries),
                   "warn": 0, "fail": 0, "error": 0},
        "api_calls": len(entries), "cache_hits": 0, "elapsed_ms": 1.0,
        "started_at": "2026-08-18T00:00:00+00:00",
        "identity": identity or {
            "provider": "stub", "model": "stub-m",
            "rubric_version": 1, "judge_model": "judge-m",
            "cases_hash": "x", "prompt_versions": {"m0_structure": 1},
        },
    })
    # 逐模块产物(详情接口)
    for e in entries:
        module_dir = run_dir / e["case_id"] / e["module"]
        module_dir.mkdir(parents=True)
        (module_dir / "prompt.txt").write_text("prompt 内容", encoding="utf-8")
        (module_dir / "response.json").write_text(
            json.dumps({"ok": True}, ensure_ascii=False), encoding="utf-8")
    return run_dir


def _entry(case, module, verdict="pass"):
    return {"case_id": case, "module": module, "verdict": verdict,
            "l1": {"passed": True, "failures": []},
            "l2": {"passed": True, "failures": []}, "l3": None,
            "cached": False, "elapsed_ms": 1.0, "error": None}


# ===== GET 端点 =====


def test_index_served(client):
    res = client.get("/")
    assert res.status_code == 200
    assert "evalkit" in res.text
    # 零外部资源(断网可用):无 CDN / Google Fonts 引用
    assert "http://" not in res.text and "https://" not in res.text


def test_list_runs(client, tmp_path):
    _seed_run(tmp_path, "run-a", [_entry("case_00", "m0_structure")])
    _seed_run(tmp_path, "run-b", [_entry("case_00", "m0_structure")])
    (tmp_path / "BASELINE").write_text("run-a\n", encoding="utf-8")
    res = client.get("/api/runs")
    assert res.status_code == 200
    runs = res.json()
    assert [r["run_id"] for r in runs] == ["run-b", "run-a"]  # 倒序
    assert runs[1]["is_baseline"] is True
    assert runs[1]["model"] == "stub-m"


def test_get_run_returns_meta_and_results(client, tmp_path):
    _seed_run(tmp_path, "run-a", [_entry("case_00", "m0_structure")])
    res = client.get("/api/runs/run-a")
    assert res.status_code == 200
    body = res.json()
    assert body["meta"]["run_id"] == "run-a"
    assert body["results"][0]["module"] == "m0_structure"


def test_get_run_404_for_missing(client):
    res = client.get("/api/runs/ghost")
    assert res.status_code == 404


def test_diff_endpoint(client, tmp_path):
    _seed_run(tmp_path, "base", [_entry("case_00", "m0_structure", "pass"),
                                 _entry("case_01", "m0_structure", "pass")])
    _seed_run(tmp_path, "curr", [_entry("case_00", "m0_structure", "fail"),
                                 _entry("case_01", "m0_structure", "pass")])
    (tmp_path / "BASELINE").write_text("base\n", encoding="utf-8")
    res = client.get("/api/runs/curr/diff")
    assert res.status_code == 200
    body = res.json()
    assert body["regressed"] == [["case_00", "m0_structure"]]
    assert body["fixed"] == []


def test_diff_requires_baseline(client, tmp_path):
    _seed_run(tmp_path, "curr", [_entry("case_00", "m0_structure")])
    res = client.get("/api/runs/curr/diff")
    assert res.status_code == 404
    assert "基线" in res.json()["detail"]


def test_case_module_detail(client, tmp_path):
    _seed_run(tmp_path, "run-a", [_entry("case_00", "m0_structure")])
    res = client.get("/api/cases/case_00/m0_structure?run=run-a")
    assert res.status_code == 200
    body = res.json()
    assert body["prompt"] == "prompt 内容"
    assert body["response"] == {"ok": True}
    assert body["entry"]["verdict"] == "pass"


def test_case_module_detail_404(client, tmp_path):
    _seed_run(tmp_path, "run-a", [_entry("case_00", "m0_structure")])
    res = client.get("/api/cases/case_00/m7_manual?run=run-a")
    assert res.status_code == 404


# ===== POST 端点 =====


def test_post_baseline(client, tmp_path):
    _seed_run(tmp_path, "run-a", [_entry("case_00", "m0_structure")])
    res = client.post("/api/baseline", json={"run_id": "run-a"})
    assert res.status_code == 200
    assert (tmp_path / "BASELINE").read_text(encoding="utf-8").strip() == "run-a"


def test_post_baseline_invalid_run_400(client):
    res = client.post("/api/baseline", json={"run_id": "ghost"})
    assert res.status_code == 400


def test_post_run_409_when_active(client, monkeypatch):
    monkeypatch.setattr(server._run_state, "active_run_id", "busy-run")
    res = client.post("/api/runs", json={})
    assert res.status_code == 409
    assert "已有 run 在跑" in res.json()["detail"]


def test_post_run_bad_modules_400(client):
    res = client.post("/api/runs", json={"modules": ["m1_talent"]})
    assert res.status_code == 400  # 缺上游 M0
    assert "缺上游" in res.json()["detail"]


def test_post_run_executes_background_and_updates_progress(
        client, tmp_path, monkeypatch):
    async def _fake_execute_run(**kwargs):
        progress_cb = kwargs.get("progress_cb")
        if progress_cb:
            progress_cb(case_id="case_00", done=8, total=160)
        _seed_run(tmp_path, "bg-run", [_entry("case_00", "m0_structure")])
        return {"run_id": "bg-run"}

    monkeypatch.setattr(server, "execute_run", _fake_execute_run)
    res = client.post("/api/runs", json={})
    assert res.status_code == 200
    # BackgroundTasks 在响应后同步执行(TestClient);run 已落盘,锁已释放
    assert (tmp_path / "bg-run" / "results.jsonl").exists()
    assert server._run_state.active_run_id is None
    progress = client.get("/api/runs/progress").json()
    assert progress["running"] is False


def test_progress_endpoint_shape(client):
    body = client.get("/api/runs/progress").json()
    assert set(body) >= {"running", "run_id", "case_id", "done", "total"}


def test_post_run_case_limit_zero_422(client):
    """case_limit ≤ 0 由 pydantic ge=1 拦截(422),不静默烧满 20 盘。"""
    res = client.post("/api/runs", json={"case_limit": 0})
    assert res.status_code == 422
    res = client.post("/api/runs", json={"case_limit": -3})
    assert res.status_code == 422


def test_path_traversal_run_id_rejected(client, tmp_path):
    """run_id/case_id 白名单:防路径拼接越出 runs 目录(本地工具,纵深防御)。"""
    assert client.get("/api/runs/%2e%2e").status_code == 400
    assert client.get("/api/runs/..%2Fetc%2Fpasswd").status_code in (400, 404)
    assert client.post("/api/baseline",
                       json={"run_id": "../outside"}).status_code == 400
    _seed_run(tmp_path, "run-a", [_entry("case_00", "m0_structure")])
    assert client.get(
        "/api/cases/case_00/m0_structure?run=run-a").status_code == 200
    # httpx 客户端侧会规范化 ../(404);服务端正则对不规范的客户端 400——两者都是防御
    assert client.get(
        "/api/cases/..%2Fx/m0_structure?run=run-a").status_code in (400, 404)


def test_list_runs_orders_by_started_at(client, tmp_path):
    """列表按 started_at 倒序(同秒 tie 名字倒序),新 run 置顶。"""
    _seed_run(tmp_path, "run-old", [_entry("c", "m0_structure")])
    # 造一个 started_at 更新的 run
    import json as _json
    meta_path = tmp_path / "run-new"
    _seed_run(tmp_path, "run-new", [_entry("c", "m0_structure")])
    meta = _json.loads((meta_path / "meta.json").read_text(encoding="utf-8"))
    meta["started_at"] = "2026-08-18T23:59:59+00:00"
    (meta_path / "meta.json").write_text(
        _json.dumps(meta, ensure_ascii=False), encoding="utf-8")
    runs = client.get("/api/runs").json()
    assert [r["run_id"] for r in runs][:2] == ["run-new", "run-old"]


def test_list_runs_degrades_on_corrupt_meta(client, tmp_path):
    """单个 run 的 meta.json 损坏:列表降级为占位条目,不 500。"""
    _seed_run(tmp_path, "run-good", [_entry("c", "m0_structure")])
    bad_dir = tmp_path / "run-bad"
    bad_dir.mkdir()
    (bad_dir / "meta.json").write_text("{不是 json", encoding="utf-8")
    res = client.get("/api/runs")
    assert res.status_code == 200
    runs = res.json()
    ids = [r["run_id"] for r in runs]
    assert "run-good" in ids and "run-bad" in ids
    bad_entry = next(r for r in runs if r["run_id"] == "run-bad")
    assert "meta 损坏" in bad_entry["error"]


def test_corrupt_meta_detail_returns_explicit_404(client, tmp_path):
    """损坏 meta 的 run:详情端点显式 404 + 指明文件损坏(不是裸 500)。"""
    bad_dir = tmp_path / "run-bad"
    bad_dir.mkdir()
    (bad_dir / "meta.json").write_text("{不是 json", encoding="utf-8")
    res = client.get("/api/runs/run-bad")
    assert res.status_code == 404
    assert "meta.json 损坏" in res.json()["detail"]


def test_diff_baseline_dangling_returns_explicit_404(client, tmp_path):
    """BASELINE 指向不存在的 run:diff 端点显式 404 带原因(不是裸 500)。"""
    _seed_run(tmp_path, "run-a", [_entry("case_00", "m0_structure")])
    (tmp_path / "BASELINE").write_text("ghost-run\n", encoding="utf-8")
    res = client.get("/api/runs/run-a/diff")
    assert res.status_code == 404
    assert "指向不存在" in res.json()["detail"]


def test_corrupt_results_jsonl_returns_explicit_404(client, tmp_path):
    """meta 完好但 results.jsonl 损坏:详情端点显式 404 带行号(不是裸 500)。"""
    run_dir = _seed_run(tmp_path, "run-x", [_entry("c", "m0")])
    (run_dir / "results.jsonl").write_text("{坏行\n", encoding="utf-8")
    res = client.get("/api/runs/run-x")
    assert res.status_code == 404
    assert "results.jsonl" in res.json()["detail"]
