# TASK-04 付费墙加用户协议链接 + 免责声明

## 背景
付费墙目前无条款链接(审核对付费内容要求可见条款)。隐私政策页依赖公开邮箱,**不在本任务范围**。

## 要做
- `ios/QiCompass/QiCompass/Features/Paywall/PaywallView.swift` 与 `AskPaywallView.swift`,购买 / 恢复购买按钮下方加:
  - 「使用条款(EULA)」链接 → `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/`
  - 一行免责:「内容仅供娱乐参考」(三语)
- 预留「隐私政策」链接位,但**本期隐藏**:不写假 URL、不放占位链接(由后续任务填真实 URL 后打开)
- 样式遵循 DESIGN.md(小字号次级文字,非 CTA,不用朱红)
- 文案三语进 xcstrings;跑字体子集 `--verify`

## 验收
- 三语 × 亮/暗色 × 最大 Dynamic Type 截图,链接可点击且不截断
- 现有 Paywall 相关测试全绿

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 除 TelemetryDeck(仅 TASK-06)外不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
