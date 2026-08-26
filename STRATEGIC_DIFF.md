# STRATEGIC_DIFF — 战略决策 → 代码修改点清单

> **2026-08-26 注记**:本文写作时 DESIGN.md 为宋瓷体系。设计已于 2026-08-26 换轨水墨孤本
> (Kaiti/冷宣纸/浓墨 CTA),文中"宋瓷气质/视觉不动"及旧色板引用为历史快照。
> 战略与 copy 腔调分析仍有效。


> **来源**：2026-08-01 grill-me 战略 review（worktree `grillme`）
> **范围**：本次 grill 锁定的战略决策对**当前代码**产生的 diff。
> **不是**：本文档不是战略决策记录（那是 `bazi-app-design-doc.md` §Open Questions §2026-08-01 grill-me 锁定段 的职责）。本文档只管"代码需要改什么"。
> **可累积**：未来再有 grill 决策，可追加新章节到本文档，作为代码改动的 backlog 历史。

## 落地状态（2026-08-08）

**所有 TODO 已落地。** 代码 diff 清单保留作历史 backlog 参考。

- PR #7 grill-me（2026-08-01）：本文档初始 10 项决策的代码改动主体
- PR #8 onboarding-content-rewrite（2026-08-04）：4 页文案重写（决策 #5 voice 配套）
- PR #9 feature/visual-polish（2026-08-08）：DESIGN.md Step 4 验收清单 8 项（token 清理 / destructive / padding / Dark mode 墨夜瓷釉）

PR #9 完成的部分（与本文档验收清单 §验收标准 重叠的项）：
- token 清理：合并 `cardBorder`/`separator` → `hairline`，删 `cardBackground` alias
- 错误态：`Color.red` 散点 4 处 → 新增 `BaziTheme.destructive` 语义 token
- 间距：全量 padding token 化 + 新增 `Spacing.cmd`(12pt 表格专用)
- Dark mode：`Color(UIColor { traitCollection })` 动态 token，9 token 双值（墨夜瓷釉配色）

---

## 决策摘要（5 句话版本）

1. **视觉不动**，DESIGN.md "宋瓷气质" 决策保持。CoStar 启发只取表层 copy 腔调（短句 actionable + 直言）。
2. **入口改为今日运势**（默认 Tab）。深度解析从"必经之路"降为"可选功能"。
3. **B2 强制轻注册**：首次打开必须填 5 字段出生信息 → chart 存档 → 落地今日运势。**不**立刻跑深度解析 AI。
4. **深度解析 Tab 改 β 点击触发**：用户切 Tab 看 chart（deterministic, instant）+ 顶部 anchor sentence → 点"生成免费解读"才跑 AI。
5. **三模块统一 Medium / Medium-deep voice**：今日 50-80 字 / 深度章节 200-300 字 × 7 章 / 合盘 200-300 字 × 6 章。砍掉旧长文 prompt。

详细决策树见 `bazi-app-design-doc.md` §Open Questions §2026-08-01 grill-me 锁定段。

---

## 代码 diff 清单（按 file / area 分组）

### iOS App 入口

#### `ios/QiCompass/QiCompass/App/RootTabView.swift`

- [x] **改 default Tab**：`@State private var selectedTab: Tab = .deepAnalysis` → `.dailyFortune`（在 `selectedTab` 属性声明处）
- [x] **加第 4 个 Tab `.profile`**：
  - `enum Tab` 加 case `profile`
  - `switchKey` 计算属性加映射 `"profile" → "profile"`
  - `body` 加 `ProfileView().tag(Tab.profile).tabItem { Label("我的", systemImage: "person.crop.circle") }`
  - Tab 顺序最终：`.dailyFortune` / `.deepAnalysis` / `.compatibility` / `.profile`
- [x] **onboarding sheet 后接 BirthFormView**：当前 `onComplete` 回调只设 `hasSeenOnboarding = true`。改为：先呈现 `BirthFormView` 作为 fullScreenCover，表单提交成功后才 dismiss onboarding + 落地 TabView（默认今日运势）
- [x] **`switchTab` Notification 加 `.profile` case**：在 `switchTab` 方法的 switch 里加 `case Tab.profile.switchKey: selectedTab = .profile`

