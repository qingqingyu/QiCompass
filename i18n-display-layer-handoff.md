# QiCompass 展示层语言交接说明（L1 UI 文案 / L3 命盘术语 / L4 品牌术语）

**文档性质**：施工说明书，给执行者（AI 或人）照着做。决策部分已由用户拍板，执行者不得自行改动。
**事实核验时间**：2026-09-27，基于 `main` @ `4475656`（T0 + T1 已合入）。所有数字与行号均为实测。
**要解决的现象**：系统语言为英文时，界面上仍大量出现汉字。
**范围**：iOS 展示层三语（zh / zh-hant / en）。**不含** prompt 模板与后端语言解析（那是 `i18n-trilingual-handoff.md` 的 T1-T3，en 部分已完成）。

## 与其他 i18n 文档的关系

| 文档 | 覆盖 | 状态 |
|---|---|---|
| `i18n-implementation-plan.md` | 2026-08-12，16 条执行决策 | 有效，本文档补其未覆盖的 L3 层 |
| `i18n-zh-hant-plan.md` | 繁体 + 语言切换（D1-D8 / S1-S5） | 有效 |
| `i18n-trilingual-handoff.md` | T0 iOS 类型化 / T1-T3 后端模板 / T4-T5 iOS | T0+T1 已实施；**本文档取代其 T4 的粗粒度描述** |
| **本文档** | L1 UI 文案缺口全量 + L3 命盘术语层（上游三份均未覆盖）+ L4 术语策略 | 待实施 |

冲突时：本文档 > `i18n-trilingual-handoff.md` T4 > 其余。`CLAUDE.md` 与 `DESIGN.md` 始终优先于本文档。

---

## 0. 一句话结论

界面语言分四层，**目前只有一层半是通的**。英文用户看到汉字有三个独立来源，修一个不解决另两个：

1. **L1a**：xcstrings 里 142 个中文 key **没有 en 翻译** → 回落显示 key 本身（即中文原文）
2. **L1b**：613 处中文字面量**从未进 xcstrings** → 把 xcstrings 翻完也修不到
3. **L3**：排盘响应**完全不感知语言** → 十神 / 神煞 / 五行 / 纳音 / 旺衰 恒中文，且 iOS 侧无任何术语翻译表

---

## 1. 四层语言模型（实测）

| 层 | 内容 | 现状 | 事实依据 |
|---|---|---|---|
| **L1** UI 框架文案 | 按钮 / 标题 / 弹窗 / 错误提示 | **混合** | 见 §1.1 |
| **L2** AI 正文 | 命书章节 / 合盘 / 今日运势 | ✅ en 已通 | T1 落地 `prompts/en/` 15 模板 |
| **L3** 命盘术语数据 | 十神 / 神煞 / 五行 / 纳音 / 长生 / 旺衰 | ❌ **完全未接** | 见 §1.2 |
| **L4** 品牌与保留术语 | 干支 / 农历 / 壹-捌 / 印章 / 竖排 | 中文（部分有意） | 策略见 §3 |

### 1.1 L1 的两类缺口

**L1a — 已被 Xcode 抽取但缺 en**（填 xcstrings 即可修）：

- `Localizable.xcstrings` 共 356 key；**162 个缺 en**，其中 **142 个 key 本身含汉字**（另 20 个是纯符号/格式串，无害）
- `sourceLanguage = zh-Hans`，这类 key 的"文本"就是中文 → 英文用户直接看到中文原文
- 另有 12 条 `state: new` 的 zh-Hans 占位（均为 `%@` 格式串）待补实
- 按文件分布（Top）：`ProfileView` 36 / `CompatibilityConfigView` 17 / `ChartArchivePickerView` 11 / `L10n.swift` 10 / `BirthInfoConfirmSheet` 7 / `CompatibilityPairListView` 7
- 其中 31 条是插值串（`"\(x) · 日主 \(y)"` 被抽成 `%@ · 日主 %@`），需按 `String(localized:)` 带参数的方式改写，不能简单填表

**L1b — 从未进 xcstrings**（必须改代码）：**613 处 / 59 文件**（统计已排除双语表、纯数据表、开发日志）。成因是以 `String` 而非 `LocalizedStringKey` 传参，Xcode 抽不到。Top：

