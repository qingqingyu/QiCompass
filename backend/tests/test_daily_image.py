"""每日运势插画端点测试(S2:状态缓存 + 生图端点)。

覆盖:
- miss → POST 派发(generating)→ 后台 Mock 生图 → ready → GET bytes
- ready 命中 → POST 不重派(idempotent)
- 失败 → status=failed → GET 409 透出 error_message
- 僵尸 generating(超 STALE_SECONDS)→ GET 409 可重派
- singleflight:同 key 并发只调一次 generate
- 当日上限 → 429 显式
- key 未配置 → 503(AIProviderError 显式)
- image_cache 单元:get/get_latest/count/upsert/文件往返
"""

from __future__ import annotations

import asyncio
import sqlite3
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient

from app.ai.image_cache import (
    STATUS_FAILED,
    STATUS_GENERATING,
    STATUS_READY,
    DailyImageCache,
)
from app.ai.image_client import ImageGenClient
from app.ai.singleflight import SingleflightCoalescer
from app.api import daily_image as daily_image_api
from app.errors import AIProviderError, InvalidInputError
from app.main import app
from app.models.daily_fortune import ChartPayload, PillarRef

TARGET = date(2026, 8, 30)  # 丙子日(与 V4 样图同日)
CHART = ChartPayload(
    day_master="己",
    day_master_element="earth",
    day_master_strength="weak",
    favorable_elements=["火", "土"],
    unfavorable_elements=["水", "金"],
    four_pillars={
        "year": PillarRef(gan="庚", zhi="午"),
        "month": PillarRef(gan="己", zhi="卯"),
        "day": PillarRef(gan="己", zhi="卯"),
        "hour": PillarRef(gan="辛", zhi="未"),
    },
)


def _request(chart_hash: str = "img_hash_001") -> dict:
    return {
        "chart_hash": chart_hash,
        "target_date": TARGET.isoformat(),
        "chart_payload": CHART.model_dump(),
    }


class StubImageClient:
    """生图 Mock:可编程延迟/返回/失败,带调用计数(singleflight 验证)。"""

    def __init__(self, *, png: bytes = b"\x89PNG-stub", delay: float = 0.0,
                 error: Exception | None = None):
        self.png = png
        self.delay = delay
        self.error = error
        self.calls = 0

    async def generate(self, prompt: str, *, timeout: float | None = None) -> bytes:
        self.calls += 1
        if self.delay:
            await asyncio.sleep(self.delay)
        if self.error is not None:
            raise self.error
        return self.png


@pytest.fixture
def cache(tmp_path: Path) -> DailyImageCache:
    c = DailyImageCache(str(tmp_path / "t.db"), images_dir=tmp_path / "images")
    c.init_schema()
    return c


@pytest.fixture
def wired(cache: DailyImageCache):
    """挂隔离 cache 到 app.state(测完还原,不污染模块默认实例)。"""
    saved = (
        app.state.daily_image_cache, app.state.image_client,
        app.state.image_singleflight,
    )
    stub = StubImageClient()
    app.state.daily_image_cache = cache
    app.state.image_client = stub  # type: ignore[assignment]
    app.state.image_singleflight = SingleflightCoalescer()
    yield stub
    (app.state.daily_image_cache, app.state.image_client,
     app.state.image_singleflight) = saved


# ===== image_cache 单元 =====


def test_cache_roundtrip_and_file(cache: DailyImageCache):
    row = cache.get("h", "2026-08-30", 1)
    assert row is None
    cache.upsert("h", "2026-08-30", 1, STATUS_GENERATING, prompt_hash="p1")
    assert cache.get("h", "2026-08-30", 1)["status"] == STATUS_GENERATING

    path = cache.save_image("h", "2026-08-30", b"pngbytes")
    assert cache.load_image(path) == b"pngbytes"
    # save 返回文件名,文件落在 images_dir 内(cwd 无关)
    assert (cache._images_dir / path).exists()  # noqa: SLF001

    cache.upsert("h", "2026-08-30", 1, STATUS_READY, image_path=path)
    assert cache.get("h", "2026-08-30", 1)["status"] == STATUS_READY


def test_get_latest_prefers_newest_version(cache: DailyImageCache):
    cache.upsert("h", "2026-08-30", 1, STATUS_FAILED)
    cache.upsert("h", "2026-08-30", 2, STATUS_GENERATING)
    assert cache.get_latest("h", "2026-08-30")["status"] == STATUS_GENERATING


def test_count_excludes_failed(cache: DailyImageCache):
    cache.upsert("a", "2026-08-30", 1, STATUS_GENERATING)
    cache.upsert("b", "2026-08-30", 1, STATUS_READY)
    cache.upsert("c", "2026-08-30", 1, STATUS_FAILED)
    cache.upsert("d", "2026-08-29", 1, STATUS_READY)  # 别日不计
    assert cache.count_generated_today("2026-08-30") == 2


