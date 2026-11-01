"""TASK-02(2026-11-01):Apple 沙盒交易回落测试。

覆盖任务书五场景:
1. prod 命中 → 不碰 sandbox,environment="production"
2. prod 404 → sandbox 命中 → environment="sandbox"
3. 两边都 404 → 显式 AppleVerificationError(不静默)
4. prod 非 404 错误 → 不回落,直接上抛(错误显式传播)
5. webhook 按 JWS payload 的 environment claim 选对 verifier
   (sandbox / production 各自路由;claim 嵌在互斥的 data / summary /
   externalPurchaseToken 内——外层 payload 无顶层 environment 字段;
   缺 claim / 未知值显式拒绝)

另含:entitlement / ask_purchases 老表 environment 列迁移(数据不丢)
与 environment 落库口径。
"""

from types import SimpleNamespace

import pytest

from app.entitlement.apple_client import AppleServerAPIClient
from app.errors import AppleVerificationError
from appstoreserverlibrary.api_client import APIException

_PRODUCT = "com.qicompass.deep_analysis.single"


def _payload(tx_id: str = "tx-1"):
    return SimpleNamespace(
        transactionId=tx_id,
        productId=_PRODUCT,
        originalPurchaseDate=1767225300000,  # ms
        revocationDate=None,
    )


class _StubAPIClient:
    """getTransactionInfo 桩:可编程抛 APIException 或返回签名串。"""

    def __init__(self, *, api_exception: APIException | None = None):
        self.calls: list[str] = []
        self._api_exception = api_exception

    def get_transaction_info(self, transaction_id: str):
        self.calls.append(transaction_id)
        if self._api_exception is not None:
            raise self._api_exception
        return SimpleNamespace(signedTransactionInfo="sig-x")


class _StubVerifier:
    """验签桩:记录调用(哪个环境的 verifier 被用到是本套件的核心断言)。"""

    def __init__(self):
        self.decode_tx_calls: list[str] = []
        self.decode_notification_calls: list[str] = []

    def verify_and_decode_signed_transaction(self, signed: str):
        self.decode_tx_calls.append(signed)
        return _payload()

    def verify_and_decode_signed_notification(self, body: str):
        self.decode_notification_calls.append(body)
        # 内层交易 JWS 也走同一 verifier(与实现的环境路由一致)
        return SimpleNamespace(
            notificationType="REFUND",
            data=SimpleNamespace(signedTransactionInfo="inner-sig"),
        )


def _make_client(prod_api, sbx_api, prod_verifier, sbx_verifier):
    """绕过真实 SDK 构造(需有效 EC 私钥),直接装配被测对象。

    只填 verify_transaction / verify_notification 用到的实例属性,
    不触发 __init__(其内部会实例化真 SDK 对象)。
    """
    obj = AppleServerAPIClient.__new__(AppleServerAPIClient)
    obj._bundle_id = "com.qicompass.app"
    obj._app_apple_id = "123"
    obj._client_prod = prod_api
    obj._client_sbx = sbx_api
    obj._verifier_prod = prod_verifier
    obj._verifier_sbx = sbx_verifier
    return obj


# ===== 场景 1:prod 命中,绝不回落 =====


def test_prod_hit_no_sandbox_fallback():
    prod, sbx = _StubAPIClient(), _StubAPIClient()
    client = _make_client(prod, sbx, _StubVerifier(), _StubVerifier())

    info = client.verify_transaction("tx-1")

    assert info.environment == "production"
    assert prod.calls == ["tx-1"]
    assert sbx.calls == []


# ===== 场景 2:prod 404 → sandbox 命中 =====


def test_prod_404_falls_back_to_sandbox():
    prod = _StubAPIClient(api_exception=APIException(404))
    sbx = _StubAPIClient()
    client = _make_client(prod, sbx, _StubVerifier(), _StubVerifier())

    info = client.verify_transaction("tx-sbx")

    assert info.environment == "sandbox"
    assert prod.calls == ["tx-sbx"]
    assert sbx.calls == ["tx-sbx"]


# ===== 场景 3:两环境均 404 → 显式错误 =====


def test_both_404_explicit_error():
    prod = _StubAPIClient(api_exception=APIException(404))
    sbx = _StubAPIClient(api_exception=APIException(404))
    client = _make_client(prod, sbx, _StubVerifier(), _StubVerifier())

    with pytest.raises(AppleVerificationError, match="均不存在"):
        client.verify_transaction("tx-none")


# ===== 场景 4:prod 非 404 错误 → 不回落,原样上抛 =====


def test_prod_non_404_error_no_fallback():
    prod = _StubAPIClient(api_exception=APIException(
        500, raw_api_error=5000000, error_message="apple 5xx"))
    sbx = _StubAPIClient()
    client = _make_client(prod, sbx, _StubVerifier(), _StubVerifier())

    with pytest.raises(AppleVerificationError, match="production"):
        client.verify_transaction("tx-err")
    assert sbx.calls == []  # 非交易不存在错误绝不回落(掩盖真实故障)


