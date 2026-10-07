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

# arch -arm64:Rosetta(x86_64)语境下 venv 的 arm64 编译包(pydantic_core 等)
# ImportError 启动即崩,显式钉死架构(2026-10-07 本机复现两次)。**仅 macOS +
# Rosetta** 需要:`arch` 是 macOS 专用命令,Linux 服务器上的 GNU coreutils
# `arch` 只打印架构、不接受 `-arm64` 参数(2026-10-07 review,部署 Linux 会
# 直接启动失败)。
UVICORN_BIN=".venv/bin/uvicorn"
if [[ "$(uname -s)" == "Darwin" ]] \
    && [[ "$(uname -m)" == "x86_64" ]] \
    && [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == "1" ]]; then
    UVICORN_BIN="arch -arm64 .venv/bin/uvicorn"
fi

# --proxy-headers --forwarded-allow-ips 127.0.0.1:匿名免费配额按
# request.client.host 计,反代(Caddy/Nginx)后无此参数时所有匿名用户都被算成
# 127.0.0.1、全站共享一份每日配额(2026-10-07 review,部署必须项)。
exec $UVICORN_BIN app.main:app \
    --host 0.0.0.0 \
    --port 8000 \
    --workers "$WORKERS" \
    --proxy-headers \
    --forwarded-allow-ips 127.0.0.1
