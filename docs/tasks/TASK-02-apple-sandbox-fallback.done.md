# TASK-02 后端 Apple 沙盒交易回落(P0,部署文档 §6 / D6)

## 背景
`backend/app/entitlement/apple_client.py` 只按一个 `APP_STORE_ENVIRONMENT` 初始化 client 与 verifier。App Review 与 TestFlight 在生产构建里用的都是沙盒交易 → 生产后端 `getTransactionInfo` not found → redeem 失败 → 审核被拒(Guideline 2.1)。Apple 官方协议:先查 production,"交易不存在"再查 sandbox。(不违反 ADR-0010「无 fallback」,那条管 AI provider。)

## 要做
- `AppleServerAPIClient` 同时持有 production + sandbox 两套 `AppStoreServerAPIClient` 与 `SignedDataVerifier`
- `verify_transaction`(L125 附近):先查 production;**仅**在"交易不存在"时回落 sandbox;其他错误照常上抛,不得吞
- `verify_notification`(L157 附近):按 JWS payload 的 `environment` 选 verifier
- `entitlement` 表与 `ask_credits` 台账新增 `environment` 列(按仓库既有迁移方式),记录交易来源环境,便于对账排除沙盒记录
- 更新 `backend/.env.example` / `backend/README.md` 说明配置变化

## 测试(新增)
- prod 命中
- prod not-found → sandbox 命中
- 两边都 not-found → 显式错误
- prod 返回非 not-found 错误 → 不回落,直接上抛
- webhook:sandbox / production 两种 environment 各自选对 verifier

## 验收
- `cd backend && pytest` 全绿
- 若动到 interpret / entitlement 闸位,另跑 `pytest tests/test_context_binding.py` 全绿
- 若动到 `app/models/entitlement.py`,跑 `python3 tools/check_sku_sync.py` PASS

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 除 TelemetryDeck(仅 TASK-06)外不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
