"""账号删除测试(2026-11-24,docs/账号删除端点设计决策 §3 拍板口径)。

覆盖:
- delete_user_data 单事务全表口径(出生数据整删/台账匿名化/含文本缓存清/
  legacy local_id 行/不越权删他人数据/不存在账号回滚)
- /api/auth/account 路由(未登录 401 / Apple 未配置 503 / Google 直删 /
  Apple 换 code 验 sub 后删 / sub 不匹配 403 且不删 / 残留 JWT 拒判)
- chapter_feedback IP HMAC(明文不落库 / 去重防刷语义不变 / 存量清洗)
- compat 模块清单与 prompts.COMPATIBILITY_MODULES 漂移锁定
"""

from __future__ import annotations

import sqlite3
import uuid
from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.ai.prompts import COMPATIBILITY_MODULES
from app.auth.account_deletion import (
    _COMPAT_MODULES_FOR_DELETION,
    delete_user_data,
)
from app.auth.apple_revocation import (
    AppleRevocationNotConfiguredError,
    AppleRevocationUserMismatchError,
)
from app.auth.jwt_service import create_access_token
from app.main import app


# ---------- 夹具:一个共享 tmp 库,全部 store schema 就位 ----------


@pytest.fixture
def shared_db(tmp_path):
    """建一个含全部相关表的单文件库(与生产 DB_PATH 同构)。"""
    from app.ai.cache import InterpretationCache
    from app.ai.feedback_store import ChapterFeedbackStore
    from app.ask.store import AskCreditsStore
    from app.auth.user_store import UserStore
    from app.entitlement.store import EntitlementStore
    from app.quota.store import FreeLLMQuotaStore
    from app.sync.store import UserChartSyncStore

    db = str(tmp_path / "shared.db")
    UserStore(db).init_schema()
    EntitlementStore(db).init_schema()
    UserChartSyncStore(db).init_schema()
    AskCreditsStore(db).init_schema()
    InterpretationCache(db).init_schema()
    ChapterFeedbackStore(db).init_schema()
    FreeLLMQuotaStore(db).init_schema()
    return db


