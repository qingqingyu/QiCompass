"""应用全局常量。"""

import os

# lunar_python 版本(与 requirements.txt 锁定一致)
LUNAR_PYTHON_VERSION = "1.4.8"

# 当前 schema 版本(ChartSnapshot D1)
SCHEMA_VERSION = 1

# API 模型标识
MODEL_ID = "bazi-calculate-v1"

# ---------- AI 解读(/api/interpret)----------

# 部署级 AI provider 选择。不允许客户端逐请求指定,避免成本/安全边界失控。
# 默认 anthropic 保持旧部署兼容;非法值必须在启动期暴露。
AI_PROVIDER = (os.environ.get("AI_PROVIDER") or "anthropic").strip().lower()
if AI_PROVIDER not in {"anthropic", "openai"}:
    raise ValueError(
        "AI_PROVIDER must be one of: anthropic, openai "
        f"(got {AI_PROVIDER!r})"
    )

# API key 缺失时启动不失败,调用 /api/interpret 时显式报 503。
# 其他路由如 /api/bazi/calculate 不需要 key,不应被拖累。
ANTHROPIC_API_KEY: str | None = os.environ.get("ANTHROPIC_API_KEY") or None
OPENAI_API_KEY: str | None = os.environ.get("OPENAI_API_KEY") or None

ANTHROPIC_MODEL = (
    os.environ.get("ANTHROPIC_MODEL") or "claude-sonnet-4-6"
).strip()
OPENAI_MODEL = (os.environ.get("OPENAI_MODEL") or "gpt-5.5").strip()
# OpenAI 兼容网关(如官方、Azure、第三方代理)。默认官方 endpoint。
# 末尾斜杠统一去掉,避免拼路径出现 //。
OPENAI_BASE_URL = (os.environ.get("OPENAI_BASE_URL") or "https://api.openai.com/v1").strip().rstrip("/")

# Anthropic 协议中转(如 z.ai https://api.z.ai/api/anthropic);/v1/messages 由 client 拼。
# 留空走官方 https://api.anthropic.com。末尾斜杠统一去掉。
ANTHROPIC_BASE_URL: str | None = (
    os.environ.get("ANTHROPIC_BASE_URL") or ""
).strip().rstrip("/") or None

if not ANTHROPIC_MODEL:
    raise ValueError("ANTHROPIC_MODEL must not be blank")
if not OPENAI_MODEL:
    raise ValueError("OPENAI_MODEL must not be blank")
if not OPENAI_BASE_URL:
    raise ValueError("OPENAI_BASE_URL must not be blank")

# 两家统一调用参数;不自动重试/降级。
# 2026-09-27 1024→8192:v1 深度模块模板强制「总输出 1500-2500 字(zh)/
# 900-1500 words(en)」(用户决策 2026-08-11),zh 上限 ≈3000-4000 token +
# JSON 结构开销,1024 必截断 → 半截 JSON 进缓存被 iOS 当散文渲染(真机
# m1_talent 实证)。cap≠目标:短模块(daily_fortune 50-80 字)输出由 prompt
# 篇幅约束,不因 cap 放开变长。截断本身由 client 层 stop_reason/finish_reason
# 显式报错兜底(不再静默成功)。
AI_MAX_OUTPUT_TOKENS = 8192
# 推理模型(gpt-5.x / claude-sonnet)生成命书需要 30-50s;max_tokens 放开到
# 8192 后长模块(m1/m2/m3/m5/m7)实际生成 ~3000-4000 token,预计 40-90s,
# 90s 贴线,给 150s 留余量(超时即报 503,不会无限挂)。iOS APIClient
# timeoutIntervalForRequest=180s(2026-09-28,150+30s 余量):本值之外还有
# entitlement 校验/缓存写/序列化,客户端同卡 150 会把后端已成功的生成变成
# 客户端失败而次数已扣——两值有意不等,客户端改值时同步此注释。
AI_TIMEOUT_SECONDS = 150.0

