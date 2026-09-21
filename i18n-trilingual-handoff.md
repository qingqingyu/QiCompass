# QiCompass 三语（简 / 繁 / 英）实施交接说明

**文档性质**：施工说明书，给执行者（AI 或人）照着做。**不是决策文档** —— 决策已在上游文档拍板，此处只落地。
**事实核验时间**：2026-09-21，基于 `main` @ `460f259`。所有数字与行号均为实测，不是转述上游文档。
**目标**：UI + AI 解读全链路支持 简体中文（zh）/ 繁体中文（zh-hant）/ 英文（en）三语 + App 内语言切换。

## 上游文档（执行前必读，本文档不复述其决策）

| 文档 | 作用 |
|---|---|
| `i18n-implementation-plan.md` | 2026-08-12，16 条执行决策（翻译责任层 / key 命名 / 日期格式化 / 缓存维度） |
| `i18n-zh-hant-plan.md` | 2026-09-07，繁体 + 语言切换方案（D1-D8 决策 + S1-S5 切片） |
| `i18n-issues-breakdown.md` | 2026-08-12，英文版 Slice 1-8 拆解 |
| `CLAUDE.md` | 全局与项目约束，**优先级高于本文档** |
| `DESIGN.md` | 视觉事实源，字体条款需本次显式扩展（见 T5） |

**本文档修订上游两处范围估算**，见 §6。有冲突时以本文档 §6 为准，其余以上游为准。

---

## 0. 一句话现状

架构已就绪（语言是一等维度，加语言≈注册而非重构），三件事挡路：

1. **英文不是"不完整"，是 500** —— 英文系统用户跑深度解析 / 合盘当场硬报错
2. **繁体零实现，且当前被静默降级为简体** —— `zh-TW` / `zh-HK` 被坍缩成 `zh`
3. **语言判断是裸字符串比较** —— 加 `zh-hant` 全仓照常编译、静默跑错（前后端各有一处）

---

## 1. 现状事实（实测）

### 1.1 已就绪，可直接复用（不要重写）

| 能力 | 位置 | 状态 |
|---|---|---|
| 双 header 语言解析 | `backend/app/api/language.py` `resolve_language()` | ✅ `X-QiCompass-Lang` 优先 → `Accept-Language` → 默认 `zh` |
| "已支持语言"单一事实源 | `backend/app/engine/term_translations.py` `TERM_TRANSLATIONS` / `is_language_supported()` | ✅ 注册表驱动，加语言=加一张表 |
| prompt 模板按语言外部文件化 | `backend/app/ai/prompts.py:841` `_load_template()`，`prompts/{lang}/{module}_v{version}.md` | ✅ 机制就位；**但只有 daily_fortune 迁了**（见 1.3） |
| 缺模板显式抛错（不静默回中文） | `prompts.py:855` → `interpret.py:186` → 500 | ✅ 符合"错误显式传播" |
| `language` 打穿响应与两级缓存 | `InterpretResponse.language` / 后端 SQLite / iOS `InterpretationCache.language` | ✅ 缓存天然按语言隔离 |
| iOS 本地化层骨架 | `ios/.../L10n/{L10n,AppLanguage,BaziDateFormatter}.swift` | ✅ 存在，`AppLanguage` 需改造（T0） |
| iOS dot-key 纪律 | `Resources/Localizable.xcstrings` | ✅ **193 个 manual dot-key，zh-Hans / en 零缺口** |

### 1.2 实测数字（执行者可自行复现）

**iOS `Localizable.xcstrings`**（`sourceLanguage: zh-Hans`）：

- 总 key：**358**
- `extractionState: manual`（dot-key，如 `onboarding.form.title`）：**193**，zh-Hans / en **全覆盖，零缺口**
- 自动抽取（key 本身是中文字面量）：**165**，其中 **152 个零本地化**（英文用户直接看到中文）
- `state: new`（占位未翻）：**12**，全在 zh-Hans，均为 `%@` 格式串
- **zh-Hant：0**
- `knownRegions`（`QiCompass.xcodeproj/project.pbxproj:689`）：只有 `zh-Hans`, `en`, `Base`