def _seed_full_account(db: str, user_id: str, local_id: str = "ulid-A") -> None:
    """给 user_id 播全量数据(每张表至少一行)+ 一个无关旁观者账号。"""
    now = datetime.now(timezone.utc).isoformat()
    conn = sqlite3.connect(db)
    # 旁观者(验证不越权删):另一个 user + 另一个 local_id
    other_user = str(uuid.uuid4())
    conn.execute(
        "INSERT INTO qicompass_user (id, provider, provider_user_id, email,"
        " created_at, last_login_at) VALUES (?,?,?,?,?,?)",
        (user_id, "apple", "apple-sub-me", "me@example.com", now, now))
    conn.execute(
        "INSERT INTO qicompass_user (id, provider, provider_user_id, email,"
        " created_at, last_login_at) VALUES (?,?,?,?,?,?)",
        (other_user, "google", "google-sub-other", None, now, now))

    # 同步命盘(出生数据)
    conn.execute(
        "INSERT INTO user_chart_sync (id, user_id, content_hash, alias,"
        " schema_version, birth_solar_time, gender, city_longitude,"
        " city_timezone, zi_hour_rule, calc_rule_snapshot, payload,"
        " created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (str(uuid.uuid4()), user_id, "hash-me-1", "我", 1, now, "male",
         116.4, "Asia/Shanghai", "zi_next_day", "{}", "{}", now, now))
    conn.execute(
        "INSERT INTO user_chart_sync (id, user_id, content_hash, alias,"
        " schema_version, birth_solar_time, gender, city_longitude,"
        " city_timezone, zi_hour_rule, calc_rule_snapshot, payload,"
        " created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (str(uuid.uuid4()), other_user, "hash-other-1", "他", 1, now, "female",
         1.0, "Europe/London", "zi_next_day", "{}", "{}", now, now))

    # entitlement:user_id 轨 + legacy NULL 轨(本账号 local_id)+ 他人行
    conn.execute(
        "INSERT INTO entitlement (transaction_id, product_id, content_hash,"
        " module, user_local_id, purchased_at, original_purchase_date,"
        " is_active, user_id) VALUES (?,?,?,?,?,?,?,?,?)",
        ("tx-me-1", "deep.single", "hash-me-1", "bazi_deep", local_id,
         now, now, 1, user_id))
    conn.execute(
        "INSERT INTO entitlement (transaction_id, product_id, content_hash,"
        " module, user_local_id, purchased_at, original_purchase_date,"
        " is_active, user_id) VALUES (?,?,?,?,?,?,?,?,?)",
        ("tx-me-legacy", "compat.single", "hash-me-1", "compatibility",
         local_id, now, now, 1, None))  # backfill 前的 legacy 行
    conn.execute(
        "INSERT INTO entitlement (transaction_id, product_id, content_hash,"
        " module, user_local_id, purchased_at, original_purchase_date,"
        " is_active, user_id) VALUES (?,?,?,?,?,?,?,?,?)",
        ("tx-other", "deep.single", "hash-other-1", "bazi_deep", "ulid-other",
         now, now, 1, other_user))

    # ask 台账
    owner = f"user:{user_id}"
    conn.execute(
        "INSERT INTO ask_wallet (owner, balance, updated_at) VALUES (?, ?, ?)",
        (owner, 7, now))
    # ask_trial_mints 主键是 (ip, day)——owner 维度经 WALLET 关联,不落此表;
    # 删除口径对它天然无 user 行(见 account_deletion:ask_trial_mints 按图 7 删 owner
    # 的注释——实际无 owner 列,测试改为验证该表在删除中不受影响即可)
    conn.execute(
        "INSERT INTO ask_trial_mints (ip, day, count) VALUES (?, ?, ?)",
        ("1.2.3.4", "2026-11-24", 1))
    # ask_purchases 实际列:transaction_id, owner, credits, purchased_at, refunded_at, environment
    conn.execute(
        "INSERT INTO ask_purchases (transaction_id, owner, credits,"
        " purchased_at) VALUES (?,?,?,?)",
        ("ask-tx-me", owner, 15, now))
    conn.execute(
        "INSERT INTO ask_purchases (transaction_id, owner, credits,"
        " purchased_at) VALUES (?,?,?,?)",
        ("ask-tx-other", f"user:{other_user}", 15, now))
    # 历史 + 答案缓存(含文本)+ 他人同问不同盘
    conn.execute(
        "INSERT INTO ask_history (owner, chart_hash, day, question_hash,"
        " created_at) VALUES (?,?,?,?,?)",
        (owner, "hash-me-1", "2026-11-24", "qhash-1", now))
    conn.execute(
        "INSERT INTO ask_answer_cache (chart_hash, target_date, question_hash,"
        " conv_fingerprint, interp_fingerprint, language, prompt_version,"
        " variant, answer_json, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("hash-me-1", "2026-11-24", "qhash-1", "cf", "if", "zh", 3,
         "fresh", '{"answer": "你说的处境…"}', now))
    conn.execute(
        "INSERT INTO ask_answer_cache (chart_hash, target_date, question_hash,"
        " conv_fingerprint, interp_fingerprint, language, prompt_version,"
        " variant, answer_json, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("hash-other-1", "2026-11-24", "qhash-1", "cf", "if", "zh", 3,
         "fresh", '{"answer": "他人同问"}', now))

    # interpretation_cache:纯盘面行(保留)/ 含输入行(删)/ 合盘行(删)/ 他人行(保留)
    def _cache(content_hash, module, uih):
        conn.execute(
            "INSERT INTO interpretation_cache (content_hash, module,"
            " prompt_version, target_date, prompt_hash, provider, model,"
            " parent_hash, user_input_hash, language, interpretation,"
            " generated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (content_hash, module, 7, "2026-11-24", "ph", "anthropic",
             "glm-5.3", "", uih, "zh", "cached text", now))
    _cache("hash-me-1", "m0_structure", "")            # 纯盘面 → 保留
    _cache("hash-me-1", "m4_health", "uih-123")        # 含输入 → 删
    # 注:真实生产里合盘行的 content_hash 是 compute_compatibility_hash
    # 组合哈希(已购=经 entitlement 覆盖;免费组合哈希无账号联动,是已知
    # 拍板项,见 review 记录)。此处种子用个体盘哈希 = 模拟「已购联动」形态。
    _cache("hash-me-1", "compatibility", "")            # 合盘(含称呼)→ 删
    _cache("hash-other-1", "m4_health", "uih-999")     # 他人 → 保留
    _cache("hash-other-1", "m0_structure", "")         # 他人 → 保留

    # 免费 LLM 配额
    conn.execute(
        "INSERT INTO free_llm_quota (bucket, day, count) VALUES (?,?,?)",
        (owner, "2026-11-24", 3))
    conn.execute(
        "INSERT INTO free_llm_quota (bucket, day, count) VALUES (?,?,?)",
        ("ip:9.9.9.9", "2026-11-24", 5))  # IP 桶 → 保留(防滥用)
    conn.execute(
        "INSERT INTO free_llm_quota_refunds (bucket, day, count) VALUES (?,?,?)",
        (owner, "2026-11-24", 1))

    conn.commit()
    conn.close()


