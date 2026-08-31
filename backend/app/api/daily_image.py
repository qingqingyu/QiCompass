"""每日运势插画端点(S2,2026-08-30「一幅图」)。

- POST /api/bazi/daily-fortune/image:触发/查询生成状态。
  服务端重算确定性流日数据(免信客户端)→ image_prompt 拼装 → 查缓存:
  ready 直返;generating 且未 stale 返 generating;miss/failed/stale 派发
  BackgroundTasks 后台生成(gpt-image-2 实测 63-181s,不能同步等)。
- GET /api/bazi/daily-fortune/image/content?chart_hash&target_date:
  ready → 200 image/png bytes(行在文件丢失 → 删行自愈 404,客户端重 POST
  重生成);generating → 202;failed/stale → 409;无行 → 404(先 POST)。

并发与护栏:
- 进程内 singleflight(SingleflightCoalescer)合并同 key 并发生成;
  DB generating 行挡住「轮询期间重复 POST」(响应已返回,后台未完成)。
- generating 超 STALE_SECONDS(300s > 实测 181s 上界)判僵尸,可重派。
- 当日全局发起量(generating+ready)达 DAILY_IMAGE_LIMIT → 429 显式。

错误显式传播:引擎/缓存/上游失败全部上抛或落 status=failed(GET 409
透出 error_message),不静默降级。
"""

from __future__ import annotations

import hashlib
import logging
import time
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, BackgroundTasks, Request
from fastapi.responses import JSONResponse, Response
from starlette.concurrency import run_in_threadpool

from ..ai.image_cache import (
    STATUS_FAILED,
    STATUS_GENERATING,
    STATUS_READY,
    DailyImageCache,
)
from ..ai.image_client import ImageGenClient
from ..ai.image_prompt import build_image_prompt
from ..ai.prompts import PROMPT_VERSIONS
from ..ai.singleflight import SingleflightCoalescer
from ..config import DAILY_IMAGE_LIMIT
from ..engine.daily_fortune import compute_daily_fortune
from ..errors import AIProviderError, DailyImageLimitError, InvalidInputError
from ..models.daily_fortune import DailyFortuneRequest

router = APIRouter()
logger = logging.getLogger(__name__)

# generating 僵尸判定:实测生图 63-181s,300s 仍未 ready 视为进程重启残留
STALE_SECONDS = 300.0


@router.post("/api/bazi/daily-fortune/image")
async def trigger_daily_image(
    req: DailyFortuneRequest,
    request: Request,
    background_tasks: BackgroundTasks,
) -> JSONResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    # 0) chart_hash 会进图文件名(save_image),入口先拒路径分隔符
    #    (fail-fast 422;save_image 汇点另有守卫作 defense-in-depth)
    if "/" in req.chart_hash or "\\" in req.chart_hash:
        raise InvalidInputError(
            f"chart_hash 含路径分隔符(非法缓存键): {req.chart_hash!r}",
        )

    # 1) 重算确定性流日数据(与 /daily-fortune 同源,免信客户端拼 prompt)
    fortune = await run_in_threadpool(
        compute_daily_fortune,
        chart_hash=req.chart_hash,
        target_date=req.target_date,
        chart_payload=req.chart_payload,
    )

    # 2) 确定性 prompt + 身份三元组
    day_gan, day_zhi = fortune.day_pillar[0], fortune.day_pillar[1]
    prompt = build_image_prompt(
        day_gan, day_zhi,
        fortune.day_relation_to_day_master, fortune.huangli_yi,
    )
    prompt_hash = hashlib.sha256(prompt.encode()).hexdigest()
    version = PROMPT_VERSIONS["daily_fortune_image"]
    target_date = req.target_date.isoformat()

    cache: DailyImageCache = request.app.state.daily_image_cache

    # 3) 查缓存:ready / 新鲜 generating 直接返;miss/failed/stale 走派发
    row = await run_in_threadpool(
        cache.get, req.chart_hash, target_date, version,
    )
    if row is not None:
        if row["status"] == STATUS_READY:
            # 不在此 stat 验文件存在(热路径多一次 I/O);文件丢失自愈
            # 在 GET 侧收敛(删行 404 → 客户端重 POST → miss 重生成)
            return JSONResponse({"status": STATUS_READY})
        if (
            row["status"] == STATUS_GENERATING
            and _age_seconds(row["updated_at"]) < STALE_SECONDS
        ):
            return JSONResponse({"status": STATUS_GENERATING})

    # 4) 成本护栏:当日全局发起量达上限 → 429(failed 不计配额)。
    #    count 与占位非原子:并发 POST 不同 key 可少量越过上限(受并发数
    #    上界约束,成本护栏量级下可接受,不为此引锁/事务)
    count = await run_in_threadpool(cache.count_generated_today, target_date)
    if count >= DAILY_IMAGE_LIMIT:
        raise DailyImageLimitError(
            f"当日生图量已达上限({DAILY_IMAGE_LIMIT}),明日再试",
        )

    # 5) 占位 generating + 后台生成
    await run_in_threadpool(
        cache.upsert, req.chart_hash, target_date, version, STATUS_GENERATING,
        prompt_hash=prompt_hash,
    )
    background_tasks.add_task(
        _generate_and_store,
        request.app.state.image_client,
        request.app.state.image_singleflight,
        cache,
        req.chart_hash,
        target_date,
        version,
        prompt_hash,
        prompt,
    )
    logger.info(
        "daily.image.dispatch request_id=%s chart_hash=%s target_date=%s "
        "elapsed_ms=%.1f",
        request_id, req.chart_hash, target_date,
        (time.perf_counter() - start) * 1000,
    )
    return JSONResponse({"status": STATUS_GENERATING})


