# TASK-17 生产配置 Sign in with Apple 吊销密钥 + 真机删号走查(P0,上架前,真人步骤为主)

## 背景

App 目前只保留 Apple 登录,所以每一次删号都会走 Apple token 吊销
(`backend/app/api/auth.py` `delete_account`)。生产 `.env` 缺少下面三个变量时,
`revoke_apple_tokens` 抛 `AppleRevocationNotConfiguredError`,**所有用户删号都返回 503**。
App Review 实测删号时遇到 503 = 违反 5.1.1(v),直接被拒。

## 要做

**真人步骤(用户本人在 Apple Developer 后台完成,AI 不能代办):**

1. Apple Developer → Certificates, Identifiers & Profiles → Keys → 新建 Key,勾选 **Sign in with Apple**,
   关联 App ID `com.qicompass.app`,下载 `.p8`(只能下载一次,妥善保存)
2. 记下 Key ID 与 Team ID

**AI 可做的部分:**

3. 在 `docs/后端部署设计决策.md` §3「配置与密钥」的变量表中补三个变量及说明
   (`APPLE_AUTH_TEAM_ID` / `APPLE_AUTH_KEY_ID` / `APPLE_AUTH_PRIVATE_KEY`,私钥可写成一行、换行用字面 `\n`,
   `config.py` 会归一化),并注明它们属于密钥,**不进 git**
4. 后端启动日志:若三者缺任一,启动时打一条 **warning**(写明「删号将全部 503」),
   但不阻止启动(本地开发不需要配置);生产部署检查清单里加一项「启动日志无此 warning」
5. 写一份真机走查记录模板 `docs/tasks/TASK-17-walkthrough.md`,包含下面「验收」的四步,留空格给用户填结果

## 验收(真机,生产或预发后端)

1. 用测试 Apple ID 登录 → 购买一次深度解析(沙盒)→ 同步一张命盘
2. 我的 → 设置 → 删除账号 → 系统弹 Apple 重认证 → 确认 → 看到完成提示
3. 后端日志出现 `apple.revocation.ok` 与 `account.deleted`;`user_chart_sync` 无该用户行,
   `entitlement` 对应行已是 `deleted` 哨兵且 `is_active = 0`
4. iPhone「设置 → Apple ID → 登录与安全 → 通过 Apple 登录」列表里**已经没有**本 App
   (这是 Apple 侧吊销成功的直接证据)

## 全局约束(必读)

- 来源:2026-11-27 外部 review;开工前读 `CLAUDE.md` 全文
- commit 必须三段式 body:Why / What / Impact
- `.p8` 内容、Key ID、Team ID 不得写进任何会提交的文件
