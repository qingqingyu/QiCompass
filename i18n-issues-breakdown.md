# QiCompass i18n Vertical Slice Breakdown

**源 plan**:`i18n-implementation-plan.md`(2026-08-12 grill-me 产出)
**切片方式**:Vertical slice(tracer bullet)— 每个 slice 切穿 schema + API + UI + tests,完成后可独立 demo
**v1 总工作量**:17-24 天(若跳过 Slice 7/8)
**适用范围**:v1 阶段。v2 加语种靠 App Store Connect 国家数据决策

---

## 总览

| Slice | 标题 | Type | Blocked by | 工作量 |
|---|---|---|---|---|
| 1 | Tracer Bullet — 英文版每日运势端到端 | AFK | None | 5-7 天 |
| 2 | 英文版深度解析免费 2 章端到端 | AFK | Slice 1 | 3-4 天 |
| 3 | 英文版深度解析付费 5 章端到端 | AFK | Slice 2 | 2-3 天 |
| 4 | 英文版合盘免费 + 付费端到端 | AFK | Slice 1 | 3-4 天 |
| 5 | 英文版 Onboarding + 付费墙 + 通用 UI | AFK | Slice 1, 2, 4 | 2-3 天 |
| 6 | 英文版术语 QA + 视觉打磨 | **HITL** | Slice 1-5 | 2-3 天 |
| 7 | compatibility alias 模板英文版(可跳过) | AFK | Slice 4 | 0.5 天 |
| 8 | bazi_deep alias 模板英文版(可跳过) | AFK | Slice 2 | 0.5 天 |

**依赖图**:
```
Slice 1 (tracer)
  ├─→ Slice 2 (deep free)
  │     ├─→ Slice 3 (deep paid)
  │     └─→ Slice 8 (deep alias, 可跳过)
  ├─→ Slice 4 (compat)
  │     └─→ Slice 7 (compat alias, 可跳过)
  └─→ Slice 5 (onboarding) ← 也 blocked by Slice 2, 4
        ↓
      Slice 6 (QA + 打磨,HITL)
```

**推进顺序建议**:
1. **Sprint 1**:Slice 1(tracer bullet,验证全链路)
2. **Sprint 2**:Slice 2 + Slice 4 并行(两大功能模块)
3. **Sprint 3**:Slice 3 + Slice 5 + Slice 7/8(收尾 + alias)
4. **Sprint 4**:Slice 6(QA + 打磨)

---

## Slice 1: Tracer Bullet — 英文版每日运势端到端

### Parent

`i18n-implementation-plan.md` § 4 实施计划(整合 P1/P2/P3/P4/P5/P6/P7 + i1/i3/i4 部分跨 Slice 1)

### What to build

打通每日运势模块的英文版完整端到端链路。用户在英文系统语言下打开 QiCompass 进入每日运势页,看到完整英文体验(无中文残留,无术语错位)。

本 slice 是 tracer bullet,**承担所有架构地基工作**(后续 slice 复用):
- 后端:术语翻译表地基 + 双 header 解析层 + prompt 模板按 language 加载 + `InterpretResponse.language` 字段 + 缓存键加 language 维度
- iOS:`InterpretationCache` 加 language 字段 + `AppLanguage` 计算 + `L10n` 枚举骨架 + `BaziDateFormatter` + `BaziFont` token + `DailyFortuneHeaderView` 完整本地化

每日运势相关术语集(本 slice 最小集):日主 / 五行(Metal/Water/Wood/Fire/Earth)/ 流日柱 / 流日天干 / 流日地支 / 流日关系(十神 10 个)/ 旺衰 / 喜用神 / 忌神。约 20-30 个术语。

### Acceptance criteria

