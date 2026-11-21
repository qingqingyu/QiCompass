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
# host env 化(2026-11-18 S2):Docker 形态默认 0.0.0.0(容器内绑定正确,对
# 公网暴露由 compose 不 publish 8000 兜住);systemd 直跑形态生产设 127.0.0.1,
# 让唯一入口走本机反代(§2.2)。
HOST="${UVICORN_HOST:-0.0.0.0}"
echo "starting uvicorn workers=$WORKERS host=$HOST port=8000"

# data/ 可写自检(2026-11-21 非 root 化配套):SQLite + images 全写这里,
# 容器内非 root(uid 10001)而宿主 bind mount ./data 属主不符时,首写才炸——
# 提前到启动即报并带宿主侧修复指引(错误显式传播,不静默降级到别处)。
# Mac/systemd 直跑形态 data/ 属当前用户,自检恒过零副作用。
DATA_DIR="$(dirname "${QICOMPASS_DB_PATH:-data/qicompass.db}")"
# mkdir 一并纳入守卫(2026-11-21 review):set -e 下裸 mkdir 失败(父目录不可写,
# 如 QICOMPASS_DB_PATH 指向系统路径且非 root 直跑)会以裸错误退出,绕过下方指引。
if ! mkdir -p "$DATA_DIR" 2>/dev/null || ! touch "$DATA_DIR/.writecheck" 2>/dev/null; then
    # 路径原样打印(兼容绝对/相对配置),工作目录另附——直接拼 $(pwd)/$DATA_DIR
    # 在绝对路径配置下会产出 "/app//app/data" 类畸形串
    echo "ERROR: data 目录不可写(或不可建):$DATA_DIR(工作目录 $(pwd))" >&2
    echo "  Docker 部署:宿主侧执行 sudo chown -R 10001:10001 ./data(镜像以 uid 10001 非 root 运行)" >&2
    exit 1
fi
rm -f "$DATA_DIR/.writecheck"

# uvicorn 解析(2026-11-18 S2):Mac 开发用 venv 的 .venv/bin/uvicorn;容器
# 内 pip 装在 PATH(/usr/local/bin/uvicorn)且**没有 .venv**——smoke 实测
# 硬编码 .venv 路径在容器里 No such file or directory 启动即崩。
if [[ -x ".venv/bin/uvicorn" ]]; then
    UVICORN_BIN=".venv/bin/uvicorn"
elif command -v uvicorn >/dev/null 2>&1; then
    UVICORN_BIN="$(command -v uvicorn)"
else
    echo "ERROR: uvicorn 不可用(已找 .venv/bin/uvicorn 与 PATH)" >&2
    exit 1
fi

# arch -arm64:Rosetta(x86_64)语境下 venv 的 arm64 编译包(pydantic_core 等)
# ImportError 启动即崩,显式钉死架构(2026-10-07 本机复现两次)。**仅 macOS +
# Rosetta** 需要:`arch` 是 macOS 专用命令,Linux 服务器上的 GNU coreutils
# `arch` 只打印架构、不接受 `-arm64` 参数(2026-10-07 review,部署 Linux 会
# 直接启动失败)。
if [[ "$(uname -s)" == "Darwin" ]] \
    && [[ "$(uname -m)" == "x86_64" ]] \
    && [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" == "1" ]]; then
    # 拼接上方已解析的 UVICORN_BIN(2026-11-18 S2 review):不回退硬编码
    # .venv 路径,否则 Rosetta 语境 + 无 .venv(用 PATH uvicorn)时把解析
    # 结果覆盖成不存在的路径。
    UVICORN_BIN="arch -arm64 $UVICORN_BIN"
fi

# --proxy-headers --forwarded-allow-ips:匿名免费配额按 request.client.host 计,
# 反代(Caddy/Nginx)后无此参数时所有匿名用户都被算成反代地址、全站共享一份
# 每日配额(2026-10-07 review,部署必须项)。
# 信任地址经 FORWARDED_ALLOW_IPS 配置(2026-10-08 review):默认 127.0.0.1
# (反代与后端同机);**Docker Compose 部署时反代在另一容器**,uvicorn 看到的
# 对端是 Docker 内网地址——须在 .env 填 compose 网段(本仓 docker-compose.yml
# 已固定 172.28.0.0/16,照抄该值;勿抄 Docker 默认池的 172.18.0.0/16,CIDR
# 永不命中且无报错)或反代容器 IP,否则 X-Forwarded-For 不被信任,全站匿名
# 用户仍共享一份配额。uvicorn 支持逗号分隔多值/CIDR 网段/`*`(CIDR 需
# >=0.31,requirements 已锁;仅信任边界完全可控时才可用 `*`:直连暴露
# 端口下任意客户端可伪造转发头刷额度)。
FORWARDED_ALLOW_IPS="${FORWARDED_ALLOW_IPS:-127.0.0.1}"
# --timeout-graceful-shutdown(2026-11-18 S2):发版重启时让进行中的 LLM 请求
# (≤150s)在宽限期内跑完再退,否则用户已扣次数的生成被砍断。默认 200s 给
# 150s 上限留余量;Docker 形态配套 compose stop_grace_period 210s(>200,防
# SIGKILL 抢在宽限期结束前),两者一起改勿单边调。
GRACEFUL="${UVICORN_GRACEFUL_SHUTDOWN_SECONDS:-200}"
exec $UVICORN_BIN app.main:app \
    --host "$HOST" \
    --port 8000 \
    --workers "$WORKERS" \
    --proxy-headers \
    --forwarded-allow-ips "$FORWARDED_ALLOW_IPS" \
    --timeout-graceful-shutdown "$GRACEFUL"
