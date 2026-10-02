# Review 修复清单 — main `7de82ff..61a7cfa`(2026-10-02)

> 范围:`main` 上 14 个新提交(yuyan L1-L6 语言冻结 / 自动翻译 / STALE_SOURCE 降级 /
> M4M5 持久化 / 每日运势翻译 / 快照语言列,Me 页合并版,合盘陈旧回调守卫)。
> 上一轮 10 条(`30acf05..7de82ff`)已在 `ff06d5b` 全部修复,本文只列**新问题**。
>
> 基线状态(`61a7cfa`):backend pytest 1077 绿;`check_prompt_sync` / `check_sku_sync` /
> `check_term_sync` PASS。iOS 未在 review 环境编译,以下 iOS 条目来自代码阅读。
>
> 行号以 `61a7cfa` 为准,修复前先 `git log` 确认没漂移。

## 给修复者的约束

- 遵守仓库 `CLAUDE.md`:错误显式传播(不吞异常/不用默认值掩盖失败)、commit 三段式(Why/What/Impact)、不擅自加依赖。
- 每条修复都要带**防回归测试**(后端 pytest;iOS 放 `ios/Tests/Shared/TranslationFlowTests.swift` 或相应测试文件)。
- 动了 `backend/app/ai/prompts.py` 或 iOS `PromptContextBuilder*.swift` / `ModuleDefinitions.swift` → 跑 `python3 tools/check_prompt_sync.py`。
- 收尾:`cd backend && python -m pytest tests/ -q` 全绿 + iOS `xcodebuild test` 全绿。
- 每条修完把对应 checkbox 勾上;判断为误报的写明理由,不要静默跳过。

---

## 🔴 P0

### [ ] 1. 每日运势翻译不按日期防伪 → 昨天的运势写进今天的共享缓存(后端)

- **位置**:`backend/app/api/interpret.py:1205`(translate 端点 5.5 原文防伪)→ `backend/app/ai/cache.py::has_interpretation_text`(约 :157-190)
- **问题**:`daily_fortune` 已进 `TRANSLATE_MODULES`(`models/interpret.py:332`),但防伪 SQL 只比对 `content_hash / module / prompt_version / language / interpretation`,**不比对 `target_date`**。
- **复现**:POST `/api/interpret/translate`,`module=daily_fortune`,`target_date=今天`,`source_interpretation=该盘昨天的 zh 运势原文`。防伪通过 → 翻译 → 写入**今天**的 en 缓存键。之后所有设备当天请求该盘 en 运势都拿到昨天的内容。
- **修复方向**:`has_interpretation_text` 增加 `target_date` 参数;`module == "daily_fortune"` 时 SQL 加 `AND target_date=?`(其他 module 用与缓存写入相同的空值口径,参考同文件 `key.target_date or ""`)。路由层把 `req.target_date` 传进去。daily 请求缺 `target_date` 时应 422,不能放行。
- **验收**:新增 pytest——昨天原文 + 今天 target_date → 409 STALE_SOURCE,且不写缓存;同日原文 → 正常翻译。

### [ ] 2. 每日运势跨语言翻译遇 409 / 失败时不降级为正常生成(iOS)

- **位置**:`ios/QiCompass/QiCompass/Services/DailyFortuneOrchestrator.swift:181`(新增的 cross-language 分支)
- **问题**:深度解析在 L4(`a2e93b1`)已经做了"STALE_SOURCE → 降级为目标语言重新生成";每日运势的跨语言路径直接返回 `translateExisting` 的结果,409 时直接 throw。
- **复现**:用户先生成当日 zh 运势 → 后端 bump `PROMPT_VERSIONS["daily_fortune"]`(或后端缓存被清)→ 用户切 en。每次 `runInterpretation`(含 VM 静默重试)都会命中同一条 zh 行 → `/translate` 409 → 失败。24h 跨语言窗口内一直失败,即使用户还有次数也不会尝试生成。
- **修复方向**:对齐 L4 语义——`STALE_SOURCE` 时清掉该跨语言源行(或标记不可译),然后走正常的目标语言生成路径。配额豁免策略对齐 L4。其他翻译错误要显式报给用户(可重试),不能静默吞掉。
- **验收**:iOS 测试——mock translate 返回 409 → 断言调用了 generate,最终状态成功;mock 返回网络错 → 断言是可重试的失败态。