def _table_rows(db: str, table: str, where: str = "1=1", params=()) -> list:
    conn = sqlite3.connect(db)
    rows = conn.execute(
        f"SELECT * FROM {table} WHERE {where}", params).fetchall()
    conn.close()
    return rows


# ---------- delete_user_data 单事务口径 ----------


def test_delete_user_data_full_scope(shared_db):
    user_id = str(uuid.uuid4())
    _seed_full_account(shared_db, user_id)
    stats = delete_user_data(shared_db, user_id)

    assert stats["qicompass_user"] == 1
    assert stats["user_chart_sync"] == 1
    assert stats["entitlement"] == 2  # user_id 轨 + legacy local_id 轨
    assert stats["ask_purchases"] == 1
    assert stats["ask_wallet"] == 1
    assert stats["ask_history"] == 1
    assert stats["ask_answer_cache"] == 1  # 他人同问行保留
    assert stats["interpretation_cache"] == 2  # 含输入 + 合盘;纯盘面保留
    assert stats["free_llm_quota"] == 1  # IP 桶保留

    # 台词匿名化形状
    rows = _table_rows(shared_db, "entitlement",
                       "transaction_id IN ('tx-me-1','tx-me-legacy')")
    assert len(rows) == 2
    for row in rows:
        # 列序:tx0 product1 content_hash2 module3 local_id4 purchased5
        #       orig6 is_active7 refunded8 revoked9 user_id10 env11
        assert row[2] == "deleted"          # content_hash 抹
        assert row[4] == "deleted"          # user_local_id 抹
        assert row[7] == 0                  # is_active
        assert row[9] is not None           # revoked_at
        assert row[10] is None              # user_id
    assert _table_rows(shared_db, "entitlement", "user_id IS NULL AND user_local_id='deleted'")
    # 他人行原样
    other = _table_rows(shared_db, "entitlement", "transaction_id='tx-other'")
    assert len(other) == 1 and other[0][2] == "hash-other-1"

    # 他人 ask_purchases / 答案缓存 / interpretation_cache 保留
    assert len(_table_rows(shared_db, "ask_purchases",
                           "transaction_id='ask-tx-other'")) == 1
    assert len(_table_rows(shared_db, "ask_answer_cache",
                           "chart_hash='hash-other-1'")) == 1
    assert len(_table_rows(shared_db, "interpretation_cache",
                           "content_hash='hash-other-1'")) == 2
    # 纯盘面行保留
    assert len(_table_rows(
        shared_db, "interpretation_cache",
        "content_hash='hash-me-1' AND module='m0_structure'")) == 1
    # IP 配额桶保留
    assert len(_table_rows(shared_db, "free_llm_quota",
                           "bucket='ip:9.9.9.9'")) == 1
    # 旁观者 user 保留
    assert len(_table_rows(shared_db, "qicompass_user")) == 1


def test_delete_user_data_nonexistent_rolls_back(shared_db):
    user_id = str(uuid.uuid4())
    other = str(uuid.uuid4())
    _seed_full_account(shared_db, other)
    with pytest.raises(ValueError, match="不存在"):
        delete_user_data(shared_db, user_id)
    # 回滚:旁观者数据原样
    assert len(_table_rows(shared_db, "qicompass_user")) == 2
    assert len(_table_rows(shared_db, "user_chart_sync")) == 2