@router.get("/api/bazi/daily-fortune/image/content")
async def daily_image_content(
    chart_hash: str, target_date: str, request: Request,
) -> Response:
    """轮询/取图。按 prompt_version 取最新行(lifetime 最多 1 版在用)。"""
    cache: DailyImageCache = request.app.state.daily_image_cache

    row = await run_in_threadpool(
        cache.get_latest, chart_hash, target_date,
    )
    if row is None:
        return JSONResponse({"status": "missing"}, status_code=404)
    if row["status"] == STATUS_READY:
        try:
            png = await run_in_threadpool(cache.load_image, row["image_path"])
        except FileNotFoundError:
            # 行在文件不在(部署卷分离/外部清理):自愈删行 → 404,客户端
            # 重 POST 即重生成。显式日志留现场——比永久 500 死循环
            # (POST 见 ready 直返、GET 永远 500)对该 key 更糟。
            logger.warning(
                "daily.image.file_missing chart_hash=%s target_date=%s "
                "image_path=%s — 删行触发重生成",
                chart_hash, target_date, row["image_path"],
            )
            await run_in_threadpool(
                cache.delete, chart_hash, target_date, row["prompt_version"],
            )
            return JSONResponse({"status": "missing"}, status_code=404)
        return Response(content=png, media_type="image/png")
    if row["status"] == STATUS_GENERATING:
        if _age_seconds(row["updated_at"]) < STALE_SECONDS:
            return JSONResponse({"status": STATUS_GENERATING}, status_code=202)
        # 僵尸行:进程重启残留,显式 409 让客户端重 POST 重派
        return JSONResponse(
            {"status": STATUS_FAILED, "error": "generation timed out (stale)"},
            status_code=409,
        )
    return JSONResponse(
        {"status": STATUS_FAILED, "error": row["error_message"]},
        status_code=409,
    )


async def _generate_and_store(
    client: ImageGenClient,
    singleflight: SingleflightCoalescer,
    cache: DailyImageCache,
    chart_hash: str,
    target_date: str,
    version: int,
    prompt_hash: str,
    prompt: str,
) -> None:
    """后台生图 + 落盘 + 状态回写(BackgroundTasks 在响应后执行)。

    异常处理不属「吞错」:失败被显式持久化为 status=failed + error_message,
    经 GET 409 透出给客户端;日志留全量现场。
    """
    key = (chart_hash, target_date, version)
    try:
        png = await singleflight.coalesce(
            key, lambda: client.generate(prompt),
        )
        image_path = await run_in_threadpool(
            cache.save_image, chart_hash, target_date, png,
        )
        await run_in_threadpool(
            cache.upsert, chart_hash, target_date, version, STATUS_READY,
            prompt_hash=prompt_hash, image_path=image_path,
        )
        logger.info(
            "daily.image.ready chart_hash=%s target_date=%s bytes=%d",
            chart_hash, target_date, len(png),
        )
    except AIProviderError as e:
        await run_in_threadpool(
            cache.upsert, chart_hash, target_date, version, STATUS_FAILED,
            prompt_hash=prompt_hash, error_message=e.message,
        )
        logger.error(
            "daily.image.failed chart_hash=%s target_date=%s error=%s",
            chart_hash, target_date, e.message,
        )
    except Exception as e:  # 状态机兜底:任何意外都落 failed(非吞错,见上)
        await run_in_threadpool(
            cache.upsert, chart_hash, target_date, version, STATUS_FAILED,
            prompt_hash=prompt_hash, error_message=f"{type(e).__name__}: {e}",
        )
        logger.exception(
            "daily.image.unexpected chart_hash=%s target_date=%s",
            chart_hash, target_date,
        )


def _age_seconds(iso_updated_at: str) -> float:
    """updated_at 距今秒数。解析失败按 inf(视为 stale):stale 方向可自愈
    (重派回写合法时间戳),fresh 方向是永久僵尸(202 死循环,永不重派)。
    实际不可达(所有写入均走 _utcnow() isoformat),纯防御取向选择。"""
    try:
        updated = datetime.fromisoformat(iso_updated_at)
        return (datetime.now(timezone.utc) - updated).total_seconds()
    except ValueError:
        return float("inf")