后端:
- [ ] `backend/app/engine/term_translations.py` 新建,包含每日运势需要的 ~20-30 个术语 zh→en 翻译(Joey Yap 体系)
- [ ] `backend/app/api/language.py` 新建,实现 `resolve_language(request)` 函数(双 header fallback)
- [ ] `backend/app/ai/prompts/en/daily_fortune_v2.md` 新建(英文版每日运势模板,术语用 Joey Yap 体系)
- [ ] `backend/app/ai/prompts/zh/daily_fortune_v2.md` 从现有 `prompts.py:245-277` 迁移
- [ ] `backend/app/ai/prompts.py` 改造:`render_prompt(module, context, language="zh")` 加 language 参数,删除 `_TEMPLATES` 全局字典,改用 `_load_template(module, language, version)` 动态加载
- [ ] `backend/app/models/interpret.py`:`InterpretResponse` 加 `language: str` 字段
- [ ] 后端 SQLite 缓存表加 `language` 列(实施前 grep 确认具体路径)
- [ ] 后端路由层 wiring:从 `request.headers` 解析 language,传入 `render_prompt` 和缓存查询
- [ ] `backend/tests/test_i18n.py` 新建:模拟 `Accept-Language: en` 调用 `/api/interpret` module=daily_fortune,断言响应 `language == "en"` 且 interpretation 是英文

iOS:
- [ ] `ios/QiCompass/QiCompass/Models/InterpretationCache.swift` 加 `language: String?` 字段(optional,nil 视为 "zh")
- [ ] `ios/QiCompass/QiCompass/Services/InterpretationCacheStore.swift`:`getLatest()` 和 `upsert()` 加 `language` 参数,Predicate 加 language 匹配
- [ ] `ios/QiCompass/QiCompass/Networking/DTOs/InterpretDTOs.swift`:`InterpretResponse` DTO 加 `language: String`
- [ ] `ios/QiCompass/QiCompass/L10n/AppLanguage.swift` 新建:`AppLanguage.current` 计算属性
- [ ] `ios/QiCompass/QiCompass/L10n/L10n.swift` 新建:类型安全的本地化 key 引用(本 slice 只需填 DailyFortune 模块的 key)
- [ ] `ios/QiCompass/QiCompass/L10n/BaziDateFormatter.swift` 新建:农历永远 zh_CN,公历按 user locale
- [ ] `ios/QiCompass/QiCompass/Theme/BaziFont.swift` 新建:serif/body/number 三个 token
- [ ] `ios/QiCompass/QiCompass/Resources/Localizable.xcstrings`:录入 DailyFortune 模块所有 key + zh-Hans + en 双语
- [ ] `ios/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneHeaderView.swift`:所有硬编码中文替换为 `L10n.DailyFortune.xxx`,DateFormatter 替换为 `BaziDateFormatter.lunar`

端到端验收:
- [ ] iOS 模拟器系统语言切到 English,打开 QiCompass 进入每日运势页,UI 无中文残留
- [ ] 后端单元测试通过(`pytest`)
- [ ] iOS 编译通过(Xcode build),无 warning
- [ ] `Accept-Language: zh-Hans` 调用,响应 `language == "zh"`,interpretation 是中文(向后兼容)
- [ ] `Accept-Language: en-US` 调用,响应 `language == "en"`,interpretation 是英文
- [ ] SwiftData 老缓存(nil language)在查询时自动视为 "zh",D1 决策"不用 VersionedSchema"不被破坏

### Blocked by

None — 可立即开始

---

## Slice 2: 英文版深度解析免费 2 章端到端

### Parent

`i18n-implementation-plan.md` § 4(P1 扩展 + P3 部分扩展 + i2/i4 部分跨 Slice 2)

### What to build

用户在英文系统下创建/选择命主后跑深度解析免费 2 章(性格底色 + 事业方向),看到完整英文解读。

本 slice 在 Slice 1 地基上,扩展术语翻译表到完整集合(覆盖深度解析所需的所有术语),并完成 DeepAnalysis 模块的 UI 本地化。

术语扩展范围:
- 十神完整 10 个(比肩/劫财/食神/伤官/偏财/正财/正官/七杀/正印/偏印)
- 神煞完整 20 个(11 吉 + 9 凶)
- 纳音完整 30 个
- 大运 / 流年 / 命宫 / 调候 / 扶抑 / 从格 / 专旺 等核心术语