**iOS 源码中文字面量**（去注释后统计，121 个 .swift 中）：**72 个文件、1175 处**。重灾区：

| 处数 | 文件 | 性质 |
|---|---|---|
| 124 | `Features/DeepAnalysis/ChapterContent.swift:187` `labels` | 硬编码简体 map，**整个命书阅读页的标签层**，不走 L10n |
| 96 | `Networking/APIClient.swift` | Mock 文本 + 日志，非用户可见，**低优先** |
| 88 | `Features/DailyFortune/DailyImageHeroSection.swift` | 十神映射表，已有 `mappingZh` / `mappingEn` 双表 |
| 87 | `Shared/ZodiacHelper.swift` | 生肖汉字表 |
| 55 | `Persistence/DailyFortuneVerifier.swift` | 验证日志，非用户可见，**低优先** |
| 55 | `Features/Profile/ProfileView.swift` | 用户可见 UI 文案 |
| 43 / 32 / 29 | `Compatibility/AssessmentCardGrid` / `CompatibilityConfigView` / `CompatibilityViewModel` | 用户可见 UI + **错误提示文案** |
| 23 | `Services/AccountManager.swift` | 用户可见错误提示 |
| 16 | `Models/ModuleDefinitions.swift:29-51` | M0-M7 标题 + 副标题，用户可见 |

> 注意：`1175` 不等于"待翻译 1175 条"。其中相当部分是术语数据表（干支 / 五行 / 十神 / 生肖）与开发期日志，不进 UI。执行 T4 时先分类再动手，不要无差别替换。

**后端 prompt 模板目录**：

```
backend/app/ai/prompts/zh/  → daily_fortune_v2.md, daily_fortune_v3.md, daily_fortune_unknown_hour_v3.md
backend/app/ai/prompts/en/  → daily_fortune_v2.md, daily_fortune_v3.md, daily_fortune_unknown_hour_v3.md
（无 zh-hant/ 目录）
```

其余模板全部内嵌在 `prompts.py:666` 的 `_LEGACY_TEMPLATES` 常量里（**简体中文硬编码**），而 legacy fallback 被 `language == "zh"` 门卡死（`prompts.py:846`）。

**evalkit 基线**：`backend/evalkit/runs/BASELINE` **不存在**（首轮真实基线未跑，对齐 CLAUDE.md "首轮基线未定"）。→ 见 §2 的验收替代方案。

### 1.3 模板债真实规模（**修订上游估算**）

`i18n-zh-hant-plan.md` 说 en 债是"6 个模板（deep×3 + compat×3）"。实测**不止**：iOS 深度解析当前走的是 **M0-M7 八模块链式调用**（`ios/.../Models/ModuleDefinitions.swift:16-23`），这 8 个模板同样只存在于 `_LEGACY_TEMPLATES`。

| module | 版本 | zh 载体 | en 载体 | 是否 iOS 现役 |
|---|---|---|---|---|
| `m0_structure` … `m7_manual`（8 个） | v1 | `_LEGACY_TEMPLATES` | **无 → 500** | ✅ **现役深度解析主路径** |
| `compatibility_free` / `compatibility_paid` | v3 / v3 | `_LEGACY_TEMPLATES` | **无 → 500** | ✅ 现役合盘 |
| `compatibility`（alias） | v3 | `_LEGACY_TEMPLATES` | 无 | ⚠️ 仅向后兼容老 App |
| `bazi_deep` / `_free` / `_paid` | v3 / v3 / v6 | `_LEGACY_TEMPLATES` | 无 | ⚠️ 仅向后兼容老 App |
| `daily_fortune`(+`unknown_hour` 变体) | v3 | ✅ 文件 | ✅ 文件 | ✅ 现役 |

**结论**：现役路径的 en 债是 **10 个模板**（M0-M7 + compat free/paid），不是 6 个。alias 的 4 个（`bazi_deep`×3 + `compatibility`）是否补 en，取决于是否仍需服务老版本 App —— **这是执行者要向用户确认的唯一一个范围问题**，默认按"不补，但保持 500 显式报错"处理。