#### `ios/QiCompass/QiCompass/Features/Onboarding/OnboardingView.swift`

- [x] **StartPage CTA 改向**：当前 `onComplete()` 触发后 `hasSeenOnboarding = true` 直接 dismiss。改为触发后**进入 BirthFormView**（不 dismiss onboarding，而是 push/navigate to form）。表单完成才完整 dismiss。
- [x] **保留现有 4 页设计**（WelcomePage / StancePage / PrivacyPage / StartPage 不动，2026-08-01 决策#18）

#### `ios/QiCompass/QiCompass/Features/DeepAnalysis/BirthFormView.swift`

- [x] **加 first-launch 模式**：现有 BirthFormView 用于"深度解析 Tab 内排盘"。新增"首次注册"模式（B2 流）：
  - 加 `var isFirstLaunch: Bool = false` 入参
  - `isFirstLaunch = true` 时：表单提交成功后**触发 onComplete 回调**（让 onboarding dismiss），不直接 push DeepAnalysisResultView
  - `isFirstLaunch = false` 时：保留现有行为（push DeepAnalysisResultView）
- [x] **不立刻跑深度解析 AI**（B2 核心）：表单提交只触发 `/api/bazi/calculate` 排盘 + chart 存档，**不**触发 `/api/interpret bazi_deep_free`

### 深度解析模块

#### `ios/QiCompass/QiCompass/Features/DeepAnalysis/DeepAnalysisView.swift`

- [x] **加 chart 顶部 deterministic anchor sentence**：pillars 表上方加 1 行文本，由后端 `day_master_strength` + `favorable_elements` + `unfavorable_elements` 拼接返回，instant，0 AI 成本。文案模板待定（候选："你的日主是 **{day_gan}**（{day_gan_element}），命局整体 **{day_master_strength_label}**，**喜 {favorable_elements}**、**忌 {unfavorable_elements}**。"）
- [x] **改"生成免费解读"按钮为触发点（β）**：当前流程如果是 auto-generate，改为先显示按钮 + disabled 状态。用户点击 → 触发 ViewModel 的 `generateFreeChapters()` → ~10s skeleton loading → fade in
- [x] **移除"再生成"按钮**（如果有）：任何模块都不放重跑按钮

#### `ios/QiCompass/QiCompass/Features/DeepAnalysis/DeepAnalysisViewModel.swift`

- [x] **拆 `loadOrCreateChart()` 与 `generateFreeChapters()`**：
  - `loadOrCreateChart()`：从 SwiftData 取 chart snapshot 或新建（deterministic, instant）
  - `generateFreeChapters()`：触发 `/api/interpret bazi_deep_free`，~10s。**不在 chart 创建时自动调**
- [x] **加 `freeChaptersState: GenerationState`**：`.idle` / `.generating` / `.success` / `.failed`。View 根据状态显示按钮 / skeleton / 内容 / 错误重试

#### `ios/QiCompass/QiCompass/Features/DeepAnalysis/PaidChaptersLockView.swift`

- [x] **检查现有付费章节锁定 UI**：确认是否已实现 5 章付费锁标。如果没有，按 MONETIZATION.md §免费/付费内容分界 实现

#### `ios/QiCompass/QiCompass/Features/DeepAnalysis/InterpretationSection.swift`

- [x] **章节渲染适配 Medium-deep voice**：每章渲染时按段落（3-5 段）+ 短句呈现。如果现有实现是单段长文，需调整渲染逻辑

### 今日运势模块

#### `ios/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneView.swift` + 子组件

- [x] **AI 总览渲染压到 50-80 字**：当前实现假设 150-200 字 prompt 输出。需要：
  - 调整 Text frame / lineLimit 容纳 50-80 字
  - 排版节奏：3-5 短句，可以一行一句或自然换行