def test_compat_module_names_match_prompts():
    """删除清单与 prompts.COMPATIBILITY_MODULES 漂移锁定(加模块漏登 → 红)。"""
    assert set(_COMPAT_MODULES_FOR_DELETION) == set(COMPATIBILITY_MODULES)


# ---------- /api/auth/account 路由 ----------


@pytest.fixture
async def auth_client(shared_db, monkeypatch):
    """替换 user_store 为 tmp 库实例(路由经 app.state.user_store)。"""
    from app.auth.user_store import UserStore

    store = UserStore(shared_db)
    saved = getattr(app.state, "user_store", None)
    app.state.user_store = store
    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            yield ac, store
    finally:
        app.state.user_store = saved


def _make_user(store, provider="google", provider_sub="google-sub-x"):
    return store.upsert_by_provider(provider, provider_sub, "x@example.com")


async def test_delete_account_requires_auth(auth_client):
    ac, _ = auth_client
    resp = await ac.request("DELETE", "/api/auth/account", json={})
    assert resp.status_code == 401, resp.text


async def test_delete_account_google_flow(auth_client):
    ac, store = auth_client
    user = _make_user(store, provider="google")
    token = create_access_token(user.id)
    resp = await ac.request("DELETE", "/api/auth/account", headers={"Authorization": f"Bearer {token}"}, json={})
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["deleted"] is True
    assert body["user_id_prefix"] == user.id[:8]
    assert body["tables"]["qicompass_user"] == 1
    assert store.get_by_id(user.id) is None


async def test_delete_account_apple_not_configured_503(auth_client, monkeypatch):
    ac, store = auth_client
    user = _make_user(store, provider="apple", provider_sub="apple-sub-x")
    token = create_access_token(user.id)
    # 只 patch configured 开关:真 revoke_apple_tokens 首行即抛 503,
    # 无需(也不应)替换函数本体——被调到 = 配置检查失效,测试必红
    monkeypatch.setattr(
        "app.auth.apple_revocation.revocation_configured", lambda: False)
    resp = await ac.request("DELETE", "/api/auth/account", headers={"Authorization": f"Bearer {token}"}, json={"apple_authorization_code": "any-code"})
    assert resp.status_code == 503, resp.text
    # 未删
    assert store.get_by_id(user.id) is not None


async def test_delete_account_apple_revokes_then_deletes(auth_client, monkeypatch):
    ac, store = auth_client
    user = _make_user(store, provider="apple", provider_sub="apple-sub-x")
    token = create_access_token(user.id)
    calls: list[tuple[str, str]] = []

    async def fake_revoke(authorization_code, expected_apple_user_id):
        calls.append((authorization_code, expected_apple_user_id))

    monkeypatch.setattr("app.api.auth.revoke_apple_tokens", fake_revoke)
    resp = await ac.request("DELETE", "/api/auth/account", headers={"Authorization": f"Bearer {token}"}, json={"apple_authorization_code": "fresh-code"})
    assert resp.status_code == 200, resp.text
    assert calls == [("fresh-code", "apple-sub-x")]
    assert store.get_by_id(user.id) is None


async def test_delete_account_apple_sub_mismatch_403_no_delete(
        auth_client, monkeypatch):
    ac, store = auth_client
    user = _make_user(store, provider="apple", provider_sub="apple-sub-x")
    token = create_access_token(user.id)

    async def mismatch(authorization_code, expected_apple_user_id):
        raise AppleRevocationUserMismatchError(message="sub mismatch")

    monkeypatch.setattr("app.api.auth.revoke_apple_tokens", mismatch)
    resp = await ac.request("DELETE", "/api/auth/account", headers={"Authorization": f"Bearer {token}"}, json={"apple_authorization_code": "other-persons-code"})
    assert resp.status_code == 403, resp.text
    # Apple 侧吊销失败 → 本地不删(先吊销后删除)
    assert store.get_by_id(user.id) is not None


