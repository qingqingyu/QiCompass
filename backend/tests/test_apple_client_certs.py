"""Apple Root CA 装载 + main.py fail-fast 测试(2026-08-23 Fix 4)。

覆盖:
- _load_apple_root_certs:目录缺失 / 空 / 坏 .cer → RuntimeError(fail-fast)
- _load_apple_root_certs:合法 DER .cer → 返回 bytes 列表
- _build_apple_server_api:env 不齐 → MockAppleServerAPI(dev/test 降级保留)
- _build_apple_server_api:env 配齐 + 构造失败 → RuntimeError **不降级 Mock**
  (Mock 验证全通过,生产降级 = entitlement 校验形同虚设,fail-open)

背景:老实现 root_certificates 恒空 + 注释称「空 list 只做签名格式校验」,
实测 SDK _ChainVerifier 对空 root 列表必抛 VerificationException(fail-closed),
即真支付链路 100% 502。本组测试锁定修复后的行为。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from app.entitlement import MockAppleServerAPI
from app.entitlement.apple_client import _load_apple_root_certs
from app.main import _build_apple_server_api


def _write_test_root_cert(certs_dir: Path) -> bytes:
    """生成一张自签名 EC P-256 根证书(DER)写入 certs_dir,返回 DER bytes。

    cryptography 是 app-store-server-library 的传递依赖(SDK 签名链必装),
    测试直接用它造合法 DER,不新增依赖。
    """
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test-apple-root")])
    now = datetime.now(timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(days=1))
        .not_valid_after(now + timedelta(days=1))
        .sign(key, hashes.SHA256())
    )
    der = cert.public_bytes(serialization.Encoding.DER)
    (certs_dir / "AppleRootCA-TEST.cer").write_bytes(der)
    return der


# ===== _load_apple_root_certs =====


def test_load_root_certs_missing_dir_raises(tmp_path):
    """目录不存在 → RuntimeError(不返回空 list)。"""
    with pytest.raises(RuntimeError, match="目录缺失"):
        _load_apple_root_certs(tmp_path / "no-such-dir")


def test_load_root_certs_empty_dir_raises(tmp_path):
    """目录存在但无 .cer → RuntimeError。"""
    certs_dir = tmp_path / "certs"
    certs_dir.mkdir()
    with pytest.raises(RuntimeError, match="目录为空"):
        _load_apple_root_certs(certs_dir)


def test_load_root_certs_garbage_cer_raises(tmp_path):
    """非 DER X.509 内容的 .cer → RuntimeError(下载损坏早暴露)。"""
    certs_dir = tmp_path / "certs"
    certs_dir.mkdir()
    (certs_dir / "broken.cer").write_bytes(b"not a certificate")
    with pytest.raises(RuntimeError, match="无法解析"):
        _load_apple_root_certs(certs_dir)


def test_load_root_certs_valid_der_returns_bytes(tmp_path):
    """合法 DER .cer → 返回 bytes 列表。"""
    certs_dir = tmp_path / "certs"
    certs_dir.mkdir()
    der = _write_test_root_cert(certs_dir)
    certs = _load_apple_root_certs(certs_dir)
    assert certs == [der]


# ===== _build_apple_server_api fail-fast =====


def test_build_apple_api_env_incomplete_returns_mock(monkeypatch):
    """env 不齐 → MockAppleServerAPI(dev/test 降级保留,行为不变)。"""
    import app.main as main_mod
    monkeypatch.setattr(main_mod, "apple_env_configured", lambda: False)
    api = _build_apple_server_api()
    assert isinstance(api, MockAppleServerAPI)


def test_build_apple_api_env_configured_init_failure_does_not_fallback_mock(
    monkeypatch,
):
    """env 配齐 + 客户端构造失败(缺 Root CA / 私钥格式不对等)
    → RuntimeError 向上抛,**绝不降级 Mock**(fail-open 防线)。

    填 dummy env 值:真实失败点在 Root CA 目录缺证书或 SDK 私钥解析,
    具体哪一步不重要——断言的是「失败必须传播,不许 Mock 兜底」。
    """
    import app.main as main_mod
    monkeypatch.setattr(main_mod, "apple_env_configured", lambda: True)
    monkeypatch.setattr(main_mod, "APP_STORE_BUNDLE_ID", "com.test.app")
    monkeypatch.setattr(main_mod, "APP_STORE_KEY_ID", "TESTKEY001")
    monkeypatch.setattr(main_mod, "APP_STORE_ISSUER_ID", "issuer-test")
    monkeypatch.setattr(main_mod, "APP_STORE_PRIVATE_KEY", "not-a-real-key")
    monkeypatch.setattr(main_mod, "APP_STORE_ENVIRONMENT", "sandbox")
    monkeypatch.setattr(main_mod, "APP_STORE_APP_APPLE_ID", "1")
    with pytest.raises(RuntimeError):
        _build_apple_server_api()


def test_real_sdk_import_surface():
    """真 SDK(app-store-server-library 1.x)import 面 + 签名面防回归锚。

    背景(2026-11-22 生产实修):apple_client 的 lazy import 写的是 0.x
    时代的平铺模块 models_library,SDK 1.x 已重构为 models 包——dev 测试全
    mock 盖住了这层,生产 env 配齐首次真 import 即炸(东京 VPS 启动失败)。
    本用例**不 mock**,直接按 apple_client 实际 import 的三处符号逐一
    验证;SDK 未装的极简环境 importorskip 跳过(venv 必装,CI/dev 都会跑)。
    未来升级 SDK 改布局/改签名时,这里先红,而不是等生产启动炸。
    """
    pytest.importorskip("appstoreserverlibrary")
    # 1) Environment 枚举:apple_client.__init__ 用(1.x = models 包)
    from appstoreserverlibrary.models.Environment import Environment
    assert Environment.PRODUCTION is not None
    assert Environment.SANDBOX is not None
    # 2) API client + 异常类型:verify_transaction 用
    from appstoreserverlibrary.api_client import (
        APIException,
        AppStoreServerAPIClient,
    )
    exc = APIException(500, error_message="t")
    for attr in ("http_status_code", "api_error", "raw_api_error",
                 "error_message"):
        assert hasattr(exc, attr), f"APIException 缺 {attr}(404 回落判定依赖)"
    import inspect
    params = inspect.signature(AppStoreServerAPIClient.__init__).parameters
    assert "signing_key" in params, "client 构造签名漂移"
    # bytes 类型断言:SDK ≥1.0.0 该参数注解恒为 bytes;str 私钥构造即抛
    # TypeError(本仓生产实修根因之一)。只查参数名不锁类型 = 锚有洞。
    assert params["signing_key"].annotation is bytes, (
        "signing_key 注解不再是 bytes——SDK 签名面漂移,apple_client 的"
        " .encode(\"utf-8\") 需复核"
    )
    # 3) verifier:两处方法名(1.x notification 方法去掉了 signed_ 前缀)
    from appstoreserverlibrary.signed_data_verifier import SignedDataVerifier
    assert hasattr(SignedDataVerifier, "verify_and_decode_signed_transaction")
    assert hasattr(SignedDataVerifier, "verify_and_decode_notification"), (
        "1.x 方法名;若 SDK 又改名,apple_client.verify_notification 同步"
    )


def test_real_sdk_client_init_success(monkeypatch, tmp_path):
    """env 配齐 + 合法 EC PEM + 证书就位 → 真 SDK 全套构造成功(正向锚)。

    背景(2026-11-22 生产实修):signing_key 必须 bytes,str 私钥在 SDK
    构造即抛 TypeError(被包装成 RuntimeError)。若无本正向锚,把
    apple_client.__init__ 里的 .encode("utf-8") 删掉后全仓测试依然全绿
    ——str→TypeError→RuntimeError 恰好满足既有 fail-fast 用例的失败
    断言,bytes 修复可被静默回退到事故原状。本用例真实穿过两套
    client + verifier 构造,是 bytes 修复唯一的行为级回归锚。
    """
    pytest.importorskip("appstoreserverlibrary")
    certs_dir = tmp_path / "certs"
    certs_dir.mkdir()
    _write_test_root_cert(certs_dir)

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    pem = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()

    import app.entitlement.apple_client as apple_client_mod
    monkeypatch.setattr(apple_client_mod, "_CERTS_DIR", certs_dir)

    from app.entitlement.apple_client import AppleServerAPIClient
    client = AppleServerAPIClient(
        bundle_id="com.test.app",
        key_id="TESTKEY001",
        issuer_id="issuer-test",
        private_key=pem,
        app_apple_id="123",
    )
    assert client._client_prod is not None
    assert client._client_sbx is not None
    assert client._verifier_prod is not None
    assert client._verifier_sbx is not None