# v1 prompt 系统 §1 temperature 分级:
# - M0-M2 结构判断要稳,低 temperature 抑制创造性
# - M3-M7 叙述要有质感,适度放开创造性
# 老模块(bazi_deep_*/compatibility_*/daily_fortune)走默认值 0.6(向后兼容)
AI_DEFAULT_TEMPERATURE = 0.6
MODULE_TEMPERATURES: dict[str, float] = {
    # 老模块(向后兼容,不传 temperature 时也走 0.6)
    "bazi_deep": 0.6, "bazi_deep_free": 0.6, "bazi_deep_paid": 0.6,
    "compatibility": 0.6, "compatibility_free": 0.6, "compatibility_paid": 0.6,
    "daily_fortune": 0.6,
    # 插画走 images/generations,无 temperature 参数——键存在只为
    # test_module_temperatures_covers_all_known_modules 的全覆盖断言
    # (PROMPT_VERSIONS 的 key 必须都在,防漂移),值不被消费。
    "daily_fortune_image": 0.6,
    # v1 新模块:M0-M2 结构层稳, M3-M7 叙述层放
    "m0_structure": 0.3, "m1_talent": 0.3, "m2_high_low": 0.3,
    "m3_system": 0.6, "m4_health": 0.6, "m5_wealth": 0.6,
    "m6_dynamics": 0.6, "m7_manual": 0.6,
    # 翻译(D10.2,2026-10-01):只做语言转换,压最低档抑制改写
    "translate": 0.2,
}


def resolve_temperature(module: str) -> float:
    """取 module 对应 temperature;未知 module 返回 AI_DEFAULT_TEMPERATURE。

    设计:不抛错(向后兼容老模块/未知 module),未知 module 静默走默认值;
    通过测试断言所有当前 module 都在字典里(test_ai_client_factory.py
    的 test_module_temperatures_covers_all_known_modules)。

    TODO(Stage 4):路由层 interpret.py 的 ai_client.interpret(prompt) 调用
    改为 ai_client.interpret(prompt, temperature=resolve_temperature(req.module)),
    把 module → temperature 分级真正接通。Stage 2 只铺基础设施,不接入路由。
    """
    return MODULE_TEMPERATURES.get(module, AI_DEFAULT_TEMPERATURE)

# 后端 SQLite 缓存路径(D2 第二级);可被 env 覆盖
DB_PATH = os.environ.get("QICOMPASS_DB_PATH", "data/qicompass.db")

# ---------- 每日运势插画(gpt-image-2,2026-08-30「一幅图」)----------
# 独立于文本 AI 的 OPENAI_* 配置:image 专用中转与 key,不共用。
# 缺失时启动不失败(对齐 AI key 缺失策略),调用生图端点时显式 503。
IMAGE_API_BASE_URL = (os.environ.get("IMAGE_API_BASE_URL") or "").strip().rstrip("/")
IMAGE_API_KEY: str | None = os.environ.get("IMAGE_API_KEY") or None
IMAGE_MODEL = (os.environ.get("IMAGE_MODEL") or "gpt-image-2").strip()
if not IMAGE_MODEL:
    raise ValueError("IMAGE_MODEL must not be blank")
# 实测 63-181s/张(2026-08-30 三方向样图),240s 留余量;超时即显式报错不重试。
IMAGE_TIMEOUT_SECONDS = 240.0
# 全局日护栏:当日 generating+ready 行数达上限 → 429(成本护栏,不静默降级)。
DAILY_IMAGE_LIMIT = int(os.environ.get("DAILY_IMAGE_LIMIT") or "200")
if DAILY_IMAGE_LIMIT <= 0:
    raise ValueError(f"DAILY_IMAGE_LIMIT must be positive (got {DAILY_IMAGE_LIMIT})")
# 插画尺寸:gpt-image-2 无 16:9,1536×1024(3:2)为最接近横幅;与 iOS hero 容器 3:2 一致。
IMAGE_SIZE = "1536x1024"

