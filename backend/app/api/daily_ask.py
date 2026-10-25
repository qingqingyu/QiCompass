"""问事端点(今日页问事窗)——S4b-3,2026-10-25。

路由:
- POST /api/bazi/daily-ask  作答(每条用户消息扣 1 次)
- GET  /api/ask/balance     余额查询(首次自动铸造 3 次试用)
- POST /api/ask/redeem      次数包入账(Apple 验证复用 entitlement 协议)

流程(MONETIZATION.md §问事窗 技术口径;次序即代码次序):
验签(daily 族 token,含 target_date)→ 试用铸造(钱包无行时;置于
缓存查之前——DC/限铸拦下的身份连免费缓存答案也不给,拍板)→
重复问判定(variant fresh/repeat)→ 共享缓存查(命中免费秒回)→
余额闸 try_consume(402)→ 渲染(此时已扣;422 回补次数)→
IP 硬闸(300/日)→ LLM → 失败退(次数回补 + IP 闸回退,按实际
消耗退)→ 契约校验 + 禁词扫描 → 写缓存 + 记 history。

扣费纪律:预扣 + 失败自动退(对齐 interpret 分类退先例);缓存命中
不扣不烧(「缓存命中不计」);重复问(同 owner 同盘同日同题)走
variant=repeat 重生成照扣(拍板 ② 修订版)。
"""

from __future__ import annotations

import hashlib
import json
import logging
import time
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query, Request
from starlette.concurrency import run_in_threadpool

from ..ai.forbidden_words import scan as scan_forbidden_words
from ..ai.forbidden_words import validate_interpretation
from ..ai.prompts import PROMPT_VERSIONS, render_prompt
from ..ask.service import AskGrantService
from ..ask.store import AskCreditsStore
from ..auth.dependencies import get_current_user_id
from ..config import (
    ASK_IP_DAILY_LIMIT,
    ASK_MINT_LIMIT_PER_IP,
    ASK_PACK_CREDITS,
    ASK_PACK_PRODUCT_ID,
    ASK_TRIAL_CREDITS,
    REFUND_DAILY_LIMIT,
)
from ..context_binding import verify_interpret_context
from ..errors import (
    AIProviderError,
    AppleVerificationError,
    AskCreditsRequiredError,
    EntitlementError,
    InvalidInputError,
)
from ..models.daily_ask import (
    AskBalanceResponse,
    AskRedeemRequest,
    AskRedeemResponse,
    DailyAskRequest,
    DailyAskResponse,
    DailyAskTurn,
)
from .interpret import _normalize_client_ip, _strip_code_fences
from .language import resolve_language

router = APIRouter()
logger = logging.getLogger(__name__)

# 对话注入上限:只取末 6 轮(prompt 上下文成本边界);超过 20 轮整单 422
# (客户端截断责任,服务端不静默丢弃用户对话)
_MAX_HISTORY_TURNS = 20
_INJECT_TURNS = 6

# ask_mode_note(端点拼装,S4b-1 模板占位符)
_FRESH_NOTE = "首次提问，直接作答。"
_REPEAT_NOTE = (
    "命主今天已问过同一问题——点破重复，温和追问其真正犹豫的点，"
    "不要原样重复上一轮答案。")

# follow_up_suggestions 契约(与 v6 ask_suggestions 同口径)
_MAX_FOLLOW_UPS = 3
_FOLLOW_UP_MAX_LEN = 60
_ANSWER_MAX_LEN = 2000


def _owner_for(
    current_user_id: str | None, user_local_id: str | None,
) -> str:
    """钱包 owner:登录 user_id 优先,匿名 user_local_id(对齐付费桶前缀纪律)。"""
    if current_user_id:
        return f"user:{current_user_id}"
    if user_local_id:
        return f"ulid:{user_local_id}"
    raise InvalidInputError(
        "问事请求须携带身份:登录(JWT)或 user_local_id(匿名)至少其一")


def _utc_day() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _build_conversation(history: list[DailyAskTurn]) -> str:
    """对话上文 → prompt 注入文本;空 → 「（无）」(与三语模板占位约定一致)。"""
    turns = history[-_INJECT_TURNS:]
    if not turns:
        return "（无）"
    lines = [
        f"{'问' if t.role == 'user' else '答'}：{t.text}" for t in turns]
    return "\n".join(lines)


