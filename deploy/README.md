# 生产部署操作手册

设计依据见 `docs/后端部署设计决策.md`;本文是照着做的步骤。

```
iPhone ──HTTPS──▶ api.knowfate.app(Cloudflare DNS,灰云,不开代理)
                      │
               VPS(新加坡)
               ├ caddy 容器:自动 HTTPS,转发到 api
               ├ api 容器:FastAPI,2 个 worker
               └ /srv/qicompass/data:qicompass.db + images/
```

服务器上的目录(全部在 `/srv/qicompass/` 下):

| 路径 | 内容 |
|---|---|
| `.env` | 生产密钥,只在服务器上,不进 git、不进镜像 |
| `data/` | 数据库与插画,**付费记录在这里** |
| `backups/` | 每日数据库备份,保留 30 天 |
| `src/` | 发版时从 Mac 同步过来的代码,不要在服务器上手改 |
| `current_tag` / `previous_tag` | 当前与上一个版本号(回滚用) |

## 首次部署

### 1. 开服务器

- 2 核 / 2–4G 内存 / Ubuntu 24.04,新加坡机房。
- 用 SSH 密钥登录,不用密码。
- 防火墙只放行 22、80、443(含 443/UDP)。

### 2. 装 Docker(在服务器上)

```bash
curl -fsSL https://get.docker.com | sh
```

### 3. 写生产 `.env`(在服务器上)

```bash
mkdir -p /srv/qicompass
nano /srv/qicompass/.env
```

以 `backend/.env.example` 为模板逐项填。与 Mac 上的开发 `.env` 的区别:

- `JWT_SECRET_KEY`:用 `openssl rand -hex 32` 新生成。**上线后不要再改**,改了全体用户要重新登录和重新排盘。
- `QICOMPASS_LLM_HEALTH_TOKEN`:同样用 `openssl rand -hex 32` 生成。
- `APP_STORE_*` 五项填真值,`APP_STORE_ENVIRONMENT=production`。缺任一项服务会拒绝启动。
- AI 的 key 建议用单独的生产 key,方便单独看账单和吊销。
- **不要写** `QICOMPASS_DB_PATH`、`FORWARDED_ALLOW_IPS`、`UVICORN_BIN`:这三项由 compose 固定,写了发版脚本会报错拦下。
- **不要写** `QICOMPASS_ALLOW_MOCK_APPLE`。

`.env` 由 bash `source` 读取(和 Mac 上一致):值里有空格或特殊字符要加引号。

### 4. 配 DNS(在 Cloudflare)

加一条 A 记录:名称 `api`,值填服务器 IP,**代理状态选「仅 DNS」(灰云)**。
开橙云会让超过约 100 秒的 AI 请求全部失败。

### 5. 发版(在 Mac 上,仓库根目录)

```bash
./deploy/release.sh root@<服务器IP>
```

脚本会同步代码、构建镜像、启动服务并打印 `/api/health` 的结果。
首次启动时 Caddy 会自动申请证书,需要第 4 步的 DNS 已经生效。

### 6. 验证

```bash
curl https://api.knowfate.app/api/health
curl -H "Authorization: Bearer <QICOMPASS_LLM_HEALTH_TOKEN>" https://api.knowfate.app/api/health/llm
```

### 7. 配每日备份(在服务器上)

```bash
crontab -e
# 加一行(每天 UTC 19:17,即北京时间凌晨 3:17):
17 19 * * * bash /srv/qicompass/src/deploy/backup.sh >> /srv/qicompass/backups/backup.log 2>&1
```

异地备份(强烈建议,否则服务器磁盘坏了付费记录无法恢复):装好并配置 `rclone`
指向对象存储(如 Cloudflare R2)后,创建 `/srv/qicompass/backup.env`:

```bash
BACKUP_RCLONE_REMOTE=r2:knowfate-backups/db
```

### 8. 恢复演练(上线前至少做一次)

没演练过的备份不算备份。在另一台机器(或本机另一个目录)上:

```bash
gunzip -c qicompass-<时间>.db.gz > /srv/qicompass/data/qicompass.db
chown 10001:10001 /srv/qicompass/data/qicompass.db
# 然后照常发版,确认服务起来、付费记录还在
```

恢复到正在运行的服务器时,先停服务再替换文件:

```bash
docker compose -f /srv/qicompass/src/deploy/docker-compose.yml stop api
rm -f /srv/qicompass/data/qicompass.db-wal /srv/qicompass/data/qicompass.db-shm
# 替换 qicompass.db 后:
docker compose -f /srv/qicompass/src/deploy/docker-compose.yml start api
```

### 9. 上线前的外部配置

- App Store Connect → App Store Server Notifications V2,生产和沙盒都填
  `https://api.knowfate.app/api/webhooks/appstore`。
- AI 厂商控制台设月度消费上限。
- 外部可用性监控(UptimeRobot 等)每 5 分钟请求 `/api/health`。

## 日常发版

```bash
# Mac 上:先跑测试,commit,然后
./deploy/release.sh root@<服务器IP>
```

- 发版前会自动备份一次数据库。
- 旧容器最多等 210 秒让进行中的 AI 请求跑完,期间有数秒不可用。
- `backend/` 或 `deploy/` 有未提交改动时脚本拒绝发版。

## 回滚

```bash
./deploy/release.sh root@<服务器IP> --rollback
```

切回上一个发版成功的版本,不重新构建。数据库表结构只做 `CREATE IF NOT EXISTS`,回滚不需要动数据。

## 改配置

改 `/srv/qicompass/.env` 后重启才生效:

```bash
docker compose -f /srv/qicompass/src/deploy/docker-compose.yml restart api
```

切换 AI provider / 模型也是这样做;客户端通过 `/api/health` 自动隔离旧缓存。

## 看日志

```bash
docker compose -f /srv/qicompass/src/deploy/docker-compose.yml logs --tail 200 -f api
```

LLM 失败率告警也在这里:搜 `ALERT llm_failure_rate`。
