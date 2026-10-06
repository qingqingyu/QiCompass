# 语言切换 L1-L6 实施 Review

**日期**:2026-10-02
**基线**:`main` @ `61a7cfa`(对比走查基线 `7de82ff`,含 L1-L6 + 双 review 12 条修复)
**上游**:`i18n-language-switch-audit.md`(F1-F7 方案)、`i18n-zh-hant-plan.md` D10
**结论**:主路径(跟随系统 → 简体,重启后界面 + 命书 + 合盘 + 每日运势全切)按设计已打通;发现 **3 个中等问题**(会让个别场景卡死或多扣次数)+ 若干低优先级项,下文给出修法。

---

## 0. 已验证

| 项 | 结果 |
|---|---|
| backend 全量 pytest | **1077 passed** |
| `test_interpret_translate.py` / `test_i18n.py` / `test_interpret_compat_postprocess.py` | 166 passed |
| `tools/check_prompt_sync.py` | PASS(需装 `lunar_python`;未装时报 promo builder ModuleNotFoundError,是环境问题不是代码问题) |
| `tools/check_term_sync.py` / `tools/check_sku_sync.py` | PASS |
| iOS XCTest | **未跑**(review 环境为 Linux,无 Xcode)——需本地跑 `AppLanguageTests` / `TranslationFlowTests` / `DeepAnalysisArchiveLoadTests` |

代码层确认正确的部分:

- **L1 启动冻结**:`AppLanguage.current` / `activeOverrideWire` 改读 `launchOverride` 快照,`QiCompassApp.init` 首行 `freezeLaunchSnapshot()`;设置行显示生效语言 endonym + 未重启常驻小注;单测覆盖冻结 / 重启 / 缺快照 / 坏快照
- **L3 自动翻译**:深度解析 hydrate 后 `autoTranslateIfNeeded`、合盘 openDetail `autoTranslateCrossLanguageIfIdle`,会话级去重 Set;翻译中提示条隐藏、章首「正在译为××…」
- **L4 STALE_SOURCE 降级**(深度解析):M0 过期 → 下游全转重生成;`quotaExempt` 显式参数;重生成失败不 resume(不把成本转嫁配额)
- **L5 每日运势翻译**:后端白名单 + 五键同构校验 + 原文形状前置 422;iOS 先跨语言查同 `target_date` 再决定生成,翻译不 `tryConsume`
- **后端修复**:zh 变体 script 优先(`zh-Hans-HK` → `zh`,与 iOS 对齐);翻译 singleflight 加 `"translate"` 命名空间(防与生成互拿结果);原文长度按 `source_language` 分档(en ×4);原文不 strip(防伪逐字比对);A/B 代号替换只对中文生效
- 新增 UI 文案(正在译为 / 部分章节翻译失败 / 离线 · 显示的是 / 重启 App 后切换为 等)xcstrings 三语齐全

---

## 1. 中等问题(建议修)

### R1 每日运势:翻译遇 STALE_SOURCE 没有回落生成 → 当天卡死

- **位置**:`Services/DailyFortuneOrchestrator.swift` `runInterpretation` → `translateExisting`(约 L181-L191、L330-L399)
- **现象**:跨语言有原文 → 一律走 `translate`;后端返回 409 `STALE_SOURCE` 时错误直接上抛,VM 走失败态 + 一次静默重试 → 再次翻译 → 再 409。手动「重试」同样走翻译。**原文 24h 内一直存在,所以当天永远拿不到新语言的每日运势**(只看到引擎模板文案)。
- **触发条件**(都不罕见):
  1. 切语言当天后端 bump 了 `daily_fortune` 的 `PROMPT_VERSIONS`;
  2. 后端原文核验失败(`has_interpretation_text` 查不到逐字相同的行:后端缓存库重建 / 换环境 / `_drop_legacy_cache_if_needed` 触发)——后端也是返回 `STALE_SOURCE`。
