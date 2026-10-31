# TASK-03 修订旧文档口径(纯文档)

## 背景
2026-10-28 拍板后,两份文档口径过时或与实际不符。

## 要做
### `docs/archive-testflight.md` §5
- 删掉"QiCompass 本地存命盘数据,**不**上云"
- 改为如实申报清单,依据:
  - 出生信息发往后端排盘与 LLM 生成解读
  - 登录后 `SyncManager.push` 会上传命盘到后端
  - Sign in with Apple 用户 ID
  - 购买记录(entitlement / ask_credits)
- 申报口径:Other User Content / User ID / Purchase History;用途 App Functionality;不用于追踪

### `MONETIZATION.md`
- 决策汇总「上架区域」:全球 → 全球**不含中国大陆**(理由:APP 备案 + 命理内容下架风险 + 后端在新加坡)
- 「文案保持中文(v1 范围)」→ 商店文案 zh-Hans / zh-Hant / en 三语
- §不做「优惠码 / 推广活动 — v2」→ v1 用 **Apple Offer Codes(消耗型)** 赠送测评者;「苹果促销代码 v1 不主动发」同步改
- 文件头 last updated 更新为当天并加一行更新说明

## 验收
- 两份文档无残留旧口径(grep「不上云」「保持中文」「优惠码」核对)

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 除 TelemetryDeck(仅 TASK-06)外不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
