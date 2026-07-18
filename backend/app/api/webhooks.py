"""POST /api/webhooks/appstore — Apple Server Notifications V2 退款 webhook(M2c)。

流程:
1. 读 raw body(Apple 发 JWS 字符串,multipart 或 raw)
2. verify_notification(同步 SDK → run_in_threadpool)
   验签失败 → 返 200 + log warning(避免 Apple 重试风暴)
3. 解析 notificationType + transactionId
4. type ∈ {REFUND, REVOKE}:
   REFUND → store.deactivate(reason="refund", at=now)
   REVOKE → store.deactivate(reason="revoke", at=now)
5. 其他 type → 仅 log(不操作)
6. 永远返 200(空 body)

Apple 重试逻辑:Apple 看 status code,非 2xx 会重试 N 次(配置 dependent)。
所有"无法处理"的失败都返 200,避免空转重试:
- 验签失败(签名无效 / payload 不可解析)→ 200(可能是攻击或 Apple 升级 API)
- 未知 notificationType → 200(Apple 升级新 type 时老后端不应卡住)
- DB 写失败 → 500(让 Apple 重试,DB 恢复后能补上)

幂等:store.deactivate 已是幂等(同 tx 二次返 False)。
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Request
from fastapi.responses import Response
from starlette.concurrency import run_in_threadpool

from ..entitlement import AppleServerAPI, EntitlementStore
from ..errors import AppleVerificationError, InterpretationCacheError

router = APIRouter()
logger = logging.getLogger(__name__)


# 处理的 notification type(对齐 MONETIZATION.md §退款 webhook)
# Apple 用 REFUND 表示用户退款,REVOKE 表示家庭共享撤销(v1 不主动配家庭共享但兼容)
_HANDLED_TYPES = frozenset({"REFUND", "REVOKE"})


@router.post("/api/webhooks/appstore")
async def appstore_webhook(request: Request) -> Response:
    """Apple Server Notifications V2 入口。

    Returns:
        200 + 空 body(成功 / 验签失败 / 未知 type)
        500(DB 写失败,Apple 会重试)
    """
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())

    store: EntitlementStore = request.app.state.entitlement_store
    apple: AppleServerAPI = request.app.state.apple_server_api

    # 读 raw body(Apple 发 JWS 字符串,Content-Type 可能是 application/json 或 text)
    body_bytes = await request.body()
    if not body_bytes:
        logger.warning(
            "webhook.empty_body request_id=%s content_length=0", request_id)
        return Response(status_code=200)

    try:
        body_str = body_bytes.decode("utf-8")
    except UnicodeDecodeError as e:
        logger.warning(
            "webhook.decode_failed request_id=%s error=%r", request_id, e)
        return Response(status_code=200)

    # 验签 + 解析(M2c 用 SDK;M2a/b Mock 已实现)
    try:
        notification = await run_in_threadpool(
            apple.verify_notification, body_str)
    except AppleVerificationError as e:
        # 验签失败:返 200 + log(避免 Apple 重试风暴)
        logger.warning(
            "webhook.verify_failed request_id=%s body_len=%d error=%s",
            request_id, len(body_str), e,
        )
        return Response(status_code=200)
    except Exception as e:
        # 兜底:MockAppleServerAPI 不应抛非 AppleVerificationError,但防御编程
        logger.exception(
            "webhook.unexpected_verify_error request_id=%s error=%r",
            request_id, e)
        return Response(status_code=200)

    ntype = notification.notification_type
    tx_id = notification.transaction_id

    log_ctx = {
        "request_id": request_id,
        "notification_type": ntype,
        "transaction_id": tx_id,
    }
    logger.info("webhook.notification %s", log_ctx)

    if ntype not in _HANDLED_TYPES:
        # 未知 type(可能是 SUBSCRIBED / DID_CHANGE_RENEWAL_STATUS 等订阅事件,
        # 消耗型 IAP 不会触发;但 Apple 升级 API 加新 type 时不应卡住)
        logger.info("webhook.unhandled_type %s (skipped)", log_ctx)
        return Response(status_code=200)

    # REFUND / REVOKE → deactivate entitlement
    reason = "refund" if ntype == "REFUND" else "revoke"
    now_iso = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
    try:
        updated = await run_in_threadpool(
            store.deactivate,
            transaction_id=tx_id,
            reason=reason,  # type: ignore[arg-type]
            at_iso=now_iso,
        )
    except Exception as e:
        # DB 写失败 → 500(让 Apple 重试,DB 恢复后能补上)
        logger.exception(
            "webhook.deactivate_failed %s error=%r", log_ctx, e)
        raise InterpretationCacheError(
            f"webhook 处理失败({type(e).__name__}): {e}",
            request_id=request_id,
        ) from e

    logger.info(
        "webhook.deactivated %s reason=%s updated=%s",
        log_ctx, reason, updated,
    )
    return Response(status_code=200)
