# QiCompass 繁体中文 + App 内语言切换 方案

**状态**:2026-09-07 拍板(zh-Hant 进 v1 + 语言切换从 v2 提前),方案文档,未实施
**上游文档**:`i18n-implementation-plan.md`(2026-08-12,16 决策 + 11 slice 计划,本文档修订其中两项)
**范围**:后端 + iOS 全链路 zh-Hant 支持;App 内语言切换(跟随系统 / 简体 / 繁体 / English)

---

## 1. 决策修订(对 08-12 plan 的 supersede)

| 08-12 plan 原决策 | 本方案修订 |
|---|---|
| v1 语言 = zh-Hans + en | **zh-Hant 进 v1**,变成三语 |
| App 内语言切换 UI = v2 | **提前到 v1**(本次一并实施) |
| 第二波语种候选只有 es / ja,数据驱动 | zh-Hant 不走"第二波"流程,直接进 v1;es / ja 仍按原计划数据驱动 |

**理由**:
1. 繁体与 en 性质不同——不需要 PMF 赌注。命理文化圈内台/港/澳 + 海外繁体华人对八字认知度与简体用户同源,没有"海外非华人市场验证"问题
2. 现状是**错的**:繁体系统用户(zh-Hant / zh-TW / zh-HK)的 Accept-Language 被后端坍缩成 `zh`,被动拿到简体版;命理内容繁体用户读简体有摩擦(命理典籍传统即繁体)
3. 边际成本低:术语 90% 同形(干支/五行/生肖全同形),主要是字形转换 + 校对,无 en 那样的 LLM 跨语言调优风险(模型对繁中能力≈简中)
4. 架构 08-12 就按"可扩展多语言"开口子:TERM_TRANSLATIONS 注册表、prompts/{lang}/ 目录、X-QiCompass-Lang header、缓存 language 维度全部就绪,加语言是标准流程
5. 语言选择器上线顺手解掉 08-12 已知 trade-off("海外华人系统英文 → 被迫用英文版")

---

## 2. 现状盘点(2026-09-07 逐项核实)

### 已就绪(可直接复用)

- 后端 `app/api/language.py`:双 header 解析(X-QiCompass-Lang 优先 → Accept-Language → 默认 zh)。**X-QiCompass-Lang 已实现,只是 v1 iOS 不发**
- 后端 `app/engine/term_translations.py`:en 术语表(Joey Yap 体系)+ `translate_context()`;语言支持集合 = TERM_TRANSLATIONS 注册键
- 后端 prompt 模板外部文件化机制:`app/ai/prompts/{zh,en}/*.md` + `_load_template()`,非 zh 语言缺模板**显式抛错**(不静默回中文)
- `InterpretResponse.language` 回传;后端 SQLite 缓存 + iOS SwiftData `InterpretationCache.language` 缓存键维度均已就位
- iOS `L10n/`(AppLanguage / L10n / BaziDateFormatter)、`Localizable.xcstrings`(sourceLanguage=zh-Hans)

### 债务 / 缺口(本方案要还的账)

| # | 缺口 | 现状事实 |
|---|---|---|
| G1 | **en deep/compat 模板缺失**(08-12 Slice 2 债) | `prompts/en/` 只有 daily_fortune 三件套;deep(bazi_deep×3)+ compat(×3)6 个模板还是 `prompts.py` `_LEGACY_TEMPLATES` 内嵌中文 → **系统英文用户跑深度解析/合盘现在就是显式 500**(interpret.py "模板缺失"错误) |
| G2 | deep/compat 的 `translate_context` 未实现 | 只有 daily_fortune 有翻译规则;deep/compat context 中文术语直接进 prompt(被 G1 的 500 掩盖,没暴露) |
| G3 | xcstrings 三语缺口 | 352 keys:dot-style manual 187 + 中文字面量自动抽取 165;有 zh-Hans 200 / en 187 / **完全无 localization 152**;缺 en 165 |
| G4 | 章节标签 iOS 硬编码中文 | `ChapterContent.swift:187` `labels: [String: String]` 是简体中文 map(LLM 输出结构化 key → iOS 映射显示文案),不走 L10n |
| G5 | zh 变体坍缩 | `resolve_language` 只取 Accept-Language primary tag → `zh`,不看 script/region;`AppLanguage.swift` 同样只看 languageCode |
| G6 | 农历/字体单语 | `BaziDateFormatter.lunar` 恒 zh_CN;`Font.custom("Kaiti SC")` 恒简体楷体 |
| G7 | 无语言切换 UI | v1 跟随系统,无入口 |

