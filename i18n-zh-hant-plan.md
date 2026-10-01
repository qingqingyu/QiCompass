# QiCompass 繁体中文 + App 内语言切换 方案

**状态**:2026-09-07 拍板(zh-Hant 进 v1 + 语言切换从 v2 提前),方案文档,部分实施(见 §2.1)
**2026-10-01 增补**:D9(界面与解读共用一个语言开关)+ D10(已生成的深度解析 / 合盘切换语言时**翻译原文**,不重新解读)+ S6/S7 两个 slice
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

### 2.1 实施进度(2026-10-01 核实)

> 代码注释里的 T0-T5 编号来自另一份交接文档,与本文 slice 的对应关系:T1≈S1(en 模板)、T2≈S2 后端繁体注册 + `resolve_language` 变体解析、T3≈S2 繁体模板、T4≈S3 xcstrings、T5≈S4 App 内切换。

| 项 | 状态 |
|---|---|
| G1 en 模板 | ✅ `prompts/en/` 已含 M0-M7 + compatibility_free/paid + daily 全套;仅剩 4 个 alias 老模块(bazi_deep×3 + compatibility)在 `_LEGACY_TEMPLATES` 只有中文 |
| T0 `AppLanguage` 类型化枚举 | ✅ `ios/.../L10n/AppLanguage.swift`(`zh` / `zhHant` / `en`,wire 全小写) |
| zh-Hant 后端 | ✅ **S2 已实施(2026-10-01,yuyan worktree)**:`TERM_TRANSLATIONS` 注册 zh-hant 表 131 键(值与 iOS BaziTerms zhHant 列锁定,`check_term_sync.py` ①③ 组三相等);`prompts/zh-hant/` 14 文件(现役版本全套 + suffix 预置,parity 测试锁三语 bump 同步);`resolve_language` zh 变体解析(D4);unknown_hour suffix 三语映射;joiner 语义(zh-hant 干支连写无空格) |
| zh-Hant iOS | ✅ **S3+S4 已实施(2026-10-01,yuyan worktree)**:xcstrings zh-Hant 777/777 全覆盖(305 校对稿回导 + 472 新译)+ knownRegions 回列;`normalizeZhVariant` 已接回(止血解除) |
| 语言切换 UI / `X-QiCompass-Lang` 发送 | ✅ **S4 已实施(2026-10-01,yuyan worktree)**:ProfileView 设置区「语言」Menu(system/zh/zh-hant/en)+ AppleLanguages 镜像 + 重启 alert;`AppLanguage.current = override ?? systemLanguage`;`activeOverrideWire` 时 `APIClient.send` 发 `X-QiCompass-Lang`;BaziFont zh-hant 分流 Kaiti TC(DESIGN.md 已记);BaziDateFormatter.lunar zh_TW;新增 `AppLanguageTests`(7 用例,pbxproj 4 处登记) |
| iOS 翻译接入(S7) | ✅ **S7 已实施(2026-10-01,yuyan worktree)**:TranslateRequest DTO(translated_from)/ APIClient.translate(Live+Mock+协议默认实现)/ CachedInterpretationReader.readAllCrossLanguage / 深度 hydrate 跨语言回填原文+translationOffer+acceptTranslation 链式翻译(译后 M0 字段驱动 M1-M7,断链保成功)/ 合盘 openDetail 跨语言探测+acceptTranslation / TranslateHintBar(DESIGN.md hairline)/ STALE_SOURCE 人话;TranslationFlowTests 5 用例(含核心「译后 M0 fingerprint 驱动 M1 请求」) |
| 已生成解读的跨语言处理 | 🟡 **S6 已实施(2026-10-01,yuyan worktree)**:`POST /api/interpret/translate` 落地(D10.1-D10.3,键对齐/STALE_SOURCE/白名单/entitlement 同检/保真校验/先查后译,23 用例锁定,含「译后目标语言 /api/interpret 命中 cached=true」);实施偏差两处见 §3 D10.1 末注。iOS 接入 = S7 未做 |

---

## 3. 方案决策(D1-D10)

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

### D9:界面语言与解读语言 = 同一个开关(2026-10-01 用户拍板)