### Acceptance criteria

后端:
- [ ] `backend/app/engine/term_translations.py` 扩展:补齐十神 10 个 + 神煞 20 个 + 纳音 30 个 + 核心术语(大运/流年/命宫/调候/扶抑/从格/专旺/旺衰/五行统计等)
- [ ] `backend/app/ai/prompts/en/bazi_deep_free_v2.md` 新建(英文版免费 2 章模板)
- [ ] `backend/app/ai/prompts/zh/bazi_deep_free_v2.md` 从现有 `prompts.py:77-95` 迁移
- [ ] `backend/app/ai/prompts/en/_special_pattern_suffix_v2.md` 新建(从格降级英文版)
- [ ] `backend/app/ai/prompts/zh/_special_pattern_suffix_v2.md` 从现有 `prompts.py:131-134` 迁移
- [ ] `backend/tests/test_i18n.py` 扩展:模拟 `Accept-Language: en` 调用 `bazi_deep_free`,断言英文响应 + 术语翻译准确 + 从格降级时输出英文诚实告知段

iOS:
- [ ] `ios/QiCompass/QiCompass/Resources/Localizable.xcstrings`:录入 DeepAnalysis 模块所有 key + zh-Hans + en 双语
- [ ] `L10n.swift` 扩展 DeepAnalysis 枚举
- [ ] `ios/QiCompass/QiCompass/Features/DeepAnalysis/ChartHeaderView.swift`:硬编码中文替换
- [ ] `ios/QiCompass/QiCompass/Features/DeepAnalysis/ShenshaChips.swift`:神煞名称从硬编码改为后端返回的英文术语(后端 Response 已按 language 翻译)
- [ ] DeepAnalysis 其他 View(`DeepAnalysisView` / `ChapterView` 等)硬编码替换

端到端验收:
- [ ] iOS 模拟器英文系统,跑深度解析免费 2 章,UI 全英文
- [ ] 神煞英文名称符合 Joey Yap 体系(Heavenly Nobleman / Peach Blossom 等)
- [ ] 从格命盘跑深度解析,英文版诚实告知段正确触发
- [ ] 中文版回归测试通过(向后兼容,无功能破坏)

### Blocked by

- Slice 1(复用 language 解析层 + L10n 骨架 + SwiftData language 字段)

---

## Slice 3: 英文版深度解析付费 5 章端到端

### Parent

`i18n-implementation-plan.md` § 4(P3 部分扩展 + i2/i4 部分跨 Slice 3)

### What to build

付费用户(通过 entitlement 校验)跑深度解析付费 5 章(财运 / 爱情 / 健康 / 六亲 / 晚年),看到完整英文解读。

本 slice 是 Slice 2 的自然延伸,术语翻译已在 Slice 2 完成,只新增付费 5 章 prompt 模板 + iOS 付费章节 View 本地化。

### Acceptance criteria

后端:
- [ ] `backend/app/ai/prompts/en/bazi_deep_paid_v2.md` 新建(英文版付费 5 章模板)
- [ ] `backend/app/ai/prompts/zh/bazi_deep_paid_v2.md` 从现有 `prompts.py:101-127` 迁移
- [ ] `backend/tests/test_i18n.py` 扩展:模拟 `Accept-Language: en` + 有效 entitlement 调用 `bazi_deep_paid`,断言英文响应 5 章

iOS:
- [ ] `Localizable.xcstrings`:录入付费章节标题(财运/爱情/健康/六亲/晚年)zh-Hans + en 双语
- [ ] `L10n.swift` 扩展付费章节 key
- [ ] 付费章节 View 本地化(章节标题 + 解锁提示 + 付费墙 CTA)

