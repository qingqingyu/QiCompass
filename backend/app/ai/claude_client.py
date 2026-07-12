"""Claude API 客户端封装(httpx 同步客户端)。

设计要点:
- 用项目已有 httpx 同步客户端,与 run_in_threadpool 模式一致,
  避免为单个外部调用新增依赖
- api_key 缺失时启动不失败,调用 interpret() 时抛 ClaudeAPIError(503)
  其他路由(/api/bazi/calculate)不需要 key,不应被拖累
- 错误显式传播:httpx 超时/网络/HTTP 错误翻译成 ClaudeAPIError(503)
  带原始异常 type + message,不吞不重试(重试策略留给 v2,本 slice 失败即报错)
- Claude 返回空 content → ClaudeAPIError("Claude 返回空内容"),不返回假文本
- 可注入性:路由层通过 request.app.state.claude_client 拿实例,测试时替换成 mock
"""

from __future__ import annotations

import httpx

from ..config import CLAUDE_MAX_TOKENS, CLAUDE_MODEL, CLAUDE_TIMEOUT_SECONDS
from ..errors import ClaudeAPIError


class ClaudeClient:
    """Claude messages API 同步封装。

    Args:
        api_key: ANTHROPIC_API_KEY;None 时调用 interpret() 报 503
        model: Claude model 名(config.CLAUDE_MODEL)
    """

    def __init__(self, api_key: str | None, model: str = CLAUDE_MODEL):
        self._api_key = api_key
        self._model = model

    def interpret(self, prompt: str) -> str:
        """调 Claude messages API,返回文本。

        Args:
            prompt: 完整 prompt 字符串(render_prompt 输出)

        Returns:
            Claude 生成的文本(取第一个非空 text block)

        Raises:
            ClaudeAPIError: 任何失败场景(key 未配置/超时/限流/5xx/空内容)
        """
        if self._api_key is None:
            raise ClaudeAPIError(
                "ANTHROPIC_API_KEY not configured"
                "(后端未设置 API key,无法调用 Claude)")

        try:
            resp = httpx.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": self._api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": self._model,
                    "max_tokens": CLAUDE_MAX_TOKENS,
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=CLAUDE_TIMEOUT_SECONDS,
            )
            resp.raise_for_status()
        except httpx.TimeoutException as e:
            raise ClaudeAPIError(
                f"Claude API 超时({type(e).__name__}): {e}") from e
        except httpx.HTTPStatusError as e:
            status_code = e.response.status_code
            if status_code == 429:
                raise ClaudeAPIError(
                    f"Claude API 限流({type(e).__name__}): HTTP {status_code}"
                ) from e
            if status_code == 401:
                raise ClaudeAPIError(
                    "Claude API key 无效或未授权(HTTP 401),"
                    "请检查 ANTHROPIC_API_KEY 配置"
                ) from e
            raise ClaudeAPIError(
                f"Claude API HTTP {status_code}({type(e).__name__})"
            ) from e
        except httpx.RequestError as e:
            raise ClaudeAPIError(
                f"Claude API 调用失败({type(e).__name__}): {e}") from e

        try:
            payload = resp.json()
        except ValueError as e:
            raise ClaudeAPIError(
                f"Claude 返回非 JSON 响应({type(e).__name__}): {e}") from e

        if not isinstance(payload, dict):
            raise ClaudeAPIError(
                f"Claude 返回 JSON 顶层不是 object(type={type(payload).__name__})"
            )

        content = payload.get("content")
        if not isinstance(content, list) or not content:
            raise ClaudeAPIError("Claude 返回空 content(无文本块)")

        # content 是 list[{"type":"text","text":"..."}],取第一个非空 text block。
        for block in content:
            text = block.get("text") if isinstance(block, dict) else None
            if isinstance(text, str) and text.strip():
                return text

        first = content[0]
        first_type = first.get("type", "?") if isinstance(first, dict) else "?"
        raise ClaudeAPIError(
            f"Claude 返回 content 无 text 字段(first_type={first_type})"
        )
