"""应用全局常量。"""

import os

# lunar_python 版本(与 requirements.txt 锁定一致)
LUNAR_PYTHON_VERSION = "1.4.8"

# 当前 schema 版本(ChartSnapshot D1)
SCHEMA_VERSION = 1

# API 模型标识
MODEL_ID = "bazi-calculate-v1"

# ---------- AI 解读(/api/interpret)----------

# Claude API key 从 env 读;缺失时启动不失败,调用 /api/interpret 时报 503
# (其他路由如 /api/bazi/calculate 不需要 key,不应被拖累)
ANTHROPIC_API_KEY: str | None = os.environ.get("ANTHROPIC_API_KEY") or None

# 设计文档 Tech Stack 钦定 claude-sonnet-4-6
CLAUDE_MODEL = "claude-sonnet-4-6"

# Claude API 调用参数
CLAUDE_MAX_TOKENS = 1024
CLAUDE_TIMEOUT_SECONDS = 15.0

# 后端 SQLite 缓存路径(D2 第二级);可被 env 覆盖
DB_PATH = os.environ.get("QICOMPASS_DB_PATH", "data/qicompass.db")

# prompt 版本号单一事实源:ai/prompts.py 的 PROMPT_VERSIONS,路由层从那里导入