| 处数 | 位置 | 性质 |
|---|---|---|
| 124 | `Features/DeepAnalysis/ChapterContent.swift:187` `labels` | 命书阅读页全部结构标签（`"evidence": "据"` 这类），走 `label(_:)` 显示 |
| 42 | `Features/Compatibility/AssessmentCardGrid.swift:20+` | `title: "五行互补"` 等卡名 |
| 41 | `Features/Place/CitySearchSheet.swift:18+` | `label: "GMT+8 · 中国标准时间"` 时区表 |
| 31 | `Features/Paywall/PaywallViewModel.swift:34,44` | `return "深度命书"` / 权益清单 |
| 29 | `Features/Compatibility/CompatibilityViewModel.swift` | 用户可见错误提示 |
| 25 | `Features/Paywall/PaywallView.swift` | 付费墙文案 |
| 23 | `Services/AccountManager.swift` | 登录错误提示 |
| 17 | `Features/DeepAnalysis/DeepAnalysisHomeView.swift:60-62` | `heroRow(label: "年"/"月"/"日")` 柱标 |
| 16 | `Models/ModuleDefinitions.swift:29-51` | M0-M7 标题 + 副标题 |
| 14 | `Services/CompatibilityOrchestrator.swift` | 错误提示 |
| 13 | `Features/DeepAnalysis/ChartDetailView.swift:62,66,74` | `HairlineSection(title: "四柱"/"辅柱"/"五行分布")` |
| 12 each | `ChapterReadingInputForm` / `BirthFormView` / `AddHourSheet` / `CompatibilityConfigView` | 表单与弹层 |
| 11 | `Features/DeepAnalysis/ShenshaChips.swift` | 空态文案 + 节标 |
| 10 | `Services/PurchaseManager.swift` | 购买错误提示 |

**不要翻译**（本次白名单，纯数据 / 开发期）：`Networking/APIClient.swift`（96，mock 文本 + 日志）、`Persistence/DailyFortuneVerifier.swift`（55）、`Persistence/SwiftDataCRUDVerifier.swift`（16）、`Shared/ElementColors.swift`（32，dict 查表键）、`Services/PromptContextBuilder*.swift`（24，prompt context 构造，术语按决策不翻）、`Debug/`。

### 1.2 L3 是最大单一来源，且上游三份文档均未列为缺口

- `backend/app/api/bazi.py`（排盘端点）中 **`language` 出现 0 次** —— 排盘响应不解析 `Accept-Language`，原样返回中文术语
- 后端**已有 11 张英文术语表**（`term_translations.py`）：`HEAVENLY_STEMS_EN` 10 / `EARTHLY_BRANCHES_EN` 12 / `FIVE_ELEMENTS_EN` 5 / `TEN_GODS_EN` 11 / `STRENGTH_LABEL_EN` 5 / `STRENGTH_LABEL_ZH_EN` 6 / `NAYIN_EN` 30 / `TWELVE_STAGES_EN` 12 / `GENDER_EN` 2 / `COMPAT_TERMS_EN` 22 / `MISC_TERMS_EN` 1 —— 但**只服务 prompt context 翻译**
- iOS 侧**一张都没有**：`grep -rn "Seven Killings\|Nobleman" ios/` = 0 命中
- 因此以下位置在任何语言下都是中文：
  - `Features/DeepAnalysis/ShenshaChips.swift:38` `Text(item.name)` —— 神煞名直出后端中文
  - `Features/DeepAnalysis/XijiCard.swift:30,33` 喜用/忌讳五行 chips（`favorableElements` 是 `["木","火"]`）
  - `XijiCard.swift:43` `Text("算法:\(method)")` —— method 是中文
  - 首页 hero / 盘面细目 的十神、纳音、长生、旺衰
- **神煞 20 个（11 吉 + 9 凶）三边都没有英文表** —— 不是"未接通"，是翻译源不存在（清单见 `backend/app/engine/shensha.py:253` `SHENSHA_NAMES`）

---

## 2. 逐界面语言现状

