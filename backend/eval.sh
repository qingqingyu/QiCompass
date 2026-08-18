#!/usr/bin/env bash
# evalkit 本地 Web UI 启动脚本(独立于生产 run.sh)。
# 三条铁律:只监听 127.0.0.1 / 无鉴权 / 不进生产镜像(见 evalkit/server.py)。
set -euo pipefail

cd "$(dirname "$0")"

# 显式 source .env(对齐 run.sh;评测真实 run 需要 AI_*/JUDGE_* 凭据)
if [[ ! -f .env ]]; then
    echo "ERROR: .env not found. Copy .env.example → .env and fill credentials." >&2
    exit 1
fi
set -a; source .env; set +a

echo "evalkit UI: http://127.0.0.1:8899"
exec .venv/bin/uvicorn evalkit.server:app \
    --host 127.0.0.1 \
    --port 8899
