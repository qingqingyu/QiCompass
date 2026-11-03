# TASK-01 新增 PrivacyInfo.xcprivacy(P0,审核硬要求)

## 背景
仓库内无 Privacy Manifest;代码使用 UserDefaults / `@AppStorage`(14 个文件),属 Required Reason API,不声明会被拒。

## 要做
- 新建 `ios/QiCompass/QiCompass/Resources/PrivacyInfo.xcprivacy`,并在 `project.pbxproj` 加入 App target 资源(4 处登记)
- `NSPrivacyTracking = false`,`NSPrivacyTrackingDomains` 为空
- `NSPrivacyAccessedAPITypes`:全仓扫描后如实声明
  - UserDefaults → `CA92.1`
  - 另 grep 文件时间戳(creationDate/modificationDate)、`systemUptime`/`mach_absolute_time`、磁盘容量、`activeKeyboards`,命中即补对应 reason
- `NSPrivacyCollectedDataTypes`(口径与 TASK-03 一致):
  - Other User Content(出生信息)/ User ID(Sign in with Apple)/ Purchase History
  - Linked = true(登录后关联),Tracking = false,Purpose = App Functionality
  - TelemetryDeck 相关项由 TASK-06 追加,本任务不加

## 验收
- Xcode Archive → Generate Privacy Report 无缺项
- Release 构建成功

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 除 TelemetryDeck(仅 TASK-06)外不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
