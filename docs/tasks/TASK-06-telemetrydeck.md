# TASK-06 接入 TelemetryDeck 埋点

## 背景
代码中无任何埋点。工具已拍板 TelemetryDeck(新依赖已获同意,仅此一个 SPM 包)。

## ⚠️ 前置
下方事件表是**草案,实现前须先交用户确认**。

## 要做
- SPM 引入 TelemetryDeck Swift SDK,锁定具体版本
- `QiCompassApp.init` 初始化;App ID 从 Info.plist / xcconfig 读,不硬编码;Debug 构建不上报(或 testMode)
- 新建统一封装层(单文件,如 `Services/Analytics.swift`),业务代码不直接调 SDK;事件名与参数用 enum 约束
- **禁止上报**:出生信息、命盘内容、解读正文、问事原文、content_hash、任何自由文本;只传事件名 + 枚举值/布尔
- 不跨 App 追踪,不接 ATT
- `PrivacyInfo.xcprivacy` 与 `docs/archive-testflight.md` 隐私申报补 Analytics / Product Interaction 项(按 TelemetryDeck 官方文档)

## 事件表草案(≤15)
| 要回答的问题 | 事件 |
|---|---|
| 新用户能否走完轻注册? | `onboarding_step_completed(step)`、`birth_form_submitted(hour_known: bool)` |
| 首次看到 AI 内容的比例 | `free_chapters_generated(module: deep/compat)` |
| 免费章能否带动付费? | `paywall_shown(source: deep/compat/ask)`、`purchase_started(product)`、`purchase_succeeded(product)`、`purchase_failed(reason_enum)`、`restore_tapped` |
| 今日页留存 | `app_opened`(SDK 自动)、`daily_fortune_viewed` |
| 问事使用与试用转化 | `ask_sent(paid: bool)`、`ask_trial_exhausted` |
| 多语言是否被使用 | `language_switched(to)` |

## 验收
- 单元测试:封装层参数中不出现非枚举字符串(防误传用户内容)
- TelemetryDeck 后台 testMode 能看到全部事件
- Release 构建成功;Privacy Report 无缺项

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 除 TelemetryDeck(仅 TASK-06)外不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