def _parse_daily_ask_output(text: str) -> dict:
    """校验 LLM 输出契约 {answer, follow_up_suggestions}。

    围栏剥离复用 interpret._strip_code_fences(单一算法事实源;服务端是
    daily_ask 唯一解析方,严于 iOS 无碍)。

    Raises:
        AIProviderError(bad_response): 围栏剥离后非 JSON / 缺键 / 类型与
            长度越界——模型输出不合格式,归类 bad_response(响应形状非法),
            计入 daily_ask 模块 metrics。
    """
    stripped = _strip_code_fences(text)
    try:
        data = json.loads(stripped)
    except (json.JSONDecodeError, ValueError) as e:
        raise AIProviderError(
            f"问事回复不是合法 JSON: {e}",
            reason="bad_response") from e
    if not isinstance(data, dict):
        raise AIProviderError(
            "问事回复顶层不是 JSON 对象", reason="bad_response")
    answer = data.get("answer")
    follow_ups = data.get("follow_up_suggestions")
    if (not isinstance(answer, str) or not answer.strip()
            or len(answer) > _ANSWER_MAX_LEN):
        raise AIProviderError(
            "问事回复 answer 缺失/非字符串/超长", reason="bad_response")
    if (not isinstance(follow_ups, list) or not follow_ups
            or len(follow_ups) > _MAX_FOLLOW_UPS
            or not all(isinstance(s, str) and 1 <= len(s) <= _FOLLOW_UP_MAX_LEN
                       for s in follow_ups)):
        raise AIProviderError(
            f"问事回复 follow_up_suggestions 须为 1-{_MAX_FOLLOW_UPS} 条"
            "非空字符串(每条 ≤60 字)", reason="bad_response")
    return {"answer": answer, "follow_up_suggestions": follow_ups}