### [ ] 3. 合盘:自动翻译失败后再次进入同一对 → 死路(iOS)

- **位置**:`ios/QiCompass/QiCompass/Features/Compatibility/CompatibilityViewModel.swift:1850`(`autoTranslateCrossLanguageIfIdle` 与 `openDetail`)
- **问题**:自动翻译按 `(hash, language)` 每会话只尝试一次;但 `openDetail` 每次都会重置 `translationFailed = false` 并重建 offer。
- **复现**:切语言后打开 X 对 → 自动翻译失败(断网),此时有重试条 → 返回 → 再次打开 X:offer 存在,自动翻译因"已尝试"跳过,`translationFailed=false` 导致 `TranslateHintBar` 不显示;状态是 `.okFree(原文)` 而非 `.idle`,所以 autoGenerate 也跳过。用户只能看原语言内容,重启 App 前无法恢复。
- **修复方向**:二选一,保持一致即可——(a) "已尝试"集合里记录失败结果,再次进入时恢复 `translationFailed=true`(显示重试条);(b) 失败时把该 key 从"已尝试"集合中移除,允许再次进入时重试。手动点重试必须始终可用。
- **验收**:测试覆盖"失败 → 离开 → 再进入",断言重试条可见或自动翻译被重新触发。

### [ ] 4. 深度解析:同样的死路(切盘再切回)(iOS)

- **位置**:`ios/QiCompass/QiCompass/Features/DeepAnalysis/DeepAnalysisViewModel.swift:641`(hydrate / `performRestore` / `autoTranslateIfNeeded` / `translateHintBarMode`)
- **问题**:A 盘自动翻译失败 → 切 B 盘(`loadArchivedChart` 清空 `autoTranslationState` 与 offer)→ 切回 A:`performRestore` 重建 offer,但 hash 已在 `autoTranslationAttemptedKeys`,自动翻译跳过,`autoTranslationState` 为 nil → `translateHintBarMode` 返回 nil(提示条隐藏)。同时 `resumeV1ChainIfNeeded` 仍被 `translation_pending` 守卫挡住。
- **后果**:A 盘未翻译、缺失的章节整个会话都不翻译也不生成。
- **修复方向**:与第 3 条同一种策略(建议两处抽成同一套"尝试状态"语义);保证 offer 存在时提示条有可操作态。
- **验收**:测试 A 失败 → 切 B → 切回 A,断言提示条可见(或自动重试被触发),且链不会永久 pending。

---

## 🟠 P1

### [ ] 5. M0 降级标记是局部变量,重试后丢失 → 新旧 M0 混拼写进共享缓存(iOS)

- **位置**:`DeepAnalysisViewModel.swift:1244`(`runTranslationChain` 内的 `staleM0Downgraded`)
- **复现**:第 1 次运行时 M0 遇到 STALE_SOURCE,降级重生成(源行被移除);M1 重生成因网络失败(`staleRegenFailed`,M1 源行保留)。用户点重试 → 第 2 次运行时 `staleM0Downgraded=false` 且 M0 已无源行 → M1 的源文(基于**旧 M0**)配上新 M0 的指纹去翻译 → 混拼内容落到正常生成会命中的键上,跨用户共享。这正是 L4 想避免的情况。
- **修复方向**:把"M0 已降级"持久到 VM 状态(按 hash + language);或者在降级时一并清掉所有依赖 M0 的下游源行(M1+),让它们走重新生成而不是翻译。后者更稳。
- **验收**:测试上述两次运行场景,断言第 2 次不会用旧 M1 源文发 translate 请求。

### [ ] 6. 非 M0 章节降级重生成失败后,循环继续用未翻译字段翻译下游(iOS)