def test_save_image_rejects_path_traversal(cache: DailyImageCache):
    """chart_hash 无格式约束(客户端自由串),进文件名前汇点守卫拒穿越。"""
    with pytest.raises(InvalidInputError):
        cache.save_image("../evil", "2026-08-30", b"x")
    with pytest.raises(InvalidInputError):
        cache.save_image("a/b", "2026-08-30", b"x")
    # 正常 hash 落盘且文件确在 images 目录内
    rel = cache.save_image("img_hash_001", "2026-08-30", b"png")
    assert "/" not in rel
    assert (cache._images_dir / rel).exists()  # noqa: SLF001


def test_get_latest_returns_prompt_version_for_delete(cache: DailyImageCache):
    cache.upsert("h", "2026-08-30", 1, STATUS_FAILED)
    cache.upsert("h", "2026-08-30", 2, STATUS_READY)
    row = cache.get_latest("h", "2026-08-30")
    assert row is not None and row["prompt_version"] == 2
    cache.delete("h", "2026-08-30", 2)
    after = cache.get_latest("h", "2026-08-30")
    assert after is not None and after["prompt_version"] == 1


# ===== 端点 =====


async def test_full_flow_miss_to_ready(wired: StubImageClient, cache: DailyImageCache):
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        # miss → 派发;BackgroundTasks 在响应后由 ASGITransport 执行完
        r1 = await ac.post("/api/bazi/daily-fortune/image", json=_request())
        assert r1.status_code == 200
        assert r1.json()["status"] == STATUS_GENERATING
        assert wired.calls == 1

        # 生成完成 → ready
        r2 = await ac.post("/api/bazi/daily-fortune/image", json=_request())
        assert r2.json()["status"] == STATUS_READY
        assert wired.calls == 1  # ready 命中不重派

        # 取图 → 200 png bytes
        r3 = await ac.get("/api/bazi/daily-fortune/image/content", params={
            "chart_hash": "img_hash_001", "target_date": TARGET.isoformat(),
        })
        assert r3.status_code == 200
        assert r3.headers["content-type"] == "image/png"
        assert r3.content == wired.png


async def test_failed_returns_409_with_error(cache: DailyImageCache):
    saved = (app.state.daily_image_cache, app.state.image_client,
             app.state.image_singleflight)
    stub = StubImageClient(error=AIProviderError("upstream 500"))
    app.state.daily_image_cache = cache
    app.state.image_client = stub  # type: ignore[assignment]
    app.state.image_singleflight = SingleflightCoalescer()
    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            await ac.post("/api/bazi/daily-fortune/image", json=_request())
            r = await ac.get("/api/bazi/daily-fortune/image/content", params={
                "chart_hash": "img_hash_001", "target_date": TARGET.isoformat(),
            })
            assert r.status_code == 409
            assert r.json()["status"] == STATUS_FAILED
            assert "upstream 500" in r.json()["error"]
    finally:
        (app.state.daily_image_cache, app.state.image_client,
         app.state.image_singleflight) = saved


async def test_stale_generating_409(wired, cache: DailyImageCache):
    """僵尸 generating(更新时间超 STALE)→ 409,客户端可重 POST。"""
    stale = (datetime.now(timezone.utc) - timedelta(seconds=301)).isoformat()
    cache.upsert("img_hash_001", TARGET.isoformat(), 1, STATUS_GENERATING)
    # 直接改 updated_at 模拟超时(写库后手工置旧)
    with sqlite3.connect(cache._db_path) as conn:  # noqa: SLF001 测试触内部可接受
        conn.execute(
            "UPDATE daily_image_cache SET updated_at=? "
            "WHERE content_hash='img_hash_001'",
            (stale,),
        )
        conn.commit()
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        r = await ac.get("/api/bazi/daily-fortune/image/content", params={
            "chart_hash": "img_hash_001", "target_date": TARGET.isoformat(),
        })
        assert r.status_code == 409
        assert "stale" in r.json()["error"]


async def test_fresh_generating_202(wired, cache: DailyImageCache):
    cache.upsert("img_hash_001", TARGET.isoformat(), 1, STATUS_GENERATING)
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        r = await ac.get("/api/bazi/daily-fortune/image/content", params={
            "chart_hash": "img_hash_001", "target_date": TARGET.isoformat(),
        })
        assert r.status_code == 202
        assert r.json()["status"] == STATUS_GENERATING


async def test_traversal_chart_hash_rejected_422(wired, cache: DailyImageCache):
    """chart_hash 含路径分隔符 → 入口 422 fail-fast(不派发生成)。"""
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        r = await ac.post("/api/bazi/daily-fortune/image", json=_request(
            chart_hash="../evil",
        ))
        assert r.status_code == 422
        assert r.json()["error"]["code"] == "INVALID_INPUT"
        assert wired.calls == 0  # 未派发
        assert cache.get("../evil", TARGET.isoformat(), 1) is None  # 未占行


