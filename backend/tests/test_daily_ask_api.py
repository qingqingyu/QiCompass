"""问事端点集成测试(POST /api/bazi/daily-ask + balance + redeem)。

锁 MONETIZATION.md §问事窗 端点侧口径:验签 403 面 / 试用铸造与扣减 /
402 ASK_CREDITS_REQUIRED 三触发 / 缓存命中免费 / 重复问照扣+点破指令 /
失败退款(LLM 失败 + 契约失败 + 渲染 422)/ IP 硬闸 + 退款只退真消耗 /
禁词扫描(新产出拦截不退 + 缓存行落穿自愈)/ redeem 幂等 + 已退款拒入账。

客户端 fixture 自建(镜像 conftest.interpret_client:替换 ask 全家桶
state,teardown 恢复)——不动共享 conftest,避免影响其他测试。
"""

from __future__ import annotations

import hashlib
from datetime import datetime, timezone

import pytest

from app.ai.prompts import PROMPT_VERSIONS
from app.api.daily_ask import _utc_day
from app.ask.service import AskGrantService
from app.ask.store import AskCreditsStore
from app.entitlement.protocol import AppleTransactionInfo
from tests.fixtures.context_token_helper import token_for_context
from tests.fixtures.mock_ai import FailingAIClient, MockAIClient

# ---------- 测试素材 ----------

_GOOD_AI_JSON = (
    '{"answer": "今天适合谈判，宜午前开口。", '
    '"follow_up_suggestions": ["几点开口最稳？", "对方不让步怎么办？"]}')

_DAILY_CONTEXT = {
    "day_master": "辛金", "day_master_element": "金",
    "day_master_strength": "balanced",
    "favorable_elements": "土、金", "unfavorable_elements": "木",
    "date": "2026年10月25日", "lunar_date": "九月十六",
    "day_pillar": "辛未", "day_stem": "辛", "day_stem_element": "金",
    "day_branch": "未", "day_branch_element": "土",
    "day_relation": "比肩", "day_chong": "冲丑",
    "hour_pillars_with_relations": "子时(23-1) 比肩",
    "huangli_yi": "独立、立界", "huangli_ji": "争执、攀比",
}


