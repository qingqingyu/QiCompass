# QiCompass 后端(FastAPI)

排盘 / 合盘 / 每日运势 API。`lunar_python` 同步 CPU-bound,路由层用
`run_in_threadpool` 包;API key 只在后端,不进客户端。

## 部署备忘

> **文档分工**:`docs/后端部署设计决策.md` 是部署**设计**事实源(选址 /
> 形态 / 备份策略 / 发版流程 / 生产 env 全表,含 D1-D6 待拍板项);本节是
> 贴着代码的**操作清单**。环境变量全量清单与逐项注释见 `.env.example`
> (变量名与默认值的事实源,含生成命令与取值口径)。

### 环境与启动

- **tzdata 必须可用**(S02 时区解释依赖 stdlib `zoneinfo`):macOS/Linux 开发
  环境自带零动作;**Alpine 容器需 `apk add tzdata`**,否则历史夏令时规则
  (1986-91 中国夏令时等)缺失,启动自检会直接失败(`app/main.py` 探针)。
- 运行:`./run.sh`(多 worker uvicorn,worker 数 `WEB_CONCURRENCY`,默认 2);
  测试:`python3 -m pytest tests/ -q`(根目录 `pytest.ini`)。
- `.env` 从 `.env.example` 复制,`run.sh` 显式 source。必填项缺失即启动
  失败:`JWT_SECRET_KEY`(生产 `openssl rand -hex 32`)。
- **付费上线(App Store 验证)须配齐 `APP_STORE_*` 5 项**(申请步骤见
  `.env.example`):缺配时 Mock 锁定、redeem 显式 503;production 缺配直接
  拒绝启动,不会带 Mock 假验证上线。
- 部署后核对:`GET /api/health` 的 `prompt_versions` / `lunar_python_version`
  / `ai_provider` 与预期版本一致,再放流量。

### 反代与真实客户端 IP(必配;漏配 = 全站匿名共享一份免费配额)

- `run.sh` 已带 `--proxy-headers --forwarded-allow-ips`;信任的反代地址由
  `FORWARDED_ALLOW_IPS` 配置,默认 `127.0.0.1`(反代与后端同机)。
- **Docker Compose(反代独立容器)必须填 Docker 网段**(如 `172.18.0.0/16`)
  或反代容器 IP——否则 `X-Forwarded-For` 不被信任,所有匿名用户按反代地址
  共享一份每日免费配额。
- CIDR 写法需 uvicorn>=0.31(requirements 已锁下界);`*` 只在信任边界完全
  可控(端口不直连暴露)时用,否则任意客户端可伪造转发头刷额度。

### 服务端 LLM 配额(2026-10-08 拍板口径;改 `.env` 后重启生效)

| 变量 | 默认 | 口径 |
|---|---|---|
| `QICOMPASS_FREE_DAILY_LIMIT` | 150 | 免费 module 每日上限,只计真烧 LLM(缓存命中不计) |
| `QICOMPASS_PAID_DAILY_LIMIT` | 500 | 付费按购买主体独立分桶,与免费互不挤兑,拦脚本滥用 |
| `QICOMPASS_REFUND_DAILY_LIMIT` | 5 | 分类退(服务商故障/截断/翻译保真失败退,禁词类不退)的每日退款上限,堵「构造失败免费烧 LLM」 |

### LLM 监控(2026-10-09 A 档 + 10-10 鉴权收口)

- 告警:当前 UTC 小时桶调用数 ≥ `QICOMPASS_LLM_ALERT_MIN_CALLS`(默认 5)
  且失败率 ≥ `QICOMPASS_LLM_ALERT_FAILURE_RATE`(默认 0.5)→ ERROR 日志
  `ALERT llm_failure_rate`(进程内 10min 节流,多 worker 独立);恢复打
  `ALERT_RESOLVED llm_failure_rate`。无外部推送通道(不引入新依赖的代价),
  靠日志平台 grep / hook 该锚点。
- 出口:**`GET /api/health/llm` 需要 Bearer token**——未配置
  `QICOMPASS_LLM_HEALTH_TOKEN` 时端点整体 404(fail-closed,不暴露存在性);
  配置后须带 `Authorization: Bearer <token>`(token 仅 ASCII,含空白启动
  即拒)。该端点暴露 provider 身份/按模块调用量/provider 原始错误片段
  (URL 已脱敏),只限运维本人查:
  `curl -H "Authorization: Bearer $QICOMPASS_LLM_HEALTH_TOKEN" .../api/health/llm`

### 轮换 `JWT_SECRET_KEY` 的影响(单一开关,两类凭证同时失效)

登录 JWT 与 context_token 签名密钥(HMAC 域分隔派生,
`app/context_binding.py`)同源——轮换密钥时:

1. **登录会话**:所有已发 JWT 立即失效,用户需重新登录;
2. **context_token**:老 token 全部 403。客户端自愈路径:深度解析/每日运势
   在 403 摄入点静默重签恢复(有补存排盘入参的盘),更老的盘与合盘走既有
   「重新排盘」出口;
3. 服务端**无需清理任何存储**(无孤儿化);但轮换后短时间内 iOS 端会有一波
   403 + 重排盘流量,**选低峰执行**。