# ---------- Apple App Store Server API(M2b 后端付费系统)----------
# 5 个 APP_STORE_* env 不齐时启动挂 MockAppleServerAPI(2026-10-07 收口后):
# - APP_STORE_ENVIRONMENT=production → 启动 RuntimeError(fail-fast,
#   生产缺配 = 任意 transaction_id 免费兑换付费权益,不可静默)
# - sandbox → Mock 默认锁定(redeem 显式 503);dev 想走通链路须显式设
#   QICOMPASS_ALLOW_MOCK_APPLE=1(原 config 注释宣称的 503 保护自此兑现)
# M6 TestFlight 阶段才需真值(去 App Store Connect > Users and Access > Keys 申请)。

APP_STORE_BUNDLE_ID: str | None = (
    os.environ.get("APP_STORE_BUNDLE_ID") or None
)  # e.g. "com.qicompass.app"
APP_STORE_KEY_ID: str | None = os.environ.get("APP_STORE_KEY_ID") or None
APP_STORE_ISSUER_ID: str | None = os.environ.get("APP_STORE_ISSUER_ID") or None
# 私钥是 Apple 签发的 ECDSA P-8 文件内容(.p8 文件读出来是 PEM 格式 str)
APP_STORE_PRIVATE_KEY: str | None = os.environ.get("APP_STORE_PRIVATE_KEY") or None
# "sandbox"(TestFlight / 开发)+ "production"(上架后);默认 sandbox
APP_STORE_ENVIRONMENT = (
    os.environ.get("APP_STORE_ENVIRONMENT") or "sandbox"
).strip().lower()
if APP_STORE_ENVIRONMENT not in {"sandbox", "production"}:
    raise ValueError(
        "APP_STORE_ENVIRONMENT must be one of: sandbox, production "
        f"(got {APP_STORE_ENVIRONMENT!r})"
    )
# App Apple ID(从 App Store Connect 拿,用于 SignedDataVerifier 的 bundle 校验;
# 与 BUNDLE_ID 不同,这是数字 ID)
APP_STORE_APP_APPLE_ID: str | None = os.environ.get("APP_STORE_APP_APPLE_ID") or None


def apple_env_configured() -> bool:
    """检查 Apple 配置是否齐全(用于 main.py lifespan 决定挂 Mock 还是真 SDK)。

    返回 True 当且仅当 5 个必填 env 全部存在:
    BUNDLE_ID / KEY_ID / ISSUER_ID / PRIVATE_KEY / APP_APPLE_ID
    """
    return all([
        APP_STORE_BUNDLE_ID,
        APP_STORE_KEY_ID,
        APP_STORE_ISSUER_ID,
        APP_STORE_PRIVATE_KEY,
        APP_STORE_APP_APPLE_ID,
    ])


# ---------- 自家 JWT + Sign in with Apple(PR2.5 后端账号系统)----------
# JWT_SECRET_KEY 必填,缺失启动失败(对齐 CLAUDE.md "错误显式传播")
JWT_SECRET_KEY: str = os.environ.get("JWT_SECRET_KEY") or ""
if not JWT_SECRET_KEY:
    raise ValueError(
        "JWT_SECRET_KEY 必填(PR2.5 后端账号系统)。"
        "本地开发:在 backend/.env 设置任意长字符串(如 'dev-secret-change-me-<random>')。"
        "生产:用 openssl rand -hex 32 生成,不要 commit .env"
    )

JWT_ALGORITHM = "HS256"  # 共享密钥(对齐 PR2.5 plan 决策)
JWT_EXP_MINUTES = int(os.environ.get("JWT_EXP_MINUTES") or "43200")  # 默认 30 天
if JWT_EXP_MINUTES <= 0:
    raise ValueError(f"JWT_EXP_MINUTES must be positive (got {JWT_EXP_MINUTES})")

# Sign in with Apple ID Token 验证
# Bundle ID 作 expected audience(Apple aud claim)
APPLE_SIGN_IN_CLIENT_ID: str = (
    os.environ.get("APPLE_SIGN_IN_CLIENT_ID")
    or APP_STORE_BUNDLE_ID
    or "com.qicompass.app"
)
# Apple 公钥缓存 TTL(秒),默认 1 小时
APPLE_PUBLIC_KEYS_CACHE_TTL = int(
    os.environ.get("APPLE_PUBLIC_KEYS_CACHE_TTL") or "3600"
)

