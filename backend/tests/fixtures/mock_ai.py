"""测试用 provider-neutral AIClient mock。"""

from __future__ import annotations

from app.errors import AIProviderError


class MockAIClient:
    """计数 interpret 调用并返回固定文本。"""

    def __init__(
        self,
        response: str = "【mock 命书文本】",
        *,
        provider: str = "anthropic",
        model: str = "test-anthropic-model",
    ):
        self._response = response
        self.provider = provider
        self.model = model
        self.call_count = 0
        self.last_prompt: str | None = None

    def interpret(self, prompt: str) -> str:
        self.call_count += 1
        self.last_prompt = prompt
        return self._response


class FailingAIClient(MockAIClient):
    """调 interpret 必抛 AIProviderError(测错误传播)。"""

    def __init__(self, error: Exception | None = None, **kwargs):
        super().__init__(**kwargs)
        self._error = error

    def interpret(self, prompt: str) -> str:
        self.call_count += 1
        self.last_prompt = prompt
        if self._error:
            raise self._error
        raise AIProviderError("mock AI provider failure")
