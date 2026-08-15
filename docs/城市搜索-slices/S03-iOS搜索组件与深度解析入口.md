# S03 iOS 搜索组件 + 深度解析入口(tracer bullet)

- **类型**: AFK
- **Blocked by**: S01(需要 cities.sqlite)、S02(需要新契约)
- **覆盖决策**: Q6(匹配/排序/空态)/ Q7(双列显示/副标题)/ Q8(sheet 交互/砍默认/回显/WYSIWYG)/ Q4(客户端发物理真值)/ Q9(共享组件/xcstrings/attribution)
- **Parent**: `docs/城市搜索设计决策.md`

## What to build

城市搜索端到端第一刀,只换深度解析 `BirthFormView` 一个入口,打通全部风险层:

1. **`CitySearchSheet`**(新组件,放 `Features/Place/` 或共享层):
   - 顶部搜索框自动聚焦,键入 200ms 防抖出结果;空输入态 = 「最近选择」+「热门城市网格」(旧 52 城序即种子,静态常量)
   - 结果行:主名(`name_zh`,缺失显原文)+ 副标题「admin1, 国家」(Cambridge · 马萨诸塞, 美国)
   - 点选回填 + 收起;最近选择本地存储(UserDefaults,上限 ~8 条)
   - 视觉按 `DESIGN.md`:纸白卡片/hairline/4pt 圆角/朱砂点缀
2. **搜索引擎(纯函数 + SQLite 读)**:
   - 查询侧归一化与 S01 构建侧**完全同规则**(NFC + 大小写 + 变音符折叠)——建议把归一化规则写成两平台对照说明放组件注释里
   - 排序:`匹配质量(前缀>包含) > 人口 > 输入脚本加权(汉字/拼音→中国优先,英文→平等) > 最近选择`
   - 实现:SQLite 参数化 LIKE(前缀 `key%` 一级、包含 `%key%` 二级)+ 内存归并排序;无 FTS
3. **`CityPickerField`**(假搜索框):显示当前选中「城市, 国家」或占位「搜索出生城市」;点击推 sheet
4. **`BirthFormView` 换装**:
   - 城市 Picker → `CityPickerField`;**砍「北京」默认**,未选时提交校验「请选择出生城市」(内联错误通道)
   - DatePicker 挂出生城市时区 Calendar(WYSIWYG:选中洛杉矶后表盘即洛杉矶钟面);「时辰快捷选」的 `currentShichenHour` 同步用该 Calendar(现状 `Calendar.current`,BirthFormView.swift:172)
   - 旧「手动输入经度」开关**本 slice 原样保留**(S05 才升级替换,期间走旧 city 路径会 422——故开关暂时改为「自定义经度」并直接构造新契约 longitude + timezone=设备时区,过渡一 slice;实施时若发现更简路径以「不写兼容垫片但不断功能」为准)
5. **请求层**:`BaziCalculateRequest` 改 `birthDatetime`(裸钟面字符串,如 `1988-05-05T02:30:00`)+ `timezone` + `longitude` + `latitude` + `placeName` + `geonameId`;`APIClient` 该字段自定义编码(不再 `.iso8601` Date 直传);钟面提取用出生城市 Calendar 的 components
6. **ChartSnapshot 增字段**:`cityTimezone` / `cityName` / `cityLatitude`(SwiftData,pre-launch 直接加);同步 DTO 对齐 S02 契约
7. **cities.sqlite 加进 Xcode bundle target**;`Localizable.xcstrings` 补全部新文案(中英);设置/关于页加 GeoNames attribution 一行

## Acceptance criteria

- [ ] 输入 `wulumuqi` / `wlmq` / `乌鲁` / `三藩市` / `臺北` / `munchen` 均出正确首位或前列命中
- [ ] 空输入态显示热门网格 + 最近选择;最近选择在选择后更新
- [ ] 同名消歧:Cambridge 搜索结果含英/美两条且副标题区分,按人口排
- [ ] 未选城市提交 → 「请选择出生城市」内联错误,不发请求;**无任何默认城市**
- [ ] 选中洛杉矶 + 输入 10:00 → 请求体 `birthDatetime` 为裸 `...T10:00:00`、`timezone=America/Los_Angeles`;后端返回时辰与洛杉矶真太阳时一致(不再按设备时区错 15 小时)
- [ ] 选中城市后 DatePicker 表盘随城市时区切换显示(WYSIWYG);时辰快捷选圆圈按城市时区小时数高亮
- [ ] ChartSnapshot 含 cityTimezone/cityName/latitude;重开 App 回显正确
- [ ] cities.sqlite 进 bundle;App 可离线完成城市搜索(飞行模式验证)
- [ ] 新文案全部有中英 xcstrings key,无硬编码中文
- [ ] 关于/设置页含 GeoNames attribution
- [ ] 视觉符合 `DESIGN.md`;无阴影/无渐变/圆角 4pt
- [ ] iOS 编译通过 + VM 单测:必选校验、请求构造(裸钟面/tz/经纬度)、搜索引擎排序核心用例

## 实现锚点(现状快照 2026-08-15,实施以代码为准)

- `Features/DeepAnalysis/BirthFormView.swift:53-76` — 出生地 section(Picker + 手动经度开关)
- `Features/DeepAnalysis/BirthFormView.swift:137-175` — 时辰快捷选(`currentShichenHour` 用 `Calendar.current`)
- `Features/DeepAnalysis/BirthFormView.swift:185-199` — `CityList` enum(S04 删,本 slice 先停用)
- `Features/DeepAnalysis/DeepAnalysisViewModel.swift:60-64` — `birthDate/selectedCity/useManualLongitude/manualLongitude`(默认值砍)
- `Features/DeepAnalysis/DeepAnalysisViewModel.swift:127-149` — `validate()` + `buildRequest()` 重写
- `Networking/DTOs/BaziDTOs.swift:8-15` — `birthDatetime: Date` + coding key
- `Networking/APIClient.swift:28-31` — `.iso8601` 编解码策略调整
- `Models/ChartSnapshot.swift:18` — `cityLongitude` 旁增字段
- 新增 `Features/Place/CitySearchSheet.swift` / `CityPickerField.swift` / `CitySearchEngine.swift`(命名可调)

## 红线与约束

- **客户端不做历法计算**:iOS 只做「钟面 components + 城市 Calendar 显示」,**不做 naive→UTC 换算**(后端 zoneinfo 负责);归一化/搜索排序是字符串处理,不算历法
- **确定性**:搜索纯本地纯函数,同输入同输出;SQL 全参数化(防注入)
- **错误显式传播**:sqlite 缺失/损坏 → 显式报错态,不静默空列表
- **i18n**:全部新文案进 xcstrings(中英),不留硬编码
- **不擅自加依赖**:SQLite 读用系统 `SQLite3`(libsqlite3)或现有依赖,不引 GRDB/Realm 类新库;若评估后确需第三方,先报批

## 测试

- `ios/Tests/` 新增:CitySearchEngine 排序/归一化单测(用 bundle 内真实 sqlite 抽样)、VM 校验与请求构造单测(naive 字符串格式化、tz 传递)、CityPickerField 回显状态单测
- 手工 demo 脚本进交付说明:乌鲁木齐(拼音)、洛杉矶(时区修正)、Cambridge(消歧)三例
