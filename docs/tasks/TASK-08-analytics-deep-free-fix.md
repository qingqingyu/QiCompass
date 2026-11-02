# TASK-08 修复命书免费章埋点永不触发(TASK-06 复核返工)

## 背景(复核发现)
`free_chapters_generated(module: deep)` 只在 `module == "bazi_deep_free"` 时上报:
- `ios/QiCompass/QiCompass/Services/DeepAnalysisOrchestrator.swift:188`(`runInterpretation`)
- `ios/QiCompass/QiCompass/Services/DeepAnalysisOrchestrator.swift:424`(`runV1Module`)

但命书已走 v1 链,免费章是 `m0_structure` / `m1_talent`(`Models/ModuleDefinitions.swift` 的 `ModuleID.isFree`),全仓已无 `bazi_deep_free` 调用方(`runInterpretation` 仅被合盘与每日运势调用)。结果:命书($17.99 主力产品)免费→付费漏斗**零数据**。合盘侧(`CompatibilityOrchestrator.swift:263`)正确,不动。

## 要做
- `runV1Module`:改为按 `ModuleID(rawValue: module)?.isFree == true` 判定后上报 `Analytics.freeChaptersGenerated(module: .deep)`
- 口径:每个免费模块成功各报一次(M0、M1 各一次),在事件参数里**不**新增 module 细分(保持事件表已确认的值域);若认为应改为「M0 成功才报一次」,先问用户,不要自行改口径
- `runInterpretation` 里那段 `bazi_deep_free` 死分支删除(死代码,留着误导)
- 不要用字符串字面量重新硬编码模块名,统一走 `ModuleID`

## 测试
- 新增或扩展单测:mock apiClient,调 `runV1Module` 跑 `m0_structure` → 断言上报 1 次 deep;跑 `m2_*` 付费模块 → 不上报
- 若 Analytics 需要可注入的 sink 才能测,做最小改造(如测试可替换的 signal 闭包),并保证 `AnalyticsContractTests` 仍全绿

## 验收
- 相关单测 + `AnalyticsContractTests` 全绿;Release 构建成功
- grep `bazi_deep_free` 在 Analytics 相关代码中零命中

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