| 界面 | UI 文案 | 命盘数据 | AI 正文 | 英文用户实际看到 |
|---|---|---|---|---|
| Onboarding 三屏 | ✅ 英文（dot-key 齐） | 生肖英文 | — | ✅ 干净 |
| 确认出生信息 sheet | ❌ 中文 7 条 | 干支中文 | — | ❌ |
| Tab 栏 | ❌ 中文 4 条（`RootTabView.swift:61,69,77,85`） | — | — | ❌ **第一眼即中文** |
| 今日运势 | ⚠️ 英文（宜忌有 `mappingEn`） | ❌ 十神 / 喜忌中文 | ✅ 英文 | ⚠️ 混排 |
| 深度解析首页 hero | ❌ 年/月/日 柱标中文 | ❌ 全中文 | — | ❌ |
| 盘面细目 | ❌ 13 处节标中文 | ❌ 全中文 | — | ❌ 整页中文 |
| 命书目录 | ❌ 5 条 + M0-M7 标题 16 条 | — | — | ❌ |
| 命书章节阅读 | ❌ `labels` 124 条中文标签 | — | ✅ 英文正文 | ❌ 英文正文套中文标签 |
| 合盘全流程 | ❌ 52（L1a）+ 105（L1b） | ❌ 中文 | ✅ 英文 | ❌ **最差** |
| 合盘评估卡 | ❌ 42 处卡名 | ❌ 中文 | — | ❌ |
| 付费墙 | ❌ 5 + 56 | — | — | ❌ |
| 我的 | ❌ 44 + 17 | — | — | ❌ |
| 城市搜索 | ❌ 41 处时区标 | — | — | ❌ |
| 登录 | ❌ 中文（"使用 Apple 登录"） | — | — | ❌ |
| 各类错误提示 | ❌ 66 处（Account 23 / CompatVM 29 / Orchestrator 14） | — | — | ❌ 出错时蹦中文 |

**结论：英文目前只有 onboarding 与 AI 正文两处干净，其余全为混排。**

---

## 3. 决策 A：术语显示矩阵（用户已拍板，执行者不得改动）

这是本次新增的**单一事实源**。此前"哪些中文是有意的"散落在 `BaziDateFormatter` / `ZodiacHelper` 注释与决策 7 里，口径不一致。

| 术语类 | 数量 | zh | zh-hant | **en** | 备注 |
|---|---|---|---|---|---|
| 天干地支（甲子） | 10 + 12 | 甲子 | 甲子 | **汉字为主 + 小字拉丁转写**（`甲子` / `Jiǎ Zǐ`） | 汉字是「专业不忽悠」卖点，但须可念可讨论 |
| 十神（七杀） | 10 | 七杀 | 七殺 | **意译** `Seven Killings` | 语义载体，不译则英文正文不可读；`TEN_GODS_EN` 已有 |
| 五行（木） | 5 | 木 | 木 | **意译** `Wood` | `FIVE_ELEMENTS_EN` 已有 |
| 神煞（天乙贵人） | 20 | 天乙贵人 | 天乙貴人 | **意译 + 汉字括注** `Nobleman (天乙貴人)` | **表不存在，须新建**；译名提案见 §5 |
| 纳音（海中金） | 30 | 海中金 | 海中金 | **意译** | `NAYIN_EN` 已有，直接用 |
| 十二长生（长生） | 12 | 长生 | 長生 | **意译** | `TWELVE_STAGES_EN` 已有，直接用 |
| 旺衰 label | 5-6 | 中文 | 繁体 | **意译** | `STRENGTH_LABEL_EN` / `_ZH_EN` 已有 |
| 农历（正月初一） | — | 主要信息 | 主要信息 | **降为次要行，公历为主** | 保留中文正确，但不能是唯一日期信息 |
| 大写数字编号（壹-捌） | 8 | 壹-捌 | 壹-捌 | **保持壹-捌，不改罗马数字** | **用户 2026-09-27 拍板**；`DESIGN.md` 品牌指纹条款不动 |
| 品牌（玄机问道 / 印章 / 竖排） | — | 保留 | 保留 | 保留（QICOMPASS 拉丁标 + 印章图形） | 视觉资产，非文案 |

**执行约束**：
- 拉丁转写用带声调拼音（`Jiǎ Zǐ`），首字母大写，中间空格。**不做全大写、不用威妥玛**
- 汉字括注只在**首次出现处 / chip 主标**给，正文内不重复括注（避免噪音）
- 壹-捌 保持中文 → 英文用户会看到「壹」，这是**已批准的有意行为**，不要在任何 review 或实现中"顺手修掉"