- **决策**:只有 D6 那一个「语言 / Language」设置项,同时决定 UI 文案、命盘术语显示(`BaziTerms`)和三模块 AI 解读语言。**不做**独立的「解读语言」开关
- **理由**:
  1. 主诉求(英文系统的海外华人想看中文命书)D6 的 override 已覆盖
  2. 拆开会同屏混语:术语 chip / 章节标签走 `AppLanguage.current`,正文走 LLM 输出语言,出现「Wealth Rival」标签配「劫財」正文
  3. evalkit / `check_term_sync` / 缓存键都按单一语言设计,拆开组合翻倍
- **实现约束**:全仓只允许经 `AppLanguage.current` / `currentWire` 取语言;禁止新增第二个语言来源

### D10:已生成的深度解析 / 合盘切换语言 = 翻译原文,不重新解读(2026-10-01 用户拍板)

**问题**:缓存键含 `language`,切换语言后原解读查不到 → 若走 `/api/interpret` 会重新调 LLM 生成。LLM 非确定性 → 同一张盘换个语言结论可能变(「换语言命就变了」,违背「专业不忽悠」);深度解析 8 模块长文重生成成本也高。

**决策**:

| 模块 | 切换语言后的行为 |
|---|---|
| 深度解析 v1(`m0_structure` ~ `m7_manual`) | **翻译**已有正文 |
| 合盘(`compatibility_free` / `compatibility_paid`) | **翻译**已有正文 |
| 每日运势(`daily_fortune`) | 直接按新语言**重新生成**(短、24h 缓存,前后不一致无所谓) |
| alias 老模块(`bazi_deep*` / `compatibility`) | 不支持翻译,维持原行为(老 App 兼容路径,不投入) |

#### D10.1 后端:新端点 `POST /api/interpret/translate`

- **请求体** = `InterpretRequest` 全部字段(`content_hash` / `module` / `context` / `parent_fingerprint` / `m4_*` / `m5_*` / 合盘名字等,**内容按目标语言请求 `/api/interpret` 时会发的那份**)+ 三个新字段:
  - `source_language`:原文语言(`zh` / `zh-hant` / `en`)
  - `source_prompt_version`:原文缓存行的 `prompt_version`
  - `source_interpretation`:原文全文(客户端 SwiftData 里那份)
- **目标语言** = `resolve_language(request)`(与 `/api/interpret` 同口径,iOS 已按 D6 发 `X-QiCompass-Lang`);`source_language == 目标语言` → 422
- **模块白名单**:仅 `V1_MODULES ∪ {compatibility_free, compatibility_paid}`,其余 422
- **门控**:付费模块走与 `/api/interpret` **完全相同**的 entitlement 检查(`entitlement_base_module`),权益与语言无关,翻译不另收费、不消耗任何次数
- **陈旧原文**:`source_prompt_version != PROMPT_VERSIONS[module]` → 409 `STALE_SOURCE`(原文来自旧 prompt,本来就该重生成;客户端收到后走正常 `/api/interpret`)
- **长度上限**:`source_interpretation` 设硬上限(按该模块 max_tokens 折算字符数 ×1.5),超限 422——防止把端点当免费通用翻译器
- **缓存键对齐(关键)**:翻译结果写入后端 SQLite 时,`CacheKey` 必须与「目标语言下 `/api/interpret` 会算出的 key」**逐字段相等**(含按目标语言模板渲染出的 `prompt_hash`、`parent_hash`、`user_input_hash`、`language=目标语言`)。做法:把 `interpret()` 里「校验 → 渲染 → 算 CacheKey」抽成共享函数,两个端点共用,禁止复制粘贴。效果:之后任何设备以目标语言请求 `/api/interpret` 都命中翻译版,不会再生成一份不同结论
- **先查后译**:目标 key 已命中缓存 → 直接返回(`cached=true`),不调 LLM;并发同 key 走现有 singleflight
- **响应**:复用 `InterpretResponse`(`language` = 目标语言,`prompt_version` = 目标模块当前版本)。新增可选字段 `translated_from: str | None`(原文语言,`/api/interpret` 恒为 null)供客户端埋点 / 调试;**不改 SQLite 表结构**(`_drop_legacy_cache_if_needed` 遇列变化会整表 drop,代价是全量缓存失效),来源只打日志 `interpret.translate source_language=… target=…`

