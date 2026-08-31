# S11 合盘 roster「不可合盘」标记

- **类型**: AFK
- **Blocked by**: S05(对卡展示层 Optional 化)、S04(验收需要 hour_known=false 的 payload 存档;S05 与 S04 并行,S05 的传递闭包不含 S04,须显式列出)。**属二期**(对齐 D9/README 分期,勿排进一期);与 S07 无依赖可并行开工
- **覆盖决策**: D5 合盘行(免费照给/付费拦同形态;任一方无时辰即拦该对,复用合盘多选 D13 对级隔离)/ D9 二期(roster entry 级标记:自己无时辰→全部对不可用;他人无时辰→该对不可用)
- **Parent**: `docs/时辰未知设计决策.md` + `docs/合盘多选设计决策.md`(D13)

## What to build

1. **roster entry 标记**(合盘多选名单):每个他人命盘 entry 按 payload `hour_known` 标「不可合盘」(置灰/留白记号,水墨语言;无红色警示);**自己无时辰 → 全部对不可用**(名单整体标记 + 解释行)
2. **发起拦截**:被标记的对应级不可发起(对级错误隔离 D13 同款交互——不可点/点击轻提示,不是发起后报错);增量预查照常跑,标记在预查前由本地判据给出(单一事实源 payload,零后端改动)
3. **已有结果对**:补时辰前生成的对(若历史存在)→ 展示照常(内容是当时契约产物);S10 他人盘补时辰后该对 hash 变化 → 按新盘走(对级关系自然重算,合盘多选已有机制)
4. **免费/付费同形态**:无时辰对被拦在发起,不会出现「免费可看付费拦」——比 S07 更早一层(阶段 1 发起拦截 vs 阶段 2 拦截态);S07 一期已对任一方无时辰整对拦(含免费,因后端 `ChartPayload` 契约无法表达无时辰盘,见第 5 条),本 slice 补 roster 标记 + 发起前 UX,两者判据同源(payload)
5. **后端合盘契约**:「零后端改动」的前提是**发起前拦截**(第 2 条)——无时辰对永不发起,请求永不携带无时辰盘,契约无需表达该状态。注意现状契约**并非**「无必填时辰假设」,而是有两处硬假设构成天然 422 防线,本 slice 保持不动、只如实记录:模式 A `ChartPayload.day_master_strength` Literal 无 `"unknown_hour"` 且 `four_pillars` 必含 `hour` 柱(`app/models/daily_fortune.py:42,45`);模式 B `PersonBInput` 无 `hour_known` 字段(`app/models/compatibility.py:33`)。若未来放开对级拦截(允许无时辰合盘),需同步扩 Literal + Optional 化 hour + 模式 B 加字段(镜像 S01),本期不做

## Acceptance criteria

- [ ] 他人无时辰 → 该对 roster 标记 + 不可发起(点击轻提示,不进计算)
- [ ] 自己无时辰 → 名单整体标记 + 解释行,全部对不可发起
- [ ] 双方有时辰 → 行为与现状完全一致(增量预查/发起/免费付费)
- [ ] 标记判据只读本地 payload,零额外网络请求
- [ ] S10 他人盘补时辰后,该对标记消失、可发起、hash 按新盘
- [ ] XCTest:标记分支(自己/对方/双方)/ 发起拦截 / 补时辰翻转

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `iOS/QiCompass/QiCompass/Features/Compatibility/CompatibilityViewModel.swift` — 多选名单 / 增量预查 / 对级隔离(D13)
- `iOS/QiCompass/QiCompass/**/DualPillarsTable.swift`(S05 Optional 渲染)
- `iOS/QiCompass/QiCompass/Services/CompatibilityOrchestrator.swift` — 阶段 1/2(发起拦截在 VM 层,orchestrator 不动)
- ChartSnapshot payload `hour_known`(S04)/ UserSnapshotLink roster

## 红线与约束

- 对级隔离复用 D13 模式:错误/不可用状态对级呈现,不炸整个名单
- 每对独立 entitlement 零改动(合盘多选 D4);后端计费零改动
- 标记视觉:留白/置灰水墨表达,无红色错误样式
- 新文案进 L10n(中英)

## 测试

- `iOS/Tests/Compatibility/` 扩展:标记分支 + 发起拦截 + 补时辰翻转回归
