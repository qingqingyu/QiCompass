"""章末反馈端点 + store 测试(POST /api/interpret/feedback,2026-11-15)。

锁三拍控件上报侧口径:
- schema:module 白名单(V1_MODULES 外 422)/ section snake_case / 语言枚举
- 端点幂等:同 (hash, module, IP, 日) 重复 → 200 且表内仍一行
- 版本/模型反查:interpretation_cache 同行命中 → 填充;miss → NULL(不拒)
- store:IP 日限三态(RECORDED / DUPLICATE / RATE_LIMITED)

客户端 fixture 自建(镜像 test_daily_ask_api.ask_client 范式:替换
chapter_feedback_store state,teardown 恢复)——不动共享 conftest。
"""

from __future__ import annotations

import sqlite3

import pytest

from app.ai.feedback_store import ChapterFeedbackStore, FeedbackOutcome


def _payload(**overrides):
    body = {
        "content_hash": "a" * 40,
        "module": "m0_structure",
        "verdict": "accurate",
        "section": None,
        "app_language": "zh",
    }
    body.update(overrides)
    return body


def _seed_cache_row(db_path: str, *, content_hash: str, module: str,
                    language: str = "zh", prompt_version: int = 13):
    """直接塞 interpretation_cache 行(不走业务封装,免依赖键计算)。"""
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            "INSERT INTO interpretation_cache "
            "(content_hash, module, prompt_version, target_date, prompt_hash, "
            " provider, model, parent_hash, user_input_hash, language, "
            " interpretation, generated_at) "
            "VALUES (?, ?, ?, '', 'ph', 'openai', 'glm-test', '', '', ?, "
            "        '{}', '2026-11-15T00:00:00+00:00')",
            (content_hash, module, prompt_version, language),
        )


@pytest.fixture
async def fb_client(tmp_path):
    """替换 chapter_feedback_store 的 ASGI client(隔离 + teardown 恢复)。"""
    from httpx import ASGITransport, AsyncClient

    from app.main import app

    db_path = str(tmp_path / "test_feedback.db")
    store = ChapterFeedbackStore(db_path, daily_ip_limit=100)
    store.init_schema()
    # 反查依赖 interpretation_cache 同库存在(表由 InterpretationCache 建)
    from app.ai.cache import InterpretationCache
    InterpretationCache(db_path).init_schema()

    saved = getattr(app.state, "chapter_feedback_store", None)
    app.state.chapter_feedback_store = store
    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            yield ac, db_path, store
    finally:
        app.state.chapter_feedback_store = saved


# ---------- schema ----------

async def test_schema_rejects_non_v1_module(fb_client):
    ac, _, _ = fb_client
    resp = await ac.post("/api/interpret/feedback",
                         json=_payload(module="bazi_deep"))
    assert resp.status_code == 422


async def test_schema_rejects_bad_section_pattern(fb_client):
    ac, _, _ = fb_client
    resp = await ac.post("/api/interpret/feedback",
                         json=_payload(section="主线"))
    assert resp.status_code == 422


async def test_schema_rejects_bad_language(fb_client):
    ac, _, _ = fb_client
    resp = await ac.post("/api/interpret/feedback",
                         json=_payload(app_language="fr"))
    assert resp.status_code == 422


# ---------- 端点行为 ----------

async def test_first_feedback_recorded(fb_client):
    ac, db_path, _ = fb_client
    resp = await ac.post("/api/interpret/feedback", json=_payload())
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}
    with sqlite3.connect(db_path) as conn:
        rows = conn.execute(
            "SELECT content_hash, module, verdict, section, app_language "
            "FROM chapter_feedback").fetchall()
    assert rows == [("a" * 40, "m0_structure", "accurate", "", "zh")]


async def test_duplicate_feedback_idempotent(fb_client):
    ac, db_path, _ = fb_client
    for _ in range(2):
        resp = await ac.post("/api/interpret/feedback", json=_payload())
        assert resp.status_code == 200
    with sqlite3.connect(db_path) as conn:
        count = conn.execute(
            "SELECT COUNT(*) FROM chapter_feedback").fetchone()[0]
    assert count == 1  # 幂等:重复回应相同,表内不重复落


async def test_meta_backfilled_from_cache_row(fb_client):
    ac, db_path, _ = fb_client
    _seed_cache_row(db_path, content_hash="a" * 40, module="m0_structure")
    await ac.post("/api/interpret/feedback", json=_payload())
    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            "SELECT prompt_version, provider, model FROM chapter_feedback"
        ).fetchone()
    assert row == (13, "openai", "glm-test")