---

## 3. 方案决策(D1-D8)

### D1:zh-Hant 术语表 = 显式注册表,不引 OpenCC

- **决策**:在 `term_translations.py` 注册 `zh-Hant` 表,与 en 表同构;未注册术语显式 KeyError
- **不引 OpenCC(简→繁自动转换库)的理由**:①新依赖须用户批准且能免则免 ②一对多映射风险(发→發/髮、后→后/後、历→曆/歷),命理领域"农历→農曆"必须准确 ③与现有"显式注册、显式失败"哲学同构,en 表模式已验证
- **表内容**:天干地支/五行/生肖全同形(identity 也要显式进表);异形的主要是:伤官→傷官、七杀→七殺、偏财→偏財、正财→正財、劫财→劫財、贵人→貴人、驿马→驛馬、红艳→紅艷、纳音→納音、大运→大運 等;daily_fortune context 用到的全部字段参照 `_translate_daily_fortune_context` 的取值域补齐
- 术语用词 v1 统一台湾惯用(命理术语本身两岸同源性高,风险小)

### D2:en 债(G1+G2)收编为前置 Slice

- **决策**:S1 先还 en 债:`_LEGACY_TEMPLATES` 6 模板迁文件(byte-identical)+ 新写 en 版 6 模板 + 补 deep/compat 的 `translate_context` 规则
- **为什么是前置**:语言选择器暴露 English 选项 → 用户切到 en 跑深度解析 → 500。zh-Hant 也依赖同一批文件化模板。**不还债,语言切换就不能上线**
- evalkit 守护栏:byte-identical 迁移 → 渲染后 prompt hash 不变 → 响应缓存全命中,`python -m evalkit.runner` 应零成本 PASS(跑一轮确认无 regression 即可)

### D3:语言代码规范化 = 全小写 `zh-hant`

- **决策**:wire 格式统一 `zh` / `zh-hant` / `en`(后端 `resolve_language` 对 header 值 `.lower()` 归一,注册键、`InterpretResponse.language`、iOS AppLanguage、SwiftData 缓存键全链路用同值)
- **理由**:避免 iOS 发 `zh-Hant` / 后端存 `zh-hant` / 缓存查 `zh-Hant` 三处大小写错位导致缓存永不命中
- en 模板新增必须同步 bump `PROMPT_VERSIONS`?**zh/en 现有版本不动**(zh 模板 byte-identical;en 是新键空间,缓存键含 language 无冲突)

### D4:zh 变体解析(后端 + iOS 对称)

- primary tag = `zh` 时看子 tag 决定简繁:
  - `zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO`(及 `zh-Hant-TW` 组合)→ `zh-hant`
  - `zh-Hans` / `zh-CN` / `zh-SG` / 裸 `zh` → `zh`
- 生效于两处:`resolve_language()`(Accept-Language 与 X-QiCompass-Lang 都过此逻辑)和 iOS `AppLanguage`(`Locale.current.language.script / region`)
- 效果:繁体系统用户**零操作自动拿繁体**(不依赖语言切换 UI)

### D5:prompt 模板 zh-Hant 全量 9 文件