---

## 4. 决策 B：L3 走「术语 id + 客户端三语表」，不给排盘端点接 Accept-Language

**直觉方案（否决）**：给 `/api/bazi/calculate` 接 `Accept-Language`，后端翻译后返回 —— 看似对齐 i18n 决策 1「翻译责任在后端」。**排盘这条路不能这么走**，三个理由都指向另一边：

1. `ChartSnapshot.contentHash` 按出生信息算、**不含语言**（D1 设计）。响应随语言变 → 同一 hash 两种 payload → 切语言后本地快照仍是旧语言，串台
2. 项目硬约束「八字计算必须确定性：同一输入永远同一输出（含 `calcRuleSnapshot`）」—— 让输出随 HTTP header 变与此冲突
3. 切语言应**即时生效**，不该触发重新排盘（T5 的语言切换是重启生效，重排盘等于额外网络依赖）

**采用方案**：排盘响应**保持中文原文作为稳定术语 id**，iOS 建展示层三语术语表，按 `AppLanguage.current` 取显示值。

- 这正是 i18n 决策 1 原文里那半句「API Response 显式返回对应语言 **+ 术语 id**」——id 那半边一直没实现
- AI 正文仍按决策 1 走后端返回成品（一次性生成物、按语言缓存）。两者分工不同是正确的：**快照数据走 id，生成内容走成品**
- iOS 表规模：十神 10 + 五行 5 + 神煞 20 + 纳音 30 + 十二长生 12 + 旺衰 6 + 干支 22 = **约 105 条 × 3 语言**

**代价与对冲**：术语表两边各一份，有漂移风险 → **新增守护栏 `tools/check_term_sync.py`**，比对后端 `term_translations.py` 的表键集合与 iOS 术语表键集合，不一致即 FAIL。对齐 `check_prompt_sync.py` 的既有模式（本地跑，不接 GitHub Actions）。

**iOS 表的放置**：新建 `ios/QiCompass/QiCompass/L10n/BaziTerms.swift`（**新 .swift 文件须 pbxproj 4 处登记一致的 24 位 ID**，漏登记 = 静默不编译）。术语表用 Swift 字面量而非 xcstrings —— 理由：它是数据表不是文案，需要按 key 查而非按 locale 回落，且要能被 `check_term_sync.py` 静态提取。

---

## 5. 神煞 20 条译名提案（**待人工校对**，不得静默改动）

清单事实源：`backend/app/engine/shensha.py:253` `SHENSHA_NAMES`（11 吉 + 9 凶，《三命通会》单一来源）。

| # | zh | zh-hant | en 提案 |
|---|---|---|---|
| 1 | 天乙贵人 | 天乙貴人 | Nobleman |
| 2 | 太极贵人 | 太極貴人 | Supreme Nobleman |
| 3 | 文昌 | 文昌 | Academic Star |
| 4 | 天德 | 天德 | Heavenly Virtue |
| 5 | 月德 | 月德 | Monthly Virtue |
| 6 | 驿马 | 驛馬 | Travelling Horse |
| 7 | 桃花 | 桃花 | Peach Blossom |
| 8 | 将星 | 將星 | General Star |
| 9 | 华盖 | 華蓋 | Canopy Star |
| 10 | 金舆 | 金輿 | Golden Carriage |
| 11 | 禄神 | 祿神 | Prosperity Star |
| 12 | 羊刃 | 羊刃 | Goat Blade |
| 13 | 劫煞 | 劫煞 | Robbery Star |
| 14 | 亡神 | 亡神 | Loss Spirit |
| 15 | 孤辰 | 孤辰 | Solitary Star |
| 16 | 寡宿 | 寡宿 | Widowhood Star |
| 17 | 元辰 | 元辰 | Grievance Star |
| 18 | 灾煞 | 災煞 | Calamity Star |
| 19 | 天罗地网 | 天羅地網 | Heaven Net, Earth Snare |
| 20 | 红艳 | 紅艷 | Red Beauty |