@router.post("/api/bazi/daily-ask", response_model=DailyAskResponse)
async def daily_ask(
    req: DailyAskRequest, request: Request,
    current_user_id: str | None = Depends(get_current_user_id),
) -> DailyAskResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()
    owner = _owner_for(current_user_id, req.user_local_id)
    language = resolve_language(request)
    day = _utc_day()
    ip = _normalize_client_ip(
        request.client.host if request.client else "unknown")
    ip_bucket = f"ask-ip:{ip}"

    log_ctx = {
        "request_id": request_id, "owner": owner[:13],
        "content_hash": req.content_hash,
        "target_date": req.target_date.isoformat(), "language": language,
    }
    logger.info("daily.ask.start %s", log_ctx)

    if len(req.history) > _MAX_HISTORY_TURNS:
        raise InvalidInputError(
            f"history 超上限({_MAX_HISTORY_TURNS} 轮;客户端应截断后只传最近几轮)",
            request_id=request_id, content_hash=req.content_hash)

    # 1. 验签(daily 族:盘身字段 + target_date 都对账;伪/缺 → 403)
    verify_interpret_context(
        req.context_token, module="daily_ask",
        content_hash=req.content_hash, context=req.context,
        target_date_iso=req.target_date.isoformat())

    ask_store: AskCreditsStore = request.app.state.ask_store
    grant_service: AskGrantService = request.app.state.ask_grant_service

    question = req.question.strip()
    if not question:
        # pydantic min_length 只拦原串为空;全空白 strip 后为空属无效提问,
        # 在扣费前显式 422(不进「白烧 1 次 + 空问题行进缓存」的链路)
        raise InvalidInputError(
            "question 不能为空白(去除首尾空白后为空)",
            request_id=request_id, content_hash=req.content_hash)
    question_hash = hashlib.sha256(question.encode("utf-8")).hexdigest()
    conversation = _build_conversation(req.history)
    conv_fingerprint = hashlib.sha256(
        conversation.encode("utf-8")).hexdigest()
    # 今日解读文本指纹(prompt 输入之一,客户端自由文本不进 token 锚定):
    # 不进缓存键则不同解读文本碰撞同键,后到者免秒回按他人文本生成的
    # 答案——与「作答必须与今日解读一致」的模板前提静默断裂。合法同盘
    # 用户解读文本来自同一确定性 daily_fortune 缓存,天然同指纹不损命中。
    # 唯一剩余未锚定输入 context.date 是设备日历显示串,语义日已由
    # target_date 进键锚定,豁免。
    interp_fingerprint = hashlib.sha256(
        req.daily_interpretation.encode("utf-8")).hexdigest()

    # 2. 试用铸造(钱包无行时)——置于缓存查/扣费之前:缓存命中的新用户
    #    余额也要如实显示 3(免费秒回≠未领试用);DC 拦/限铸拦 → 402
    #    (重装农场连免费缓存答案也不给白拿,买次数包不铸造新身份即解锁)。
    #    grant_trial 同步且内含 DeviceCheck 网络往返(httpx.Client,≤5s)
    #    → run_in_threadpool,不阻塞 event loop(对齐 webhooks/entitlement
    #    对同步 SDK 的既有纪律)
    if not await run_in_threadpool(ask_store.wallet_row_exists, owner=owner):
        grant = await run_in_threadpool(
            grant_service.grant_trial,
            owner=owner, ip=ip, day=day, credits=ASK_TRIAL_CREDITS,
            mint_limit=ASK_MINT_LIMIT_PER_IP,
            device_token=req.device_token)
        if grant.outcome == "device_blocked":
            raise AskCreditsRequiredError(
                "该设备已领取过问事试用(重装不重发);购买次数包即可继续问事",
                request_id=request_id, content_hash=req.content_hash)
        if grant.outcome == "mint_limited":
            raise AskCreditsRequiredError(
                "当前网络今日新试用名额已满;购买次数包即可继续问事",
                request_id=request_id, content_hash=req.content_hash)

    # 3. 重复问判定(② 修订版):同 owner 同盘同日同题 → repeat 变体,
    #    带点破指令重生成(照扣);首问 → fresh。variant 进缓存键,互不污染。
    repeat = await run_in_threadpool(
        ask_store.has_asked, owner=owner, chart_hash=req.content_hash,
        day=day, question_hash=question_hash)
    variant = "repeat" if repeat else "fresh"
    mode_note = _REPEAT_NOTE if repeat else _FRESH_NOTE

    # 4. 共享缓存查(跨用户;命中 = 不调 LLM 不扣次数,免费秒回)
    prompt_version = PROMPT_VERSIONS["daily_ask"]
    cached_json = await run_in_threadpool(
        ask_store.get_answer,
        chart_hash=req.content_hash,
        target_date=req.target_date.isoformat(),
        question_hash=question_hash, conv_fingerprint=conv_fingerprint,
        interp_fingerprint=interp_fingerprint,
        language=language, prompt_version=prompt_version, variant=variant)
    if cached_json is not None:
        try:
            payload = json.loads(cached_json)
            # 禁词扫描(US-COMP-04,对齐 interpret 缓存命中扫描):行写入前
            # 已扫过,此处拦「词表演化后老行含新禁词」——命中不当答案返回,
            # 按 miss 落穿重生成(新答案 UPSERT 覆盖,行自愈;ask 表无删除
            # 方法,不照搬 interpret 的删行拦截)
            if scan_forbidden_words(
                    payload["answer"] + "\n".join(
                        payload["follow_up_suggestions"])):
                logger.warning(
                    "daily.ask.cache_forbidden_skip %s variant=%s",
                    log_ctx, variant)
            else:
                balance = await run_in_threadpool(
                    ask_store.get_balance, owner=owner)
                logger.info(
                    "daily.ask.cache_hit %s variant=%s", log_ctx, variant)
                return DailyAskResponse(
                    answer=payload["answer"],
                    follow_up_suggestions=payload["follow_up_suggestions"],
                    cached=True, balance=balance)
        except (json.JSONDecodeError, KeyError, TypeError) as e:
            # 缓存行损坏:不吞——记日志后按 miss 走重生成(缓存行随后被
            # UPSERT 覆盖),不让坏行把用户锁死在 500 上
            logger.exception(
                "daily.ask.cache_corrupt_skip %s error=%r", log_ctx, e)

    # 5. 余额闸(402;试用+钱包合计)
    if not await run_in_threadpool(ask_store.try_consume, owner=owner):
        raise AskCreditsRequiredError(
            "问事次数已用完;购买次数包即可继续问事",
            request_id=request_id, content_hash=req.content_hash)

    # 6. 渲染(422 先于 LLM;此时已扣 1 次——渲染失败属客户端 context
    #    契约错误,与 interpret 同判 422,但须回补次数:扣费只对「真作答」负责)
    context = dict(req.context)
    context.update({
        "user_question": question,
        "daily_interpretation": req.daily_interpretation,
        "ask_conversation": conversation,
        "ask_mode_note": mode_note,
    })
    try:
        prompt = render_prompt("daily_ask", context, language=language)
    except InvalidInputError:
        # 渲染 422:回补次数即可——IP 闸在下一步,本路径从未消耗 IP 名额,
        # 误退会把同 IP 其他请求的真实消耗抹掉(见 _refund_charge 注释)
        await _refund_charge(request, owner=owner, day=day)
        raise

    # 7. IP 硬闸(纯防脚本,300/日;真烧 LLM 路径才计)。拒绝路径同样
    #    不退 IP:try_consume 条件 UPDATE 失败时不写计数,本请求零消耗
    quota_store = request.app.state.free_quota_store
    ip_ok = await run_in_threadpool(
        quota_store.try_consume, bucket=ip_bucket, day=day,
        limit=ASK_IP_DAILY_LIMIT)
    if not ip_ok:
        await _refund_charge(request, owner=owner, day=day)
        logger.warning("daily.ask.ip_limit %s bucket=%s", log_ctx, ip_bucket)
        raise AIProviderError(
            f"当前网络今日问事生成次数已达服务端上限({ASK_IP_DAILY_LIMIT}/日),"
            "明日再来", reason="rate_limit")

    # 8. LLM(module=daily_ask 进监控桶;失败退:次数回补 + IP 闸回退——
    #    此路径 IP 名额已真实消耗,两样都退)
    ai_client = request.app.state.ai_client
    try:
        raw = await ai_client.interpret(prompt, module="daily_ask")
        payload = _parse_daily_ask_output(raw)
    except AIProviderError:
        await _refund_charge(request, owner=owner, day=day,
                             ip_bucket=ip_bucket)
        raise

    # 8.5 禁词扫描(US-COMP-04 后端终防线,对齐 interpret 4.5):命中即
    #     拦截——不返回文本、不写缓存;**不退次数**(用户可构造触发禁词的
    #     提问,退款 = 免费烧 LLM 通道,同 interpret 拍板口径)。非
    #     AIProviderError,不走上面退款分支,直接向上传播
    validate_interpretation(
        payload["answer"] + "\n" + "\n".join(payload["follow_up_suggestions"]),
        request_id=request_id, content_hash=req.content_hash,
        log_ctx=log_ctx)

    # 9. 落缓存 + 记 history + 返回
    answer_json = json.dumps(
        {"answer": payload["answer"],
         "follow_up_suggestions": payload["follow_up_suggestions"]},
        ensure_ascii=False)
    await run_in_threadpool(
        ask_store.put_answer,
        chart_hash=req.content_hash,
        target_date=req.target_date.isoformat(),
        question_hash=question_hash, conv_fingerprint=conv_fingerprint,
        interp_fingerprint=interp_fingerprint,
        language=language, prompt_version=prompt_version,
        variant=variant, answer_json=answer_json)
    await run_in_threadpool(
        ask_store.record_ask, owner=owner, chart_hash=req.content_hash,
        day=day, question_hash=question_hash)
    balance = await run_in_threadpool(ask_store.get_balance, owner=owner)

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "daily.ask.ok request_id=%s owner=%s content_hash=%s variant=%s "
        "cached=False balance=%d elapsed_ms=%.1f",
        request_id, owner[:13], req.content_hash, variant, balance,
        elapsed_ms)
    return DailyAskResponse(
        answer=payload["answer"],
        follow_up_suggestions=payload["follow_up_suggestions"],
        cached=False, balance=balance)


