"""自定义异常类(错误显式传播:不静默吞,向上抛)。"""


class BaziError(Exception):
    """八字排盘基础异常。"""

    code = "BAZI_ERROR"
    http_status = 500

    def __init__(self, message: str, *, request_id: str | None = None,
                 content_hash: str | None = None):
        super().__init__(message)
        self.message = message
        self.request_id = request_id
        self.content_hash = content_hash


class CityNotFoundError(BaziError):
    """城市经度查表失败。"""

    code = "CITY_NOT_FOUND"
    http_status = 404

    def __init__(self, city: str):
        super().__init__(f"未找到城市「{city}」的经度,请直接传 longitude 参数")


class InvalidInputError(BaziError):
    """输入参数非法(语义层面的,Pydantic 已覆盖格式校验)。"""

    code = "INVALID_INPUT"
    http_status = 422


class BaziCalculationFailedError(BaziError):
    """lunar_python 内部异常。不吞,向上抛,带原始 traceback。"""

    code = "BAZI_CALCULATION_FAILED"
    http_status = 500


class ClaudeAPIError(BaziError):
    """Claude API 调用失败(超时/限流/5xx/空内容/key 未配置)。

    错误显式传播:不吞不重试(重试策略留给 v2),失败即报错。
    """

    code = "CLAUDE_API_ERROR"
    http_status = 503


class InterpretationCacheError(BaziError):
    """后端 SQLite 缓存层异常。

    错误显式传播:读失败不降级为 Claude 调用,写失败不返回"成功但没缓存",
    让用户看到失败重试,不静默掩盖缓存层故障。
    """

    code = "INTERPRETATION_CACHE_ERROR"
    http_status = 500


class InterpretationForbiddenError(BaziError):
    """AI 解读包含禁词,被后端拦截(US-COMP-04)。

    错误显式传播:不替换文本,不返回原文,直接抛错让客户端进入 error 态。
    客户端保留二次扫描作防御性兜底,但后端是最终防线(客户端可被绕过)。
    """

    code = "INTERPRETATION_FORBIDDEN"
    http_status = 422