- [x] **宜/忌升为主视觉锚点**：当前宜/忌可能是次要 chip 列表。改为视觉 prominent block（如：左"宜"列 + 右"忌"列，每列 2-3 字 bullet）。视觉规范：朱砂/墨青做宜/忌区分，对齐 DESIGN.md 五行色映射
- [x] **12 时辰保持默认折叠**：当前已经是默认折叠，确认不动
- [x] **移除"再生成"按钮**（如果有）

#### `ios/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneViewModel.swift`

- [x] **流式追加支持**（决策 #14 配套，参 Open Question #20 已关闭）：AI 总览生成期间（3-5s），UI 显示 skeleton / 进度提示。后端如果支持 SSE 流式返回，前端 streaming 渲染；否则 polling 或 single-shot + loading state

### 合盘模块

#### `ios/QiCompass/QiCompass/Features/Compatibility/*`

- [x] **章节渲染适配 Medium voice**：与深度解析同样模式（200-300 字/章 + 3-5 段 + 短句）
- [x] **检查现有付费章节锁定 UI**：与深度解析同形态（免费基础 + 付费深度），按 MONETIZATION.md §合盘 实现
- [x] **移除"再生成"按钮**（如果有）

### 后端 prompt 模板

#### `backend/app/ai/prompts.py`

- [x] **重写 5 个模板的 voice 段落**（对齐 `bazi-app-design-doc.md` §AI Voice 规范）。**当前代码 vs 目标规范对照**：

  | 模板 | 当前代码字数 | 目标规范 | 节奏要求 |
  |---|---|---|---|
  | `BAZI_DEEP_TEMPLATE`（deprecated alias） | 300-500 字单段 | deprecated alias，voice 跟随 `_free` + `_paid` 拆分自然过时；如果还需要兼容老客户端则同步改，否则标 deprecated 不改 | — |
  | `BAZI_DEEP_FREE_TEMPLATE` | ~400 字 | 200-300 字/章 × 2 章 = 400-600 字总 | 分 3-5 段 × 2-3 短句 |
  | `BAZI_DEEP_PAID_TEMPLATE` | ~1000 字 | 200-300 字/章 × 5 章 = 1000-1500 字总 | 同上 |
  | `COMPATIBILITY_TEMPLATE` | 400-500 字 | 200-300 字/章 × 6 章（2 免费 + 4 付费）= 1200-1800 字总 | 同上 |
  | `DAILY_FORTUNE_TEMPLATE` | 150-200 字 | **50-80 字** | 3-5 短句不分段 |

  - `DAILY_FORTUNE_TEMPLATE` 额外：**砍掉"个性化宜忌 3-5 条"段**（这个 spec 现在由"宜/忌 main anchor"承接，UI 渲染而非 AI 输出）。**砍掉"12 时辰点评"要求**（保留时辰数据展示但不要求 AI 点评）
- [x] **bump `PROMPT_VERSIONS`**：5 个 module 全部 +1（bazi_deep 1→2, bazi_deep_free 1→2, bazi_deep_paid 1→2, compatibility 1→2, daily_fortune 1→2）。**这是关键**：bump 后老 iOS 客户端的本地缓存（按 prompt_version 隔离）自动失效，强制重新生成新 voice 内容
- [x] **注意 breaking change for 老 TestFlight 用户**：B2 流改入口 + β 点击触发 + prompt_version bump 三重叠加 → 老用户升级后会经历：(1) 深度解析缓存失效（prompt v1 → v2）；(2) 深度解析 Tab 不再 auto-generate，而是显示"生成免费解读"按钮。**desired behavior**（符合 grill 决策），但需要在 release notes 或首次升级引导里告知

#### `backend/app/api/interpret.py`（或对应路由层）

- [x] **检查 chart anchor sentence 接口**：决策 #11 要求深度解析 Tab 顶部有 deterministic anchor。需要：
  - 选项 a：在 `/api/bazi/calculate` response 加 `anchor_sentence` 字段，后端拼接返回
  - 选项 b：iOS 端用现有 `day_master_strength` + `favorable_elements` + `unfavorable_elements` 字段自行拼字符串
  - **推荐 a**（后端拼接，iOS 不算命理逻辑）

### 预先存在的 doc drift（**不在本次 grill 范围,已转移跟踪**）