### 1.4 会静默跑错的三处（本次最高风险）

| # | 位置 | 现状 | 加 `zh-hant` 后的后果 |
|---|---|---|---|
| R1 | `ios/.../Shared/BaziFont.swift:26` `isChineseUI = AppLanguage.current == "zh"`，守着 `:45` `:61` `:74` 三个字体入口 | 裸字符串比较 | 繁体用户掉进**英文衬线分支**，拿不到楷体。**编译通过、无警告** |
| R2 | `ios/.../Shared/ZodiacHelper.swift:58` `current == "zh" ? animalChar : zodiac` | 同上 | 繁体用户看到 `Dragon` 而不是 `龍` |
| R3 | `backend/app/ai/prompts.py:934` `suffix = BAZI_DEEP_UNKNOWN_HOUR_SUFFIX if language == "zh" else ..._EN` | 同上（后端侧） | 繁体 prompt 尾部被追加**英文** suffix。代码注释已预警："未来注册新语言时需为本 suffix 补对应常量，而非静默回落英文" |

另有 `DailyImageHeroSection.swift:300,305,321` 三处 `== "en"` 三元判断 —— 方向相对安全（繁体落到简体分支），但 T0 完成后应一并收敛。

---

## 2. 施工必须遵守的约束（违反即返工）

全部摘自 `CLAUDE.md`，**优先级高于本文档的任何建议**：

1. **不擅自加依赖** —— 本任务明确点名：**禁止引入 OpenCC** 或任何简繁转换库。理由见 `i18n-zh-hant-plan.md` D1（一对多映射风险 + 与"显式注册、显式失败"哲学冲突）。繁体术语走显式注册表，未注册术语显式 `KeyError`。
2. **错误显式传播** —— 禁止空 catch / 吞异常 / 用默认值掩盖失败。特别地：**禁止把"缺某语言模板"改成静默回落中文或英文**。现有的 `FileNotFoundError` → 500 是**正确行为**，不要"修"掉它。
3. **Git commit 三段式** —— 每个 commit 必须含 Description body，覆盖 Why（动机）/ What（改了哪些函数/类/文件）/ Impact（设计影响）。
4. **prompt 三边一致性** —— 动了 `backend/app/ai/prompts.py`（REQUIRED_FIELDS / PROMPT_VERSIONS / 模板）、iOS `PromptContextBuilder*.swift` / `ModuleDefinitions.swift`、promo `context_builder.py` / `v1_chain.py` 任一，必须跑 `python3 tools/check_prompt_sync.py` 且 PASS。
5. **Prompt 回归守护栏** —— 动了 `prompts.py` 的 M0-M7 模板任一，规则要求 `cd backend && python -m evalkit.runner` 无 regression。**但 `runs/BASELINE` 当前不存在**，无从比对 → 本次采用替代验收，见下方「§2 补充」。
6. **新 .swift 文件须 pbxproj 4 处登记一致的 24 位 ID**（objectVersion 56 传统结构）。**漏登记 = 静默不编译**。本任务若新建文件（如 `AppLanguage` 拆分、语言设置页），必须逐一核对。
7. **不接 GitHub Actions** —— 对齐 2026-08-14「本地优先」决定，所有校验本地跑。
8. **DESIGN.md 是 UI 事实源** —— 任何颜色 / 字体 / 间距 / 圆角 / 动效决策须先读；本任务的字体扩展（Kaiti TC）须在 DESIGN.md 记一笔（见 T5）。

### §2 补充：本次的 evalkit 替代验收

因 `BASELINE` 不存在，**执行者不得自行"造"一份基线**（那会把当前输出固化成事实源，属掩盖风险）。改用**渲染 byte-identical 验证**：