async def _refund_charge(
    request: Request, *, owner: str, day: str, ip_bucket: str | None = None,
) -> None:
    """失败退款:次数回补(必有)+ IP 闸回退(仅 ip_bucket 传入时)。

    ip_bucket 只在**本请求已真实消耗** IP 名额后传(LLM 失败路径);
    渲染 422 / IP 拒绝路径不传——quota.try_consume 条件 UPDATE 失败时
    不写计数,零消耗的退款会把同 IP 桶里其他请求的真实消耗减 1
    (CGNAT 同出口互相抹账),且白烧退款名额(每日 ≤REFUND_DAILY_LIMIT)。
    补偿动作,best-effort 记日志不遮蔽主错误(对齐 interpret.
    _refund_daily_quota 先例)。
    """
    ask_store: AskCreditsStore = request.app.state.ask_store
    try:
        await run_in_threadpool(ask_store.refund_consume, owner=owner)
    except Exception as e:  # noqa: BLE001 —— 补偿动作,不遮蔽主错误
        logger.exception(
            "daily.ask.refund_credits_failed owner=%s error=%r", owner[:13], e)
    if ip_bucket is None:
        return
    quota_store = request.app.state.free_quota_store
    try:
        await run_in_threadpool(
            quota_store.try_refund, bucket=ip_bucket, day=day,
            limit=REFUND_DAILY_LIMIT)
    except Exception as e:  # noqa: BLE001
        logger.exception(
            "daily.ask.refund_ip_failed bucket=%s error=%r", ip_bucket, e)