- **对照**:深度解析(L4)已把 STALE_SOURCE 降级为豁免配额的重生成,每日运势漏了同一条。
- **修法**:`runInterpretation` 里 catch `APIError.backendError(code: "STALE_SOURCE")` → 记 warning → 落穿到生成路径,**跳过 `counter.tryConsume`**(语言切换引起,与 L4 同口径;给生成路径加显式 `quotaExempt` 参数,不要靠隐式判断)。补单测:翻译 409 → 生成被调用且次数不变。

### R2 深度解析:翻译失败会把原文换成失败态,章节「重试」走的是重新生成

- **位置**:`DeepAnalysisViewModel.swift` `runTranslationChain` 非 STALE 失败分支(约 L1385-L1393)、`ChapterReadingView.swift` L244/L297 → `retryV1Module`
- **现象**:
  1. 翻译失败(后端 5xx / 保真校验 503 等)时 `moduleStates[module] = .failed(...)`:这一章原本能看到的原文**从屏幕上消失**,只剩错误文案。走查方案 F1 的要求是「失败时保留原文 + 提示条重试」。
  2. 失败章页内的「重试」按钮调用的是 `retryV1Module` → `runSingleV1Module` **正常生成**,不是翻译:
     - 扣每日次数(没带 `quotaExempt`);
     - 若失败的是 **M0**:M0 被重新生成(结论可能变),但 M1-M7 的原文行还在 `crossLanguageRows`,之后点提示条重试会用**新 M0 的链字段翻译旧叙事**——正是 L4 `staleM0Downgraded` 特意避免的「叙事错配」。
- **修法**(二选一,推荐 a):
  - a. 失败时保持 `.ok(text: 原文)` 不变,另用 `translationFailedModules: Set<ModuleID>` 标记;章首小注改为「翻译失败 · 重试」,点击 → `acceptTranslation()`(只译剩余)。章节级「重试」在 `crossLanguageRows[module] != nil` 时也转发到 `acceptTranslation()`。
  - b. 保留 `.failed`,但 `retryV1Module` 判断 `crossLanguageRows[module] != nil` 时改走翻译;并且对 M0 手动重生成的情况复用 `staleM0Downgraded` 逻辑(下游全部转重生成,豁免配额)。
- 补单测:翻译失败后原文仍可见;章节重试触发的是 translate 请求而非 interpret。

### R3 合盘:STALE_SOURCE 后「重试」会扣合盘次数

- **位置**:`CompatibilityViewModel.swift` `acceptTranslation` 的 STALE 分支(约 L2122-L2126)
- **现象**:STALE 时显示「此报告版本已更新,请重新生成。」+ 重试按钮 → `generateInterpretation()` → 正常扣合盘次数。与深度解析 L4「语言切换引起的重生成豁免配额」口径不一致,用户切语言后要为合盘多付一次。
- **修法**:STALE 分支直接自动起生成(不必让用户点),并把 `quotaExempt` 传到 `CompatibilityOrchestrator.runInterpretation`(新增参数,跳过 counter);UI 走现有「推演中」态。

---

## 2. 低优先级