async def test_meta_null_when_cache_row_missing(fb_client):
    ac, db_path, _ = fb_client
    # 缓存无行(用户读本地缓存、后端行已清)→ 反查 miss 落 NULL,不拒
    await ac.post("/api/interpret/feedback", json=_payload())
    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            "SELECT prompt_version, provider, model FROM chapter_feedback"
        ).fetchone()
    assert row == (None, None, None)


async def test_meta_falls_back_to_any_language_row(fb_client):
    """反查语言回落分支(2026-11-15 三查 R2):同 language 行 miss → 任意
    语言最新行——换语言阅读(展示语言无行、原文语言有行)时归因仍成立,
    与 store docstring「优先同 language 行;miss 再取任意语言最新行」锁定。
    """
    ac, db_path, _ = fb_client
    # 只有 zh 行;反馈自报 app_language=en(读的是 zh 原文回退展示)
    _seed_cache_row(db_path, content_hash="a" * 40, module="m0_structure",
                    language="zh")
    resp = await ac.post("/api/interpret/feedback", json=_payload(
        app_language="en"))
    assert resp.status_code == 200
    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            "SELECT prompt_version, provider, model, app_language "
            "FROM chapter_feedback").fetchone()
    # meta 取自 zh 行(回落),app_language 照记客户端自报的 en
    assert row == (13, "openai", "glm-test", "en")


async def test_inaccurate_with_section_recorded(fb_client):
    ac, db_path, _ = fb_client
    _seed_cache_row(db_path, content_hash="a" * 40, module="m0_structure",
                    language="zh-hant")
    resp = await ac.post("/api/interpret/feedback", json=_payload(
        verdict="inaccurate", section="core_loop", app_language="zh-hant"))
    assert resp.status_code == 200
    with sqlite3.connect(db_path) as conn:
        row = conn.execute(
            "SELECT verdict, section, app_language, prompt_version "
            "FROM chapter_feedback").fetchone()
    assert row == ("inaccurate", "core_loop", "zh-hant", 13)


# ---------- store 单元(日限) ----------

def _isolated_store(tmp_path, *, daily_ip_limit=100):
    """生产形态镜像:interpretation_cache 先建(main.py lifespan 顺序),
    反查才能命中/查空——单表孤库 = 生产不可达形态,不在测试里掩盖。"""
    from app.ai.cache import InterpretationCache

    db_path = str(tmp_path / "s.db")
    InterpretationCache(db_path).init_schema()
    store = ChapterFeedbackStore(db_path, daily_ip_limit=daily_ip_limit)
    store.init_schema()
    return store


def test_store_ip_daily_limit(tmp_path):
    store = _isolated_store(tmp_path, daily_ip_limit=2)
    for i in range(2):
        assert store.record(
            content_hash=f"h{i:040d}", module="m0_structure",
            verdict="accurate", section=None, app_language="zh",
            client_ip="1.2.3.4") == FeedbackOutcome.RECORDED
    # 第三条:不同盘不同章,同 IP 当日达限
    assert store.record(
        content_hash="b" * 40, module="m1_talent",
        verdict="accurate", section=None, app_language="zh",
        client_ip="1.2.3.4") == FeedbackOutcome.RATE_LIMITED
    # 其他 IP 不受影响
    assert store.record(
        content_hash="b" * 40, module="m0_structure",
        verdict="accurate", section=None, app_language="zh",
        client_ip="5.6.7.8") == FeedbackOutcome.RECORDED


def test_store_duplicate_same_hash_module_ip(tmp_path):
    store = _isolated_store(tmp_path)
    kwargs = dict(
        content_hash="a" * 40, module="m0_structure", verdict="accurate",
        section=None, app_language="zh", client_ip="1.2.3.4")
    assert store.record(**kwargs) == FeedbackOutcome.RECORDED
    assert store.record(**kwargs) == FeedbackOutcome.DUPLICATE


def test_store_concurrent_same_key_single_row(tmp_path):
    """并发竞态回归(三查 #2):绕过 SELECT 闸的窗口由唯一索引关死。

    N 个线程同时 record 同键(同 IP 同日),断言恰好一行 RECORDED、
    其余全 DUPLICATE——无双行。
    """
    from concurrent.futures import ThreadPoolExecutor

    store = _isolated_store(tmp_path)
    kwargs = dict(
        content_hash="a" * 40, module="m0_structure", verdict="accurate",
        section=None, app_language="zh", client_ip="9.9.9.9")

    with ThreadPoolExecutor(max_workers=8) as pool:
        outcomes = list(pool.map(
            lambda _: store.record(**kwargs), range(16)))

    assert outcomes.count(FeedbackOutcome.RECORDED) == 1
    assert outcomes.count(FeedbackOutcome.DUPLICATE) == 15