@router.get("/api/ask/balance", response_model=AskBalanceResponse)
async def ask_balance(
    request: Request,
    # Query 上限与 POST 模型对齐(user_local_id 128 / device_token 4096),
    # 拦超长垃圾参数直达 SQLite owner PK / DC 负载
    user_local_id: str | None = Query(None, max_length=128),
    device_token: str | None = Query(None, max_length=4096),
    current_user_id: str | None = Depends(get_current_user_id),
) -> AskBalanceResponse:
    """余额查询;钱包无行时顺手铸造试用(装机即领的懒铸造——iOS 首查
    即得 3,用户无感知差异;铸造幂等,重复查询无副作用)。"""
    owner = _owner_for(current_user_id, user_local_id)
    ask_store: AskCreditsStore = request.app.state.ask_store
    grant_service: AskGrantService = request.app.state.ask_grant_service
    if not await run_in_threadpool(ask_store.wallet_row_exists, owner=owner):
        ip = _normalize_client_ip(
            request.client.host if request.client else "unknown")
        await run_in_threadpool(
            grant_service.grant_trial,
            owner=owner, ip=ip, day=_utc_day(),
            credits=ASK_TRIAL_CREDITS,
            mint_limit=ASK_MINT_LIMIT_PER_IP, device_token=device_token)
        # device_blocked / mint_limited:余额仍是 0,如实返回(iOS 引导购买)
    balance = await run_in_threadpool(ask_store.get_balance, owner=owner)
    return AskBalanceResponse(balance=balance)


@router.post("/api/ask/redeem", response_model=AskRedeemResponse)
async def ask_redeem(
    req: AskRedeemRequest, request: Request,
    current_user_id: str | None = Depends(get_current_user_id),
) -> AskRedeemResponse:
    """次数包入账:Apple 验证(复用 entitlement 协议)→ 钱包 +15。

    幂等:同 transaction_id 二次 redeem 在 ask_purchases PK 处挡下,
    返回当前余额(credits=0),不重复加——与 entitlement redeem 的幂等
    语义对齐(重试安全,重放无收益)。
    """
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    owner = _owner_for(current_user_id, req.user_local_id)
    apple = request.app.state.apple_server_api
    ask_store: AskCreditsStore = request.app.state.ask_store

    logger.info(
        "ask.redeem.start request_id=%s owner=%s transaction_id=%s "
        "product_id=%s", request_id, owner[:13], req.transaction_id,
        req.product_id)

    # 1. Apple 验证(Mock 同协议;验证失败显式抛,不静默;未预期异常
    #    包成 AppleVerificationError 502,对齐 entitlement.redeem 先例)
    try:
        apple_info = await run_in_threadpool(
            apple.verify_transaction, req.transaction_id)
    except AppleVerificationError:
        raise
    except Exception as e:
        logger.exception(
            "ask.redeem.apple_unexpected_error request_id=%s error=%r",
            request_id, e)
        raise AppleVerificationError(
            f"Apple 验证未预期失败({type(e).__name__}): {e}",
        ) from e

    # 2. product_id 匹配(请求 vs Apple 记录)且为次数包 SKU(防跨 SKU)
    if apple_info.product_id != req.product_id:
        raise InvalidInputError(
            f"product_id 不匹配:请求 {req.product_id} / Apple "
            f"{apple_info.product_id}", request_id=request_id)
    if req.product_id != ASK_PACK_PRODUCT_ID:
        raise InvalidInputError(
            f"非问事次数包 SKU(期望 {ASK_PACK_PRODUCT_ID})",
            request_id=request_id)

    # 2.5 已退款/撤销拒入账(对齐 entitlement.redeem 第 4 步兜底闸):
    #     webhook 只处理已入账的行;「购买→立刻退款→redeem 晚到」竞态下
    #     ask_purchases 无行可扣,唯一防线就是这里 Apple 说的 is_refunded
    if apple_info.is_refunded:
        logger.warning(
            "ask.redeem.apple_says_refunded request_id=%s "
            "transaction_id=%s", request_id, req.transaction_id)
        raise EntitlementError(
            f"交易 {req.transaction_id} 已退款/撤销,无法入账问事次数",
            request_id=request_id)

    # 3. 入账(幂等;PK 挡重放)
    purchased_at = apple_info.original_purchase_date.isoformat()
    added = await run_in_threadpool(
        ask_store.redeem_credits, owner=owner,
        transaction_id=req.transaction_id,
        credits=ASK_PACK_CREDITS, purchased_at=purchased_at)
    balance = await run_in_threadpool(ask_store.get_balance, owner=owner)
    logger.info(
        "ask.redeem.ok request_id=%s owner=%s added=%s balance=%d",
        request_id, owner[:13], added, balance)
    return AskRedeemResponse(
        credits=ASK_PACK_CREDITS if added else 0,
        balance=balance,
        transaction_id=req.transaction_id,
        purchased_at=purchased_at)