- **位置**:`DeepAnalysisViewModel.swift:1374`
- **问题**:M1 降级重生成失败后执行 `continue`,`v1ChainFields` 里仍是 M1 **源语言**行抽出来的字段;后续 M2、M3… 用这些字段继续翻译 → 产生正常生成永远不会用到的缓存键,LLM 调用白花。普通失败分支是 `return` 的,这里不一致。
- **修复方向**:改为与普通失败分支一致(停止链、显式失败态、可重试);或者跳过所有依赖该模块字段的下游模块。
- **验收**:测试 M1 降级重生成失败 → 断言 M2+ 没有发出 translate 请求,状态为可重试失败。

### [ ] 7. 切换命盘不清 M4/M5 用户输入 → B 盘用了 A 盘的输入;补时辰后输入丢失(iOS)

- **位置**:`DeepAnalysisViewModel.swift:614`(`hydrateAndResume` 只在内存值为 nil 时加载已存输入)+ `loadArchivedChart`(切盘时未重置 `m4UserInput` / `m5UserInput`)
- **复现**:A、B 两盘都存有 M4 输入。打开 A → 切到 B(或给 A 补时辰,产生新 `contentHash`):`m4UserInput` 仍是 A 的年龄/关注点,B 的已存输入不会被加载 → B 的 M4 用 A 的输入生成或翻译(`user_input_hash` 不匹配 → 缓存 miss 扣次数,内容是别人的关注点)。补时辰 remap 后输入也不会按新 hash 保存,重启后丢失,L2(`ff26a00`)要修的问题依旧存在。
- **修复方向**:`loadArchivedChart` 切 hash 时清空 M4/M5 输入,再按新 hash 加载;补时辰 remap 时把输入迁移到新 hash 下。
- **验收**:测试 A→B 切换后 M4 输入为 B 的值;remap 后新 hash 下能读回输入。

---

## 🟡 P2

### [ ] 8. 每日运势跨语言读取仍是旧实现,每次多 2 次 health 请求(iOS)

- **位置**:`DailyFortuneOrchestrator.swift:308`(调用 `readAllCrossLanguage`)
- **问题**:`ff06d5b` 为合盘新增了 `readCrossLanguageByModulePriority`(身份只解析一次),但每日运势仍走 `readAllCrossLanguage`,它对每种其他语言各调一次 `readAll`,每次都解析身份(`/api/health`)。当前语言未命中时多 2 次往返;离线或 health 失败时还没尝试生成就先抛错。两套跨语言读取器还各自重复了 getLatest / purge / maxAge 循环,容易漂移。
- **修复方向**:根治放在 `readAllCrossLanguage` 内部(身份只解析一次,传给各语言的读取),然后让 `readCrossLanguageByModulePriority` 复用它,删掉重复循环。另外,最优语言那行解析失败时应继续尝试其他语言。
- **验收**:测试一次每日运势跨语言查找只解析 1 次身份。

### [ ] 9. 主命盘移出名册后,无法再改名 / 删除(iOS,需产品确认)

- **位置**:`ios/QiCompass/QiCompass/Features/Profile/ProfileView.swift:108`(`rosterVisible` 过滤掉主命盘)
- **问题**:改名(`AliasEditView`)与删除(`confirmationDialog`)只在名册编辑态里出现;主命盘被过滤出名册,而头部命主块(`identityBlock`)只会跳到 `ChartDetailView`。全 App 再无主命盘的改名/删除入口(改动前名册里主命盘也有行内改名/删除)。
- **修复方向**:**先问用户是否有意**。若为有意,在命主块或 `ChartDetailView` 补一个改名入口(删除主命盘是否允许由产品决定);若非有意,恢复主命盘在编辑态名册中的行。UI 改动先读 `DESIGN.md`。
- **验收**:能从 Me 页找到主命盘的改名入口。

---

## 建议修复顺序

1. **#1**(后端,改动小,写坏的是共享缓存,先修)
2. **#3 + #4**(同一类状态不一致问题,统一一套"尝试状态"语义一起修)
3. **#2**(对齐 L4)
4. **#5 + #6**(都在 `runTranslationChain`,一起改)
5. **#7**
6. **#8**、**#9**(#9 先问产品)
