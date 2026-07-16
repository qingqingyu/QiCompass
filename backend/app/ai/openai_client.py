"""OpenAI Responses API 同步客户端(httpx)。"""

from __future__ import annotations

import httpx

from ..config import AI_MAX_OUTPUT_TOKENS, AI_TIMEOUT_SECONDS, OPENAI_MODEL
from ..errors import AIProviderError


class OpenAIClient:
    """OpenAI Responses API 适配器。"""

    provider = "openai"

    def __init__(self, api_key: str | None, model: str = OPENAI_MODEL):
        if not model.strip():
            raise ValueError("OpenAI model must not be blank")
        self._api_key = api_key
        self._model = model

    @property
    def model(self) -> str:
        return self._model

    def interpret(self, prompt: str) -> str:
        """调 OpenAI Responses API,返回第一个非空 output_text。"""
        if not self._api_key:
            raise AIProviderError(
                "OPENAI_API_KEY not configured"
                "(后端未设置 API key,无法调用 OpenAI)"
            )

        try:
            resp = httpx.post(
                "https://api.openai.com/v1/responses",
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "Content-Type": "application/json",
                },
                json={
                    "model": self._model,
                    "input": prompt,
                    "max_output_tokens": AI_MAX_OUTPUT_TOKENS,
                    "store": False,
                },
                timeout=AI_TIMEOUT_SECONDS,
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

        status = payload.get("status")
        if status != "completed":
            safe_status = status if isinstance(status, str) else type(status).__name__
            raise AIProviderError(
                f"OpenAI response 未完成(status={safe_status})"
            )

        output = payload.get("output")
        if not isinstance(output, list) or not output:
            raise AIProviderError("OpenAI 返回空 output(无 message)")

        # refusal 的优先级高于任何文本。先完整扫描,避免畸形/混合响应中
        # 先遇到 output_text 就提前返回,把随后出现的 refusal 漏掉。
        for item in output:
            if not isinstance(item, dict) or item.get("type") != "message":
                continue
            content = item.get("content")
            if not isinstance(content, list):
                continue
            if any(
                isinstance(block, dict) and block.get("type") == "refusal"
                for block in content
            ):
                raise AIProviderError("OpenAI 拒绝生成解读(refusal)")

        for item in output:
            if not isinstance(item, dict) or item.get("type") != "message":
                continue
            content = item.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") != "output_text":
                    continue
                text = block.get("text")
                if isinstance(text, str) and text.strip():
                    return text

        raise AIProviderError("OpenAI 返回 output 无非空 output_text")