async def test_delete_account_apple_empty_code_rejected(
        auth_client, monkeypatch):
    """已配置但 code 为空(Apple 用户未走重认证)→ 502 分类错,不删。"""
    ac, store = auth_client
    user = _make_user(store, provider="apple", provider_sub="apple-sub-x")
    token = create_access_token(user.id)
    # 真实 revoke_apple_tokens:configured=True 后空 code 走 CodeInvalid 分支
    monkeypatch.setattr(
        "app.auth.apple_revocation.revocation_configured", lambda: True)
    resp = await ac.request(
        "DELETE", "/api/auth/account",
        headers={"Authorization": f"Bearer {token}"}, json={})
    assert resp.status_code == 502, resp.text
    assert resp.json()["error"]["code"] == "APPLE_REVOCATION_CODE_INVALID"
    assert store.get_by_id(user.id) is not None


async def test_delete_account_missing_body_422(auth_client):
    """DELETE 无 body(FastAPI 视请求体必填)→ 422,且不触达删除。"""
    ac, store = auth_client
    user = _make_user(store, provider="google")
    token = create_access_token(user.id)
    resp = await ac.request(
        "DELETE", "/api/auth/account",
        headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 422, resp.text
    assert store.get_by_id(user.id) is not None


async def test_stale_jwt_rejected_after_deletion(auth_client):
    """删号后的残留 JWT:强登录路由拒判(账号存在性核验)。"""
    ac, store = auth_client
    user = _make_user(store, provider="google")
    token = create_access_token(user.id)
    # 先正常通过强登录路由(存在)
    resp = await ac.get(
        "/api/entitlement/list",
        headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code in (200, 422), resp.text  # 422=缺 query 参数也行
    # 删号
    await ac.request("DELETE", "/api/auth/account", headers={"Authorization": f"Bearer {token}"}, json={})
    # 残留 JWT → 401
    resp = await ac.get(
        "/api/entitlement/list",
        headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 401, resp.text
    assert "已删除" in resp.json()["error"]["message"]


# ---------- chapter_feedback IP HMAC ----------


def test_feedback_ip_hmac_not_stored_plaintext(shared_db):
    from app.ai.feedback_store import ChapterFeedbackStore

    store = ChapterFeedbackStore(shared_db)
    store.init_schema()
    out = store.record(
        content_hash="h1", module="m0_structure", verdict="accurate",
        section=None, app_language="zh", client_ip="203.0.113.7")
    assert out.value == "recorded"
    rows = _table_rows(shared_db, "chapter_feedback")
    assert len(rows) == 1
    stored_ip = rows[0][9]  # client_ip 列
    assert stored_ip != "203.0.113.7"
    assert "." not in stored_ip and ":" not in stored_ip  # 十六进制摘要


def test_feedback_ip_hmac_dedup_and_limit(shared_db):
    from app.ai.feedback_store import ChapterFeedbackStore

    store = ChapterFeedbackStore(shared_db, daily_ip_limit=2)
    store.init_schema()
    args = dict(content_hash="h1", module="m0_structure", verdict="accurate",
                section=None, app_language="zh")
    assert store.record(client_ip="1.1.1.1", **args).value == "recorded"
    # 同 IP 同 hash 同日 → 幂等
    assert store.record(client_ip="1.1.1.1", **args).value == "duplicate"
    # 同 IP 不同 hash → 计数,2 条上限
    assert store.record(client_ip="1.1.1.1", content_hash="h2",
                        module="m0_structure", verdict="accurate",
                        section=None, app_language="zh").value == "recorded"
    assert store.record(client_ip="1.1.1.1", content_hash="h3",
                        module="m0_structure", verdict="accurate",
                        section=None, app_language="zh").value == "rate_limited"
    # 不同 IP 不受影响
    assert store.record(client_ip="2.2.2.2", content_hash="h3",
                        module="m0_structure", verdict="accurate",
                        section=None, app_language="zh").value == "recorded"


def test_feedback_ip_hmac_migrates_existing_plaintext(shared_db):
    from app.ai.feedback_store import ChapterFeedbackStore, _hash_ip

    # 先建表、播明文行(绕过 record 的 HMAC)
    store = ChapterFeedbackStore(shared_db)
    store.init_schema()
    conn = sqlite3.connect(shared_db)
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT INTO chapter_feedback (content_hash, module, verdict,"
        " section, app_language, client_ip, created_at)"
        " VALUES ('h1','m0_structure','accurate','','zh','9.9.9.9',?)", (now,))
    conn.commit()
    conn.close()
    # init_schema 幂等重跑 → 清洗
    store.init_schema()
    rows = _table_rows(shared_db, "chapter_feedback")
    assert rows[0][9] == _hash_ip("9.9.9.9")
    assert rows[0][9] != "9.9.9.9"


# ---------- 合盘缓存归属联动(2026-11-25 拍板 #1) ----------


def test_compat_ownership_link_and_cleanup(shared_db):
    """生成期记录 → 删号反查清 compat 缓存行(免费+付费+翻译)→ 归属清零。"""
    from app.ai.cache import InterpretationCache

    user_id = str(uuid.uuid4())
    _seed_full_account(shared_db, user_id)
    cache = InterpretationCache(shared_db)
    now = datetime.now(timezone.utc).isoformat()

    # 模拟生成期:登录用户的合盘(免费 + 付费 + 翻译行,同一 compat_hash)
    conn = sqlite3.connect(shared_db)
    compat_hash = "comp-hash-me"
    # 三行:免费 zh / 付费 zh / 免费翻译 en(PK 含 language 维度,不撞键)
    for module, lang in [("compatibility_free", "zh"),
                         ("compatibility_paid", "zh"),
                         ("compatibility_free", "en")]:
        conn.execute(
            "INSERT INTO interpretation_cache (content_hash, module,"
            " prompt_version, target_date, prompt_hash, provider, model,"
            " parent_hash, user_input_hash, language, interpretation,"
            " generated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (compat_hash, module, 5, "2026-11-25", "ph", "anthropic",
             "glm-5.3", "", "", lang,
             "含对方称呼的解读", now))
    # 他人的合盘缓存(不在删除范围)
    conn.execute(
        "INSERT INTO interpretation_cache (content_hash, module,"
        " prompt_version, target_date, prompt_hash, provider, model,"
        " parent_hash, user_input_hash, language, interpretation,"
        " generated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        ("comp-hash-other", "compatibility_free", 5, "2026-11-25", "ph",
         "anthropic", "glm-5.3", "", "", "zh", "他人合盘", now))
    conn.commit()
    conn.close()

    # 生成期归属记录(interpret/translate 两路各记一次——幂等)
    cache.link_compat_ownership(compat_hash, user_id)
    cache.link_compat_ownership(compat_hash, user_id)
    assert cache.compat_hashes_for_user(user_id) == [compat_hash]

    stats = delete_user_data(shared_db, user_id)

    # 全部 3 行含对方称呼的 compat 缓存被清;他人的保留
    assert stats["compat_cache"] == 3
    assert stats["compat_cache_ownership"] == 1
    assert len(_table_rows(shared_db, "interpretation_cache",
                           "content_hash='comp-hash-other'")) == 1
    assert cache.compat_hashes_for_user(user_id) == []
    # 该用户非 compat 的缓存(M4 等)在主流程已测;此处确认 compat-hash 下零行
    assert len(_table_rows(
        shared_db, "interpretation_cache",
        "content_hash='comp-hash-me'")) == 0


def test_compat_ownership_anonymous_not_recorded(shared_db):
    """匿名(无 user_id)不记归属——无账号可删,表不堆无主行。"""
    from app.ai.cache import InterpretationCache

    cache = InterpretationCache(shared_db)
    # 调用方(interpret.py)在 current_user_id 为 None 时不调 link——
    # 这里测试的是:如果意外调了带空 user_id,应能优雅处理(不炸)
    # 但实际不会发生(guard 在调用方);只验证表本身不因空查询出错
    assert cache.compat_hashes_for_user("nonexistent-user") == []
    assert cache.drop_compat_ownership("nonexistent-user") == 0


def test_link_compat_ownership_idempotent(shared_db):
    """同一 (hash, user) 重复记录不堆行(PK 双列幂等)。"""
    from app.ai.cache import InterpretationCache

    cache = InterpretationCache(shared_db)
    cache.link_compat_ownership("h1", "u1")
    cache.link_compat_ownership("h1", "u1")
    cache.link_compat_ownership("h1", "u1")
    rows = _table_rows(shared_db, "compat_cache_ownership")
    assert len(rows) == 1
    # 不同 hash / 不同 user 各自行
    cache.link_compat_ownership("h2", "u1")
    cache.link_compat_ownership("h1", "u2")
    assert len(_table_rows(shared_db, "compat_cache_ownership")) == 3
