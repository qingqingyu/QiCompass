#!/usr/bin/env bash
# 生产/预生产启动脚本。开发模式仍用 `.venv/bin/uvicorn app.main:app --reload`。
#
# 多进程:uvicorn 原生 --workers(不引入 gunicorn 依赖)。
# 每个 worker 独立 lifespan / 独立 LLM client / 独立 singleflight 表。
# SQLite WAL 模式下多进程读不阻塞写,并发写依赖 busy_timeout 5s 缓解。
set -euo pipefail

cd "$(dirname "$0")"

# 显式 source .env(对齐 .env.example 的加载方式,不引 python-dotenv 依赖)
if [[ ! -f .env ]]; then
    echo "ERROR: .env not found. Copy .env.example → .env and fill credentials." >&2
    exit 1
fi
set -a; source .env; set +a

WORKERS="${WEB_CONCURRENCY:-2}"
echo "starting uvicorn workers=$WORKERS host=0.0.0.0 port=8000"

exec .venv/bin/uvicorn app.main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --workers "$WORKERS"