端到端验收:
- [ ] iOS 模拟器英文系统,付费用户跑深度解析付费 5 章,UI 全英文
- [ ] 付费墙在英文系统下文案正确(价格 / CTA / 章节预览)
- [ ] 未付费用户尝试访问付费章节,英文版触发付费墙
- [ ] 中文版回归测试通过

### Blocked by

- Slice 2(深度解析免费 2 章必须先完成,付费 5 章复用其术语翻译)

---

## Slice 4: 英文版合盘免费 + 付费端到端

### Parent

`i18n-implementation-plan.md` § 4(P1 合盘特有术语 + P3 合盘模板 + i2/i4 合盘 View)

### What to build

用户选择两个命主跑合盘(免费 2 章 + 付费 4 章),看到完整英文解读。

本 slice 在 Slice 1 地基上,扩展合盘特有的术语(context_label / 五行互补 / 日主关系 / 生肖匹配 / 地支合冲 等评估术语),完成合盘模块 prompt 模板 + UI 本地化。

合盘特有术语翻译:
- context_label:事业合作 / 恋爱婚姻 / 朋友相处(需翻译)
- 评估定性:五行互补 / 日主关系 / 生肖匹配 / 地支合冲(需翻译)
- 章节:基础相处模式 / 互补冲突 / 五行共振 / 合作事业 / 财运合拍 / 流年同步(需翻译;第一章原「爱情深度」,2026-08-14 已替换为「五行共振」,见 `docs/合盘五行共振章节决策.md`)

### Acceptance criteria

后端:
- [ ] `backend/app/engine/term_translations.py` 扩展合盘特有术语(context_label + 评估定性 + 章节标题)
- [ ] `backend/app/ai/prompts/en/compatibility_free_v2.md` 新建
- [ ] `backend/app/ai/prompts/en/compatibility_paid_v2.md` 新建
- [ ] `backend/app/ai/prompts/zh/compatibility_free_v2.md` 从现有 `prompts.py:195-212` 迁移
- [ ] `backend/app/ai/prompts/zh/compatibility_paid_v2.md` 从现有 `prompts.py:217-239` 迁移
- [ ] `backend/tests/test_i18n.py` 扩展:模拟 `Accept-Language: en` 调用 `compatibility_free` 和 `compatibility_paid`,断言英文响应

iOS:
- [ ] `Localizable.xcstrings`:录入 Compatibility 模块所有 key + zh-Hans + en 双语
- [ ] `L10n.swift` 扩展 Compatibility 枚举
- [ ] Compatibility 相关 View 本地化(`CompatibilityView` / `ChartArchivePickerView` / 合盘结果章节 View 等)
- [ ] context_label 选择器(事业合作 / 恋爱婚姻 / 朋友相处)英文版文案

端到端验收:
- [ ] iOS 模拟器英文系统,跑合盘免费 2 章 + 付费 4 章,UI 全英文
- [ ] context_label 在英文版下显示正确(Business Partnership / Romantic / Friendship 等)
- [ ] 中文版回归测试通过

### Blocked by

- Slice 1(复用 language 解析层 + L10n 骨架)

---

## Slice 5: 英文版 Onboarding + 付费墙 + 通用 UI

### Parent

`i18n-implementation-plan.md` § 4(i2 + i4 跨 Slice 5)

### What to build

用户首次启动 App,从 Onboarding 到创建命主到付费墙到错误提示到导航,全英文体验。

本 slice 是收尾性 slice,完成所有非功能模块 UI 的本地化。后端无变化。

### Acceptance criteria

iOS:
- [ ] `Localizable.xcstrings`:录入 Onboarding + 付费墙 + 错误提示 + 导航 + 设置 + Common 模块所有 key + zh-Hans + en 双语
- [ ] `L10n.swift` 扩展 Onboarding / Common / Paywall 等枚举
- [ ] `ios/QiCompass/QiCompass/Features/Onboarding/OnboardingView.swift`:硬编码中文替换为 `L10n.Onboarding.xxx`(注意 `welcome_sutra` 已有双语,只需迁移到 L10n 引用)
- [ ] 付费墙 View 本地化(订阅价格 / CTA / 章节预览 / 恢复购买)
- [ ] 错误提示 View 本地化(网络错误 / 校验错误 / entitlement 错误)
- [ ] 导航 Tab 标签本地化(深度解析 / 合盘 / 每日运势 / 设置)
- [ ] Settings 页本地化(版本号 / 反馈 / 关于)