#### D10.2 翻译 prompt

- 新模板 `prompts/{zh,zh-hant,en}/translate_v1.md`(按**目标语言**取文件),`PROMPT_VERSIONS["translate"] = 1`;`translate` **不进** v1 module 清单(不影响 `check_prompt_sync.py` 的三边 module ID 校验,但动了 `prompts.py` 仍须跑该脚本 PASS)
- 模板硬约束:只做语言转换,**禁止增删改任何判断、吉凶倾向、年份、干支、数字**;不扩写不缩写;保持段落数
- **术语表注入**:从 `TERM_TRANSLATIONS` 取 源→目标 的术语对(十神 / 神煞 / 五行 / 纳音等)拼进 prompt,要求严格照表译。en→中文方向需要反查表:构建时检测一对多冲突,冲突**显式抛错**(不静默取第一个)
- **格式约束**:
  - v1 模块:输入是 JSON 对象 → 输出必须是**同构** JSON:key 原样不译,只译字符串值;数字 / 布尔 / null 原样
  - 合盘:章节标题行必须换成目标语言模板的格式(zh/zh-hant「第一章 五行共振」,en「Chapter 1 Five Element Resonance」),iOS 章节解析依赖此格式;两人名字(`name_a` / `name_b`)原样保留不译
  - 目标语言模板里的「全文用××书写」指令同样写进翻译 prompt(繁体:「請用繁體中文輸出」)

#### D10.3 输出校验(失败 = 显式错误,不写缓存)

1. v1 模块:剥围栏后 `json.loads`;与原文 JSON **递归同构**(key 集合相同、数组长度相同、非字符串值逐值相等)。不满足 → `AIProviderError`
2. 合盘:章节数与原文相同;两人名字在原文出现过的,译文里也必须出现
3. 走现有 `forbidden_words.validate_interpretation`(与 `/api/interpret` 同一道)
4. 合盘照常走 `_replace_ab_labels` 后置处理(兜底 A/B 代号)

任一失败 → 502 / `AIProviderError` 向上抛,客户端显示可重试错误;**禁止**回退成「返回原文」或「静默改走重新生成」。

#### D10.4 iOS:深度解析的链式依赖

M1-M7 的 `parent_fingerprint` 和 context 里的 `main_axis` / `core_loop` 来自 M0 输出的**自然语言文本**——翻译后这些值变了,M1-M7 目标语言 key 的 `parent_hash` 也随之变。规则:

1. **先译 M0**,拿到译后 JSON,按现有 VM 逻辑解析出目标语言的 `structure_fingerprint` / `main_axis` / `core_loop`
2. 再按顺序译 M1-M7,请求的 `parent_fingerprint` / context 用**译后 M0** 的值(即目标语言下正常链式调用会发的值)——这样 D10.1 的 key 对齐才成立
3. 只译原文语言里**已经存在**的模块;原文没生成过的模块,在目标语言下按正常 `/api/interpret` 生成(链上游已是译后 M0,叙事一致)
4. 任一模块翻译失败:已成功的保留,失败的显示重试,不回滚

#### D10.5 iOS:交互

- 打开深度解析 / 合盘报告时:先按 `AppLanguage.currentWire` 查 `InterpretationCache`;**未命中**再查同 `(contentHash, module)`、`promptVersion` 一致、其它语言的行
  - 找到原文 → **先显示原文**,顶部一条 hairline 提示条:「此报告以简体中文生成 · 翻译为繁體中文」(按钮文案随源/目标语言走 L10n)。点按钮才发翻译请求,**不自动批量翻译**
  - 找不到 → 正常生成
- 视觉遵守 DESIGN.md:提示条用 hairline(ink@18%),按钮不用朱红;翻译中复用现有模块 loading 态
- 翻译结果按 `resp.language` 写入 SwiftData(与生成结果同表同键,无需新字段)
- 每日运势不出提示条,直接按新语言生成

#### D10.1b 实施偏差记录(S6 落地时,2026-10-01)