def _interp_fp(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


_INTERP_DEFAULT = "比肩当值 同气相扶亦暗藏争夺。"


def _body(
    *, question="今天适合去谈判吗？", user_local_id="ulid-test-1",
    context=None, target_date="2026-10-25", history=None,
    daily_interpretation=_INTERP_DEFAULT, device_token=None,
    sign_token=True, content_hash="chash-ask-1", token_context=None,
):
    context = dict(context if context is not None else _DAILY_CONTEXT)
    body = {
        "content_hash": content_hash,
        "context": context,
        "target_date": target_date,
        "user_local_id": user_local_id,
        "question": question,
        "history": history or [],
        "daily_interpretation": daily_interpretation,
    }
    if device_token:
        body["device_token"] = device_token
    if sign_token:
        body["context_token"] = token_for_context(
            content_hash=content_hash, module="daily_ask",
            context=token_context if token_context is not None else context,
            target_date_iso=target_date)
    return body


class _StubApple:
    """ask redeem 专用 Apple 桩:固定 product_id + is_refunded 可编程。"""

    def __init__(self, product_id="com.qicompass.daily_ask.pack15",
                 is_refunded=False):
        self.product_id = product_id
        self.is_refunded = is_refunded
        self.calls: list[str] = []

    def verify_transaction(self, transaction_id: str) -> AppleTransactionInfo:
        self.calls.append(transaction_id)
        return AppleTransactionInfo(
            transaction_id=transaction_id, product_id=self.product_id,
            original_purchase_date=datetime(2026, 10, 25, tzinfo=timezone.utc),
            is_refunded=self.is_refunded)


class _FakeDeviceCheck:
    """DC 桩:bit0 可编程(端点测试只需要 query 分支)。"""

    def __init__(self, *, bit0=False):
        self.bit0 = bit0

    def query_two_bits(self, device_token):
        from app.ask.devicecheck import DeviceCheckQueryResult
        return DeviceCheckQueryResult(success=True, bit0=self.bit0)

    def update_two_bits(self, device_token, *, bit0):
        return True


@pytest.fixture
async def ask_client(tmp_path):
    """替换 ask 全家桶 state 的 ASGI client(隔离 + teardown 恢复)。"""
    from httpx import ASGITransport, AsyncClient

    from app.main import app

    ask_store = AskCreditsStore(str(tmp_path / "test_ask.db"))
    ask_store.init_schema()
    grant = AskGrantService(ask_store, None)
    ai = MockAIClient(_GOOD_AI_JSON)
    apple = _StubApple()

    saved = {k: getattr(app.state, k, None) for k in (
        "ask_store", "ask_grant_service", "devicecheck_client",
        "ai_client", "apple_server_api")}
    app.state.ask_store = ask_store
    app.state.ask_grant_service = grant
    app.state.devicecheck_client = None
    app.state.ai_client = ai
    app.state.apple_server_api = apple
    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            yield ac, ask_store, ai, apple, grant
    finally:
        for k, v in saved.items():
            setattr(app.state, k, v)


# ---------- 主流程 ----------

class TestAskFlow:
    async def test_first_question_charged_once(self, ask_client):
        ac, store, ai, _, _ = ask_client
        resp = await ac.post("/api/bazi/daily-ask", json=_body())
        assert resp.status_code == 200
        data = resp.json()
        assert data["cached"] is False
        assert data["balance"] == 2          # 试用 3 − 1
        assert data["answer"].startswith("今天适合谈判")
        assert len(data["follow_up_suggestions"]) == 2
        assert ai.call_count == 1
        assert ai.last_module == "daily_ask"  # 监控桶归属
        assert "今天适合去谈判吗" in ai.last_prompt
        assert "首次提问" in ai.last_prompt   # fresh 指令注入

    async def test_history_injected_and_truncated(self, ask_client):
        ac, _, ai, _, _ = ask_client
        history = [
            {"role": "user" if i % 2 == 0 else "ai", "text": f"第{i}轮"}
            for i in range(6)
        ] + [{"role": "user", "text": "末轮问题"}]
        resp = await ac.post(
            "/api/bazi/daily-ask",
            json=_body(question="接着问", history=history))
        assert resp.status_code == 200
        # 只注末 6 轮:第 0 轮不进,末轮在
        assert "第0轮" not in ai.last_prompt
        assert "末轮问题" in ai.last_prompt

    async def test_history_over_limit_422(self, ask_client):
        ac, _, ai, _, _ = ask_client
        history = [{"role": "user", "text": f"r{i}"} for i in range(21)]
        resp = await ac.post(
            "/api/bazi/daily-ask", json=_body(history=history))
        assert resp.status_code == 422
        assert ai.call_count == 0

    async def test_no_identity_422(self, ask_client):
        ac, _, ai, _, _ = ask_client
        body = _body()
        body.pop("user_local_id")
        resp = await ac.post("/api/bazi/daily-ask", json=body)
        assert resp.status_code == 422

    async def test_whitespace_question_422_before_charge(self, ask_client):
        """全空白问题:pydantic min_length 拦不住,strip 后须 422——
        且必须发生在扣费/烧 LLM 之前。"""
        ac, store, ai, _, _ = ask_client
        resp = await ac.post(
            "/api/bazi/daily-ask", json=_body(question="   "))
        assert resp.status_code == 422
        assert ai.call_count == 0
        # 校验位于铸造之前:钱包行未建(无行 = 0),下一次合法请求才铸
        assert store.get_balance(owner="ulid:ulid-test-1") == 0

    async def test_unknown_hour_context_ok(self, ask_client):
        """unknown_hour 盘:S09 放宽 3 字段,同端点可答。"""
        ac, _, _, _, _ = ask_client
        ctx = dict(_DAILY_CONTEXT, day_master_strength="unknown_hour")
        for f in ("favorable_elements", "unfavorable_elements",
                  "hour_pillars_with_relations"):
            ctx.pop(f)
        resp = await ac.post(
            "/api/bazi/daily-ask", json=_body(context=ctx))
        assert resp.status_code == 200


class TestAskAuth:
    async def test_missing_token_403(self, ask_client):
        ac, _, ai, _, _ = ask_client
        resp = await ac.post(
            "/api/bazi/daily-ask", json=_body(sign_token=False))
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "CONTEXT_TOKEN_REQUIRED"
        assert ai.call_count == 0

    async def test_token_of_other_chart_403(self, ask_client):
        ac, _, ai, _, _ = ask_client
        # token 按另一张盘的 context 签 → 盘身对账失败
        body = _body(token_context=dict(_DAILY_CONTEXT, day_pillar="甲子"))
        resp = await ac.post("/api/bazi/daily-ask", json=body)
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "CONTEXT_TOKEN_INVALID"

    async def test_token_date_mismatch_403(self, ask_client):
        ac, _, ai, _, _ = ask_client
        # 请求 10-26,token 仍是 10-25 签的 → daily 族日期对账失败
        body = _body(target_date="2026-10-26")
        body["context_token"] = token_for_context(
            content_hash="chash-ask-1", module="daily_ask",
            context=_DAILY_CONTEXT, target_date_iso="2026-10-25")
        resp = await ac.post("/api/bazi/daily-ask", json=body)
        assert resp.status_code == 403


class TestCreditsAndGates:
    async def test_exhausted_402_paywall_code(self, ask_client):
        ac, store, ai, _, _ = ask_client
        for i in range(3):  # 试用 3 次,3 个不同问题
            resp = await ac.post("/api/bazi/daily-ask",
                                 json=_body(question=f"问题{i}？"))
            assert resp.status_code == 200
        resp = await ac.post("/api/bazi/daily-ask",
                             json=_body(question="第四次？"))
        assert resp.status_code == 402
        body = resp.json()
        assert body["error"]["code"] == "ASK_CREDITS_REQUIRED"
        assert ai.call_count == 3

    async def test_device_blocked_402(self, ask_client):
        ac, _, ai, _, grant = ask_client
        grant._devicecheck = _FakeDeviceCheck(bit0=True)
        resp = await ac.post("/api/bazi/daily-ask",
                             json=_body(device_token="dc-token"))
        assert resp.status_code == 402
        assert resp.json()["error"]["code"] == "ASK_CREDITS_REQUIRED"
        assert ai.call_count == 0

    async def test_ip_hard_limit_refunds(self, ask_client, monkeypatch):
        ac, store, ai, _, _ = ask_client
        monkeypatch.setattr("app.api.daily_ask.ASK_IP_DAILY_LIMIT", 1)
        assert (await ac.post("/api/bazi/daily-ask",
                              json=_body(question="第一问？"))).status_code == 200
        resp = await ac.post("/api/bazi/daily-ask",
                             json=_body(question="第二问？"))
        assert resp.status_code == 503                    # AIProviderError 面
        assert "服务端上限" in resp.json()["error"]["message"]
        assert ai.call_count == 1
        # IP 闸拦下时次数已回补:余额仍为 3−1(第一问烧掉)
        assert store.get_balance(owner="ulid:ulid-test-1") == 2
        # 拒绝路径零写零退:IP 计数停在已真实消耗的 1
        assert _ip_ask_count() == 1


class TestRefunds:
    async def test_llm_failure_refunds_credits(self, ask_client):
        ac, store, ai, _, _ = ask_client
        failing = FailingAIClient()
        ask_client_state_set_ai(failing)
        resp = await ac.post("/api/bazi/daily-ask", json=_body())
        assert resp.status_code == 503
        assert store.get_balance(owner="ulid:ulid-test-1") == 3  # 回补

    async def test_bad_output_contract_refunds(self, ask_client):
        ac, store, ai, _, _ = ask_client
        ai.set_response("这不是 JSON")
        resp = await ac.post("/api/bazi/daily-ask", json=_body())
        assert resp.status_code == 503
        assert store.get_balance(owner="ulid:ulid-test-1") == 3

    async def test_render_422_refunds(self, ask_client):
        ac, store, ai, _, _ = ask_client
        ctx = dict(_DAILY_CONTEXT)
        # date 渲染必需但不在 _DAILY_BIND_FIELDS → 验签过、渲染 422(退款路径)
        ctx.pop("date")
        body = _body(context=ctx, token_context=_DAILY_CONTEXT)
        resp = await ac.post("/api/bazi/daily-ask", json=body)
        assert resp.status_code == 422
        assert store.get_balance(owner="ulid:ulid-test-1") == 3

    async def test_llm_failure_refunds_ip_quota(self, ask_client):
        """LLM 失败:IP 名额真消耗过 → 回退(计数回 1,不多不少)。"""
        ac, store, ai, _, _ = ask_client
        assert (await ac.post("/api/bazi/daily-ask", json=_body(
            question="第一问？"))).status_code == 200
        assert _ip_ask_count() == 1
        ask_client_state_set_ai(FailingAIClient())
        resp = await ac.post("/api/bazi/daily-ask", json=_body(
            question="第二问？"))
        assert resp.status_code == 503
        assert _ip_ask_count() == 1          # 消耗 1 + 退 1

    async def test_render_422_does_not_refund_ip_quota(self, ask_client):
        """渲染 422 发生在 IP 闸之前:零消耗,不得退(误退会抹掉同 IP
        其他请求的真实消耗——2026-10-26 review 修复的回归锚点)。"""
        ac, store, ai, _, _ = ask_client
        assert (await ac.post("/api/bazi/daily-ask", json=_body(
            question="第一问？"))).status_code == 200
        assert _ip_ask_count() == 1
        ctx = dict(_DAILY_CONTEXT)
        ctx.pop("date")
        body = _body(question="第二问？", context=ctx,
                     token_context=_DAILY_CONTEXT)
        assert (await ac.post("/api/bazi/daily-ask", json=body)
                ).status_code == 422
        assert _ip_ask_count() == 1          # 不动:本路径从未消耗

    async def test_ip_reject_does_not_refund_ip_quota(self, ask_client,
                                                      monkeypatch):
        """IP 拒绝路径 try_consume 未写计数:零消耗,不得退(达限后误退
        = 每日多顶穿硬闸 ≤5 次——回归锚点)。"""
        ac, store, ai, _, _ = ask_client
        monkeypatch.setattr("app.api.daily_ask.ASK_IP_DAILY_LIMIT", 1)
        assert (await ac.post("/api/bazi/daily-ask", json=_body(
            question="第一问？"))).status_code == 200
        assert _ip_ask_count() == 1
        resp = await ac.post("/api/bazi/daily-ask", json=_body(
            question="第二问？"))
        assert resp.status_code == 503
        assert _ip_ask_count() == 1          # 拒绝即零写零退


class TestForbiddenWords:
    async def test_fresh_answer_forbidden_422_no_refund(self, ask_client):
        """新产出含禁词:422 拦截,不退次数(用户可构造触发,退款 = 免费
        烧 LLM 通道——对齐 interpret 4.5 拍板口径)。"""
        ac, store, ai, _, _ = ask_client
        ai.set_response(
            '{"answer": "此事必定成功,放心去办。", '
            '"follow_up_suggestions": ["几时动身最稳？"]}')
        resp = await ac.post("/api/bazi/daily-ask", json=_body())
        assert resp.status_code == 422
        assert resp.json()["error"]["code"] == "INTERPRETATION_FORBIDDEN"
        assert store.get_balance(owner="ulid:ulid-test-1") == 2  # 照扣不退
        # 禁词答案不得进共享缓存
        assert store.get_answer(
            chart_hash="chash-ask-1", target_date="2026-10-25",
            question_hash=hashlib.sha256(
                "今天适合去谈判吗？".encode()).hexdigest(),
            conv_fingerprint=hashlib.sha256(
                "（无）".encode()).hexdigest(),
            interp_fingerprint=_interp_fp(_INTERP_DEFAULT),
            language="zh", prompt_version=PROMPT_VERSIONS["daily_ask"],
            variant="fresh") is None

    async def test_cache_hit_forbidden_falls_through(self, ask_client):
        """缓存行含禁词(词表演化后的老行):不当答案返回,落穿重生成,
        UPSERT 覆盖自愈。"""
        ac, store, ai, _, _ = ask_client
        store.put_answer(
            chart_hash="chash-ask-1", target_date="2026-10-25",
            question_hash=hashlib.sha256(
                "今天适合去谈判吗？".encode()).hexdigest(),
            conv_fingerprint=hashlib.sha256("（无）".encode()).hexdigest(),
            interp_fingerprint=_interp_fp(_INTERP_DEFAULT),
            language="zh", prompt_version=PROMPT_VERSIONS["daily_ask"],
            variant="fresh",
            answer_json='{"answer": "注定能成。", '
                        '"follow_up_suggestions": ["几时问？"]}')
        resp = await ac.post("/api/bazi/daily-ask", json=_body())
        assert resp.status_code == 200
        data = resp.json()
        assert data["cached"] is False           # 落穿重生成
        assert data["answer"].startswith("今天适合谈判")
        assert ai.call_count == 1

    async def test_different_interpretation_misses_cache(self, ask_client):
        """daily_interpretation 是 prompt 输入但客户端自由文本:不同文本
        不得互蹭共享缓存(否则后到者拿到按他人文本生成的答案,与模板
        「作答必须与今日解读一致」前提断裂)——键含 interp_fingerprint
        的回归锚点。"""
        ac, store, ai, _, _ = ask_client
        first = await ac.post("/api/bazi/daily-ask", json=_body())
        assert first.json()["cached"] is False
        # 同盘同日同题同空对话,仅解读文本不同 → 必 miss 重生成
        second = await ac.post("/api/bazi/daily-ask", json=_body(
            user_local_id="ulid-test-2",
            daily_interpretation="伤官见官 今日口舌是非须慎言。"))
        data = second.json()
        assert data["cached"] is False
        assert ai.call_count == 2
        # 解读原文进 prompt(各答各的语境)
        assert "伤官见官" in ai.last_prompt


class TestCacheAndRepeat:
    async def test_cross_user_cache_hit_free(self, ask_client):
        ac, store, ai, _, _ = ask_client
        first = await ac.post("/api/bazi/daily-ask", json=_body())
        assert first.json()["balance"] == 2
        calls_after_first = ai.call_count
        # 另一个用户(新 ulid→新钱包)问同一张盘同一天同一个问题:
        # repeat 判定按 owner 分 → fresh;命中共享缓存 → 免费秒回
        second = await ac.post("/api/bazi/daily-ask",
                               json=_body(user_local_id="ulid-test-2"))
        data = second.json()
        assert data["cached"] is True
        assert data["balance"] == 3            # 未扣(试用刚铸,一分未花)
        assert ai.call_count == calls_after_first

    async def test_same_user_repeat_charged_with_directive(self, ask_client):
        ac, store, ai, _, _ = ask_client
        await ac.post("/api/bazi/daily-ask", json=_body())
        second = await ac.post("/api/bazi/daily-ask", json=_body())
        data = second.json()
        assert data["cached"] is False          # 重复问:重生成,不重放
        assert data["balance"] == 1             # 照扣(拍板 ② 修订版)
        assert "已问过同一问题" in ai.last_prompt  # 点破指令注入


class TestBalanceAndRedeem:
    async def test_balance_lazy_mints_trial(self, ask_client):
        ac, store, _, _, _ = ask_client
        resp = await ac.get(
            "/api/ask/balance", params={"user_local_id": "ulid-new"})
        assert resp.status_code == 200
        assert resp.json()["balance"] == 3

    async def test_balance_oversized_params_422(self, ask_client):
        """query 参数上限与 POST 模型对齐(128/4096),拦垃圾超长参数。"""
        ac, _, _, _, _ = ask_client
        resp = await ac.get(
            "/api/ask/balance",
            params={"user_local_id": "x" * 129})
        assert resp.status_code == 422
        resp2 = await ac.get(
            "/api/ask/balance",
            params={"user_local_id": "ulid-ok", "device_token": "y" * 4097})
        assert resp2.status_code == 422

    async def test_redeem_adds_credits_idempotent(self, ask_client):
        ac, store, _, apple, _ = ask_client
        resp = await ac.post("/api/ask/redeem", json={
            "transaction_id": "txn-pack-1",
            "product_id": "com.qicompass.daily_ask.pack15",
            "user_local_id": "ulid-test-1",
        })
        assert resp.status_code == 200
        assert resp.json()["credits"] == 15
        # 该测试未先发问 → 钱包行由 redeem 首建,试用 3 不叠加
        # (铸造只在「钱包无行」时发生;iOS 实流首开问事窗即查 balance 先铸)
        assert resp.json()["balance"] == 15
        # 重放同一 transaction → credits 0,余额不动
        replay = await ac.post("/api/ask/redeem", json={
            "transaction_id": "txn-pack-1",
            "product_id": "com.qicompass.daily_ask.pack15",
            "user_local_id": "ulid-test-1",
        })
        assert replay.status_code == 200
        assert replay.json()["credits"] == 0
        assert replay.json()["balance"] == 15
        assert len(apple.calls) == 2              # 每次都验(幂等在台账层)

    async def test_redeem_wrong_product_422(self, ask_client):
        ac, _, _, apple, _ = ask_client
        apple.product_id = "com.qicompass.deep_analysis.single"
        resp = await ac.post("/api/ask/redeem", json={
            "transaction_id": "txn-x",
            "product_id": "com.qicompass.daily_ask.pack15",
            "user_local_id": "ulid-test-1",
        })
        assert resp.status_code == 422

    async def test_redeem_refunded_transaction_403(self, ask_client):
        """「购买→Apple 退款→redeem 晚到」竞态:webhook 时 ask_purchases
        无行可扣,is_refunded 是唯一防线(entitlement.redeem 同款兜底闸)。"""
        ac, store, _, apple, _ = ask_client
        apple.is_refunded = True
        resp = await ac.post("/api/ask/redeem", json={
            "transaction_id": "txn-refunded",
            "product_id": "com.qicompass.daily_ask.pack15",
            "user_local_id": "ulid-test-1",
        })
        assert resp.status_code == 403
        assert resp.json()["error"]["code"] == "ENTITLEMENT_ERROR"
        assert store.get_balance(owner="ulid:ulid-test-1") == 0  # 未入账

    async def test_purchased_credits_spend_after_trial(self, ask_client):
        ac, store, _, _, _ = ask_client
        await ac.post("/api/ask/redeem", json={
            "transaction_id": "txn-pack-1",
            "product_id": "com.qicompass.daily_ask.pack15",
            "user_local_id": "ulid-test-1",
        })
        for i in range(3):  # 试用 3 次
            await ac.post("/api/bazi/daily-ask", json=_body(question=f"q{i}？"))
        # 钱包付(redeem 先建行 → 无试用叠加;15-3-1=11)
        resp = await ac.post("/api/bazi/daily-ask", json=_body(question="继续？"))
        assert resp.status_code == 200
        assert resp.json()["balance"] == 15 - 4


def ask_client_state_set_ai(new_ai):
    """替换 fixture client 背后的 ai_client(同一 app.state)。"""
    from app.main import app
    app.state.ai_client = new_ai


def _ip_ask_count() -> int:
    """读端点实际使用的 ask-ip 桶当日计数(autouse fixture 已隔离到 tmp)。"""
    from app.main import app
    host = "127.0.0.1"  # httpx ASGITransport 默认 client host
    return app.state.free_quota_store.get_count(
        bucket=f"ask-ip:{host}", day=_utc_day())