# Sign in with Google ID Token 验证
# 无兜底默认(与 Apple 不同):Google client ID 是 Google Cloud Console 发的
# 一串 .apps.googleusercontent.com,没有可推导的默认值。未配置时
# provider=google 的登录显式抛 GOOGLE_SIGN_IN_NOT_CONFIGURED(503),
# 不静默放行也不阻断 Apple 登录(错误显式传播)。
GOOGLE_SIGN_IN_CLIENT_ID: str | None = os.environ.get("GOOGLE_SIGN_IN_CLIENT_ID") or None
# Google 公钥缓存 TTL(秒),默认 1 小时
GOOGLE_PUBLIC_KEYS_CACHE_TTL = int(
    os.environ.get("GOOGLE_PUBLIC_KEYS_CACHE_TTL") or "3600"
)

# prompt 版本号单一事实源:ai/prompts.py 的 PROMPT_VERSIONS,路由层从那里导入

# ---------- 免费 LLM 生成每日上限(2026-10-07 匿名滥用收口) ----------
# 只计真烧 LLM 的免费 module 生成(缓存命中不计;付费另见下方
# PAID_DAILY_LIMIT 独立分桶,2026-10-08 第十四轮起不再豁免);
# 高于 iOS 本地 10/日,正常用户无感;匿名刷 LLM 的成本面被压掉 97%+。
# 2026-10-08 拍板 30 → 150:国内移动网/校园网 CGNAT 下大量真实用户共用
# 一个 IPv4 出口,30/日是全出口共享——正常使用即达限;而脚本本可换 IP
# 绕过,30 挡住的主要是共享出口的真实用户。放宽后单 IP 最坏 150 次/日
# (免费模块以 M0/每日短文为主),成本可控。
FREE_DAILY_LIMIT = int(
    os.environ.get("QICOMPASS_FREE_DAILY_LIMIT") or "150")
if FREE_DAILY_LIMIT <= 0:
    raise ValueError(
        f"QICOMPASS_FREE_DAILY_LIMIT must be positive (got {FREE_DAILY_LIMIT})")

# ---------- 免费配额退款每日上限(2026-10-08 拍板:分类退 + 防刷上限) ----------
# 退款(服务商故障/契约截断/翻译保真失败)按 (bucket, day) 计数,超过上限
# 不再退——「构造可触发退款的失败 = 免费烧 LLM 不扣额」的通道被每日退款
# 次数封顶。默认 5:正常用户一天内触发 5 次以上非用户过错失败几乎不可能
# (服务商故障期集中失败由 limit 保护成本面,不让退款变成无界)。
REFUND_DAILY_LIMIT = int(
    os.environ.get("QICOMPASS_REFUND_DAILY_LIMIT") or "5")
if REFUND_DAILY_LIMIT <= 0:
    raise ValueError(
        f"QICOMPASS_REFUND_DAILY_LIMIT must be positive (got {REFUND_DAILY_LIMIT})")

# ---------- 付费 LLM 生成每日上限(2026-10-08 第十四轮拍板) ----------
# 付费 module 不再豁免服务端计数:M4/M5 用户输入不绑 token,每次换输入 =
# 新缓存键 = 新 LLM 调用,已购用户可无限烧(成本 DoS 面)。付费按同款
# bucket 维度(登录 user_id / 匿名 IP)独立计数(paid: 前缀分桶,与免费
# 互不挤兑),上限高于任何正常单用户 usage(深度链 8 章 + M4/M5 数轮 +
# 合盘,一天几十次以内),只拦脚本滥用。缓存命中仍不计。
# 2026-10-08 十六轮拍板 100 → 500:匿名付费按 IP 分桶,与免费桶同样的
# CGNAT 共享出口问题——正常付费用户每人每盘 6 个付费章真烧(m0 bump 日
# 全链重生成),一个出口下 ~16 盘就挤兑触顶,付费用户撞 429 体验最差;
# 登录付费按 user_id 不受影响。500 下正常 CGNAT 付费群体几乎不可能集体
# 触顶(≈83 盘/日),脚本滥用仍有硬闸。env QICOMPASS_PAID_DAILY_LIMIT 可调。
PAID_DAILY_LIMIT = int(
    os.environ.get("QICOMPASS_PAID_DAILY_LIMIT") or "500")
