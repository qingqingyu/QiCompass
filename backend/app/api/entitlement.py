"""POST /api/entitlement/redeem — iOS 购买完成后同步 entitlement 到后端(M2b)。

流程:
1. 幂等查表:同 transaction_id 已 active → 直接返回(不重复调 Apple)
2. 幂等查表:同 transaction_id 已 inactive → 403(已退款/撤销,不能重新激活)
3. Apple 验证:verify_transaction(transaction_id)
   - 网络/签名/SDK 失败 → 502 AppleVerificationError
   - Apple 返回 is_refunded=True → 403 EntitlementError(理论上 webhook 已经处理)
4. 校验 product_id 匹配请求中的 product_id(防 iOS 传错)
5. 写表(INSERT OR IGNORE,极小概率并发 redeem)
6. 返回 entitled=true + 时间戳

错误显式传播(对齐 backend/app/api/interpret.py):
- Apple 调用失败不吞,抛 AppleVerificationError
- DB 失败不吞,抛 InterpretationCacheError(复用 500 体系)
- product_id 不匹配不静默接受,抛 AppleVerificationError
"""

from __future__ import annotations

import logging
import time
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Request
from starlette.concurrency import run_in_threadpool

from ..entitlement import AppleServerAPI, EntitlementStore
from ..errors import (
    AppleVerificationError,
    EntitlementError,
    InterpretationCacheError,
)
from ..auth.dependencies import require_authenticated_user
from ..models.entitlement import (
    EntitlementListItem,
    EntitlementListResponse,
    EntitlementRedeemRequest,
    EntitlementRedeemResponse,
)

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/api/entitlement/redeem", response_model=EntitlementRedeemResponse)
async def redeem(
    req: EntitlementRedeemRequest, request: Request,
    current_user_id: str = Depends(require_authenticated_user),
) -> EntitlementRedeemResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    store: EntitlementStore = request.app.state.entitlement_store
    apple: AppleServerAPI = request.app.state.apple_server_api

    log_ctx = {
        "request_id": request_id,
        "transaction_id": req.transaction_id,
        "product_id": req.product_id,
        "content_hash": req.content_hash,
        "module": req.module,
        "user_local_id": req.user_local_id,
    }
    logger.info("entitlement.redeem.start %s", log_ctx)

    # 1. 幂等查表(同 transaction_id 已存在)
    try:
        existing = await run_in_threadpool(
            store.get_by_transaction, req.transaction_id)
    except Exception as e:
        logger.exception(
            "entitlement.redeem.lookup_failed %s error=%r", log_ctx, e)
        raise InterpretationCacheError(
            f"entitlement 查询失败({type(e).__name__}): {e}",
            request_id=request_id, content_hash=req.content_hash,
        ) from e

    if existing is not None:
        if existing["is_active"] == 1:
            # 已激活 → 幂等返回(不重复调 Apple)
            logger.info(
                "entitlement.redeem.idempotent_hit %s "
                "purchased_at=%s", log_ctx, existing["purchased_at"])
            return EntitlementRedeemResponse(
                entitled=True,
                transaction_id=existing["transaction_id"],
                purchased_at=datetime.fromisoformat(existing["purchased_at"]),
                original_purchase_date=datetime.fromisoformat(
                    existing["original_purchase_date"]),
            )
        else:
            # 已 inactive(退款/撤销)→ 不能重新激活
            logger.warning(
                "entitlement.redeem.inactive_reject %s "
                "refunded_at=%s revoked_at=%s",
                log_ctx, existing.get("refunded_at"), existing.get("revoked_at"))
            raise EntitlementError(
                f"交易 {req.transaction_id} 已退款/撤销,无法重新激活",
                request_id=request_id, content_hash=req.content_hash,
            )

    # 2. Apple 验证(同步 SDK → run_in_threadpool)
    try:
        apple_info = await run_in_threadpool(
            apple.verify_transaction, req.transaction_id)
    except (AppleVerificationError, EntitlementError):
        raise
    except Exception as e:
        # apple_client 抛 AppleVerificationError,Mock 也抛;但兜底防未知异常
        logger.exception(
            "entitlement.redeem.apple_unexpected_error %s error=%r",
            log_ctx, e)
        raise AppleVerificationError(
            f"Apple 验证未预期失败({type(e).__name__}): {e}",
        ) from e

    # 3. 校验 product_id 匹配
    if apple_info.product_id != req.product_id:
        logger.warning(
            "entitlement.redeem.product_mismatch %s apple_product_id=%s",
            log_ctx, apple_info.product_id)
        raise AppleVerificationError(
            f"product_id 不匹配:请求 {req.product_id} / Apple {apple_info.product_id}",
        )

    # 4. 校验未退款
    if apple_info.is_refunded:
        logger.warning(
            "entitlement.redeem.apple_says_refunded %s", log_ctx)
        raise EntitlementError(
            f"Apple 返回交易 {req.transaction_id} 已退款/撤销",
            request_id=request_id, content_hash=req.content_hash,
        )

    # 5. 写表(INSERT OR IGNORE 幂等)
    now_utc = datetime.now(timezone.utc)
    purchased_at_iso = now_utc.replace(microsecond=0).isoformat()
    original_purchase_date_iso = apple_info.original_purchase_date.replace(
        microsecond=0).isoformat()

    try:
        inserted = await run_in_threadpool(
            store.insert,
            transaction_id=req.transaction_id,
            product_id=apple_info.product_id,
            content_hash=req.content_hash,
            module=req.module,
            user_local_id=req.user_local_id,
            user_id=current_user_id,  # 强制登录后必有值(redeem 走 require_authenticated_user)
            purchased_at=purchased_at_iso,
            original_purchase_date=original_purchase_date_iso,
        )
    except Exception as e:
        logger.exception(
            "entitlement.redeem.insert_failed %s error=%r", log_ctx, e)
        raise InterpretationCacheError(
            f"entitlement 写入失败({type(e).__name__}): {e}",
            request_id=request_id, content_hash=req.content_hash,
        ) from e

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "entitlement.redeem.ok elapsed_ms=%.1f %s inserted=%s",
        elapsed_ms, log_ctx, inserted)

    return EntitlementRedeemResponse(
        entitled=True,
        transaction_id=req.transaction_id,
        purchased_at=now_utc,
        original_purchase_date=apple_info.original_purchase_date,
    )