端到端验收:
- [ ] iOS 模拟器英文系统,首次启动 App,完整跑 onboarding 流程(欢迎 → 创建命主 → 进入主界面),无中文残留
- [ ] 触发各种错误状态(网络断开 / API 失败),错误提示英文版正确
- [ ] 进入付费墙,价格 / CTA / 章节预览英文版正确
- [ ] Tab 切换 / 设置页所有文案英文
- [ ] 中文版回归测试通过

### Blocked by

- Slice 1(每日运势 — 主功能)
- Slice 2(深度解析 — 主功能)
- Slice 4(合盘 — 主功能)

理由:Onboarding 完成后会引导用户进入主功能模块,主功能模块必须先就绪才有完整体验。

---

## Slice 6: 英文版术语本地化 QA + 视觉打磨

### Parent

`i18n-implementation-plan.md` § 7 风险与未解决问题(术语翻译质量 + 视觉一致性)

### What to build

邀请懂英文八字的用户(或专业命理翻译审稿人)验证术语翻译质量 + 修复跨模块视觉一致性问题。

本 slice 是 **HITL(Human-in-the-loop)**,因为术语翻译质量需要外部专业判断,开发者自测不够。

### Acceptance criteria

术语 QA:
- [ ] 邀请 1-3 位懂英文八字的人(可以是海外华人八字爱好者 / 英文八字社区活跃用户)做术语 review
- [ ] 收集反馈:`term_translations.py` 哪些术语需要调整
- [ ] 调整后 `prompt_version +1`(触发老缓存自动失效,Q13 决策)
- [ ] 单元测试覆盖调整后的术语

视觉打磨:
- [ ] 英文版字体 fallback 验证(Kaiti SC → 系统衬线 fallback 是否正常)
- [ ] 数字对齐验证(`.monospacedDigit()` 在英文排版下是否正确)
- [ ] 长术语折叠(英文术语比中文长,如 "Hurting Officer" vs "伤官",验证 UI 容器是否需要调整)
- [ ] 跨模块术语一致性(同一术语在每日运势 / 深度解析 / 合盘显示一致)
- [ ] 边界场景:`Accept-Language: zh-Hans-CN,en;q=0.8` 等复杂 header 的解析正确性
- [ ] v1 trade-off 验证:海外华人 iPhone 系统英文,App 表现是否符合预期(拿到英文版)

### Type

**HITL** — 需要外部用户/翻译审稿人参与,不能纯 AFK

### Blocked by

- Slice 1, 2, 3, 4, 5(所有功能 slice 完成才能整体 QA)

---

## Slice 7: compatibility alias 模板英文版(可跳过)

### Parent

`i18n-implementation-plan.md` § 4

### What to build

`compatibility` alias 模板(M4 拆分前的老客户端兼容)的英文版。

### 决策点:本 slice 可跳过

`prompts.py:161-162` 注释提到"M4 拆分后 iOS 改用 _free / _paid,此 alias 可后续删除"。

**如果 v1 阶段决定删 alias**:跳过本 slice,直接在 Slice 4 实施时删除 `compatibility` alias 模板,Module 枚举移除 `compatibility` 值。

**如果保留 alias 兼容老客户端**:做本 slice。

### Acceptance criteria(如保留)

- [ ] `backend/app/ai/prompts/en/compatibility_v2.md` 新建
- [ ] `backend/app/ai/prompts/zh/compatibility_v2.md` 从现有 `prompts.py:163-190` 迁移
- [ ] `backend/tests/test_i18n.py` 扩展:模拟老客户端调用 alias,断言英文响应

