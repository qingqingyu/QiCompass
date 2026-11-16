#!/usr/bin/env bash
# 服务器端发版步骤(由 release.sh 经 ssh 调用,也可在服务器上手动跑)。
#
#   server-deploy.sh <tag>        构建并切到 <tag>
#   server-deploy.sh --rollback   切回上一个已发版本(不重新构建)
set -euo pipefail

ROOT=/srv/qicompass
COMPOSE=(docker compose -f "$ROOT/src/deploy/docker-compose.yml")
APP_UID=10001   # 与 backend/Dockerfile 的 useradd --uid 一致

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "用法: $0 <tag> | --rollback"

if [[ "$1" == "--rollback" ]]; then
    [[ -f "$ROOT/previous_tag" ]] || die "没有可回滚的上一个版本($ROOT/previous_tag 不存在)"
    TAG="$(cat "$ROOT/previous_tag")"
    docker image inspect "qicompass-api:$TAG" >/dev/null 2>&1 \
        || die "上一个版本的镜像 qicompass-api:$TAG 已不在本机,无法回滚"
    ROLLBACK=1
else
    TAG="$1"
    ROLLBACK=0
fi

# ---------- 预检 ----------
[[ -f "$ROOT/.env" ]] || die "$ROOT/.env 不存在。按 deploy/README.md 第 3 步创建。"

# 这三项由 compose / 镜像固定。run.sh 会 source .env,.env 里再写一份会
# 覆盖 compose 的值:数据库可能落到容器临时盘(重启即丢付费记录),或反代
# 头不被信任(全站匿名用户共享一份免费配额)。两种都不报错,所以在这里拦。
if grep -nE '^[[:space:]]*(export[[:space:]]+)?(QICOMPASS_DB_PATH|FORWARDED_ALLOW_IPS|UVICORN_BIN)=' "$ROOT/.env"; then
    die "上面这些变量由 docker-compose.yml 固定,请从 $ROOT/.env 里删掉(或注释掉)再发版。"
fi
grep -qE '^[[:space:]]*(export[[:space:]]+)?JWT_SECRET_KEY=.+' "$ROOT/.env" \
    || die "$ROOT/.env 缺 JWT_SECRET_KEY(用 openssl rand -hex 32 生成)。"

mkdir -p "$ROOT/data" "$ROOT/backups"
chown "$APP_UID:$APP_UID" "$ROOT/data" "$ROOT/.env"
chmod 600 "$ROOT/.env"

# ---------- 发版前备份 ----------
if [[ -n "$("${COMPOSE[@]}" ps -q api 2>/dev/null)" ]]; then
    echo "==> 发版前备份数据库"
    bash "$ROOT/src/deploy/backup.sh"
else
    echo "==> api 容器未在运行(首次部署),跳过发版前备份"
fi

# ---------- 构建与切换 ----------
export IMAGE_TAG="$TAG"
if [[ "$ROLLBACK" == 0 ]]; then
    echo "==> 构建镜像 qicompass-api:$TAG"
    "${COMPOSE[@]}" build api
fi
echo "==> 启动 $TAG(旧容器最多等 210s 让在飞请求跑完)"
"${COMPOSE[@]}" up -d

# ---------- 健康检查 ----------
echo "==> 等待服务就绪"
healthy=0
for _ in $(seq 1 30); do
    if "${COMPOSE[@]}" exec -T api python -c \
        "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/api/health', timeout=5).read().decode())" \
        2>/dev/null; then
        healthy=1
        break
    fi
    sleep 3
done
if [[ "$healthy" != 1 ]]; then
    echo "---- api 最近日志 ----" >&2
    "${COMPOSE[@]}" logs --tail 60 api >&2 || true
    die "服务 90 秒内未就绪。版本记录未更新;修复后重发,或运行 server-deploy.sh --rollback。"
fi

# ---------- 记录版本(健康后才写,失败的版本不会成为回滚目标) ----------
if [[ -f "$ROOT/current_tag" ]] && [[ "$(cat "$ROOT/current_tag")" != "$TAG" ]]; then
    cp "$ROOT/current_tag" "$ROOT/previous_tag"
fi
echo "$TAG" > "$ROOT/current_tag"
echo "==> 完成:当前版本 $TAG"
echo "    请核对上面输出里的 ai_provider / ai_model / prompt_versions 是否符合预期。"