**执行者须知**：en 列是提案，须经用户术语 QA（对齐 `i18n-issues-breakdown.md` Slice 6 的 HITL 定位）。**先按此表实现、标注待校，不要自行换词**。繁体列的一对多字已校：艳→艷 / 舆→輿 / 驿→驛 / 华→華 / 将→將 / 禄→祿 / 灾→災 / 罗→羅 / 网→網。

---

## 6. 任务分解

依赖：`U0 → (U1 ∥ U2 ∥ U3) → U4 → U5 → U6`。U1/U2/U3 可并行。

### U0 — 前置修复（上一轮 review 的未修项，先做）

这四条是 `main` @ `4475656` 上的现存缺陷，**其中前两条会让 U1-U5 的验收结论失真**，必须先清。

1. **止血 zh-Hant 半启用**（`L10n/AppLanguage.swift:64` `systemLanguage`）：`.zhHant` 现在可从 Locale 解析出来，但后端 `resolve_language` 未改（`zh-TW` → `"zh"`）、xcstrings 繁体 0 条、`knownRegions` 无 `zh-Hant`。后果：繁体设备读缓存用 `"zh-hant"`、写入 `resp.language="zh"` → **合盘永不命中缓存，而 `CompatibilityOrchestrator.swift:159` 契约是「命中不消耗次数」→ 每次查看都扣配额 + 重烧 LLM**。
   **改法**：`systemLanguage` 暂时把 zh-Hant 折回 `.zh`（保留 enum case 与全部 switch 分支，只是不让它从 Locale 产出），并在该处留 TODO 指向繁体栈就绪的条件（后端 `resolve_language` D4 + `prompts/zh-hant/` + xcstrings 繁体 + `knownRegions`）。**不要**删 case，那会丢掉 T0 的编译器强制。
2. **深度解析缓存语言收口**（`Services/DeepAnalysisOrchestrator.swift:364` 与 `:233`）：`runV1Module` 的 `upsert` 未传 `language` → `InterpretationCacheStore.swift:39` 默认 `"zh"`；`restoreCachedV1Modules` 读死 `"zh"`。T1 让英文深度解析可用后，**英文正文被存进 `language="zh"` 行**，T5 语言切换一上线立刻串台。同 commit 的 daily（`:219`）与 compat（`:273`）已改 `resp.language`，只有 deep 漏了。
   **改法**：写入改 `language: resp.language`，读取改 `AppLanguage.currentWire`，**两处必须同批改**（否则存量 zh 行读不到）。同时清掉 `:194-196` 已过期的 "Slice 2 未实现英文翻译" TODO 注释。
3. **`Features/DailyFortune/DailyImageHeroSection.swift:350`**：正官宜项「覆命」应为「**復命**」（复→復/複/覆 一对多，台湾标准用「復命」）。同表其余转繁已逐条核过，无误。
4. **`backend/app/api/interpret.py:186`**：新增的 `except ValueError` 同时罩住 `validate_context` 与 `render_prompt`，但错误信息写死「context.chart 非合法 JSON」。将来任一 `.md` 模板花括号写错会被这句话带偏排查方向。
   **改法**：把 `json.loads` 的 `ValueError` 收窄到翻译层内部捕获后再包装。

**验收**：iOS 全量 XCTest 绿；backend pytest 全绿；繁体模拟器（zh-TW）行为与 T0 之前完全一致（无繁体残留、缓存正常命中）。

### U1 — L1a：填 xcstrings 的 142 条 en 缺口

**改动**：
- 142 个含汉字的 key 补 en；20 个纯符号串按需补（多数可直接复制）；12 条 `state: new` 的 zh-Hans 占位补实
- 31 条插值串（`%@ · 日主 %@` 这类）：改为 `String(localized:)` + 参数形式，**不要**在 xcstrings 里硬拼
- **保持 key 原样**（key 本身是中文文本），新代码才用 dot-key。改 key 会让所有引用点失效
- 完成后 zh-Hant 列**暂不填**（等 U0-1 的繁体栈就绪，属 `i18n-trilingual-handoff.md` 的 T4 范围）

**验收**：Xcode Export Localizations 导出 en 无缺失；英文模拟器走 Tab 栏 / 我的 / 登录 / 确认 sheet，无中文残留。

### U2 — L1b：613 处硬编码中文走 L10n