if PAID_DAILY_LIMIT <= 0:
    raise ValueError(
        f"QICOMPASS_PAID_DAILY_LIMIT must be positive (got {PAID_DAILY_LIMIT})")

# ---------- LLM 失败率告警阈值(2026-10-09 监控闭环 A 档) ----------
# 近 1h 窗口内 provider 调用总数 ≥ LLM_ALERT_MIN_CALLS 且失败率 ≥
# LLM_ALERT_FAILURE_RATE 时,MeteredAIClient 打 ERROR 级「ALERT
# llm_failure_rate」标记日志(grep/外接 hook 可消费;不引入外部告警
# 服务,进程内 10min 节流,多 worker 各自独立节流)。min_calls 下限
# 防低流量误报(如 1 次调用失败 = 100% 失败率不该告警)。
LLM_ALERT_FAILURE_RATE = float(
    os.environ.get("QICOMPASS_LLM_ALERT_FAILURE_RATE") or "0.5")
if not (0 < LLM_ALERT_FAILURE_RATE <= 1):
    raise ValueError(
        "QICOMPASS_LLM_ALERT_FAILURE_RATE must be in (0, 1] "
        f"(got {LLM_ALERT_FAILURE_RATE})")
LLM_ALERT_MIN_CALLS = int(
    os.environ.get("QICOMPASS_LLM_ALERT_MIN_CALLS") or "5")
if LLM_ALERT_MIN_CALLS <= 0:
    raise ValueError(
        f"QICOMPASS_LLM_ALERT_MIN_CALLS must be positive (got {LLM_ALERT_MIN_CALLS})")

# ---------- evalkit L3 裁判(S05,2026-08-18;默认回落生成侧,现有部署零感知) ----------
# 独立 env:同模型自评有系统性偏袒;独立配置才能"用更强的模型当裁判",
# 也才能做「Anthropic 生成 / OpenAI 裁判」交叉验证。换裁判 = 换一批分数,
# 不与旧分数混比(JUDGE_MODEL 进 evalkit RunIdentity)。
# ADR-0010「provider 单选无 fallback」评测侧同样适用。
JUDGE_PROVIDER: str = (
    os.environ.get("JUDGE_PROVIDER") or AI_PROVIDER
).strip().lower()
if JUDGE_PROVIDER not in {"anthropic", "openai"}:
    raise ValueError(
        "JUDGE_PROVIDER must be one of: anthropic, openai "
        f"(got {JUDGE_PROVIDER!r})"
    )

# 默认回落对应 provider 的生成侧 model
JUDGE_MODEL: str = (
    os.environ.get("JUDGE_MODEL")
    or (ANTHROPIC_MODEL if JUDGE_PROVIDER == "anthropic" else OPENAI_MODEL)
).strip()
if not JUDGE_MODEL:
    raise ValueError("JUDGE_MODEL must not be blank")

# 默认回落对应 provider 的生成侧 key
JUDGE_API_KEY: str | None = (
    os.environ.get("JUDGE_API_KEY")
    or (ANTHROPIC_API_KEY if JUDGE_PROVIDER == "anthropic" else OPENAI_API_KEY)
)

# 裁判 base_url 覆盖(默认回落生成侧;跨 provider 交叉验证时裁判流量
# 可指向不同网关,避免生成侧中转只代理特定模型导致裁判莫名 4xx)。
# 仅 openai 裁判分支消费(anthropic 裁判走官方默认 endpoint)。
JUDGE_BASE_URL: str = (
    os.environ.get("JUDGE_BASE_URL") or OPENAI_BASE_URL
).strip().rstrip("/")
if not JUDGE_BASE_URL:
    raise ValueError("JUDGE_BASE_URL must not be blank")
