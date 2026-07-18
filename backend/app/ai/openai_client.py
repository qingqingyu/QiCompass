"""OpenAI Chat Completions API 同步客户端(httpx)。

支持自定义 base_url,兼容官方 / Azure / 第三方代理(如 clawto.link)。
注意:不用 Responses API(/v1/responses),因为大多数第三方网关不支持。
"""

from __future__ import annotations

import httpx

from ..config import AI_MAX_OUTPUT_TOKENS, AI_TIMEOUT_SECONDS, OPENAI_MODEL
from ..errors import AIProviderError


class OpenAIClient:
    """OpenAI Chat Completions API 适配器。"""

    provider = "openai"

    def __init__(
        self,
        api_key: str | None,
        model: str = OPENAI_MODEL,
        base_url: str = "https://api.openai.com/v1",
    ):
        if not model.strip():
            raise ValueError("OpenAI model must not be blank")
        if not base_url.strip():
            raise ValueError("OpenAI base_url must not be blank")
        self._api_key = api_key
        self._model = model
        self._base_url = base_url.rstrip("/")

    @property
    def model(self) -> str:
        return self._model

    def interpret(self, prompt: str) -> str:
        """调 OpenAI Chat Completions API,返回 choices[0].message.content。"""
        if not self._api_key:
            raise AIProviderError(
                "OPENAI_API_KEY not configured"
                "(后端未设置 API key,无法调用 OpenAI)"
            )

        url = f"{self._base_url}/chat/completions"
        try:
            # trust_env=False:不读 HTTPS_PROXY/HTTP_PROXY 环境变量。
            # 原因:本地开发用的代理软件(Clash/Surge/V2Ray)TLS-in-TLS 隧道
            # 经常出 SSL EOF,而 clawto.link 这种国内/亚洲 endpoint 本就不需要代理。
            # 部署到生产后,服务器一般也不该走用户级代理。
            resp = httpx.post(
                url,
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": self._model,
                    "messages": [{"role": "user", "content": prompt}],
                    "max_tokens": AI_MAX_OUTPUT_TOKENS,
                },
                timeout=AI_TIMEOUT_SECONDS,
                trust_env=False,
            )
            resp.raise_for_status()
        except httpx.TimeoutException as e:
            raise AIProviderError(
                f"OpenAI API 超时({type(e).__name__}): {e}"
            ) from e
        except httpx.HTTPStatusError as e:
            status_code = e.response.status_code
            if status_code == 429:
                raise AIProviderError(
                    f"OpenAI API 限流({type(e).__name__}): HTTP {status_code}"
                ) from e
            if status_code == 401:
                raise AIProviderError(
                    "OpenAI API key 无效或未授权(HTTP 401),"
                    "请检查 OPENAI_API_KEY 配置"
                ) from e
            raise AIProviderError(
                f"OpenAI API HTTP {status_code}({type(e).__name__})"
            ) from e
        except httpx.RequestError as e:
            raise AIProviderError(
                f"OpenAI API 调用失败({type(e).__name__}): {e}"
            ) from e

        try:
            payload = resp.json()
        except ValueError as e:
            raise AIProviderError(
                f"OpenAI 返回非 JSON 响应({type(e).__name__}): {e}"
            ) from e

        if not isinstance(payload, dict):
            raise AIProviderError(
                "OpenAI 返回 JSON 顶层不是 object"
                f"(type={type(payload).__name__})"
            )

        choices = payload.get("choices")
        if not isinstance(choices, list) or not choices:
            raise AIProviderError("OpenAI 返回空 choices(无 message)")

        first = choices[0]
        if not isinstance(first, dict):
            raise AIProviderError(
                f"OpenAI choices[0] 不是 object(type={type(first).__name__})"
            )

        # content_filter 优先抛错(类比 Responses API 的 refusal 处理):
        # 即使有部分文本,只要被 filter 拦截就视为解读不可用,不能展示半截。
        finish_reason = first.get("finish_reason")
        if finish_reason == "content_filter":
            raise AIProviderError("OpenAI 拒绝生成解读(content_filter)")

        message = first.get("message")
        if not isinstance(message, dict):
            raise AIProviderError(
                f"OpenAI message 不是 object(type={type(message).__name__})"
            )

        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return content
        # content 可能是 None / 空串 / 非预期类型(如 tool_calls 触发)
        raise AIProviderError(
            "OpenAI 返回 message.content 为空"
            f"(finish_reason={finish_reason!r}, type={type(content).__name__})"
        )
