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
