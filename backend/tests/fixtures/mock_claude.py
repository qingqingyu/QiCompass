"""测试用 ClaudeClient mock 实现。

放在 fixtures/ 下(而非 conftest.py)使其可被测试文件显式 import。
conftest.py 的 mock_claude_client fixture 也从这里导入。
"""

from __future__ import annotations

from app.errors import ClaudeAPIError


class MockClaudeClient:
    """ClaudeClient 的 mock:计数 interpret 调用次数,返回固定文本。

    用法:
        mock = MockClaudeClient()
        mock.interpret("...")  # 返回固定文本,call_count += 1
        mock.call_count        # 断言调用次数
    """

    def __init__(self, response: str = "【mock 命书文本】"):
        self._response = response
        self.call_count = 0
        self.last_prompt: str | None = None

    def interpret(self, prompt: str) -> str:
        self.call_count += 1
        self.last_prompt = prompt
        return self._response


class FailingClaudeClient(MockClaudeClient):
    """调 interpret 必抛 ClaudeAPIError(测错误传播)。"""

    def __init__(self, error: Exception | None = None):
        super().__init__()
        self._error = error

    def interpret(self, prompt: str) -> str:
        self.call_count += 1
        self.last_prompt = prompt
        if self._error:
            raise self._error
        raise ClaudeAPIError("mock Claude failure")