- 凡把 `_LEGACY_TEMPLATES` 里的模板迁到 `prompts/zh/*.md`，迁移必须 **byte-identical**（含尾部换行）
- 验收方式：迁移前后对同一 context 调 `render_prompt()`，比对 `sha256`，**必须完全相等**
- 迁移若 byte-identical，则 `PROMPT_VERSIONS` **不 bump**（渲染结果未变，老缓存仍有效，符合 D3）
- 新增 en / zh-hant 模板**不 bump 任何版本号** —— 缓存键含 `language`，是新键空间，无冲突

---

## 3. 任务分解

依赖关系：

```
T0（iOS 类型化）─┬─→ T4（iOS 文案）─→ T5（切换 UI）─→ T6（验收）
                 │                        ↑
T1（en 模板债）──┴─→ T2（后端语言解析）→ T3（zh-hant 模板）
```

T0 与 T1 可并行。**T0 必须在 T2/T3 之前完成**（否则 R1/R2 会静默带病上线）。

---

### T0 — iOS `AppLanguage` 类型化（先做，最便宜的保险）

**Why**：`AppLanguage.current` 现在是 `String`，全仓 6 处 `== "字面量"` 比较。加 `zh-hant` 时这些分支**照常编译、无警告、静默跑错**（R1/R2）。改成 enum 后，编译器会逼执行者走一遍每一个分支。这是整个任务里投入产出比最高的一步。

**改动**：

- `ios/QiCompass/QiCompass/L10n/AppLanguage.swift` —— 由 `enum AppLanguage { static var current: String }` 改为带 case 的枚举：
  - case：`zh` / `zhHant` / `en`，`rawValue` 用 wire 格式 `"zh"` / `"zh-hant"` / `"en"`（对齐 D3 全小写规范）
  - 新增计算属性：`isChinese: Bool`（zh 与 zhHant 均 true）—— 供字体 / 生肖等"只区分中文与否"的场景用
  - `current` 返回 `AppLanguage`；同时保留 `currentWire: String` 供缓存键 / header 使用（**wire 值必须与后端注册键逐字相等**）
  - 从 `Locale.current` 解析时按 **D4 规则**看 script / region：`zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO` → `.zhHant`；`zh-Hans` / `zh-CN` / `zh-SG` / 裸 `zh` → `.zh`；其余未注册 → `.zh`（默认）
- 收敛全部 6 处调用点，**不要用 `switch` 的 `default` 分支兜底**（那等于把编译器检查关掉）：
  - `Shared/BaziFont.swift:26,45,61,74` —— `isChineseUI` 改用 `isChinese`；并按 T5 预留 `zhHant` → Kaiti TC 分支
  - `Shared/ZodiacHelper.swift:58` —— 改 `isChinese` 判断；繁体需要**繁体生肖汉字表**（龍 / 馬 / 雞 / 豬 / 鼠 / 牛 / 虎 / 兔 / 蛇 / 羊 / 猴 / 狗），新增 `zodiacToCharHant`
  - `Features/DailyFortune/DailyImageHeroSection.swift:300,305,321` —— 三元判断改 switch，补 `zhHant` 十神表（傷官 / 七殺 / 偏財 / 正財 / 劫財 等异形字）
  - `L10n/L10n.swift:338` —— 按上下文判断该用 `isChinese` 还是精确 case
  - `Services/CachedInterpretationReader.swift:49`、`DailyFortuneOrchestrator.swift:149`、`CompatibilityOrchestrator.swift:186`、`DeepAnalysisOrchestrator.swift:222`、`APIClient.swift:285` —— 改用 `currentWire`

**验收**：

- iOS 全量 XCTest 绿（含 `GoldenQueriesTests`）
- 人工核对：全仓 `grep -rn 'AppLanguage.current ==' --include="*.swift"` 返回 **0 条**
- 此时 `zhHant` case 已存在但未启用（xcstrings 无繁体、后端无繁体），行为应与改造前完全一致

**陷阱**：`AppLanguage` 是缓存键的一部分。改造过程中若 wire 值有任何大小写或拼写漂移（`zh-Hant` vs `zh-hant`），缓存会**永不命中**且不报错。改完务必确认 `currentWire` 对 zh / en 两种旧情形返回值与改造前逐字相同（老缓存不能失效）。

