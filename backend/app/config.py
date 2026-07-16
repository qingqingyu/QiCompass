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

if not ANTHROPIC_MODEL:
    raise ValueError("ANTHROPIC_MODEL must not be blank")
if not OPENAI_MODEL:
    raise ValueError("OPENAI_MODEL must not be blank")

# 两家统一调用参数;不自动重试/降级。
AI_MAX_OUTPUT_TOKENS = 1024
AI_TIMEOUT_SECONDS = 15.0

# 后端 SQLite 缓存路径(D2 第二级);可被 env 覆盖
DB_PATH = os.environ.get("QICOMPASS_DB_PATH", "data/qicompass.db")

# prompt 版本号单一事实源:ai/prompts.py 的 PROMPT_VERSIONS,路由层从那里导入