| # | 问题 | 位置 | 修法 |
|---|---|---|---|
| R4 | **换盘不清 M4/M5 输入**。L2 改为「内存为 nil 才读持久化」,但 `loadArchivedChart` 的 `chart_changed` 清洗块没清 `m4UserInput` / `m5UserInput`(只有 `reset()` 清)→ 存档切换到 B 盘时沿用 A 盘的输入,B 盘自己存的输入永远读不回;B 盘翻译请求的 `user_input_hash` 也会对不上 | `DeepAnalysisViewModel.swift` ~L555 | chart_changed 块里加 `m4UserInput = nil; m5UserInput = nil`(补时辰换 hash 的场景若要沿用,显式把旧 hash 的持久化值拷到新 hash) |
| R5 | 非 M0 章 STALE 降级重生成后,依赖它的下游章(如 M5 依赖 M1+M3 链字段)仍按旧叙事翻译 | `runTranslationChain` | 可接受;若要严谨,按 `requiredChainFields` 依赖图把受影响下游也转重生成 |
| R6 | 每日运势离线小注误标:L6 之前写入的快照 `interpretationLanguage == nil` 一律视为 `zh`,英文用户近 7 天的英文快照离线时会被标成「显示的是简体中文版本」 | `DailyFortuneViewModel.swift` ~L548 | `nil` 时不显示语言小注(未知就不断言),只有非 nil 且不一致才标 |
| R7 | 离线提示条写「联网后自动译为××」,但只在 `scenePhase → active` 时重试;用户联网后一直停在 App 里不会触发 | `DeepAnalysisView.swift` onChange(scenePhase) | 文案改为「联网后重新打开即可自动翻译」,或用系统 Network 框架 `NWPathMonitor` 监听恢复(系统框架,非新依赖) |
| R8 | xcstrings 仍有 10 个 key 缺 zh-Hant(合盘 Match 重构新增:`hepan.balance.*` ×3 + 7 个格式串),繁体界面这些位置显示简体 | `Localizable.xcstrings` | 补 zh-Hant;不影响「切简体」场景 |
| R9 | 注释陈旧:`currentLanguageOverride` 注释仍写「设置行右侧当前档显示」,实际右侧已改显示生效语言 endonym | `ProfileView.swift` ~L803 | 改注释 |

---

## 3. 建议的修复顺序

1. **R1**(每日运势卡死,影响面最大,改动小)
2. **R2**(原文消失 + 误扣次数 + M0 叙事错配)
3. **R3**、**R4**
4. 其余低优先级项顺手修

修完需本地跑:backend pytest、iOS `TranslationFlowTests` / `AppLanguageTests` / `DeepAnalysisArchiveLoadTests`;动了 `prompts.py` 则加跑 `check_prompt_sync.py`。真机验收沿用 `i18n-language-switch-audit.md` §6,并补两条:

- [ ] 每日运势:切语言后 bump `daily_fortune` 版本(或清后端缓存),当天仍能拿到新语言解读且次数不变(R1)
- [ ] 深度解析:让某章翻译失败(断网 / mock 503),原文仍可见,点重试走翻译且次数不变(R2)

---

# 第二轮复核(2026-10-06)

