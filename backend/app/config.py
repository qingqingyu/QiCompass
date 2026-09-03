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
AI_MAX_OUTPUT_TOKENS = 1024
# 推理模型(gpt-5.x / claude-sonnet)生成命书需要 30-50s,
# 15s 会 read-timeout。给 90s 留足余量(超时即报 503,不会无限挂)。
AI_TIMEOUT_SECONDS = 90.0

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
# 缺失时启动不失败(M2a/b 测试 / dev 用 MockAppleServerAPI);调用 /api/entitlement/redeem
# 时若仍为 Mock 会显式报 503(对齐 AI_PROVIDER key 缺失策略)。
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