按「英文用户第一眼看到什么」排序，**不按代码量排**：

1. `App/RootTabView.swift:61,69,77,85` Tab 栏 4 条（最高优先，第一眼）
2. `Features/Profile/ProfileView.swift` 14 处 + `Features/Account/SignInView.swift`
3. `Features/DeepAnalysis/ChapterContent.swift:187` `labels` 124 条 → 新增 `deepanalysis.chapter.*` dot-key（注意 `:326` 附近的 `gain_or_loss` / `cost` 嵌套 map 一并处理）
4. `Models/ModuleDefinitions.swift:29-51` M0-M7 标题 + 副标 16 条
5. 错误提示 66 处：`Services/AccountManager.swift` 23 / `Features/Compatibility/CompatibilityViewModel.swift` 29 / `Services/CompatibilityOrchestrator.swift` 14 + `Services/PurchaseManager.swift` 10
6. `Features/Compatibility/AssessmentCardGrid.swift` 42 + `CompatibilityConfigView` 12
7. `Features/Paywall/{PaywallViewModel,PaywallView}.swift` 56
8. `Features/DeepAnalysis/{ChartDetailView,DeepAnalysisHomeView,ChapterReadingInputForm,BirthFormView,AddHourSheet,ShenshaChips}.swift`
9. `Features/Place/CitySearchSheet.swift` 41 处时区标 → **优先改用 `TimeZone.localizedName(for:locale:)` 而非翻译硬编码表**（更省且随系统语言自动对）

**陷阱**：`HairlineSection(title:)` / `heroRow(label:)` / `AssessmentCard(title:)` 这些参数类型是 `String` 而非 `LocalizedStringKey`，这正是它们没被抽取的原因。改法是在**调用侧**传 `L10n.xxx`（已本地化的 `String`），不要去改组件签名为 `LocalizedStringKey`（会波及全部调用点，超出本次范围）。

**验收**：`grep` 复查上述文件无用户可见中文字面量残留；英文模拟器逐屏走查（含触发至少 3 类错误提示）。

### U3 — L3：iOS 术语表 + 展示层接入

**改动**：
1. 新建 `ios/QiCompass/QiCompass/L10n/BaziTerms.swift`：约 105 条 × 3 语言，按 §3 矩阵与 §5 译名。**zh 列为 identity（显式写出，不做"缺失即原文"的静默透传）**，对齐后端 `TERM_TRANSLATIONS` 的显式注册哲学
2. 键集合与后端逐字对齐：十神取 `TEN_GODS_EN` 键（**含「偏官/七杀」同义映射，11 条不是 10 条**）、五行取 `FIVE_ELEMENTS_EN`、纳音取 `NAYIN_EN`、长生取 `TWELVE_STAGES_EN`、旺衰取 `STRENGTH_LABEL_EN` + `STRENGTH_LABEL_ZH_EN`
3. **后端补神煞英文表**：`term_translations.py` 新增 `SHENSHA_EN`（20 条，按 §5），并注册进 `TERM_TRANSLATIONS["en"]` —— 这样 prompt context 里的神煞也能翻（当前是漏的）
4. 展示层接入：`ShenshaChips.swift:38` / `XijiCard.swift:30,33,43` / 首页 hero 十神 / 盘面细目 纳音·长生·旺衰 —— 全部改为查 `BaziTerms`
5. 干支按 §3：en 下汉字主 + 小字拉丁转写（新增 `BaziTerms.romanization(for:)`），**只在 chip 主标与首次出现处**给转写
6. 新建 `tools/check_term_sync.py`：比对后端表键集合 vs iOS `BaziTerms.swift` 静态提取的键集合，不一致 FAIL。写法参照 `tools/check_prompt_sync.py`
7. pbxproj 登记 `BaziTerms.swift`（**4 处一致的 24 位 ID**）

**验收**：`python3 tools/check_term_sync.py` PASS；英文模拟器盘面细目页**零汉字**（干支的汉字主标除外，那是 §3 有意保留）；iOS 全量 XCTest 绿 + 新增 `BaziTermsTests`（覆盖：三语键集合相等 / 未注册 key 的行为 / 干支转写）。

### U4 — 农历与日期（§3 的农历条）