---

### T1 — 后端英文模板债（英文当前是 500，最高优先）

**Why**：`prompts/en/` 只有 daily_fortune 三件套；M0-M7 + compat free/paid 仍在 `_LEGACY_TEMPLATES`，而 legacy fallback 被 `language == "zh"` 门卡死（`prompts.py:846`）→ `FileNotFoundError` → `interpret.py:186` → 500。**英文系统用户今天打开深度解析或合盘就是硬报错**。语言切换 UI 上线会把这条路径直接暴露给用户，所以必须前置。

**改动**：

1. **迁 zh 模板到文件**（byte-identical）：把 `_LEGACY_TEMPLATES` 中现役 10 个 module（`m0_structure`…`m7_manual`、`compatibility_free`、`compatibility_paid`）迁到 `backend/app/ai/prompts/zh/{module}_v{version}.md`，版本号取 `PROMPT_VERSIONS` 现值（M0-M7 = v1，compat = v3）
   - 迁移后这些 key 可从 `_LEGACY_TEMPLATES` 删除；alias 的 4 个（`bazi_deep`×3 + `compatibility`）**暂时保留在常量里**，除非用户确认老 App 已下线
2. **新写 en 模板** 同名 10 个，落 `prompts/en/`。术语体系沿用已定的 Joey Yap 体系（见 `term_translations.py` 现有 en 表）
3. **补 `translate_context` 规则**：`term_translations.py:198` `translate_context()` 目前只实现了 `_translate_daily_fortune_context`，deep / compat 的 context 中文术语会**直接进 prompt**（此前被 T1 的 500 掩盖，没暴露）。需按 module 补对应翻译规则，字段取值域参照 `REQUIRED_FIELDS[module]`
4. **从格 suffix 的 en 版**：`prompts.py:908-917` 对非 zh 的 `special_pattern` 显式 raise（一处**有意保留**的债）。本次一并还掉：落 `prompts/{zh,en}/_special_pattern_suffix_v{version}.md`，按文件中的 TODO 改成 `_load_template` 调用
5. `backend/tests/test_i18n.py` 扩 en deep / compat 全链路用例

**验收**：

- `cd backend && pytest` 全绿
- **byte-identical 证明**：迁移前后 `render_prompt()` 输出 sha256 相等（对每个迁移的 module 各跑一次，把 hash 写进 commit body）
- `python3 tools/check_prompt_sync.py` PASS
- `PROMPT_VERSIONS` **未 bump**（byte-identical 迁移 + en 新键空间，见 §2 补充）
- 手动验证：带 `Accept-Language: en-US` 调 `/api/interpret`，module 取 `m0_structure` 与 `compatibility_free`，**不再 500**

**陷阱**：模板里有 `{placeholder}`，`format_map` 走 `_StrictFormatDict`。en 模板若漏写某个 `REQUIRED_FIELDS` 占位符不会报错（少填不抛），但**多写一个 context 里没有的占位符会抛 KeyError**（`prompts.py:777`）。逐个对照 `REQUIRED_FIELDS[module]` 写。

---

### T2 — 后端语言解析 zh 变体 + zh-Hant 注册

**Why**：`_extract_primary_tag()`（`language.py` 末尾）只取 primary tag，`zh-TW` / `zh-HK` 全部坍缩成 `zh` → 台港澳用户不是"拿不到繁体"，而是**静默拿到简体**。

**改动**：

1. `backend/app/api/language.py` —— `_extract_primary_tag` 改为保留 script / region 并按 **D4 规则**归一：
   - `zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO`（含 `zh-Hant-TW` 等组合）→ `zh-hant`
   - `zh-Hans` / `zh-CN` / `zh-SG` / 裸 `zh` → `zh`
   - 其余语言维持"取 primary tag + 小写"现有行为
   - `X-QiCompass-Lang` 与 `Accept-Language` **两条路径都过此逻辑**（D4 明确要求）
   - 归一结果全小写（D3），与 iOS `currentWire` 逐字一致
