# S03 iOS 表单拆双 picker + 日期必选

- **类型**: AFK
- **Blocked by**: None — 与 S01/S02 并行(hour_known 恒 true,纯 iOS 数据质量修复)
- **覆盖决策**: D8(默认日期洞一起修,含「把矛盾变成教育」文案与工作量备注)
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

修「日期字段默认 1990-03-15、可不碰就提交」的数据质量洞,并为 S04 时辰未知做表单结构准备:

1. **拆双 picker**(`BirthFormView`):现状日期与时刻是同一个 DatePicker(`displayedComponents: [.date, .hourAndMinute]`)同一个 `birthDate` 绑定,**无法只隐藏小时分量** → 拆成两个控件、两个绑定:
   - 日期行(date-only wheel sheet),`birthDate: Date?` 未选择初始态
   - 时刻行(hourAndMinute wheel sheet),独立绑定(默认值保留现状语义)
   - 时辰快捷选(`shichenGrid`)改写时刻绑定,语义不变(选中=该时辰中点)
2. **birthDate Optional 化**(`DeepAnalysisViewModel`):校验加「请选择出生日期」(未选择 → formInvalid);「不晚于当下」校验保留
3. **Optional 化波及**(决策 D8 工作量备注清单):`OnboardingView`(生肖屏 birthYear 取值)/ `BirthInfoConfirmSheet`(确认展示)/ `DeepAnalysisViewModel`(buildRequest / wallTimeString / setShichenHour)/ `APIClient` mock 路径——提交时强制解包前校验已保证非空,失败显式抛错不静默
4. **文案教育**(D8):表单日期区一行微文案「日期决定年月柱与生肖;时刻决定时柱与喜忌」(L10n 中英)
5. **提交门**:`PrimaryCTAButton` 逻辑不变,校验失败走现有 `formInvalid` 内联错误展示

本 slice **不引入**「不知道出生时刻」入口(那是 S04);时刻行照常必选默认。

## Acceptance criteria

- [ ] 全新表单不碰日期直接提交 → formInvalid「请选择出生日期」,不发起网络请求
- [ ] 不碰日期但城市未选 → 两条错误并列展示
- [ ] 日期已选 + 时刻未碰 → 正常提交(时刻默认值语义与现状一致),排盘结果与现状同输入一致
- [ ] 时辰快捷选仍按「中点小时」生效,日期行「X时 ›」小标显示正确
- [ ] 二次确认 sheet(BirthInfoConfirmSheet)展示拆分后的日期与时刻,数值与表单一致
- [ ] onboarding 三屏流程走通(Welcome → 表单 → 生肖反馈),生肖屏 birthYear 取自所选日期
- [ ] XCTest:未选择/已选择/时辰快捷选/确认 sheet 数值一致性 用例全绿

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `iOS/QiCompass/QiCompass/Features/DeepAnalysis/BirthFormView.swift:100-127` — 同一 DatePicker(sheet)+ `datePickerSheet`
- `iOS/QiCompass/QiCompass/Features/DeepAnalysis/BirthFormView.swift:148-210` — 时辰快捷选 / `currentShichenHour`(23 归子时)
- `iOS/QiCompass/QiCompass/Features/DeepAnalysis/DeepAnalysisViewModel.swift:60` — `birthDate` 默认 1990-03-15;`:152-158` validateForm;`:192-201` setShichenHour
- `iOS/QiCompass/QiCompass/Features/Onboarding/OnboardingView.swift:110` — 生肖屏 `placeCalendar.component(.year, from: vm.birthDate)`
- `iOS/QiCompass/QiCompass/Features/Onboarding/BirthInfoConfirmSheet.swift:92` 附近 — 确认展示(注意:该文件在 Onboarding 目录不在 DeepAnalysis)
- `iOS/QiCompass/QiCompass/Networking/APIClient.swift:387` 附近 — mock 路径

## 红线与约束

- 表单视觉遵循水墨孤本 O2 无框下划线语言(新 date-only / time-only sheet 复用现有 wheel sheet 样式)
- 错误显式传播:Optional 解包失败显式抛错,禁止 `?? Date()` 静默兜底
- 新文案进 L10n / xcstrings(中英)
- 不动后端、不动 prompt

## 测试

- `iOS/Tests/` 新增/扩展表单校验用例:日期必选门 / 时辰默认 / 拆分后数值一致性;全量 XCTest 保持绿(基准 166+)
