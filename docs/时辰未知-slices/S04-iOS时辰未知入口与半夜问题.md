# S04 iOS「不知道出生时刻」入口 + 二值半夜问题

- **类型**: AFK
- **Blocked by**: S01(后端契约)、S03(表单已拆双绑定)
- **覆盖决策**: D1(单一入口系统分流)/ D3(二值问题「是否半夜出生」,iOS 采集半边)/ D8(时辰可跳过的表单状态机)
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

1. **入口**(`BirthFormView` 时刻区):「不知道出生时刻」显式选项(checkbox / chip,水墨语言);选中后:
   - 时刻行与时辰快捷选**收起**(不再展示任何看似精确的时刻)
   - 展开二值问题:「你是否在半夜(约 11 点之后)出生?」三态:是 / 否 / 不确定。**默认未选,必须选一个才可提交**(不把「不确定」设为默认——避免又一层默认假答案;未选 → formInvalid)
   - 取消勾选 → 恢复时刻行,lateNight 状态保留还是重置:重置(回到有时刻路径,三态答案作废)
2. **VM 状态**(`DeepAnalysisViewModel`):`hourKnown: Bool`(默认 true)、`lateNight: Bool?`;`buildRequest` 带上 `hour_known` / `late_night`(S01 契约);`hour_known=false` 时 `birth_datetime` 时辰部分传什么由契约定(后端 12:00 占位,iOS 传时刻绑定当前值即可,语义被 flag 否定——**建议 iOS 显式传 12:00** 减少歧义)
3. **ChartSnapshot payload**:存档 `hour_known` / `late_night`(`decodeIfPresent` 解码,老盘缺字段 → 视为 hour_known=true);content_hash 计算跟随后端语义(S01:flag=false 时时辰桶不参与)——iOS 侧 hash 是算好传后端还是后端算?现状 content_hash 在后端算(契约),iOS 只存档;对齐现状
4. **二次确认 sheet**:无时辰提交时确认页明示「出生时刻:未知(半夜:是/否/不确定)」,防误提交
5. **onboarding 与深度解析兜底表单共用** `BirthFormView`,自动获得同能力;Profile 新建命盘 sheet 同

## Acceptance criteria

- [ ] 勾选「不知道」+ 三态选「否」→ 提交请求 `hour_known=false, late_night=false`
- [ ] 三态「是」/「不确定」→ `late_night=true` / `null`(编码上不传或显式 null,对齐 S01 契约)
- [ ] 勾选但三态未选 → formInvalid,不发起请求
- [ ] 取消勾选 → 时刻行恢复,`late_night` 清空,请求走 `hour_known=true` 原路径
- [ ] ChartSnapshot 存档含两字段;老盘(缺字段)解码不 crash 且按 hour_known=true 处理
- [ ] 二次确认 sheet 无时辰态展示正确
- [ ] onboarding 三屏流程:勾选不知道 → 提交 → `.ready` 生肖反馈屏照常(年柱已知场景)
- [ ] XCTest:状态机全分支(勾/取消/三态/提交链路/payload 解码)

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `iOS/QiCompass/QiCompass/Features/DeepAnalysis/BirthFormView.swift` — 时刻区 / 时辰快捷选(S03 拆分后)
- `iOS/QiCompass/QiCompass/Features/DeepAnalysis/DeepAnalysisViewModel.swift` — 表单状态 / `buildRequest`
- `iOS/QiCompass/QiCompass/Models/` ChartSnapshot payload(D1 JSON payload 设计,新字段 decodeIfPresent)
- `iOS/QiCompass/QiCompass/Features/Onboarding/BirthInfoConfirmSheet.swift` — 确认页(在 Onboarding 目录)

## 红线与约束

- 不做用户元选择(D1):入口只有「不知道/知道」,不问「要猜还是接受不准」
- 不做四段时段(已否决);不采集任何「大概上午/下午」信息
- 错误显式传播:三态未选就拦截,不默认
- 视觉:收起动画克制;「不知道」选项文案不弱智化(「不知道出生时刻」而非「跳过」)
- 新文案进 L10n(中英)

## 测试

- `iOS/Tests/` 新增 `BirthFormHourUnknownTests`:状态机 / 请求字段 / payload 编解码 / 确认 sheet
