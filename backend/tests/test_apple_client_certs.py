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
