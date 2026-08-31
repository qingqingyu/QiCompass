"""gpt-image-2 生图客户端(httpx,OpenAI images/generations 兼容)。

镜像 OpenAIClient 惯用法:显式校验、trust_env=False(本地代理 TLS-in-TLS
坑)、失败抛 AIProviderError 不重试不降级。实测延迟 63-181s/张
(2026-08-30 三方向样图),timeout 由 config.IMAGE_TIMEOUT_SECONDS(240s)
控制,超时即显式报错。

返回 b64_json → bytes(iOS 端 UIImage(data:) 一步成像)。
"""

from __future__ import annotations

import base64
import logging
from typing import Any

import httpx

from ..config import IMAGE_MODEL, IMAGE_SIZE, IMAGE_TIMEOUT_SECONDS
from ..errors import AIProviderError

logger = logging.getLogger(__name__)


class ImageGenClient:
    """OpenAI images/generations 适配器(gettoken image 中转实测兼容)。"""

    def __init__(
        self,
        api_key: str | None,
        model: str = IMAGE_MODEL,
        base_url: str = "",
        size: str = IMAGE_SIZE,
    ):
        if not model.strip():
            raise ValueError("Image model must not be blank")
        if not size.strip():
            raise ValueError("Image size must not be blank")
        # base_url 允许空(key/base 缺失策略:启动不失败,调用时显式 503)
        self._api_key = api_key
        self._model = model
        self._base_url = base_url.rstrip("/")
        self._size = size

    @property
    def model(self) -> str:
        return self._model

    async def generate(self, prompt: str, *, timeout: float | None = None) -> bytes:
        """生成一张插画,返回 PNG bytes。

        Raises:
            AIProviderError: key/base_url 未配置 / HTTP 非 200 / 超时 /
                响应缺 b64_json(全部显式,不重试不降级)。
        """
        if not self._api_key:
            raise AIProviderError(
                "IMAGE_API_KEY not configured(后端未设置生图 key,无法生成插画)"
            )
        if not self._base_url:
            raise AIProviderError(
                "IMAGE_API_BASE_URL not configured(后端未设置生图网关地址)"
            )

        url = f"{self._base_url}/images/generations"
        try:
            async with httpx.AsyncClient(
                timeout=timeout if timeout is not None else IMAGE_TIMEOUT_SECONDS,
                trust_env=False,
            ) as client:
                resp = await client.post(
                    url,
                    headers={"Authorization": f"Bearer {self._api_key}"},
                    json={
                        "model": self._model,
                        "prompt": prompt,
                        "size": self._size,
                    },
                )
        except httpx.HTTPError as e:
            raise AIProviderError(
                f"生图请求失败({type(e).__name__}: {e})",
            ) from e

        if resp.status_code != 200:
            # 错误消息只透状态码(同 openai_client 口径):error_message 会经
            # GET 409 直达客户端,上游 body 可能回显网关内部细节,不外漏;
            # 排障现场截断后落服务端日志。
            logger.error(
                "image.gen.http_error status=%d body=%.300s",
                resp.status_code, resp.text,
            )
            raise AIProviderError(
                f"生图上游 HTTP {resp.status_code}",
            )

        try:
            payload: Any = resp.json()
        except ValueError as e:
            # 200 但非 JSON(网关错误页等):归一为 provider 错,兑现
            # 「失败即 AIProviderError」类契约,不漏裸 JSONDecodeError
            raise AIProviderError(f"生图响应非 JSON: {e}") from e
        data: Any = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, list) or not data:
            raise AIProviderError("生图响应缺 data 数组")
        if not isinstance(data[0], dict):
            raise AIProviderError("生图响应 data[0] 非对象")
        b64 = data[0].get("b64_json")
        if not b64:
            raise AIProviderError("生图响应缺 b64_json 字段")
        try:
            return base64.b64decode(b64)
        except Exception as e:  # b64 解码失败属上游脏数据,归一为 provider 错
            raise AIProviderError(f"生图响应 b64 解码失败: {e}") from e
