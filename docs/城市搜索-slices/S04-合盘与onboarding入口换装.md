# S04 合盘快速添加 + onboarding 入口换装

- **类型**: AFK
- **Blocked by**: S03(组件与引擎已就绪)
- **覆盖决策**: Q9(三入口统一/删 CityList)
- **Parent**: `docs/城市搜索设计决策.md`

## What to build

把 S03 的 `CityPickerField` + `CitySearchSheet` 复制到剩余两个出生地入口,删除旧 `CityList`:

1. **合盘快速添加**(临时人表单,`CompatibilityConfigView` 内):城市 Picker → `CityPickerField`;临时人输入模型 `city: String` 换结构化 place(lon/lat/tz/name/geonameId);「现排 B」请求随 S02 契约发物理真值;落点名兜底(`input.city ?? "经度 …"`)改为 place 显示名
2. **onboarding**:先确认表单屏与 `BirthFormView` 的复用关系——若复用(S03 已换装)则本 slice 只剩 `BirthInfoConfirmSheet` 出生地回显改「城市, 国家」+ 提交前校验链路确认;若 onboarding 有独立表单实现,则同样换装
3. **删 `CityList` enum**(`BirthFormView.swift:185-199`)与全仓对 `CityList.cities` 的引用(grep 清零);旧 `selectedCity: String` / `tempSelectedCity: String` 状态迁移为结构化 place 后删除
4. 快速添加的 DatePicker 同样挂临时所选城市时区 Calendar(WYSIWYG 一致性)

## Acceptance criteria

- [ ] 合盘快速添加:搜「东京」→ 临时人 B 排盘请求 `timezone=Asia/Tokyo` + 经纬度正确,合盘结果页正常
- [ ] 快速添加落点名兜底显示所选城市显示名(不再出现「经度 xx」字样,除非 S05 自定义地点)
- [ ] onboarding 全流程:表单选城 → 确认页回显「城市, 国家」→ 提交生成命盘,行为与深度解析入口一致
- [ ] 未选城市时两条路径均有必选校验(合盘在添加临时人时、onboarding 在提交时)
- [ ] `grep -r "CityList" ios/` 零残留;`selectedCity` 字符串状态零残留
- [ ] 三入口(深度解析/合盘/onboarding)搜索行为一致:同查询同结果同排序
- [ ] iOS 编译通过;合盘相关既有测试(`CompatibilityViewModelBatchTests` 等)适配后全绿
- [ ] 新增文案中英 xcstrings key 补齐

## 实现锚点(现状快照 2026-08-15,实施以代码为准)

- `Features/Compatibility/CompatibilityConfigView.swift:239-269` — 临时人表单 DatePicker + 城市 Picker
- `Features/Compatibility/CompatibilityConfigView.swift:156` — 落点名兜底 `input.city ?? "经度 …"`
- `Features/Compatibility/CompatibilityViewModel.swift` — 临时人输入模型(`tempSelectedCity` 等)与「现排 B」请求构造
- `Features/Onboarding/BirthInfoConfirmSheet.swift:36` — 出生地回显
- `Features/DeepAnalysis/BirthFormView.swift:185-199` — `CityList` enum(删除)
- `ios/Tests/Compatibility/CompatibilityViewModelBatchTests.swift` — 既有测试适配

## 红线与约束

- **合盘多选红线**(D4/D12/D6)零改动:不碰 entitlement/付费/持久化结构;临时人仍不建 `UserSnapshotLink`
- **零兼容垫片**:字符串 city 状态直接删,不留「字符串或结构体」双形态
- **错误显式传播**:必选校验失败照常走内联错误,不默认兜底城市

## 测试

- 合盘临时人请求构造单测(物理真值 + naive 钟面 + tz)
- onboarding 提交链路单测(未选城拦截)
- 三入口一致性冒烟(同查询字符串断言同首位结果)
