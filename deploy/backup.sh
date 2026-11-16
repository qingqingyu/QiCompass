#!/usr/bin/env bash
# 数据库备份(在服务器上跑;cron 每日一次,发版前也会自动跑一次)。
#
# - 用 SQLite 在线备份 API 取一致快照。WAL 模式下直接 cp 数据库文件会拿到
#   不一致的副本,所以不能用 cp。
# - 备份后做完整性校验,不通过即失败退出。
# - data/images/ 不备份:丢了按需重新生成,只是多花生图费用。
# - 本机保留 30 天。异地上传是可选项:创建 /srv/qicompass/backup.env 写入
#   BACKUP_RCLONE_REMOTE=<rclone远端:桶/路径> 后启用(需自行安装并配置
#   rclone);配置了但上传失败 = 本脚本失败退出。
set -euo pipefail

ROOT=/srv/qicompass
COMPOSE=(docker compose -f "$ROOT/src/deploy/docker-compose.yml")
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
TMP_IN_CONTAINER="/data/.backup-$STAMP.db"
TMP_ON_HOST="$ROOT/data/.backup-$STAMP.db"
OUT="$ROOT/backups/qicompass-$STAMP.db.gz"

mkdir -p "$ROOT/backups"
trap 'rm -f "$TMP_ON_HOST"' EXIT

"${COMPOSE[@]}" exec -T api python - "$TMP_IN_CONTAINER" <<'PY'
import os, sqlite3, sys

dst_path = sys.argv[1]
src = sqlite3.connect(os.environ["QICOMPASS_DB_PATH"])
dst = sqlite3.connect(dst_path)
try:
    src.backup(dst)
    result = dst.execute("PRAGMA integrity_check").fetchone()[0]
finally:
    dst.close()
    src.close()
if result != "ok":
    sys.exit(f"备份完整性校验失败: {result}")
PY

gzip -c "$TMP_ON_HOST" > "$OUT"
chmod 600 "$OUT"
echo "备份完成: $OUT ($(du -h "$OUT" | cut -f1))"

find "$ROOT/backups" -name 'qicompass-*.db.gz' -mtime +30 -delete

BACKUP_RCLONE_REMOTE=""
if [[ -f "$ROOT/backup.env" ]]; then
    # shellcheck disable=SC1091
    source "$ROOT/backup.env"
fi
if [[ -n "$BACKUP_RCLONE_REMOTE" ]]; then
    rclone copy "$OUT" "$BACKUP_RCLONE_REMOTE"
    echo "已上传到 $BACKUP_RCLONE_REMOTE"
else
    echo "WARNING: 未配置异地备份(backup.env 的 BACKUP_RCLONE_REMOTE)。" \
         "备份只存在本机,服务器磁盘损坏时付费记录无法恢复。" >&2
fi
