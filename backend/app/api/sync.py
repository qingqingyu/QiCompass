"""PR3.1 /api/sync/pull + /api/sync/push 路由。

跨设备命盘同步接口(必须登录)。

- pull:用户拉所有云端命盘(全量,iOS 登录后/启动时调)
- push:用户上传本地命盘列表(全量,iOS 创建/修改命盘后调),后端 UPSERT
"""

from __future__ import annotations

import logging
import time
import uuid

from fastapi import APIRouter, Depends, Request
from starlette.concurrency import run_in_threadpool

from ..auth.dependencies import require_authenticated_user
from ..models.sync import (
    ChartSyncData,
    SyncPullResponse,
    SyncPushRequest,
    SyncPushResponse,
)
from ..sync.store import UserChartSyncStore

router = APIRouter(tags=["sync"])
logger = logging.getLogger(__name__)


@router.post("/api/sync/pull", response_model=SyncPullResponse)
async def sync_pull(
    request: Request,
    user_id: str = Depends(require_authenticated_user),
) -> SyncPullResponse:
    """登录用户拉所有云端命盘(全量)。

    用例:iOS 登录后 / App 启动时,拉云端所有命盘到本地 SwiftData。
    后端按 user_id 查 user_chart_sync 表。
    """
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    store: UserChartSyncStore = request.app.state.user_chart_sync_store

    logger.info("sync.pull.start request_id=%s user_id=%s", request_id, user_id[:8])

    rows = await run_in_threadpool(store.list_by_user, user_id)
    charts = [
        ChartSyncData(
            content_hash=r.content_hash,
            alias=r.alias,
            schema_version=r.schema_version,
            birth_solar_time=r.birth_solar_time,
            gender=r.gender,
            city_longitude=r.city_longitude,
            city_timezone=r.city_timezone,
            zi_hour_rule=r.zi_hour_rule,
            calc_rule_snapshot_base64=r.calc_rule_snapshot,
            payload_json=r.payload,
            created_at=r.created_at,
        )
        for r in rows
    ]

    elapsed_ms = int((time.perf_counter() - start) * 1000)
    logger.info(
        "sync.pull.ok request_id=%s user_id=%s count=%d elapsed_ms=%d",
        request_id, user_id[:8], len(charts), elapsed_ms,
    )

    return SyncPullResponse(user_id=user_id, charts=charts)


@router.post("/api/sync/push", response_model=SyncPushResponse)
async def sync_push(
    req: SyncPushRequest,
    request: Request,
    user_id: str = Depends(require_authenticated_user),
) -> SyncPushResponse:
    """登录用户上传本地命盘列表(全量,后端 UPSERT)。

    用例:iOS 创建/修改命盘后,上传本地所有命盘到云端。
    后端按 (user_id, content_hash) UPSERT,保留 created_at,更新其他字段 + updated_at。

    返回 upserted_count(实际操作行数,可能 < len(charts) 如果都是 no-op)
    + total_count(云端总行数,含本次未传的)。
    """
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    store: UserChartSyncStore = request.app.state.user_chart_sync_store

    logger.info(
        "sync.push.start request_id=%s user_id=%s incoming_count=%d",
        request_id, user_id[:8], len(req.charts),
    )

    upserted = 0
    for chart in req.charts:
        # run_in_threadpool 每条单独包(批量 INSERT 在 SQLite WAL 下并发安全,但单线程简单)
        await run_in_threadpool(
            store.upsert,
            user_id=user_id,
            content_hash=chart.content_hash,
            alias=chart.alias,
            schema_version=chart.schema_version,
            birth_solar_time=chart.birth_solar_time,
            gender=chart.gender,
            city_longitude=chart.city_longitude,
            city_timezone=chart.city_timezone,
            zi_hour_rule=chart.zi_hour_rule,
            calc_rule_snapshot=chart.calc_rule_snapshot_base64,
            payload=chart.payload_json,
            created_at=chart.created_at,
        )
        upserted += 1

    total = await run_in_threadpool(store.count_by_user, user_id)

    elapsed_ms = int((time.perf_counter() - start) * 1000)
    logger.info(
        "sync.push.ok request_id=%s user_id=%s upserted=%d total=%d elapsed_ms=%d",
        request_id, user_id[:8], upserted, total, elapsed_ms,
    )

    return SyncPushResponse(
        user_id=user_id, upserted_count=upserted, total_count=total,
    )