# ===== 场景 5:webhook 按 environment claim 路由 verifier =====
#
# 报文形状对齐 Apple 真实格式(2026-11-01 修正):外层 payload
# (responseBodyV2DecodedPayload)**无**顶层 environment 字段——claim 嵌在
# 互斥的 data / summary / externalPurchaseToken 之一内(字段清单经 Apple
# 官方 Node SDK ResponseBodyV2DecodedPayload.ts 与本仓 Python SDK
# SignedDataVerifier._verify_notification 推导逻辑双核对)。


def _jws_payload_body(payload: dict):
    import base64
    import json

    seg = base64.urlsafe_b64encode(
        json.dumps(payload).encode()).decode().rstrip("=")
    return f"header.{seg}.signature"


def _jws_body(environment: str | None = None):
    """真实形状:data.environment(REFUND / REVOKE 等携带交易的通知)。"""
    return _jws_payload_body({
        "notificationType": "REFUND",
        "data": {"environment": environment},
    })


def test_notification_sandbox_routes_sbx_verifier():
    sbx_v, prod_v = _StubVerifier(), _StubVerifier()
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), prod_v, sbx_v)

    note = client.verify_notification(_jws_body("Sandbox"))

    assert note.environment == "sandbox"
    assert len(sbx_v.decode_notification_calls) == 1
    assert prod_v.decode_notification_calls == []


def test_notification_production_routes_prod_verifier():
    sbx_v, prod_v = _StubVerifier(), _StubVerifier()
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), prod_v, sbx_v)

    note = client.verify_notification(_jws_body("Production"))

    assert note.environment == "production"
    assert len(prod_v.decode_notification_calls) == 1
    assert sbx_v.decode_notification_calls == []


def test_notification_summary_environment_routes_verifier():
    """SUMMARY 类通知无 data,claim 在 summary.environment——同款路由。"""
    sbx_v, prod_v = _StubVerifier(), _StubVerifier()
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), prod_v, sbx_v)

    note = client.verify_notification(_jws_payload_body({
        "notificationType": "SUMMARY",
        "summary": {"environment": "Sandbox"},
    }))

    assert note.environment == "sandbox"
    assert len(sbx_v.decode_notification_calls) == 1
    assert prod_v.decode_notification_calls == []


def test_notification_external_purchase_token_prefix_routes():
    """EXTERNAL_PURCHASE_TOKEN 无 data/summary,按 externalPurchaseId 前缀。"""
    sbx_v, prod_v = _StubVerifier(), _StubVerifier()
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), prod_v, sbx_v)

    sandbox_note = client.verify_notification(_jws_payload_body({
        "notificationType": "EXTERNAL_PURCHASE_TOKEN",
        "externalPurchaseToken": {"externalPurchaseId": "SANDBOX-evt-1"},
    }))
    prod_note = client.verify_notification(_jws_payload_body({
        "notificationType": "EXTERNAL_PURCHASE_TOKEN",
        "externalPurchaseToken": {"externalPurchaseId": "evt-1"},
    }))

    assert sandbox_note.environment == "sandbox"
    assert prod_note.environment == "production"


def test_notification_data_present_but_missing_environment_rejected():
    """data 在场但缺 environment → 显式拒绝(SDK 同款:None 必验签失败)。"""
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), _StubVerifier(), _StubVerifier())

    with pytest.raises(AppleVerificationError, match="environment"):
        client.verify_notification(_jws_payload_body({
            "notificationType": "REFUND",
            "data": {"bundleId": "com.qicompass.app"},
        }))


def test_notification_no_payload_object_rejected():
    """三负载全缺(data/summary/externalPurchaseToken)→ 无处取 claim,拒绝。"""
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), _StubVerifier(), _StubVerifier())

    with pytest.raises(AppleVerificationError, match="environment"):
        client.verify_notification(
            _jws_payload_body({"notificationType": "REFUND"}))


def test_notification_malformed_data_object_rejected():
    """data 键在场但非对象 → 显式"非对象"拒绝(诊断不误导为缺负载)。"""
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), _StubVerifier(), _StubVerifier())

    with pytest.raises(AppleVerificationError, match="data 非对象"):
        client.verify_notification(_jws_payload_body({
            "notificationType": "REFUND",
            "data": "garbage",
        }))


def test_notification_unknown_environment_rejected():
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), _StubVerifier(), _StubVerifier())

    with pytest.raises(AppleVerificationError, match="未知"):
        client.verify_notification(_jws_body("Staging"))


def test_notification_bad_jws_rejected():
    client = _make_client(
        _StubAPIClient(), _StubAPIClient(), _StubVerifier(), _StubVerifier())

    with pytest.raises(AppleVerificationError, match="JWS"):
        client.verify_notification("not-a-jws")


