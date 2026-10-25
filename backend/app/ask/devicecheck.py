"""Apple DeviceCheck 两比特接口客户端(问事防刷,S4b-2,2026-10-25)。

用途(MONETIZATION.md §问事窗,2026-10-25 拍板 v1 就加):跨重装的设备
指纹——2 比特存苹果服务器,卸载重装不重置。用 bit0 标记「该物理设备
已铸造过问事试用」,堵「重装刷 3 次」的源头(与 IP 限铸闸互补:DC 锚
设备、限铸锚网络出口)。

零新依赖:JWT 用 pyjwt(ES256)+ cryptography(已在 requirements,
Apple Sign in 验签同源依赖)。

降级纪律(错误显式传播的边界):
- 未配置 env → build_from_config 返回 None,service 层走纯限铸闸
  (启动时已 warning 一次,非静默)
- 密钥不可读/不可用 → 构建期 RuntimeError 显式抛(配置错误是部署
  问题,fail-fast;不留到运行期每次铸造 500)
- 查询/回写失败(网络/非 200/坏响应体)→ 打日志后按「无法判定」
  处理:查询失败放行铸造(限铸闸兜底)、回写失败不回滚铸造(bit
  漏写最坏 = 该设备可再铸一次,仍被限铸闸封顶)。防刷件故障不应
  500 正常用户的问事流。
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass

import httpx
import jwt

logger = logging.getLogger(__name__)

# 生产 API;测试注入 mock transport 时同 base_url 即可拦截
DEVICECHECK_BASE_URL = "https://api.devicecheck.apple.com"


@dataclass(frozen=True)
class DeviceCheckQueryResult:
    """查询结果:bit0 仅在 success 时有意义;失败显式带状态。"""

    success: bool
    bit0: bool = False
    # status_code / error 供日志与测试断言;success=False 时 bit0 恒 False
    status_code: int | None = None


class DeviceCheckClient:
    """DeviceCheck v1 两比特接口(query_two_bits / update_two_bits)。"""

    def __init__(
        self, *, team_id: str, key_id: str, private_key_pem: str,
        base_url: str = DEVICECHECK_BASE_URL,
        http_client: httpx.Client | None = None,
        timeout_seconds: float = 5.0,
    ):
        self._team_id = team_id
        self._key_id = key_id
        self._private_key_pem = private_key_pem
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout_seconds
        # http_client 注入口留给测试(MockTransport);None = 每次请求
        # 短连接(对齐仓库「SQLite 短连接」的轻量习惯,不长寿连接状态)
        self._http_client = http_client

    @classmethod
    def build_from_config(
        cls, *, team_id: str, key_id: str, private_key: str,
    ) -> "DeviceCheckClient | None":
        """从 config 读三元组构建;任一缺失 → None(调用方降级,不静默)。

        private_key 支持两种形态:p8 PEM 文本,或 "@路径"(密钥不入 env
        明文的部署习惯,读文件失败显式抛)。
        """
        if not (team_id and key_id and private_key):
            logger.warning(
                "devicecheck 未配置(需 team_id/key_id/private_key 三元组),"
                "问事试用铸造走纯 IP 限铸闸(防刷降级,非静默)")
            return None
        if private_key.startswith("@"):
            path = private_key[1:]
            try:
                with open(path, encoding="utf-8") as f:
                    private_key = f.read()
            except OSError as e:
                # 配置错误是部署问题:显式抛(错误传播),不降级吞掉
                raise RuntimeError(
                    f"QICOMPASS_DEVICECHECK_PRIVATE_KEY 指向文件不可读: "
                    f"{path}: {e}") from e
        client = cls(team_id=team_id, key_id=key_id, private_key_pem=private_key)
        # 密钥可用性在构建期验证(试签一发):坏 p8 若留到运行期,每次铸造
        # 都在 jwt.encode 处裸抛 → 端点 500,违反「防刷件故障不 500」契约;
        # 且与「@路径不可读显式抛」对称——不可读抛,可读但坏同样抛。
        # 坏 PEM 在已装 pyjwt 下抛 cryptography 的 ValueError(实测未被
        # pyjwt 包成 PyJWTError),非 str/bytes 抛 TypeError——一并纳入
        try:
            client._make_jwt()
        except (jwt.PyJWTError, ValueError, TypeError) as e:
            raise RuntimeError(
                "QICOMPASS_DEVICECHECK_PRIVATE_KEY 不是可用的 ES256 私钥"
                f"(p8 PEM 解析/试签失败): {e}") from e
        return client

    # ---------- 内部 ----------

    def _make_jwt(self) -> str:
        """ES256 JWT(iss=team_id, iat=秒);kid 进 header。

        DeviceCheck 不吃 exp,iat 每 JWT 生成时新鲜取(苹果要求请求时间
        与服务器时差有限,不缓存 JWT)。
        """
        now = int(time.time())
        return jwt.encode(
            {"iss": self._team_id, "iat": now},
            self._private_key_pem,
            algorithm="ES256",
            headers={"kid": self._key_id},
        )

    def _post(self, path: str, payload: dict) -> httpx.Response:
        headers = {"X-Apple-DC-JWT": self._make_jwt()}
        if self._http_client is not None:
            return self._http_client.post(
                f"{self._base_url}{path}", json=payload, headers=headers)
        with httpx.Client(timeout=self._timeout) as client:
            return client.post(
                f"{self._base_url}{path}", json=payload, headers=headers)

    # ---------- 对外 ----------

    def query_two_bits(self, device_token: str) -> DeviceCheckQueryResult:
        """查询设备两比特。失败返回 success=False(调用方降级,见模块注释)。"""
        payload = {
            "device_token": device_token,
            "timestamp": int(time.time() * 1000),
            # transaction_id 任意唯一串即可(苹果仅用作请求去重审计)
            "transaction_id": f"qc-ask-query-{int(time.time() * 1000)}",
        }
        try:
            resp = self._post("/v1/query_two_bits", payload)
        except (httpx.HTTPError, jwt.PyJWTError) as e:
            logger.exception("devicecheck.query_failed device_token=%s… "
                             "error=%r", device_token[:8], e)
            return DeviceCheckQueryResult(success=False)
        if resp.status_code != 200:
            logger.error(
                "devicecheck.query_failed device_token=%s… status=%s body=%s",
                device_token[:8], resp.status_code, resp.text[:200])
            return DeviceCheckQueryResult(success=False,
                                          status_code=resp.status_code)
        try:
            data = resp.json()
        except ValueError as e:
            # 200 但响应体非 JSON(代理/CDN 插页等):按查询失败降级,
            # 不让 JSONDecodeError 裸抛穿透到问事流
            logger.error("devicecheck.query_bad_json device_token=%s… "
                         "error=%r body=%s",
                         device_token[:8], e, resp.text[:200])
            return DeviceCheckQueryResult(success=False,
                                          status_code=resp.status_code)
        if not isinstance(data, dict):
            logger.error("devicecheck.query_bad_shape device_token=%s… "
                         "body=%s", device_token[:8], resp.text[:200])
            return DeviceCheckQueryResult(success=False,
                                          status_code=resp.status_code)
        return DeviceCheckQueryResult(
            success=True, bit0=bool(data.get("bit0", False)),
            status_code=200)

    def update_two_bits(self, device_token: str, *, bit0: bool) -> bool:
        """回写两比特。失败只记日志返回 False(不回滚铸造,见模块注释)。"""
        payload = {
            "device_token": device_token,
            "timestamp": int(time.time() * 1000),
            "transaction_id": f"qc-ask-update-{int(time.time() * 1000)}",
            "bit0": bit0,
            "bit1": False,
        }
        try:
            resp = self._post("/v1/update_two_bits", payload)
        except (httpx.HTTPError, jwt.PyJWTError) as e:
            logger.exception("devicecheck.update_failed device_token=%s… "
                             "error=%r", device_token[:8], e)
            return False
        if resp.status_code != 200:
            logger.error(
                "devicecheck.update_failed device_token=%s… status=%s body=%s",
                device_token[:8], resp.status_code, resp.text[:200])
            return False
        return True