- `prompts/zh-hant/`:daily_fortune_v2 / v3 / unknown_hour_v3 + bazi_deep / free / paid + compatibility / free / paid,共 9 文件,由 zh 版转繁 + 模板内**显式写明「請用繁體中文輸出」指令**
- LLM 繁体输出可靠性:同模型繁中能力≈简中,风险低;S5 做 10 盘 spot check。**展示层不做运行时简繁强转**(尊重 LLM 输出,坏了修 prompt 而不是转字)

### D6:App 内语言切换(iOS)

- **入口**:「我的」tab `ProfileView.settingsSection`(子时规则旁,同区)新增「语言 / Language」设置项
- **选项**:跟随系统 / 简体中文 / 繁體中文 / English;存储 `@AppStorage("appLanguageOverride")` = `system` / `zh` / `zh-hant` / `en`
- **生效机制 = AppleLanguages + 重启提示**(方案 A),不自管 per-locale Bundle 热切换(方案 B)。理由:165 个字面量 key 不经过 L10n,方案 B 覆盖不住;系统机制全覆盖、实现最薄。代价是切换后需重启 App,用 alert 引导(v2 再考虑热切换)
- **header**:`override ≠ system` 时 URLSession `httpAdditionalHeaders["X-QiCompass-Lang"] = <规范化值>`(后端已支持,零后端改动);跟随系统时不发(让 Accept-Language 说话)
- `AppLanguage.current` 改为 `override ?? systemLanguage`;SwiftData 缓存查询自动对齐(D4 的同值保证)
- 老缓存兼容规则不变:`language == nil` 视为 `zh`(繁体用户的老简体缓存不会误命中,会重新生成繁体,行为正确)

### D7:iOS 展示层三语化

- **xcstrings 三语补全**:zh-Hans 缺口 152 + en 缺口 165 + zh-Hant 全量 352;zh-Hant 初翻用 Xcode Export Localizations 导出后转繁,**人工校对** UI 文案(一对多映射重灾区:软件→軟體、设置→設定、后→後/后)
- **G4 章节标签**:`ChapterContent.labels` 从硬编码中文 map 改为走 L10n(新增 `deepanalysis.chapter.*` key)
- **农历 formatter**:`BaziDateFormatter.lunar` 按语言取 locale(`zh-hant` → `zh_TW`);公历维持 user locale;干支柱维持中文术语不翻
- **字体**:`zh-hant` 用 `Font.custom("Kaiti TC")`(iOS 自带,不打包),zh/en 维持 Kaiti SC / 系统衬线。**这是 DESIGN.md「Kaiti SC」条款的显式扩展,需在 DESIGN.md 记一笔**(zh-Hant 显示简体字形楷体是错的)
- pbxproj `knownRegions` 加 `zh-Hant`(Xcode UI 操作或手工 + 校验;xcstrings 本身自动容纳)

### D8:App Store Connect

- ASC 加 zh-Hant App 信息本地化(台湾/港/澳商店页名称、副标题、关键词、描述);截图 v1 复用简体(后续迭代再补繁体截图)

---

## 4. Slice 计划

| # | Slice | 内容 | 依赖 | 工作量估算 |
|---|---|---|---|---|
| **S1** | 后端还债 + 模板文件化 | `_LEGACY_TEMPLATES` 6 模板迁 `prompts/zh/`(byte-identical);新写 `prompts/en/` 6 模板(deep×3 + compat×3);补 deep/compat `translate_context` 术语翻译规则;`test_i18n.py` 扩 en deep/compat 全链路;evalkit 无 regression 确认 | 无 | 2-3 天 |
| **S2** | 后端 zh-Hant | `term_translations.py` 注册 zh-Hant 全量表;`prompts/zh-hant/` 9 文件;`resolve_language` zh 变体解析(D4)+ `is_language_supported` 扩展;`test_i18n.py` 扩 zh-Hant(zh-TW/zh-HK header / X-QiCompass-Lang) | S1 | 1-2 天 |
| **S3** | iOS 文案层 | xcstrings 三语补全(D7);`ChapterContent.labels` L10n 化;knownRegions;硬编码中文扫描收尾(字面量 key 逐步转 dot-key,不强求一次清零) | 无(可与 S1/S2 并行) | 3-5 天 |
| **S4** | iOS 语言切换 | ProfileView 语言设置项;`AppLanguage` override 改造 + zh 变体解析;X-QiCompass-Lang 发送;BaziDateFormatter / 字体 per-language;缓存键对齐验证 | S2 S3 | 1-2 天 |
| **S5** | 验收 | 繁体真机三模块走查;en deep/compat 走查(不再 500);LLM 繁体输出 10 盘 spot check;ASC zh-Hant listing | S1-S4 | 1 天 |