2. `backend/app/engine/term_translations.py` —— 注册 `zh-Hant` 表（键名用小写 `zh-hant`），与 en 表同构：
   - 天干 / 地支 / 五行 / 生肖**全同形，identity 也必须显式进表**（D1：未注册术语显式 KeyError，不做静默透传）
   - 异形重点：伤官→傷官、七杀→七殺、偏财→偏財、正财→正財、劫财→劫財、贵人→貴人、驿马→驛馬、红艳→紅艷、纳音→納音、大运→大運
   - 用词统一台湾惯用（D1）
   - `translate_context` 的 zh-hant 规则覆盖 daily_fortune + deep + compat（与 T1 第 3 步同批处理）
3. **修 R3**：`prompts.py:934` 的 `if language == "zh" else ..._EN` 二分改为按语言显式取常量，新增 `BAZI_DEEP_UNKNOWN_HOUR_SUFFIX_HANT`。**未注册语言应抛错而非回落英文**（代码注释已要求）
4. `backend/tests/test_i18n.py` 扩：`Accept-Language: zh-TW` / `zh-HK` / `zh-Hant-TW` / `X-QiCompass-Lang: zh-hant` 各一条

**验收**：`pytest` 全绿；`zh-TW` header 进来 `resolve_language` 返回 `zh-hant`；`is_language_supported("zh-hant")` 为 True。

**陷阱**：`is_language_supported()` 的实现是 `language == "zh" or language in TERM_TRANSLATIONS`。注册键写成 `zh-Hant`（大写 H）会导致 header 归一出的 `zh-hant` 查不到 → 静默 fallback 到 zh。**全链路小写**。

---

### T3 — 后端 zh-Hant prompt 模板

**Why**：T2 让繁体请求能被识别，但没有模板就是 500。

**改动**：

- 新建 `backend/app/ai/prompts/zh-hant/`，补齐与 `prompts/zh/` **同名同版本**的全部现役模板：daily_fortune 三件套 + M0-M7 八个 + compat free/paid 两个 = **13 个文件**（上游文档写的"9 文件"是按旧的 deep×3 + compat×3 口径，见 §6）
- 每份由 zh 版转繁 + 模板内**显式写明「請用繁體中文輸出」**指令（D5）
- 从格 suffix / unknown_hour suffix 的繁体版一并补齐（对齐 T1 第 4 步与 T2 第 3 步）
- **展示层不做运行时简繁强转**（D5）：尊重 LLM 输出，输出简体就去修 prompt，不要加转字函数

**验收**：`pytest` 全绿；带 `X-QiCompass-Lang: zh-hant` 跑三模块均正常返回且 `InterpretResponse.language == "zh-hant"`。

**陷阱**：转繁时注意一对多映射（发→發/髮、后→後/后、历→曆/歷、干→乾/幹）。命理语境里「农历→農曆」「天干→天干」「干支→干支」必须准确。**不要用自动转换工具一把梭后不校对**。

---

### T4 — iOS 文案三语化（工作量主体）

**Why**：xcstrings 繁体 0 覆盖，且 152 个中文字面量 key 对英文用户零本地化。

**改动**：

1. **`ChapterContent.swift:187` `labels` 走 L10n**（优先级最高的单点）：124 条硬编码简体 map 是整个命书阅读页的标签层。改为 `deepanalysis.chapter.*` dot-key，三语补全。注意 `:326` 附近还有 `gain_or_loss` / `cost` 等嵌套 map，一并处理
2. **`ModuleDefinitions.swift:29-51`** M0-M7 的 title / subtitle 共 16 条走 L10n
3. **用户可见错误提示**走 L10n：`CompatibilityViewModel.swift`（29 处）/ `AccountManager.swift`（23 处）/ `CompatibilityConfigView.swift`（32 处）/ `ProfileView.swift`（55 处）
4. **xcstrings 三语补全**：193 个 manual dot-key 补 zh-Hant 全量；165 个自动抽取字面量补 en（152 个零覆盖的）+ zh-Hant；12 条 `state: new` 的 zh-Hans 占位补实
5. `pbxproj:689` `knownRegions` 加 `"zh-Hant"`
6. **`BaziDateFormatter.lunar`** 按语言取 locale：`zh-hant` → `zh_TW`（D7）。公历维持 user locale，干支柱维持中文术语不翻（既有决策，不要改）