> 2026-08-08 注:以下 drift 在 PR #9 视觉打磨 slice 中**未清理**(PR #9 只改 DESIGN.md,未触 bazi-app-design-doc.md)。
> 已转移到 `bazi-app-design-doc.md` §Next Steps line 678-679 自身的"预先存在的 doc drift 待清理"段跟踪,
> 下次启动 bazi-app-design-doc.md 大改时一并清。

#### `bazi-app-design-doc.md` §Visual Design Tokens

- [ ] line ~488-502 还是旧黑金色板（bgTop `#0d0b08` / bgMid `#12100d` / 主金 `#c9a03c` / 亮金 `#f5d785` 等），与 DESIGN.md 的 paper `#FDFCFA` / cinnabar `#C33B3B` / jade `#2C5F3F` 决策**直接矛盾**

#### `bazi-app-design-doc.md` §V1 Minimum Viable Aesthetic

- [ ] line ~678+ 写"金底深色（不可协商）+ ZCOOL XiaoWei 显示字体"，与 DESIGN.md "极浅暖白 paper + Songti SC" 决策**直接矛盾**

---

## 验收标准（本次 grill 决策落地的判定）

- [x] 冷启动 App → 落地默认 Tab = 今日运势（不是深度解析）
- [x] Tab bar 显示 4 个：今日运势 / 深度解析 / 合盘 / 我的
- [x] 首次启动 → OnboardingView 4 页 → StartPage CTA → BirthFormView → 表单提交 → 落地今日运势（已个性化，不跑深度解析 AI）
- [x] 第二次冷启动 → 直接到今日运势（跳过 OnboardingView）
- [x] 切到深度解析 Tab → chart 立即可见 + anchor sentence → "生成免费解读"按钮 → 点击 → ~10s → 2 章 fade in
- [x] 今日页 AI 总览篇幅 ≤ 80 字（实测）
- [x] 深度章节每章 200-300 字（实测），分 3-5 段，每段 2-3 短句
- [x] 合盘页章节同 Medium voice（实测）
- [x] 任何模块都**没有**"再生成"按钮
- [x] `prompts.py` 的 `PROMPT_VERSIONS` 5 个 module 全部 = 2
- [x] 老缓存（prompt_version=1）自动失效，重新生成新 voice
- [x] 用真实命盘 spike：跑 20 个盘，长句（> 50 字/句）占比 < 20%

---

## Open implementation questions（战略已锁，实施细节已在 PR #7-#9 解决）

> 2026-08-08 注:以下 6 个问题在实施过程中逐项得到答案,保留作历史参考。具体落地见各 PR commit。

1. **"我的" Tab 内容清单**：v1 无账号系统，"我的"具体放什么？候选：多命盘管理（`UserSnapshotLink` list）/ 已购 entitlements / 设置（zi_hour_rule default / 主题 / 语言）/ 关于（版本 / 隐私政策 / 联系）。需 PRODUCT 决策
2. **anchor sentence 文案模板**：候选 "你的日主是 **庚金**，命局整体 **偏旺**，**喜火**炼锐、**忌水**沉钝。" — 需 PRODUCT + 命理审核
3. **流式追加实现**：今日页 AI 总览 3-5s 等待。选项 a（SSE 流式）/ b（polling）/ c（single-shot + loading state）。需 ENG 决策（后端是否支持 SSE）
4. **宜/忌 main anchor 视觉规范**：朱砂/墨青做宜/忌区分？字号？layout？需 DESIGN 决策
5. **宜/忌 main anchor 数据源**：actionable bullet（如 "果断 / 独处"）不是 lunar_python `getDayYi/Ji` 的传统黄历词汇风格。候选 a（后端基于 `favorable_elements` + 流日关系确定性映射到 actionable 词表，推荐）/ b（AI 一起生成，但违背"UI 渲染而非 AI 输出"）/ c（`getDayYi/Ji` + 前端词汇风格转换）。需 PRODUCT + ENG 决策
6. **M3 paywall 触发点调整**：当前付费墙触发流程是否还合理？B2 改入口后，付费墙触达路径可能需要重新评估