**总量约 8-13 天**。S3 是工作量主体(翻译 + 校对),可与后端 S1/S2 并行。

---

## 5. 验收标准

- [ ] 系统语言 zh-Hant / zh-TW / zh-HK 的真机:全 UI 繁体、三模块 AI 解读繁体、缓存按语言隔离不串
- [ ] 切换到 English 后跑深度解析 / 合盘:正常返回英文(不再 500)
- [ ] 切回简体:内容与缓存正常,无串台
- [ ] `python -m evalkit.runner` 无 regression;动了 REQUIRED_FIELDS 相关实现则 `tools/check_prompt_sync.py` PASS
- [ ] backend pytest 全绿(含 test_i18n 扩展);iOS 全量 XCTest 绿(含 GoldenQueriesTests)
- [ ] 语言切换 alert 引导重启后,所选语言全链路生效(UI + 后端解读 + 缓存)

---

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 简→繁一对多映射错(后/裡/发/历) | 术语表显式注册不受影响;UI 文案人工校对(S3 重检点);LLM 输出 spot check(S5) |
| LLM 繁体输出夹简体字 | 模板显式输出语言指令;S5 10 盘 spot check;修 prompt 不做运行时强转 |
| xcstrings 并行会话撞车(09-01 实踩) | 严格按既有 key 级三方合并规程 + 合并后钉点跑 xcodebuild 验证 build 级完好 |
| AppleLanguages 重启生效的 UX 摩擦 | 切换时 alert 明示"重启后生效";v1 接受,v2 再考虑热切换 |
| 台/港用词差异(軟體 vs 軟件) | v1 统一台版;收集反馈后迭代(prompt/文案改动走版本号失效缓存) |
| 字面量 key(165 个)翻译遗漏 | Xcode 自动抽取的 key 以源文案为 key,漏翻 fallback 显示简体不 crash;S3 结束用 UI 走查清单逐屏核对 |

---

## 7. 明确不做(防 scope creep)

| 项目 | 处理 |
|---|---|
| 粤语口语 / 港式变体 | 不做,v1 统一台版书面语 |
| 运行时简繁自动转换(展示层) | 不做,坏输出修 prompt |
| es / ja 等其他语种 | 仍按 08-12 plan:v1 上线 60-90 天看 ASC 数据决策 |
| 语言热切换(不重启) | v2,视重启摩擦反馈再立项 |
| 繁体版专属截图 / 营销素材 | v1 复用简体,后续迭代 |

---

## 8. 实施前置检查清单(每个 slice 起手)

- [ ] `grep` 实际影响范围(`_LEGACY_TEMPLATES` / `translate_context` / `AppleLanguages` / 硬编码中文)
- [ ] CLAUDE.md 全局约束(错误显式传播 / 不擅自加依赖 / 三段式 commit)
- [ ] 单元测试覆盖新代码;动 prompt 相关跑 evalkit + check_prompt_sync
- [ ] xcstrings 合并走 key 级三方规程
- [ ] PR/commit 描述引用本文档决策编号(D1-D8)

---

**文档版本**:v1.0(2026-09-07)
**拍板记录**:用户 2026-09-07 决定加繁体 + 语言选择,委托评估后成文
