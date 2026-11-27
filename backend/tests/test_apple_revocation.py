"""TASK-15:revoke_apple_tokens HTTP 层测试(httpx.MockTransport,不新增依赖)。

端点层(test_account_deletion)整体 monkeypatch 掉了本函数——这里按流程
逐步断言:换 code → 验归属 → 吊销,含 token_type_hint 跟随实际 token、
各失败分型与「未打到 /auth/revoke」的短路性。
"""
from __future__ import annotations

import base64
from types import SimpleNamespace

import httpx
import jwt as pyjwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
)

from app.auth import apple_revocation as ar
from app.config import normalize_pem_private_key
from app.errors import BaziError


def _err_type(exc: BaziError) -> str:
    return type(exc).__name__


@pytest.fixture
def p256_pair():
    priv = ec.generate_private_key(ec.SECP256R1())
    priv_pem = priv.private_bytes(
        Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()).decode()
    pub_pem = priv.public_key().public_bytes(
        Encoding.PEM, PublicFormat.SubjectPublicKeyInfo).decode()
    return priv_pem, pub_pem


@pytest.fixture
def configured(monkeypatch, p256_pair):
    priv_pem, _ = p256_pair
    monkeypatch.setattr(ar, "APPLE_AUTH_TEAM_ID", "TEAM123")
    monkeypatch.setattr(ar, "APPLE_AUTH_KEY_ID", "KEYID99")
    monkeypatch.setattr(ar, "APPLE_AUTH_PRIVATE_KEY", priv_pem)
    monkeypatch.setattr(ar, "APPLE_SIGN_IN_CLIENT_ID", "com.qicompass.app")
    return p256_pair