**基线**:`main` @ `093680f`(对比第一轮 `61a7cfa`,含 R1-R9 修复 + bug2 分支 F1-F5 / #6-#9 + 翻译链世代号收口)
**结论**:第一轮 R1-R9 **全部已处理**;新增修复(豁免路径不退款、hydrate / 翻译链世代号、daily 防伪补 `target_date`)方向正确,未发现阻塞上线的问题。剩下 3 个低优先级观察项,可择机处理。

## A. 验证

| 项 | 结果 |
|---|---|
| backend 全量 pytest | **1078 passed** |
| `check_prompt_sync.py` / `check_term_sync.py` / `check_sku_sync.py` | 全 PASS |
| xcstrings | 缺 en / zh-Hant 的 key:**0**(第一轮 R8 的 10 个已补);新增「翻译失败 · 重试」「联网后重新打开 App 即自动译为%@」三语齐全;废弃文案已从目录移除 |
| iOS XCTest | **仍未跑**(Linux 环境)——本轮新增 / 改动 `TranslationFlowTests`(+414 行)、`DeepAnalysisArchiveLoadTests`、`DailyFortuneFailureFallbackTests`、`CompatibilityViewModelBatchTests`、`CachedInterpretationReaderTests`,需本地全量跑一遍 |

## B. 第一轮问题处理情况

| # | 状态 | 实现要点 |
|---|---|---|
| R1 每日运势 STALE 卡死 | ✅ | `runInterpretation` catch STALE → `generateInterpretation(quotaExempt: true)`;其它翻译错误照常上抛 |
| R2 深度解析失败抹原文 / 重试扣次数 | ✅ | 失败恢复 `.ok(原文)` + `translationFailedModules` 驱动章首「翻译失败 · 重试」;章节级重试按 `hasCrossLanguageOriginal` 分流到重译 |
| R3 合盘 STALE 重试扣次数 | ✅ | STALE → 自动 `generateInterpretation(quotaExempt: true)`;禁词 / cached 分支都不给豁免路径退款 |
| R4 换盘不清 M4/M5 | ✅ | chart_changed 清内存输入;同人补时辰 `remapHash` 迁移持久化(AddHourSheet 提交点 + 换盘守卫兜底) |
| R5 非 M0 STALE 下游叙事 | ➖ 接受 | 未改;另 #6 让降级重生成失败也断链,避免混合键 |
| R6 离线小注误标 | ✅ | `interpretationLanguage == nil` 不显示小注 |
| R7 离线文案 | ✅ | 改为「联网后重新打开 App 即自动译为××」 |
| R8 xcstrings 缺 zh-Hant | ✅ | 0 缺口 |
| R9 陈旧注释 | ✅ | 已改 |

额外修复也核对过,逻辑成立:豁免路径 cached 命中不再 refund(防「每章白送 1 次」);`hydrateGeneration` / `translationGeneration` 解决换盘时旧任务覆写新盘标志;`staleM0DowngradedKeys` 提升为 VM 状态,重试时下游仍走重生成;后端 daily 防伪比对 `target_date`(防昨天的原文写进今天的共享键);自动翻译去重命中时恢复失败提示条,不再死路。

## C. 新观察项(低优先级)

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| N1 | **「失败」提示条会在没失败时出现**。自动翻译去重命中就一律置失败态(深度解析 `autoTranslationState = .failed` / 合盘 `translationFailed = true`)。但上一次可能只是被打断:合盘 `openDetail` 会 `translateTask?.cancel()`,翻译进行中退回列表再进,提示条显示「翻译失败」,其实没失败;深度解析换盘再切回同理。另外深度解析上一次若处于 `.offlinePending`,会被覆盖成 `.failed`,丢掉回前台自动重试那一次机会 | `DeepAnalysisViewModel.autoTranslateIfNeeded`、`CompatibilityViewModel.autoTranslateCrossLanguageIfIdle` | 去重 Set 只在**确实失败**时记录(或分开记录「已尝试」与「已失败」);被取消 / 被换盘打断的尝试不计入,重进时允许再自动一次;`.offlinePending` 命中去重时保持原态 |
| N2 | **同日生的两张盘可能互相迁移 M4/M5 输入**。`isSamePersonHourAddition` 只比「旧盘无时柱 + 新盘有时柱 + 年月日三柱相同」。名册里两个同一天出生的人(一个没填时辰、一个填了),在两者之间切换时会被判成「同人补时辰」,把 A 的年龄 / 关注点(含健康信息)拷到 B 名下(B 没存过输入时) | `DeepAnalysisViewModel.isSamePersonHourAddition` + chart_changed 块 | 换盘守卫里的兜底 remap 去掉,只保留 `AddHourSheet` 提交点那次 remap(那里明确知道是同一个人);或比对 link / 性别 / 出生地等身份信息,不只比柱 |
| N3 | **合盘 STALE 降级的模块层级跟着当前权益走**。`generateInterpretation(quotaExempt:)` 按当前 entitlement 选 `_free` / `_paid`,原文是免费层、但用户此刻已购(该组合在 openDetail 已被分流掉,一般到不了这里)——仅在翻译在飞期间恰好完成购买时可能出现,结果是用豁免生成拿到付费层内容 | `CompatibilityViewModel.acceptTranslation` STALE 分支 | 可接受(用户已付费,只是付费层不扣合盘次数);若要严谨,降级生成沿用 `offer.module` 的层级 |

## D. 建议

- 可以合入 / 上线;N1-N3 不阻塞。
- 上线前在本地跑全量 iOS XCTest,再按第一轮 §3 补充的两条 + 走查文档 §6 做一次真机验收。
