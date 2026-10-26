"""DeviceCheck 客户端单测(问事窗 S4b-2,2026-10-25)。

锁:未配置 → None 降级(非静默)/ @路径读 key / ES256 JWT 形状(kid/iss/
iat)/ query 两比特成功与失败路径 / update 失败不抛只返回 False。
HTTP 一律 httpx.MockTransport,不真调苹果。
"""

from __future__ import annotations

import httpx
import jwt as pyjwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.ask.devicecheck import DeviceCheckClient


def _ec_keypair() -> tuple[str, str]:
    """生成 ES256 密钥对,返回 (private_pem, public_pem)。"""
    key = ec.generate_private_key(ec.SECP256R1())
    priv = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()).decode()
    pub = key.public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    return priv, pub


def _client(handler, priv: str) -> DeviceCheckClient:
    transport = httpx.MockTransport(handler)
    return DeviceCheckClient(
        team_id="TEAM123456", key_id="KEYID99",
        private_key_pem=priv,
        base_url="https://dc.test",
        http_client=httpx.Client(transport=transport))


class TestBuildFromConfig:
    def test_missing_trio_returns_none(self, caplog):
        result = DeviceCheckClient.build_from_config(
            team_id="", key_id="K", private_key="P")
        assert result is None
        assert any("devicecheck 未配置" in r.message for r in caplog.records)

    def test_private_key_at_path_form(self, tmp_path):
        priv, _ = _ec_keypair()
        key_file = tmp_path / "DeviceCheck.p8"
        key_file.write_text(priv, encoding="utf-8")
        client = DeviceCheckClient.build_from_config(
            team_id="TEAM123456", key_id="KEYID99",
            private_key=f"@{key_file}")
        assert client is not None

    def test_private_key_at_unreadable_path_raises(self, tmp_path):
        with pytest.raises(RuntimeError, match="不可读"):
            DeviceCheckClient.build_from_config(
                team_id="TEAM123456", key_id="KEYID99",
                private_key=f"@{tmp_path / 'nope.p8'}")

    def test_invalid_private_key_raises_at_build(self):
        """坏 p8 构建期显式抛(fail-fast),不留到运行期每次铸造 500。"""
        with pytest.raises(RuntimeError, match="ES256"):
            DeviceCheckClient.build_from_config(
                team_id="TEAM123456", key_id="KEYID99",
                private_key="not-a-pem-at-all")


class TestQueryTwoBits:
    def test_ok_returns_bit0(self):
        priv, pub = _ec_keypair()
        captured: dict = {}

        def handler(request: httpx.Request) -> httpx.Response:
            captured["path"] = request.url.path
            captured["jwt"] = request.headers["X-Apple-DC-JWT"]
            captured["body"] = request.read().decode()
            return httpx.Response(200, json={"bit0": True, "bit1": False})

        client = _client(handler, priv)
        result = client.query_two_bits("device-token-abc")
        assert result.success is True and result.bit0 is True
        assert captured["path"] == "/v1/query_two_bits"
        assert '"device_token":"device-token-abc"' in captured["body"]
        assert '"timestamp":' in captured["body"]
        # JWT 形状:ES256 + kid header + iss/iat claims(验签用同对公钥)
        headers = pyjwt.get_unverified_header(captured["jwt"])
        assert headers["alg"] == "ES256" and headers["kid"] == "KEYID99"
        claims = pyjwt.decode(
            captured["jwt"], pub, algorithms=["ES256"])
        assert claims["iss"] == "TEAM123456" and "iat" in claims

    def test_http_error_degrades_not_raises(self):
        priv, _ = _ec_keypair()
        client = _client(
            lambda request: httpx.Response(410, text="Gone"), priv)
        result = client.query_two_bits("tok")
        assert result.success is False and result.bit0 is False
        assert result.status_code == 410

    def test_network_error_degrades_not_raises(self):
        priv, _ = _ec_keypair()

        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("boom")

        client = _client(handler, priv)
        result = client.query_two_bits("tok")
        assert result.success is False

    def test_200_non_json_body_degrades(self):
        """200 但响应体非 JSON(代理插页等)→ success=False,不裸抛。"""
        priv, _ = _ec_keypair()
        client = _client(
            lambda request: httpx.Response(200, text="<html>hi</html>"), priv)
        result = client.query_two_bits("tok")
        assert result.success is False and result.bit0 is False

    def test_200_non_dict_json_degrades(self):
        """200 + JSON 数组(非对象)→ success=False,body.get 不可用。"""
        priv, _ = _ec_keypair()
        client = _client(
            lambda request: httpx.Response(200, json=[1, 2]), priv)
        result = client.query_two_bits("tok")
        assert result.success is False


class TestUpdateTwoBits:
    def test_ok_returns_true(self):
        priv, _ = _ec_keypair()
        captured: dict = {}

        def handler(request: httpx.Request) -> httpx.Response:
            captured["path"] = request.url.path
            captured["body"] = request.read().decode()
            return httpx.Response(200, json={})

        client = _client(handler, priv)
        assert client.update_two_bits("tok", bit0=True) is True
        assert captured["path"] == "/v1/update_two_bits"
        assert '"bit0":true' in captured["body"]
        assert '"bit1":false' in captured["body"]

    def test_http_error_returns_false(self):
        priv, _ = _ec_keypair()
        client = _client(
            lambda request: httpx.Response(401, text="Unauthorized"), priv)
        assert client.update_two_bits("tok", bit0=True) is False

    def test_network_error_returns_false(self):
        priv, _ = _ec_keypair()

        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectTimeout("timeout")

        client = _client(handler, priv)
        assert client.update_two_bits("tok", bit0=True) is False