1. **保真失败 HTTP 码用 503 而非文档草写的 502**:复用既有 `AIProviderError`
   (http_status=503,与 /api/interpret 的「provider 输出违约」同语义同码),
   不为翻译另立 502 通道。
2. **反查冲突「显式抛错」细化为「显式裁决表 + 未裁决抛错」**:D10.2 原文
   要求 en→中文反查一对多冲突显式抛错;实际落地为
   `_REVERSE_CANONICAL_OVERRIDES` 裁决表——已裁决冲突照常翻译(否则
   en→zh 方向因 偏官/七杀 同译 Seven Killings 永远 500):
   - `Seven Killings → 七杀`(同义词,canonical 取 engine 主用形)
   - `Wu → 整组剔除`(戊/午 同音异义,天干 vs 地支不可机械裁决,交 LLM
     按上下文判断——S6 实施时发现的文档未预见冲突)
   未登记的新冲突仍显式 KeyError。

#### D10.6 已知风险(接受)

- 客户端提交原文 = 理论上可提交任意文本让后端翻译:靠模块白名单 + 付费模块 entitlement + 长度上限 + v1 JSON 同构校验(不是该模块形状的 JSON 会被拒)限制;v1 不做额外限流
- 翻译 prompt 后续改版(bump `translate` 版本)不会让已缓存的译文失效(译文存在目标模块 key 下)——可接受,译文问题少;必要时手动清缓存

---

## 4. Slice 计划

| # | Slice | 内容 | 依赖 | 工作量估算 |
|---|---|---|---|---|
| **S1** | 后端还债 + 模板文件化 | `_LEGACY_TEMPLATES` 6 模板迁 `prompts/zh/`(byte-identical);新写 `prompts/en/` 6 模板(deep×3 + compat×3);补 deep/compat `translate_context` 术语翻译规则;`test_i18n.py` 扩 en deep/compat 全链路;evalkit 无 regression 确认 | 无 | 2-3 天 |
| **S2** | 后端 zh-Hant | `term_translations.py` 注册 zh-Hant 全量表;`prompts/zh-hant/` 9 文件;`resolve_language` zh 变体解析(D4)+ `is_language_supported` 扩展;`test_i18n.py` 扩 zh-Hant(zh-TW/zh-HK header / X-QiCompass-Lang) | S1 | 1-2 天 |
| **S3** | iOS 文案层 | xcstrings 三语补全(D7);`ChapterContent.labels` L10n 化;knownRegions;硬编码中文扫描收尾(字面量 key 逐步转 dot-key,不强求一次清零) | 无(可与 S1/S2 并行) | 3-5 天 |
| **S4** | iOS 语言切换 | ProfileView 语言设置项;`AppLanguage` override 改造 + zh 变体解析;X-QiCompass-Lang 发送;BaziDateFormatter / 字体 per-language;缓存键对齐验证 | S2 S3 | 1-2 天 |
| **S6** | 后端翻译端点(D10.1-D10.3) | 抽「校验→渲染→CacheKey」共享函数;`POST /api/interpret/translate`;`translate_v1.md` 三语模板 + 术语对注入(含反查冲突检测);同构 / 章节 / 名字 / 禁词校验;pytest:key 对齐(翻译后以目标语言调 `/api/interpret` 命中缓存且 `cached=true`)、STALE_SOURCE、白名单、entitlement 403、同构失败不写缓存;`check_prompt_sync.py` PASS | S1(zh↔en 可先做);zh-hant 方向依赖 S2 | 2-3 天 |
| **S7** | iOS 翻译接入(D10.4-D10.5) | APIClient + DTO(`translated_from`);跨语言缓存查找;提示条 UI + L10n key;深度解析 M0→M7 顺序翻译与链式取值;合盘翻译;单测覆盖「译后 M0 字段驱动 M1 请求」 | S4、S6 | 2 天 |
| **S5** | 验收 | 繁体真机三模块走查;en deep/compat 走查(不再 500);LLM 繁体输出 10 盘 spot check;**翻译前后结论一致性 spot check(D10)**;ASC zh-Hant listing | S1-S4、S6、S7 | 1-1.5 天 |