`L10n/BaziDateFormatter.swift`：en 下公历为主要信息行、农历降为次要行。zh / zh-hant 维持现状（农历为主）。干支柱维持中文术语不翻（既有决策，不要改）。

### U5 — 英文全屏走查（**HITL，需真人**）

英文模拟器逐屏截图核对：onboarding → 今日运势 → 深度解析（首页 / 盘面细目 / 目录 / 章节阅读）→ 合盘全流程 → 付费墙 → 我的 → 城市搜索 → 登录 + 至少 3 类错误提示。产出残留清单。

### U6 — 术语 QA（**HITL，需真人**）

§5 的 20 条神煞 en 译名 + §3 的十神/纳音/长生 en 用词终审。这一步在 `i18n-issues-breakdown.md` 里就是 Slice 6 的 HITL 定位，**不要让 AI 代替拍板**。

---

## 7. 验收清单

- [ ] U0 四条全部修复；繁体设备行为回到 T0 之前（无半启用）
- [ ] 深度解析缓存读写语言一致，英文正文不再落进 `language="zh"` 行
- [ ] xcstrings en 零缺口（142 + 20 + 12 占位）
- [ ] 英文模拟器逐屏走查：除 §3 有意保留项（干支汉字主标 / 壹-捌 / 农历次要行 / 印章 / 竖排），**无中文残留**
- [ ] `python3 tools/check_term_sync.py` PASS
- [ ] `python3 tools/check_prompt_sync.py` PASS（动了 `term_translations.py` 即触发）
- [ ] `cd backend && pytest` 全绿；iOS 全量 XCTest 绿（含新增 `BaziTermsTests`）
- [ ] `BaziTerms.swift` pbxproj 4 处登记一致
- [ ] `PROMPT_VERSIONS` 未误 bump（本次只加术语表，不动模板 → 不该 bump）
- [ ] §5 译名标注"待校"，未被静默改动
- [ ] `i18n-implementation-plan.md` 追加 §3 术语显示矩阵的指针（事实源声明）

---

## 8. 明确禁止

1. **禁止给 `/api/bazi/calculate` 接 `Accept-Language`** —— 理由见 §4，与"排盘确定性"硬约束冲突
2. **禁止把壹-捌 改成罗马数字或阿拉伯数字** —— 用户 2026-09-27 明确拍板保持中文
3. **禁止自行改动 §5 的 en 译名** —— 标注待校，由用户终审
4. **禁止删除 `AppLanguage` 的 `.zhHant` case** —— U0-1 只是不让它从 Locale 产出，case 与 switch 分支必须保留（那是 T0 的编译器强制价值所在）
5. **禁止改 xcstrings 里中文字面量 key 的 key 本身** —— 会让全部引用点失效；新代码才用 dot-key
6. **禁止把组件签名从 `String` 改成 `LocalizedStringKey`** —— 波及面远超本次范围，改调用侧即可
7. **禁止翻译白名单文件**（`APIClient` mock / `*Verifier` / `ElementColors` 查表键 / `PromptContextBuilder`）
8. **禁止引入任何新依赖**（含简繁转换库）—— `CLAUDE.md` 全局约束
9. **禁止空 catch / 吞异常 / 默认值掩盖失败** —— 术语表查不到应显式失败或显式回落并留日志，不静默
10. **禁止接 GitHub Actions** —— 本地优先

---

## 9. 需要真人的步骤（AI 不要代劳）

| # | 步骤 | 为什么 |
|---|---|---|
| 1 | §5 神煞 20 条 en 译名终审 | 命理术语用词是产品声音，非工程判断 |
| 2 | 十神 / 纳音 / 长生 en 用词终审 | 同上 |
| 3 | U5 英文全屏真机走查 | 混排与截断只有真机可见 |
| 4 | 繁体栈就绪后解除 U0-1 的折回 | 需确认后端 D4 + 繁体模板 + xcstrings 三者齐备 |

---

## 10. commit 规范

每个 U 独立 commit，body 按 `CLAUDE.md` 三段式：Why（动机）/ What（改了哪些函数/类/文件）/ Impact（设计影响）。U0 的四条建议拆成四个 commit（性质不同：止血 / 缓存收口 / 文字修正 / 错误处理收窄）。