@router.get("/api/entitlement/list", response_model=EntitlementListResponse)
async def list_entitlements(
    request: Request,
    current_user_id: str = Depends(require_authenticated_user),
) -> EntitlementListResponse:
    """拉取当前登录用户的全部 entitlement(跨设备 / 重装 / 退登回登同步用)。

    流程:
    1. JWT 验签(require_authenticated_user)→ current_user_id = qicompass_user.id
    2. store.list_by_user_id(user_id) → list[dict](按 purchased_at DESC)
    3. 包装成 EntitlementListResponse 返回

    iOS 客户端在 onSignedIn 回调里调用此接口,把远端 entitlement 批量写入
    本地 SwiftData。包含 inactive 记录(客户端自行筛选,用于正确同步退款状态)。

    **未带 JWT / 验签失败** → require_authenticated_user 抛 401(对齐强制登录决策)。
    """
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    store: EntitlementStore = request.app.state.entitlement_store

    log_ctx = {"request_id": request_id, "user_id": current_user_id}
    logger.info("entitlement.list.start %s", log_ctx)

    try:
        rows = await run_in_threadpool(store.list_by_user_id, current_user_id)
    except Exception as e:
        logger.exception(
            "entitlement.list.lookup_failed %s error=%r", log_ctx, e)
        raise InterpretationCacheError(
            f"entitlement 列表查询失败({type(e).__name__}): {e}",
            request_id=request_id,
        ) from e

    entitlements: list[EntitlementListItem] = []
    for row in rows:
        # is_active 在 DB 里是 INTEGER(0/1),转 bool 给 Pydantic schema
        row["is_active"] = bool(row["is_active"])
        # datetime 字段从 ISO 字符串解析回去(对齐 EntitlementRedeemResponse 的 datetime 类型)
        row["purchased_at"] = datetime.fromisoformat(row["purchased_at"])
        row["original_purchase_date"] = datetime.fromisoformat(
            row["original_purchase_date"])
        if row.get("refunded_at"):
            row["refunded_at"] = datetime.fromisoformat(row["refunded_at"])
        if row.get("revoked_at"):
            row["revoked_at"] = datetime.fromisoformat(row["revoked_at"])
        entitlements.append(EntitlementListItem(**row))

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "entitlement.list.ok elapsed_ms=%.1f %s count=%d is_active_count=%d",
        elapsed_ms, log_ctx, len(entitlements),
        sum(1 for e in entitlements if e.is_active),
    )

    return EntitlementListResponse(entitlements=entitlements)