def _install_transport(monkeypatch, handler):
    """模块内 httpx.AsyncClient 强制挂 MockTransport(handler)。"""
    real_async_client = httpx.AsyncClient

    def factory(**kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        return real_async_client(**kwargs)

    monkeypatch.setattr(ar.httpx, "AsyncClient", factory)


def _token_response(*, refresh: bool = True, sub: str = "apple-user-1"):
    id_payload = base64.urlsafe_b64encode(
        ('{"sub": "%s"}' % sub).encode()).decode().rstrip("=")
    id_token = "header.%s.sig" % id_payload
    body = {"access_token": "at-1", "id_token": id_token}
    if refresh:
        body["refresh_token"] = "rt-1"
    return body


async def test_happy_path_full_flow(monkeypatch, configured):
    _, pub_pem = configured
    seen = {"token": None, "revoke": None}

    def handler(request: httpx.Request) -> httpx.Response:
        url, form = request.url.path, dict(
            pair.split("=", 1) for pair in
            request.read().decode().split("&"))
        if url == "/auth/token":
            seen["token"] = form
            return httpx.Response(200, json=_token_response())
        if url == "/auth/revoke":
            seen["revoke"] = form
            return httpx.Response(200, json={"success": True})
        raise AssertionError("意外请求 " + url)

    _install_transport(monkeypatch, handler)
    monkeypatch.setattr(
        ar, "verify_apple_identity_token",
        lambda tok: SimpleNamespace(apple_user_id="apple-user-1"))

    await ar.revoke_apple_tokens("code-xyz", expected_apple_user_id="apple-user-1")

    assert seen["token"]["code"] == "code-xyz"
    assert seen["token"]["grant_type"] == "authorization_code"
    assert seen["token"]["client_id"] == "com.qicompass.app"
    # client_secret 是 ES256 JWT,测试公钥可解出约定 claims
    secret = pyjwt.decode(
        seen["token"]["client_secret"], pub_pem, algorithms=["ES256"],
        audience="https://appleid.apple.com",
        options={"verify_exp": False})
    assert secret["iss"] == "TEAM123"
    assert secret["sub"] == "com.qicompass.app"
    # kid 在 JWT 头(标识用哪把 .p8),不在 claims
    assert pyjwt.get_unverified_header(
        seen["token"]["client_secret"])["kid"] == "KEYID99"

    assert seen["revoke"]["token"] == "rt-1"
    assert seen["revoke"]["token_type_hint"] == "refresh_token"


async def test_token_endpoint_non_200_short_circuits(monkeypatch, configured):
    seen = {"revoke": False}

    def handler(request):
        if request.url.path == "/auth/token":
            return httpx.Response(400, json={"error": "invalid_grant"})
        seen["revoke"] = True
        raise AssertionError("不应打到 /auth/revoke")

    _install_transport(monkeypatch, handler)
    with pytest.raises(BaziError) as ei:
        await ar.revoke_apple_tokens("bad", expected_apple_user_id="x")
    assert _err_type(ei.value) == "AppleRevocationCodeInvalidError"
    assert not seen["revoke"]


async def test_sub_mismatch_rejects(monkeypatch, configured):
    def handler(request):
        if request.url.path == "/auth/token":
            return httpx.Response(200, json=_token_response(sub="someone-else"))
        raise AssertionError("sub 不符不应打到 /auth/revoke")

    _install_transport(monkeypatch, handler)
    monkeypatch.setattr(
        ar, "verify_apple_identity_token",
        lambda tok: SimpleNamespace(apple_user_id="someone-else"))
    with pytest.raises(BaziError) as ei:
        await ar.revoke_apple_tokens("code", expected_apple_user_id="apple-user-1")
    assert _err_type(ei.value) == "AppleRevocationUserMismatchError"


async def test_access_token_fallback_hint(monkeypatch, configured):
    seen = {}

    def handler(request):
        if request.url.path == "/auth/token":
            return httpx.Response(200, json=_token_response(refresh=False))
        form = dict(pair.split("=", 1) for pair in
                    request.read().decode().split("&"))
        seen.update(form)
        return httpx.Response(200, json={})

    _install_transport(monkeypatch, handler)
    monkeypatch.setattr(
        ar, "verify_apple_identity_token",
        lambda tok: SimpleNamespace(apple_user_id="apple-user-1"))
    await ar.revoke_apple_tokens("code", expected_apple_user_id="apple-user-1")
    assert seen["token"] == "at-1"
    assert seen["token_type_hint"] == "access_token"


async def test_revoke_non_200_raises(monkeypatch, configured):
    def handler(request):
        if request.url.path == "/auth/token":
            return httpx.Response(200, json=_token_response())
        return httpx.Response(400, text="revoke failed")

    _install_transport(monkeypatch, handler)
    monkeypatch.setattr(
        ar, "verify_apple_identity_token",
        lambda tok: SimpleNamespace(apple_user_id="apple-user-1"))
    with pytest.raises(BaziError) as ei:
        await ar.revoke_apple_tokens("code", expected_apple_user_id="apple-user-1")
    assert _err_type(ei.value) == "AppleRevocationEndpointError"


async def test_not_configured_rejects(monkeypatch):
    monkeypatch.setattr(ar, "APPLE_AUTH_TEAM_ID", "")
    # 护栏:配置缺失必须在发起任何 HTTP 之前拒绝——分支若被重排到
    # 构造 client 之后,这里直接炸而不是打真实 appleid.apple.com
    def refuse_http(request):
        raise AssertionError("配置缺失不应发起 HTTP " + request.url.path)

    _install_transport(monkeypatch, refuse_http)
    with pytest.raises(BaziError) as ei:
        await ar.revoke_apple_tokens("code", expected_apple_user_id="x")
    assert _err_type(ei.value) == "AppleRevocationNotConfiguredError"


async def test_private_key_literal_newline_normalized(monkeypatch, p256_pair):
    """APPLE_AUTH_PRIVATE_KEY 以字面 \n 单行书写时,经 config 归一化后可签名。

    归一化走 config.normalize_pem_private_key 真实现(不在测试里
    自己 replace 自证)——config 侧归一化被回归破坏时,本用例报警。
    """
    priv_pem, pub_pem = p256_pair
    one_line = priv_pem.replace("\n", "\\n")
    monkeypatch.setattr(ar, "APPLE_AUTH_TEAM_ID", "TEAM123")
    monkeypatch.setattr(ar, "APPLE_AUTH_KEY_ID", "KEYID99")
    monkeypatch.setattr(
        ar, "APPLE_AUTH_PRIVATE_KEY", normalize_pem_private_key(one_line))
    monkeypatch.setattr(ar, "APPLE_SIGN_IN_CLIENT_ID", "com.qicompass.app")

    seen = {}

    def handler(request):
        if request.url.path == "/auth/token":
            form = dict(pair.split("=", 1) for pair in
                        request.read().decode().split("&"))
            seen["secret"] = form["client_secret"]
            return httpx.Response(200, json=_token_response())
        return httpx.Response(200, json={})

    _install_transport(monkeypatch, handler)
    monkeypatch.setattr(
        ar, "verify_apple_identity_token",
        lambda tok: SimpleNamespace(apple_user_id="apple-user-1"))
    await ar.revoke_apple_tokens("code", expected_apple_user_id="apple-user-1")
    decoded = pyjwt.decode(
        seen["secret"], pub_pem, algorithms=["ES256"],
        audience="https://appleid.apple.com",
        options={"verify_exp": False})
    assert decoded["iss"] == "TEAM123"