async def test_ready_row_file_missing_heals_404(
        wired, cache: DailyImageCache):
    """ready 行但图文件丢失(部署卷分离/外部清理)→ 删行自愈 → 404。"""
    cache.upsert("img_hash_001", TARGET.isoformat(), 1, STATUS_READY,
                 image_path=str(cache._images_dir / "ghost.png"))
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        r = await ac.get("/api/bazi/daily-fortune/image/content", params={
            "chart_hash": "img_hash_001", "target_date": TARGET.isoformat(),
        })
        assert r.status_code == 404
        assert r.json()["status"] == "missing"
    # 行已删:客户端重 POST 走 miss → 重生成
    assert cache.get("img_hash_001", TARGET.isoformat(), 1) is None


async def test_garbage_updated_at_treated_stale(wired, cache: DailyImageCache):
    """updated_at 不可解析(理论不可达,防御)→ 判 stale(409 可重派)非 202。"""
    cache.upsert("img_hash_001", TARGET.isoformat(), 1, STATUS_GENERATING)
    with sqlite3.connect(cache._db_path) as conn:  # noqa: SLF001
        conn.execute(
            "UPDATE daily_image_cache SET updated_at='garbage' "
            "WHERE content_hash='img_hash_001'",
        )
        conn.commit()
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        r = await ac.get("/api/bazi/daily-fortune/image/content", params={
            "chart_hash": "img_hash_001", "target_date": TARGET.isoformat(),
        })
        assert r.status_code == 409
        assert "stale" in r.json()["error"]


async def test_missing_row_404(wired, cache: DailyImageCache):
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        r = await ac.get("/api/bazi/daily-fortune/image/content", params={
            "chart_hash": "nobody", "target_date": TARGET.isoformat(),
        })
        assert r.status_code == 404


async def test_singleflight_dedupes_concurrent(wired: StubImageClient,
                                               cache: DailyImageCache):
    """同 key 并发 POST:后台生图只发生一次(singleflight + DB 行双闸)。"""
    wired.delay = 0.2
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        rs = await asyncio.gather(
            ac.post("/api/bazi/daily-fortune/image", json=_request()),
            ac.post("/api/bazi/daily-fortune/image", json=_request()),
        )
        statuses = {r.json()["status"] for r in rs}
        # 两个都非 5xx;首个 miss 派发,第二个要么 generating 命中行,
        # 要么经 singleflight 合并(await 同一 task)
        assert statuses <= {STATUS_GENERATING, STATUS_READY}
        # 等合并 task 收尾再断言调用数
        await asyncio.sleep(0.05)
        assert wired.calls == 1


async def test_daily_limit_429(cache: DailyImageCache):
    saved = (app.state.daily_image_cache, app.state.image_client,
             app.state.image_singleflight)
    saved_limit = daily_image_api.DAILY_IMAGE_LIMIT
    daily_image_api.DAILY_IMAGE_LIMIT = 1  # monkeypatch 上限=1
    try:
        # 已有一行 generating(占满配额)
        cache.upsert("other_user", TARGET.isoformat(), 1, STATUS_GENERATING)
        app.state.daily_image_cache = cache
        app.state.image_client = StubImageClient()  # type: ignore[assignment]
        app.state.image_singleflight = SingleflightCoalescer()
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            r = await ac.post("/api/bazi/daily-fortune/image", json=_request())
            assert r.status_code == 429
            assert r.json()["error"]["code"] == "DAILY_IMAGE_LIMIT"
    finally:
        daily_image_api.DAILY_IMAGE_LIMIT = saved_limit
        (app.state.daily_image_cache, app.state.image_client,
         app.state.image_singleflight) = saved


async def test_image_client_unconfigured_503(wired, cache: DailyImageCache):
    """key/base 未配置 → 后台生图抛 AIProviderError → 落 failed → GET 409。

    验证「缺失显式 503 语义」在端点链路里可观察(不是静默空图)。
    """
    saved = (app.state.daily_image_cache, app.state.image_client,
             app.state.image_singleflight)
    app.state.daily_image_cache = cache
    app.state.image_client = ImageGenClient(api_key=None, base_url="")  # type: ignore[assignment]
    app.state.image_singleflight = SingleflightCoalescer()
    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            await ac.post("/api/bazi/daily-fortune/image", json=_request())
            r = await ac.get("/api/bazi/daily-fortune/image/content", params={
                "chart_hash": "img_hash_001", "target_date": TARGET.isoformat(),
            })
            assert r.status_code == 409
            assert "IMAGE_API" in r.json()["error"]
    finally:
        (app.state.daily_image_cache, app.state.image_client,
         app.state.image_singleflight) = saved
