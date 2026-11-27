# TASK-13 匿名配额 / 问事限铸的 IP 改摘要 + 旧日期行清理(P2,隐私政策一致性)

## 背景

账号删除批(4fa6be73)把 `chapter_feedback.client_ip` 改成了 HMAC 摘要,但另有三处仍存**明文 IP**,
且没有任何清理,行永久留存;隐私政策只提了章末反馈的 IP:

| 位置 | 存法 |
|---|---|
| `backend/app/api/interpret.py:770-776` `_free_quota_bucket` | 匿名免费配额桶 `ip:<明文 IP>` → `free_llm_quota` / `free_llm_quota_refunds` |
| `backend/app/api/daily_ask.py:179-181` | 问事防脚本桶 `ask-ip:<明文 IP>`(同进配额表,先 grep 确认落表位置) |
| `backend/app/api/daily_ask.py:451` → `backend/app/ask/store.py:269-311` | `ask_trial_mints.ip` 明文列(每 IP 每日限铸试用身份) |

另:`tmp/app-store-launch/privacy-policy.md:20` 写 IP 摘要「不可还原为原始 IP」。服务端持有密钥时,
IPv4 只有 2³² 个值,可以穷举比对,这句话不成立。

## 要做

1. **抽共享函数**:把 `backend/app/ai/feedback_store.py` 的 `_hash_ip` 挪到新文件
   `backend/app/core/ip_digest.py`,签名 `ip_digest(ip: str, purpose: str) -> str`
   (HMAC-SHA256,密钥仍从 `JWT_SECRET_KEY` 派生,消息 = `f"{purpose}:{ip}"`)。
   `feedback_store` 改调它,**purpose 保持 `"chapter-feedback-ip-v1"` 不变**(存量摘要不用重洗)。
2. **三处改用摘要**,前缀保留(`ip:` / `ask-ip:`)便于区分桶类型:
   - `_free_quota_bucket` → `f"ip:{ip_digest(normalized, 'free-quota-ip-v1')}"`
   - daily_ask 的 `ask-ip:` 桶 → purpose `'ask-ip-v1'`
   - `ask_trial_mints` 写入/查询的 `ip` 值 → purpose `'ask-mint-ip-v1'`
   - 所有调用点仍先走 `_normalize_client_ip`(IPv6 /64 归并等语义不变),再做摘要
3. **存量迁移**(启动时幂等,照 `feedback_store` 已有的清洗写法):把三张表中仍是明文 IP 的行
   (值含 `.` 或 `:`;注意剥掉 `ip:` / `ask-ip:` 前缀后再判断)原地改写为摘要。
   迁移和建表放在同一事务里;失败就向上抛,让启动报错,不吞。
4. **旧日期清理**:`free_llm_quota`、`free_llm_quota_refunds`、`ask_trial_mints` 中
   `day < 今天(UTC) − 7 天` 的行删除。触发点:lifespan 启动时一次,外加写路径
   「当天首次写入时」顺带一次(用进程内记录的上次清理日期判断,不要每个请求都跑 DELETE)。
   7 天常量放在 store 模块顶部并注释理由(配额与限铸只看当天,保留一周仅供排障)。
   **先 grep 确认没有任何代码读取超过当天的配额行**,有的话在 PR 里列出、停下来问。
5. **隐私政策**(`tmp/app-store-launch/privacy-policy.md`):
   - 第 20 行「保存 IP 的加密摘要(不可还原为原始 IP)」改为「保存 IP 的带密钥摘要,不保存原始 IP」
   - 在同一节补一条:「防滥用:免费额度与问事试用按 IP 的带密钥摘要计数,不保存原始 IP,计数记录保留 7 天」

## 验收

- `grep -rn "client.host" backend/app` 的每个调用点,结果要么不落库,要么先经 `ip_digest`;PR 描述里逐个列出
- 新测试(放 `backend/tests/test_ip_digest.py` 或并入相关测试文件):
  - 同 IP 同 purpose 摘要稳定;不同 purpose 摘要不同
  - 三张表写入后的值不含 `.` / `:`(剥前缀后)
  - 存量明文行迁移后变为摘要,且迁移重跑幂等
  - 8 天前的行被清理,今天和昨天的行保留
  - 匿名配额、问事限铸、反馈去重的既有测试全部保持通过(行为不变)
- `cd backend && python -m pytest` 全绿

## 全局约束(必读)

- 来源:2026-11-27 外部 review(竞品差评对照批后续);开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖(`hmac` / `hashlib` 为标准库)
