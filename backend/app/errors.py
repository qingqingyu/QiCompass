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


class InvalidInputError(BaziError):
    """输入参数非法(语义层面的,Pydantic 已覆盖格式校验)。

    S02 后城市查表(CITY_NOT_FOUND)已随 city_longitude.py 删除:
    非法时区名 / 越界经纬度由 Pydantic validator 直接 422。
    """

    code = "INVALID_INPUT"
    http_status = 422


class BaziCalculationFailedError(BaziError):
    """lunar_python 内部异常。不吞,向上抛,带原始 traceback。"""

    code = "BAZI_CALCULATION_FAILED"
    http_status = 500


class AIProviderError(BaziError):
    """AI provider 调用失败(超时/限流/5xx/空内容/key 未配置)。

    错误显式传播:不吞、不重试、不自动 fallback,失败即报错。

    reason(2026-10-09 监控):机器可读失败分型,client 层(anthropic/
    openai)全 raise 点标注,供 MeteredAIClient 落计数表——对外契约不变
    (仍是同一 code/message/http_status,iOS 零感知;不进响应负载,只进
    日志与 metrics)。取值:
    - no_api_key:key 未配置(调用即失败,零网络往返)
    - timeout / rate_limit / auth / http_error / network:HTTP 层
    - bad_response:响应形状非法(非 JSON / 空 content / 无 text 等)
    - truncated:stop_reason=max_tokens / finish_reason=length 截断
    - content_filter:OpenAI 内容过滤拒绝(anthropic 无此分型)
    - unexpected:client 未包到的异常(MeteredAIClient 兜底计数)
    - unknown:默认值(interpret.py 的契约/保真等 pipeline 失败不参与
      provider 可用性统计,不细分)
    """

    code = "AI_PROVIDER_ERROR"
    http_status = 503

    def __init__(self, message: str, *, request_id: str | None = None,
                 content_hash: str | None = None,
                 reason: str = "unknown"):
        super().__init__(message, request_id=request_id,
                         content_hash=content_hash)
        self.reason = reason


class InterpretationCacheError(BaziError):
    """后端 SQLite 缓存层异常。

    错误显式传播:读失败不降级为 provider 调用,写失败不返回"成功但没缓存",
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


class StaleSourceError(BaziError):
    """翻译端点(/api/interpret/translate)原文不可用(D10.1 + 防伪收口)。

    409 两种触发,客户端处理一致(走正常 /api/interpret 重新生成,不重试翻译):
    - source_prompt_version ≠ 当前 PROMPT_VERSIONS[module]:原文来自旧
      prompt,本来就该按新版本重新生成(而非翻译)
    - 服务端原文防伪:原文在后端缓存不可核验(清库/换环境/伪造文本)——
      译文落跨用户共享键,未经后端生成过的文本不予翻译
    """

    code = "STALE_SOURCE"
    http_status = 409


# ---------- Entitlement(M2 后端付费系统)----------


class EntitlementError(BaziError):
    """Entitlement 相关通用错误(如交易已退款/撤销无法激活)。

    错误显式传播:不静默放行,不返回 entitled=True 掩盖失败。
    """

    code = "ENTITLEMENT_ERROR"
    http_status = 403


class EntitlementNotFoundError(BaziError):
    """付费 module 调用但未找到有效 entitlement(越狱保护核心防线)。

    403 而非 404:语义是"知道你是谁但没权限",不是"资源不存在"。
    越狱设备绕过 iOS UI 直调 /api/interpret bazi_deep_paid → 此处拦下。
    """

    code = "ENTITLEMENT_NOT_FOUND"
    http_status = 403


class AppleVerificationError(BaziError):
    """Apple App Store Server API 验证失败(网络/签名无效/transaction 不存在)。

    502 Bad Gateway:上游(Apple)故障,与 AIProviderError(503)语义对齐。
    不静默放行:Apple 说不行就是不行,不允许写 entitlement 表。
    """

    code = "APPLE_VERIFICATION_ERROR"
    http_status = 502


# ---------- 每日运势插画(2026-08-30「一幅图」)----------


class DailyImageLimitError(BaziError):
    """当日全局生图量达 DAILY_IMAGE_LIMIT 上限(成本护栏)。

    429 显式拒绝,不静默降级(不偷偷回旧图/不偷偷跳过生成)——
    上限是运营闸门,触发即该被看见。
    """

    code = "DAILY_IMAGE_LIMIT"
    http_status = 429


# ---------- context_token 验签(2026-10-07 P0 安全收口)----------


class ContextTokenRequiredError(BaziError):
    """interpret/translate 请求未携带 context_token(403)。

    一刀切强制(免费+付费,2026-10-07 用户拍板无存量外部 build):
    token 由排盘端点签发,客户端从 ChartSnapshot 取;缺失即拒。
    """

    code = "CONTEXT_TOKEN_REQUIRED"
    http_status = 403


class ContextTokenInvalidError(BaziError):
    """context_token 验签失败:伪造 / 篡改 / 属于其他命盘 / secret 已轮换。

    P0 收口主闸:context 核心字段(四柱/喜忌/日主强度等盘身)必须与
    排盘端点签发的 token 一致——买一次盘给任意命盘生成付费内容的通道
    在此关闭。403 语义同 EntitlementNotFoundError:「知道你是谁,但内容对不上」。
    """

    code = "CONTEXT_TOKEN_INVALID"
    http_status = 403


class QuotaExceededError(BaziError):
    """解读生成的每日服务端上限触发(2026-10-07 匿名滥用收口)。

    计数口径:真烧 LLM 的生成(缓存命中不计);bucket = 登录 user_id,
    匿名按 IP;免费/付费分档(2026-10-08 第十四轮拍板:付费不再豁免,
    独立 paid: 前缀分桶)。免费上限 QICOMPASS_FREE_DAILY_LIMIT(默认
    150:CGNAT 共享 IPv4 出口下 30/日是全出口共享,正常用户互相挤兑;
    脚本可换 IP 绕过,上限主要约束共享出口成本面);付费上限
    QICOMPASS_PAID_DAILY_LIMIT(默认 500,拦 M4/M5 换输入无限烧 LLM 的
    脚本滥用;2026-10-08 十六轮拍板 100 → 500——匿名付费按 IP 分桶,
    CGNAT 共享出口下 100 会让正常付费群体互相挤兑触顶)。
    """

    code = "QUOTA_EXCEEDED"
    http_status = 429