# ===== 迁移:老表补 environment 列(数据不丢)=====

_OLD_ENTITLEMENT_SQL = """
CREATE TABLE entitlement (
    transaction_id         TEXT PRIMARY KEY,
    product_id             TEXT NOT NULL,
    content_hash           TEXT NOT NULL,
    module                 TEXT NOT NULL,
    user_local_id          TEXT NOT NULL,
    purchased_at           TEXT NOT NULL,
    original_purchase_date TEXT NOT NULL,
    is_active              INTEGER NOT NULL DEFAULT 1,
    refunded_at            TEXT,
    revoked_at             TEXT,
    user_id                TEXT
)
"""


def test_entitlement_old_table_gets_environment_column(tmp_path):
    import sqlite3

    from app.entitlement.store import EntitlementStore

    db = tmp_path / "ent.db"
    with sqlite3.connect(db) as conn:
        conn.execute(_OLD_ENTITLEMENT_SQL)
        conn.execute(
            "INSERT INTO entitlement (transaction_id, product_id, "
            "content_hash, module, user_local_id, purchased_at, "
            "original_purchase_date, is_active) VALUES "
            "('tx-old', 'p', 'h', 'bazi_deep', 'u', '2026-01-01', "
            "'2026-01-01', 1)")

    EntitlementStore(str(db)).init_schema()

    store = EntitlementStore(str(db))
    row = store.get_by_transaction("tx-old")
    assert row is not None
    assert row["environment"] is None  # 老行未知环境,不猜


def test_entitlement_insert_records_environment(tmp_path):
    from app.entitlement.store import EntitlementStore

    db = str(tmp_path / "ent2.db")
    store = EntitlementStore(db)
    store.init_schema()
    assert store.insert(
        transaction_id="tx-new", product_id=_PRODUCT, content_hash="h",
        module="bazi_deep", user_local_id="u",
        purchased_at="2026-11-01T00:00:00+00:00",
        original_purchase_date="2026-11-01T00:00:00+00:00",
        environment="sandbox",
    ) is True
    assert store.get_by_transaction("tx-new")["environment"] == "sandbox"


def test_ask_purchases_old_table_gets_environment_column(tmp_path):
    import sqlite3

    from app.ask.store import AskCreditsStore

    db = tmp_path / "ask.db"
    with sqlite3.connect(db) as conn:
        conn.execute("""
            CREATE TABLE ask_purchases (
                transaction_id TEXT PRIMARY KEY,
                owner          TEXT NOT NULL,
                credits        INTEGER NOT NULL,
                purchased_at   TEXT NOT NULL,
                refunded_at    TEXT
            )
        """)
        conn.execute(
            "INSERT INTO ask_purchases (transaction_id, owner, credits, "
            "purchased_at) VALUES ('txn-old', 'ulid:a', 15, '2026-10-25')")

    AskCreditsStore(str(db)).init_schema()

    with sqlite3.connect(db) as conn:
        cols = {c[1] for c in conn.execute(
            "PRAGMA table_info(ask_purchases)").fetchall()}
        row = conn.execute(
            "SELECT environment FROM ask_purchases "
            "WHERE transaction_id='txn-old'").fetchone()
    assert "environment" in cols
    assert row == (None,)  # 老行未知环境,不猜


def test_migration_concurrent_init_schema_smoke(tmp_path):
    """多 worker 并发 init_schema 不因 ALTER 竞态崩(duplicate column 收敛)。

    run.sh 默认 WEB_CONCURRENCY=2——老库首次升级时两进程同时跑迁移,
    后到者的 ALTER 撞 duplicate column name;实现按「重查列在场 = 收敛
    成功」处理。8 线程 × 各 3 次把 PRAGMA→ALTER 窗口拉满,任一线程
    抛错即失败(概率性命中竞态,作回归冒烟网)。
    """
    import sqlite3
    import threading

    from app.entitlement.store import EntitlementStore

    db = tmp_path / "ent.db"
    with sqlite3.connect(db) as conn:
        conn.execute(_OLD_ENTITLEMENT_SQL)
        conn.execute(
            "INSERT INTO entitlement (transaction_id, product_id, "
            "content_hash, module, user_local_id, purchased_at, "
            "original_purchase_date, is_active) VALUES "
            "('tx-race', 'p', 'h', 'bazi_deep', 'u', '2026-01-01', "
            "'2026-01-01', 1)")

    store = EntitlementStore(str(db))
    errors: list[Exception] = []
    barrier = threading.Barrier(8)

    def worker():
        try:
            barrier.wait()  # 对齐各线程首次 PRAGMA 检查时点
            for _ in range(3):
                store.init_schema()
        except Exception as e:  # noqa: BLE001 — 线程内失败全收集,断言处统一判
            errors.append(e)

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    assert store.get_by_transaction("tx-race") is not None  # 数据未丢
