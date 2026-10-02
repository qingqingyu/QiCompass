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