**不要做**：`APIClient.swift`（96 处）与 `DailyFortuneVerifier.swift`（55 处）的中文是 mock 文本与开发期日志，**不进 UI，不要翻译**。

**验收**：

- Xcode Export Localizations 导出三语无缺失项
- iOS 全量 XCTest 绿
- 若新建了 .swift 文件 → pbxproj **4 处登记一致的 24 位 ID** 核对通过

**陷阱**：`sourceLanguage: zh-Hans`，自动抽取 key 本身就是中文文本。补 en 时**不要把 key 改成 dot-key 再补**——那会让所有引用点失效。新代码用 dot-key，存量字面量 key 原地补翻译即可（对齐 `i18n-zh-hant-plan.md` S3「不强求一次清零」）。

---

### T5 — iOS App 内语言切换

**Why**：D6 决定把语言切换从 v2 提前到 v1；海外华人系统语言为英文时需要手动切回中文。

**改动**（严格按 D6，不要自创方案）：

- **入口**：`Features/Profile/ProfileView.swift` 的 `settingsSection`（子时规则旁，同区）新增「语言 / Language」项
- **选项**：跟随系统 / 简体中文 / 繁體中文 / English
- **存储**：`@AppStorage("appLanguageOverride")` = `system` / `zh` / `zh-hant` / `en`
- **生效机制 = `AppleLanguages` + 重启提示（方案 A）**，**不要**自管 per-locale Bundle 热切换（方案 B）。理由：165 个字面量 key 不经过 L10n，方案 B 覆盖不住。切换后用 alert 引导重启
- **header**：`override ≠ system` 时 `URLSession.httpAdditionalHeaders["X-QiCompass-Lang"] = currentWire`；跟随系统时**不发**该 header（让 `Accept-Language` 说话）
- `AppLanguage.current` 改为 `override ?? systemLanguage`
- **字体**（D7 + R1）：`zhHant` → `Font.custom("Kaiti TC")`（iOS 自带，不打包）。**这是 `DESIGN.md`「Kaiti SC」条款的显式扩展，必须在 DESIGN.md Decisions Log 记一笔**——繁体显示简体字形楷体是错的
- 老缓存兼容规则不变：`language == nil` 视为 `zh`

**验收**：切换 → 重启 → UI + AI 解读 + 缓存三者语言一致，无串台。

**陷阱**：`Kaiti TC` 的 PostScript 名需按 `BaziFont.swift:21` 的既有模式**运行时探测**（`UIFont(name:size:) != nil`），备选名 `STKaiti`。不要硬编码后不探测。

---

### T6 — 验收

见 §4。

---

## 4. 全局验收清单

- [ ] 系统语言 `zh-Hant` / `zh-TW` / `zh-HK` 真机：全 UI 繁体、三模块 AI 解读繁体、缓存按语言隔离不串
- [ ] 切换到 English 后跑深度解析 / 合盘：正常返回英文（**不再 500**）
- [ ] 切回简体：内容与缓存正常，无串台；**老缓存仍命中**（wire 值未漂移的证明）
- [ ] 语言切换 alert 引导重启后，所选语言全链路生效（UI + 后端解读 + 缓存）
- [ ] `grep -rn 'AppLanguage.current ==' --include="*.swift"` 返回 0 条
- [ ] `cd backend && pytest` 全绿（含 `test_i18n.py` 扩展）
- [ ] iOS 全量 XCTest 绿（含 `GoldenQueriesTests`）
- [ ] `python3 tools/check_prompt_sync.py` PASS
- [ ] zh 模板迁移 byte-identical 证明（每个 module 的 render sha256 迁移前后相等），hash 写进 commit body
- [ ] `PROMPT_VERSIONS` 未被误 bump
- [ ] 新建 .swift 文件的 pbxproj 4 处登记一致
- [ ] `DESIGN.md` 已记录 Kaiti TC 字体条款扩展
- [ ] LLM 繁体输出 10 盘 spot check（人工，D5 要求）
- [ ] App Store Connect zh-Hant listing（人工）