**总量约 12-18 天**(含 S6/S7)。S3 是工作量主体(翻译 + 校对),可与后端 S1/S2 并行。

---

## 5. 验收标准

- [ ] 系统语言 zh-Hant / zh-TW / zh-HK 的真机:全 UI 繁体、三模块 AI 解读繁体、缓存按语言隔离不串
- [ ] 切换到 English 后跑深度解析 / 合盘:正常返回英文(不再 500)
- [ ] 切回简体:内容与缓存正常,无串台
- [ ] `python -m evalkit.runner` 无 regression;动了 REQUIRED_FIELDS 相关实现则 `tools/check_prompt_sync.py` PASS
- [ ] backend pytest 全绿(含 test_i18n 扩展);iOS 全量 XCTest 绿(含 GoldenQueriesTests)
- [ ] 语言切换 alert 引导重启后,所选语言全链路生效(UI + 后端解读 + 缓存)
- [ ] (D9)全仓语言来源只有 `AppLanguage.current`;UI、术语 chip、解读正文三者始终同语言
- [ ] (D10)简体下生成完整深度解析(M0-M7)+ 合盘 → 切繁体 → 先显示简体原文 + 提示条 → 点翻译 → 繁体版判断/年份/干支与原文逐条一致;不触发付费墙、不消耗次数
- [ ] (D10)翻译后在另一台同账号设备(或清 iOS 本地缓存后)以目标语言打开,后端返回 `cached=true` 的同一份译文,而非新生成
- [ ] (D10)切语言后每日运势直接按新语言生成,无提示条

---

## 6. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 简→繁一对多映射错(后/裡/发/历) | 术语表显式注册不受影响;UI 文案人工校对(S3 重检点);LLM 输出 spot check(S5) |
| LLM 繁体输出夹简体字 | 模板显式输出语言指令;S5 10 盘 spot check;修 prompt 不做运行时强转 |
| xcstrings 并行会话撞车(09-01 实踩) | 严格按既有 key 级三方合并规程 + 合并后钉点跑 xcodebuild 验证 build 级完好 |
| AppleLanguages 重启生效的 UX 摩擦 | 切换时 alert 明示"重启后生效";v1 接受,v2 再考虑热切换 |
| 台/港用词差异(軟體 vs 軟件) | v1 统一台版;收集反馈后迭代(prompt/文案改动走版本号失效缓存) |
| 翻译改动了判断 / 年份 / 干支(D10) | 模板硬约束 + v1 JSON 同构校验 + S5 一致性 spot check;发现即修翻译 prompt |
| 译后 M0 字段与 M1-M7 请求不一致 → key 错位、每次重生成(D10.4) | S6 pytest 锁「翻译后目标语言 `/api/interpret` 命中」;S7 单测锁链式取值 |
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
| 独立的「解读语言」开关(D9) | 不做,与界面共用一个开关 |
| 切换语言时自动批量翻译全部报告(D10) | 不做,打开报告时用户点按钮才翻译 |
| alias 老模块 / 每日运势的翻译(D10) | 不做;每日运势直接重生成 |
| 为记录翻译来源改 SQLite 表结构(D10.1) | 不做,只打日志 |

---

## 8. 实施前置检查清单(每个 slice 起手)

- [ ] `grep` 实际影响范围(`_LEGACY_TEMPLATES` / `translate_context` / `AppleLanguages` / 硬编码中文)
- [ ] CLAUDE.md 全局约束(错误显式传播 / 不擅自加依赖 / 三段式 commit)
- [ ] 单元测试覆盖新代码;动 prompt 相关跑 evalkit + check_prompt_sync
- [ ] xcstrings 合并走 key 级三方规程
- [ ] PR/commit 描述引用本文档决策编号(D1-D10)

---

**文档版本**:v1.1(2026-10-01,增补 D9/D10 + S6/S7);v1.0(2026-09-07)
**拍板记录**:用户 2026-09-07 决定加繁体 + 语言选择,委托评估后成文;2026-10-01 拍板界面与解读共用一个语言开关(D9)、已生成报告切换语言用翻译而非重新解读(D10)
