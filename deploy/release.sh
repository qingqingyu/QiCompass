#!/usr/bin/env bash
# 发版(在 Mac 上跑):把当前 commit 的后端代码同步到服务器并重启服务。
#
#   ./deploy/release.sh root@<服务器IP>
#   ./deploy/release.sh root@<服务器IP> --rollback    # 切回上一个版本
#
# 版本号 = 当前 git commit 短 hash。backend/ 或 deploy/ 有未提交改动时拒绝
# 发版——否则线上跑的代码对不上任何 commit,出问题无法定位也无法回滚到它。
set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "用法: $0 <ssh目标,如 root@1.2.3.4> [--rollback]" >&2
    exit 2
fi
TARGET="$1"
MODE="${2:-}"
REMOTE_ROOT=/srv/qicompass

cd "$(dirname "$0")/.."

if [[ "$MODE" == "--rollback" ]]; then
    ssh "$TARGET" "bash $REMOTE_ROOT/src/deploy/server-deploy.sh --rollback"
    exit 0
elif [[ -n "$MODE" ]]; then
    echo "未知参数: $MODE(只支持 --rollback)" >&2
    exit 2
fi

if [[ -n "$(git status --porcelain -- backend deploy)" ]]; then
    echo "ERROR: backend/ 或 deploy/ 有未提交改动,先 commit 再发版:" >&2
    git status --short -- backend deploy >&2
    exit 1
fi
TAG="$(git rev-parse --short HEAD)"
echo "==> 发版 $TAG → $TARGET"

ssh "$TARGET" "mkdir -p $REMOTE_ROOT/src/backend $REMOTE_ROOT/src/deploy"

# 只同步生产需要的文件;.env 与 data/ 永不从 Mac 覆盖服务器。
rsync -az --delete \
    --exclude '.venv/' --exclude 'data/' --exclude '.env' --exclude '.env.*' \
    --exclude 'tests/' --exclude 'evalkit/' --exclude 'spikes/' \
    --exclude '__pycache__/' --exclude '.pytest_cache/' \
    backend/ "$TARGET:$REMOTE_ROOT/src/backend/"
rsync -az --delete deploy/ "$TARGET:$REMOTE_ROOT/src/deploy/"

ssh "$TARGET" "bash $REMOTE_ROOT/src/deploy/server-deploy.sh $TAG"