---

## 5. 明确禁止

1. **禁止引入 OpenCC 或任何简繁转换依赖**（CLAUDE.md 全局约束 + D1）
2. **禁止把"缺某语言模板"改成静默回落** —— 现有 `FileNotFoundError` → 500 是正确行为
3. **禁止自行生成 evalkit BASELINE** —— 首轮基线是真人步骤（20 盘 × 8 模块 + L2 人工复核 + S05 裁判校准）。本次用 byte-identical hash 替代
4. **禁止为对齐繁体而改动排盘 / 喜忌 / 神煞逻辑** —— 命理计算必须确定性，语言只影响展示与 prompt
5. **禁止展示层运行时简繁强转**（D5）
6. **禁止把老 `_LEGACY_TEMPLATES` 的 zh 模板"顺手优化"** —— 迁移必须 byte-identical，改文案是另一件事、另一个 commit、并需 bump 版本 + 跑 evalkit
7. **禁止接 GitHub Actions**（CLAUDE.md，本地优先）
8. **禁止用 `switch` 的 `default` 分支给 `AppLanguage` 兜底** —— 那等于放弃 T0 的全部收益

---

## 6. 对上游文档的修订记录

| # | 上游说法 | 实测 | 影响 |
|---|---|---|---|
| M1 | `i18n-zh-hant-plan.md` G1：en 债 = 6 模板（deep×3 + compat×3） | 现役路径是 **M0-M7 八模块**（`ModuleDefinitions.swift:16-23`），同样只存在于 `_LEGACY_TEMPLATES`。现役 en 债 = **10 个**（M0-M7 + compat free/paid） | T1 工作量上调；`prompts/zh-hant/` 由 9 文件 → **13 文件** |
| M2 | 同文档 G3：352 keys / zh-Hans 200 / en 187 / 无本地化 152 / 缺 en 165 | 现为 **358 keys / zh-Hans 206（含 12 条 `state:new` 占位）/ en 193 / 无本地化 152 / zh-Hant 0**。且 **193 个 manual dot-key 的 zh-Hans 与 en 零缺口**，缺口全在自动抽取的中文字面量上 | T4 范围更清晰：dot-key 只需补繁体，字面量 key 需补 en + 繁体 |
| M3 | 同文档 S1 验收："evalkit 应零成本 PASS，跑一轮确认无 regression" | `backend/evalkit/runs/BASELINE` **不存在**，无从比对 | 改用 byte-identical render hash 验收（§2 补充） |
| M4 | 同文档 S4 含「`AppLanguage` override 改造 + zh 变体解析」 | `AppLanguage` 是裸 `String`，6 处 `== "字面量"` 比较，其中 2 处（R1/R2）加繁体会**静默跑错** | **提前为 T0**，置于 T2/T3 之前 |
| M5 | 上游未提及 | `prompts.py:934` 后端也有同形二分（R3），繁体会被追加**英文** suffix | 纳入 T2 第 3 步 |

---

## 7. 交接给执行者的开工建议

- **并行**：T0（iOS）与 T1（后端）无依赖，可同时开
- **单点最高收益**：T0，半天量级，把后面所有繁体分支从"真机才发现"变成"编译器告诉你"
- **单点最高紧急度**：T1，因为英文深度解析 / 合盘**当前就是线上 500**
- **唯一需要向用户确认的范围问题**：alias 模板（`bazi_deep`×3 + `compatibility`）是否补 en / zh-hant —— 取决于是否仍服务老版本 App。默认不补
- 每个 T 独立 commit，commit body 按三段式写 Why / What / Impact
