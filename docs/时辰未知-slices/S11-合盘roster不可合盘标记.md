# S11 合盘 roster「不可合盘」标记

- **类型**: AFK
- **Blocked by**: S05(对卡展示层 Optional 化);一期收尾,可与 S07 并行
- **覆盖决策**: D5 合盘行(免费照给/付费拦同形态;任一方无时辰即拦该对,复用合盘多选 D13 对级隔离)/ D9 二期(roster entry 级标记:自己无时辰→全部对不可用;他人无时辰→该对不可用)
- **Parent**: `docs/时辰未知设计决策.md` + `docs/合盘多选设计决策.md`(D13)

## What to build

1. **roster entry 标记**(合盘多选名单):每个他人命盘 entry 按 payload `hour_known` 标「不可合盘」(置灰/留白记号,水墨语言;无红色警示);**自己无时辰 → 全部对不可用**(名单整体标记 + 解释行)
2. **发起拦截**:被标记的对应级不可发起(对级错误隔离 D13 同款交互——不可点/点击轻提示,不是发起后报错);增量预查照常跑,标记在预查前由本地判据给出(单一事实源 payload,零后端改动)
3. **已有结果对**:补时辰前生成的对(若历史存在)→ 展示照常(内容是当时契约产物);S10 他人盘补时辰后该对 hash 变化 → 按新盘走(对级关系自然重算,合盘多选已有机制)
4. **免费/付费同形态**:无时辰对被拦在发起,不会出现「免费可看付费拦」——比 S07 语义更早一层;S07 的「合盘付费部分拦截」只覆盖「自己无时辰但对方有时辰想看免费部分」的场景,两者判据同源(payload)
5. **后端合盘契约**:person B 走 ChartSnapshot hash(S04 存档),后端无需新增字段——确认合盘请求链路无「必填时辰」假设即可(纯核对,预期零改动)

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