### Blocked by

- Slice 4

---

## Slice 8: bazi_deep alias 模板英文版(可跳过)

### Parent

`i18n-implementation-plan.md` § 4

### What to build

`bazi_deep` alias 模板(M2 拆分前的老客户端兼容)的英文版。

### 决策点:本 slice 可跳过

`prompts.py:58-60` 注释提到"iOS M3 跟上改用 _free / _paid 后,可删此 alias"。

**如果 v1 阶段决定删 alias**:跳过本 slice,直接在 Slice 2 实施时删除 `bazi_deep` alias 模板,Module 枚举移除 `bazi_deep` 值。

**如果保留 alias 兼容老客户端**:做本 slice。

### Acceptance criteria(如保留)

- [ ] `backend/app/ai/prompts/en/bazi_deep_v2.md` 新建
- [ ] `backend/app/ai/prompts/zh/bazi_deep_v2.md` 从现有 `prompts.py:62-71` 迁移
- [ ] `backend/tests/test_i18n.py` 扩展:模拟老客户端调用 alias,断言英文响应

### Blocked by

- Slice 2

---

## 实施时如何使用这份文档

### 每个 Slice 启动前的检查

1. 读 `i18n-implementation-plan.md` 对应决策(决策 1-10)
2. 读 `CLAUDE.md` 全局约束(错误显式传播 / 不擅自加依赖 / Git 三段式 commit)
3. `grep` 当前代码确认实际影响范围(尤其 `_TEMPLATES` / `DateFormatter` / 硬编码中文)
4. PR 描述里贴本 slice 编号 + plan 决策编号

### Slice 完成的判定

每个 slice 必须满足:
- [ ] 所有 Acceptance criteria 打勾
- [ ] 单元测试通过(`pytest` / Xcode build)
- [ ] 中文版回归测试通过(向后兼容)
- [ ] Git commit 按 CLAUDE.md 三段式(Why / What / Impact)

### 跳过 Slice 7/8 的判定

如果决定跳过 Slice 7/8(删 alias):
- 在 Slice 2 / Slice 4 实施时,同步删除 alias 模板和 Module 枚举对应值
- 检查是否有 iOS 客户端还用 alias(实施前 grep `module: "bazi_deep"` / `module: "compatibility"`)
- 如果 iOS 已经全部用 `_free` / `_paid`,直接删除 alias
- 删除 alias 的 PR 描述里贴本 slice 编号 + 说明决策依据

### Sprint 推进建议

**Sprint 1(第 1 周)**:Slice 1 — tracer bullet
- 目标:打通每日运势英文版全链路
- 验收:模拟器英文系统看到完整英文每日运势

**Sprint 2(第 2-3 周)**:Slice 2 + Slice 4 并行
- 目标:两大功能模块(深度解析 + 合盘)英文版就绪
- 验收:用户能在英文系统下跑深度解析免费 2 章 + 合盘免费 2 章

**Sprint 3(第 3-4 周)**:Slice 3 + Slice 5 + Slice 7/8 决策
- 目标:付费功能 + Onboarding + 通用 UI 英文版
- 验收:完整英文版 App 可用

**Sprint 4(第 4-5 周)**:Slice 6 — HITL QA + 打磨
- 目标:术语质量验证 + 视觉一致性
- 验收:外部用户验证术语准确 + 英文版视觉无缺陷

---

## 与 i18n-implementation-plan.md 的关系

**这份文档(vertical slice breakdown)是 plan(horizontal slice)的实施视图**:
- `i18n-implementation-plan.md` = 设计决策 + 代码骨架(为什么 + 怎么做)
- `i18n-issues-breakdown.md`(本文档)= 推进计划 + 验收清单(做什么 + 何时做 + 怎么验收)

两份文档互补,实施时一起读。

---

**文档版本**:v1.0(2026-08-12 /to-issues 产出)
**下次 review 时机**:Sprint 1 完成后,基于实际工时和遇到的坑调整后续 slice 估算
