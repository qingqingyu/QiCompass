# 用户故事 + 旅程地图

> 用作 review 依据:功能 review(用户故事 + 验收标准)+ 流程 review(旅程地图)。任何功能改动 / 流程调整,先回头读这里,确认是否偏离用户价值。

## 目的

- **功能 review**:每个用户故事(US)有唯一编号 + 验收标准,代码实现是否满足逐条对照
- **流程 review**:三条核心旅程(首次排盘 / 每日查看 / 合盘咨询)是否有断点
- **边界 review**:从格 / 童限 / 空态 / 错误态 / 离线 等边界情况是否覆盖

## 用户画像

| 画像 | 代表 | 核心诉求 | 关注点 |
|---|---|---|---|
| **命理爱好者** | 阿明,35 岁 | 用工具验证自己的命理推断 | 准确性 / 专业度 / 确定性 |
| **好奇新手** | 小雅,28 岁 | 通俗理解自己的命局,怕被忽悠 | 易读性 / 诚实度 / 不算命感 |
| **关系咨询者** | 大卫,40 岁 | 了解自己与伴侣/合作对象的契合度 | 多维评估 / 流年同步 / 关系决策 |

三条用户旅程分别对应三种画像的核心使用场景。

---

## 用户故事

### 模块一:深度解析(DeepAnalysis)

#### US-DA-01:排出自己的八字命盘
**作为**命理爱好者,**我想**排出自己的八字命盘(四柱 + 十神 + 纳音 + 神煞),**以便**后续研究自己的命局。

**验收标准:**
- 输入:出生时间(公历 DatePicker + 12 时辰快捷选)+ 性别 + 出生地(52 城市 / 手动经度)
- 后端 `lunar_python` 排盘,客户端不做历法计算
- 显示四柱(年/月/日/时),**日柱 cinnabar 高亮**(日主强调)
- 每柱显示:天干 / 地支 / 天干十神 / 地支十神 / 纳音 / 十二长生 / 旬空 / 藏干 chip(五行色)
- **同一输入永远同一输出**(含 `calcRuleSnapshot` 规则快照,确定性)
- 子时规则固定 `zi_next_day`(后端 `setSect(1)`),只读展示

#### US-DA-02:了解自己的喜忌
**作为**命理爱好者,**我想**看到自己命局的喜用神和忌神,**以便**知道哪些五行对自己有利/不利。

**验收标准:**
- 后端规则引擎(扶抑法 + 调候法 + 从格检测 D3)给定性结论
- LLM 只润色话术,**禁止**自行推断喜忌
- 喜用 jade 色 / 忌神 cinnabar 色,视觉区分
- 旺衰 badge:jade 底 jade 字
- 调候用神触发时显示 jade 标记
- **从格命中时**:喜忌留空,LLM 诚实告知"喜忌结论留空,详见命书",不编造

#### US-DA-03:看大运流年
**作为**命理爱好者,**我想**看自己的大运排列 + 当前大运标记,**以便**了解人生各阶段的五行走势。

**验收标准:**
- 大运 `index=0` 童限(`ganZhi=""`)跳过,从 `index=1` 开始展示
- 当前大运 cinnabar 文字 + cinnabarSoft 底 + cinnabar 描边
- "当前" 标签 cinnabar 色
- 显示起止年龄 + 干支(Songti SC)+ 起止年份
- 横向滚动,不挤

#### US-DA-04:生成 AI 命书
**作为**好奇新手,**我想**看一段 AI 生成的话术解读我的命局,**以便**用通俗语言理解命理术语。

**验收标准:**
- 子状态独立:`.idle` / `.fetching` / `.ok(text, cached)` / `.failed(msg)` / `.dailyLimitReached(nextReset)`
- LLM 基于规则引擎结论润色,**不编造**喜忌 / 格局
- 格局 v1 砍掉,用"命局呈现××倾向"模糊叙事,**禁止**给"正官格 / 偏印格"等硬分类
- 24h 缓存,缓存命中不消耗次数
- 每日 10 次上限,达上限显示倒计时到本地午夜
- CTA cinnabar + RoundedRectangle(Radius.sm)

#### US-DA-05:看辅柱信息
**作为**命理爱好者,**我想**看命宫 / 身宫 / 胎元,**以便**补充命局分析。

**验收标准:**
- 三小卡横排:命宫 / 身宫 / 胎元
- 干支 Songti SC + ink 主色
- 纳音 inkMuted 次要信息
- 圆角 Radius.sm

#### US-DA-06:看五行平衡
**作为**命理爱好者,**我想**看五行分布比例,**以便**快速判断命局五行强弱。

**验收标准:**
- 横向 5 段条形图(木/火/土/金/水),按计数比例
- 五行色降饱和 20-30%(适配宣纸米底)
- 图例:五行中文名 + 计数
- 圆角 Radius.sm

#### US-DA-07:看神煞
**作为**命理爱好者,**我想**看本命盘命中的神煞,**以便**了解命局的吉凶星曜。

**验收标准:**
- 20 个固定清单(11 吉 + 9 凶),《三命通会》单一来源
- 吉神 jade 描边 / 凶煞 暗朱砂描边
- chip 半透明底 + 0.5pt 描边
- 空态显式"本命盘未命中神煞",不静默空

---

### 模块二:合盘(Compatibility)

#### US-COMP-01:选两个命盘合盘
**作为**关系咨询者,**我想**选自己和对方的命盘合盘,**以便**看两人的契合度。

**验收标准:**
- A 盘从本地存档选(`ChartArchivePickerView` 单选)
- B 盘两种模式:
  - `.archived`:从存档选
  - `.tempInput`:临时输入(不存档,适合临时排对方盘)
- context 三选一:通用 / 婚姻 / 事业(segmented)
- 子时规则固定 `zi_next_day`,只读提示
- 配置态可"返回修改"切回
- 底部 CTA "开始合盘" cinnabar + RoundedRectangle(Radius.sm)

#### US-COMP-02:看 4 维定性评估
**作为**关系咨询者,**我想**看 4 维定性评估,**以便**从多个角度理解关系。

**验收标准:**
- 4 张卡 2x2 网格:五行互补 / 日主关系 / 生肖匹配 / 地支合冲
- 每张卡:标题(inkMuted)+ 评估值(ink semibold)+ 简短解释(inkMuted)
- **不给数字分、不引入百分比**(定性不定量,决策 §D7)
- 未知值留空,不编造

#### US-COMP-03:看流年同步
**作为**关系咨询者,**我想**看未来 3 年两人的流年同步情况,**以便**预判关系节奏。

**验收标准:**
- 3 年流年表:年份 / A 流年 / B 流年 / 同步标签
- 同步走强 jade 底 + paper 字
- 同步承压 pressureWarning 红字
- 运势分化 / 难以定性 inkMuted
- 表头 inkMuted + 0.5pt hairline

#### US-COMP-04:生成合盘 AI 解读
**作为**关系咨询者,**我想**看一段 AI 解读合盘结果,**以便**用通俗语言理解命理术语。

**验收标准:**
- 独立 error 态,不污染整体 `.resultReady`(定性评估 + 流年同步已就绪即视为合盘成功)
- 400-500 字,涵盖五行 / 日主 / 流年同步
- 24h 缓存 + 每日 10 次上限
- 禁词守卫(后端拦截"百分百 / 一定"等绝对化用语)
- CTA cinnabar + RoundedRectangle(Radius.sm)

#### US-COMP-05:空态引导
**作为**新用户,**我想**没有存档时得到引导,**以便**知道该先做什么。

**验收标准:**
- 空态显示 `CompatibilityEmptyView`
- CTA "去深度解析" cinnabar
- CTA 触发 `.switchTab` Notification → RootTabView 切到 Tab 1

---

### 模块三:每日运势(DailyFortune)

#### US-DF-01:看今日流日运势
**作为**命理爱好者,**我想**每天看今日流日柱 + 与日主的关系,**以便**规划当日活动。

**验收标准:**
- 流日柱 cinnabar 强调(大字,Songti SC)
- 显示流日与日主的关系(正官 / 偏财 等)jade chip
- 显示冲(如果有)+ 冲目标 chip(暗朱砂)
- 公历 + 农历日期(公历 display 字体,农历 subheadline)

#### US-DF-02:看 7 天历史
**作为**命理爱好者,**我想**回看过去 7 天的流日运势,**以便**对照实际发生的事。

**验收标准:**
- 顶部 7 天历史 pill(今日 + 过去 6 天,按日期 DESC)
- 选中态 cinnabar 底 + paper 字
- 今日 pill 边框 cinnabar.opacity(0.5)
- 命中本地 snapshot 的日带圆点指示(cinnabar)
- 历史回看**不高亮当前时辰**(仅今日高亮)
- 加载失败显示 inkMuted 提示,不阻断主流程

#### US-DF-03:看 12 时辰
**作为**命理爱好者,**我想**看今日 12 时辰的干支 + 关系,**以便**按小时规划。

**验收标准:**
- 默认折叠,展开后显示 12 行
- 当前时辰(仅今日)cinnabar 文字 + cinnabarSoft 底 + "当下" 标签
- 显示:时辰字(Songti SC)+ 时间范围 + 干支 + 关系(jade)+ 冲(暗朱砂)
- 折叠时显示当前时辰一行(仅今日);历史回看显示"展开查看 12 时辰详情"

#### US-DF-04:看黄历宜/忌
**作为**好奇新手,**我想**看今日黄历宜/忌,**以便**参考日常活动。

**验收标准:**
- 宜 jade 色 tint / 忌 暗朱砂 tint
- chip 半透明底 + 0.5pt 描边
- 空时显示 "—"(inkMuted)

#### US-DF-05:生成今日 AI 解读
**作为**好奇新手,**我想**看一段 AI 解读今日流日,**以便**用通俗语言理解。

**验收标准:**
- 150-200 字
- 子状态独立(同 US-DA-04)
- 24h 缓存 + 每日 10 次上限
- 离线查看:网络失败 fallback 到本地缓存,显示"离线查看(展示本地缓存,不扣次数)"角标(cinnabar)
- 子时换日三重触发(app active / scenePhase active / NSCalendarDayChanged)

#### US-DF-06:看明日预告
**作为**命理爱好者,**我想**看明日流日柱预告,**以便**提前规划明日。

**验收标准:**
- 明日流日柱 cinnabar(Songti SC)
- 关系 chip jade + cinnabarSoft 底
- 冲(如果有)暗朱砂
- moon.stars 图标 inkMuted(克制)

---

### 模块四:Onboarding / 首启动

#### US-ON-01:首启动了解产品姿态
**作为**新用户,**我想**首次打开 app 时了解产品定位,**以便**决定是否继续使用。

**验收标准:**
- 4 页滑动(`.page` style TabView):
  1. Welcome:朱砂印章 "玄" + "玄机问道" + memorable thing "专业不忽悠,不像算命软件"
  2. Stance:4 条产品姿态(确定性排盘 / 规则引擎给喜忌 / 从格诚实降级 / 格局 v1 不硬分),朱砂小圆点
  3. Privacy:4 条数据归属(本地存储 / AI 缓存 / API key 不进客户端 / 不做云同步),墨青小圆点
  4. Start:朱砂印章 "始" + CTA "开始排盘"
- `@AppStorage("hasSeenOnboarding")` 检测,首启动 = false → sheet 弹出
- **禁止下滑 dismiss**(`.interactiveDismissDisabled()`),必须点 CTA
- 点 CTA 后设 `hasSeenOnboarding = true`,二次启动不再弹
- 圆点 indicator cinnabar 色(`.tint`)
- 无障碍:VoiceOver labels(印章 + CTA hint),Reduce Motion 系统自动处理

---

## 用户旅程地图

### 旅程 A:新用户首次排盘(核心路径,对应画像:好奇新手)

```
首启动
  ↓
Onboarding sheet(4 页,禁止下滑 dismiss)
  ├─ Page 1 Welcome(玄字印章 + memorable thing)
  ├─ Page 2 Stance(4 条产品姿态)
  ├─ Page 3 Privacy(4 条数据归属)
  └─ Page 4 Start(始字印章 + CTA "开始排盘")
  ↓ 点 CTA,dismiss sheet,hasSeenOnboarding = true
Tab 1 深度解析(.empty 态,默认 Tab)
  ↓
BirthFormView
  ├─ 出生时间(DatePicker dateAndTime)
  ├─ 时辰快捷选(12 时辰 grid,Circle 按钮)
  ├─ 性别(segmented:男 / 女)
  ├─ 出生地(52 城市 Picker / 手动经度 Toggle)
  └─ 子时规则(只读提示:"23:00 换日(早子时归当日)")
  ↓ 点 "开始排盘" CTA(cinnabar + RoundedRectangle Radius.sm)
calculating 态(分阶段加载文案,ProgressView cinnabar)
  ↓
DeepAnalysisResultView(ScrollView)
  ├─ ChartHeaderView(命主信息 + 真太阳时偏差 + 边界 warning)
  ├─ PillarsTable(四柱,日柱 cinnabar 高亮)
  ├─ AuxiliaryCards(命宫 / 身宫 / 胎元)
  ├─ ElementBalanceBar(五行平衡条)
  ├─ XijiCard(喜用 jade / 忌神 cinnabar / 旺衰 badge)
  ├─ ShenshaChips(吉 jade / 凶 暗朱砂)
  ├─ LuckPillarsTimeline(大运,当前柱 cinnabar)
  ├─ CurrentStatusCard(当下大运/流年/流日/流时)
  └─ InterpretationSection(AI 命书,idle 态显示 CTA "生成命书")
  ↓ 点 "生成命书" CTA
AI 命书生成(fetching → ok)
  ↓
用户阅读命书(可"重新生成")
```

**断点风险:**
- BirthFormView 校验失败 → `.formInvalid` 显示内联错误(Color.red)
- 排盘失败 → `.chartFailed` 显示 ErrorStateView + "返回表单" cinnabar
- 数据异常(无请求记录)→ 显示 "数据异常:无请求记录" + "返回表单"

---

### 旅程 B:每日查看运势(对应画像:命理爱好者)

```
打开 app(hasSeenOnboarding = true,已排过盘)
  ↓
Tab 1 深度解析(.chartReady 态,直接看结果)
  ↓ 切到 Tab 3(每日运势)
Tab 3 每日运势
  ↓ VM.onAppear 检查 chartHash + ziHourRule
状态机:
  - .empty → LoadingStateView("准备中…")
  - .loading → LoadingStateView("推演流日中…")
  - .chartMissing → DailyFortuneEmptyView(CTA 引导去深度解析)
  - .fortuneReady → DailyFortuneMainView
  - .failed → ErrorStateView

DailyFortuneMainView(ScrollView,下拉刷新)
  ├─ 离线角标(如果 fallback 本地缓存,cinnabar)
  ├─ 7 天历史 pill(今日 cinnabar 选中)
  ├─ DailyFortuneHeaderView(流日柱 cinnabar + 关系 jade + 冲 暗朱砂)
  ├─ DailyInterpretationSection(AI 解读,idle 态显示 CTA)
  ├─ HourPillarsSection(12 时辰,折叠态显示当前时辰)
  ├─ HuangliSection(宜 jade / 忌 暗朱砂)
  └─ TomorrowPreviewSection(明日流日柱 cinnabar)
  ↓ 点 "今日解读" CTA
AI 解读生成(fetching → ok)
  ↓
用户阅读(可看 12 时辰展开 / 7 天历史回看)
  ↓ 子时换日触发(app active / scenePhase / NSCalendarDayChanged)
重新计算流日 + 刷新 UI
```

**断点风险:**
- 网络失败 → fallback 本地缓存,显示离线角标
- 历史加载失败 → 显示 inkMuted 提示,不阻断主流程
- AI 解读达上限 → 显示倒计时到午夜,禁用生成按钮

---

### 旅程 C:合盘咨询(对应画像:关系咨询者)

```
打开 app
  ↓ 切到 Tab 2(合盘)
Tab 2 合盘
  ↓ VM.onAppear 加载命盘存档
状态机:
  - .loading → LoadingStateView
  - .empty(0 存档)→ CompatibilityEmptyView(CTA "去深度解析")
  - .configuring → CompatibilityConfigView
  - .computing → LoadingStateView("推演合盘中…")
  - .resultReady → CompatibilityMainView
  - .failed → ErrorStateView

CompatibilityConfigView(ScrollView + 底部 CTA)
  ├─ A 盘选择(ChartArchivePickerView,checkmark cinnabar)
  ├─ B 盘模式切换(segmented)
  │   ├─ .archived → ChartArchivePickerView
  │   └─ .tempInput → 临时输入表单(DatePicker / 性别 / 经度 / 城市)
  ├─ context picker(通用 / 婚姻 / 事业)
  ├─ 子时规则(只读提示)
  └─ 底部 CTA "开始合盘"(cinnabar + RoundedRectangle Radius.sm)
  ↓ 点 CTA
.computing → .resultReady
  ↓
CompatibilityMainView(ScrollView)
  ├─ DualPillarsTable(双盘对比,4 柱,A 上 B 下,干支 Songti SC + 五行色)
  ├─ AssessmentCardGrid(4 维定性,2x2,评估值 ink semibold)
  ├─ SyncedFortuneTable(3 年流年同步,走强 jade / 承压 红)
  └─ CompatibilityInterpretationSection(AI 解读,idle 态 CTA)
  ↓ 点 "生成合盘解读" CTA
AI 解读生成(400-500 字)
  ↓
顶部 "返回修改" toolbar button(cinnabar)→ 切回 .configuring
```

**断点风险:**
- A 盘未选 / B 盘未配置 → CTA 应禁用(待确认是否实现)
- 合盘计算失败 → `.failed` 显示 ErrorStateView + 重试
- 双盘数据读取失败 → 显示 "双盘数据读取失败"(暗朱砂),不阻断其他 section
- AI 解读独立 error → 不污染整体 `.resultReady`,可单独重试

---

## Review 检查清单

### 功能 review(对照用户故事)

- [ ] US-DA-01:四柱 + 日柱 cinnabar 高亮 + 确定性输出
- [ ] US-DA-02:喜忌规则引擎 + LLM 只润色 + 从格降级
- [ ] US-DA-03:大运童限跳过 + 当前柱 cinnabar
- [ ] US-DA-04:AI 命书子状态独立 + 24h 缓存 + 每日上限
- [ ] US-DA-05:辅柱三小卡 + Songti SC
- [ ] US-DA-06:五行平衡条 + 降饱和色
- [ ] US-DA-07:神煞 20 个固定 + 吉凶分色
- [ ] US-COMP-01:A/B 盘选 + B 模式切换 + context 三选
- [ ] US-COMP-02:4 维定性 + 不给分
- [ ] US-COMP-03:3 年流年同步 + 颜色编码
- [ ] US-COMP-04:合盘 AI 解读 400-500 字 + 独立 error
- [ ] US-COMP-05:空态引导去深度解析
- [ ] US-DF-01:流日柱 cinnabar + 关系 chip
- [ ] US-DF-02:7 天历史 pill + 选中态
- [ ] US-DF-03:12 时辰折叠/展开 + 当前高亮
- [ ] US-DF-04:黄历宜/忌 + chip 样式
- [ ] US-DF-05:今日 AI 解读 + 离线 fallback
- [ ] US-DF-06:明日预告 + cinnabar
- [ ] US-ON-01:4 页 onboarding + 禁止下滑 + 二次启动不弹

### 流程 review(对照旅程地图)

- [ ] 旅程 A:首启动 → onboarding → BirthFormView → 排盘 → ResultView(无断点)
- [ ] 旅程 B:打开 app → Tab 3 → 今日运势 → AI 解读(无断点)
- [ ] 旅程 C:Tab 2 → 配置 → 合盘 → 4 维定性 → AI 解读(无断点)
- [ ] 三旅程状态切换平滑(loading / empty / error / success)
- [ ] 视觉一致性(DESIGN.md token)贯穿全程

### 边界 review

- [ ] 从格检测命中 → 喜忌留空 + LLM 诚实告知(US-DA-02)
- [ ] 大运 index=0 童限 → 跳过(US-DA-03)
- [ ] 神煞空态 → 显式"未命中"(US-DA-07)
- [ ] 合盘双盘数据读取失败 → 局部错误不阻断(旅程 C)
- [ ] AI 解读达上限 → 倒计时 + 禁用按钮(US-DA-04 / US-DF-05)
- [ ] 网络失败 → 离线查看本地缓存(US-DF-05)
- [ ] 历史加载失败 → 提示不阻断(US-DF-02)
- [ ] 排盘失败 → ErrorStateView + 重试(旅程 A)
- [ ] 合盘计算失败 → ErrorStateView + 重试(旅程 C)
- [ ] 子时换日 → 三重触发(US-DF-05)

### 数据 review

- [ ] 同一输入永远同一输出(含 `calcRuleSnapshot`)
- [ ] LLM 只润色不判断(喜忌 / 格局 / 神煞边界守卫)
- [ ] 缓存键 `(content_hash, module, prompt_version)`,prompt 改版自动失效
- [ ] 每日运势多一维 `target_date`
- [ ] API key 不进客户端(所有排盘 + AI 走后端)
- [ ] `lunar_python` 强制 `setSect(1)`(产品决策"默认 23:00 换日")

### 无障碍 review

- [ ] Onboarding VoiceOver labels(印章 + CTA hint)
- [ ] Onboarding Reduce Motion(TabView .page 系统处理)
- [ ] 主要 CTA 有 accessibilityHint(待补全)
- [ ] 装饰性元素 accessibilityHidden(待补全)
- [ ] Dynamic Type 支持(待验证)

---

## 文档维护

- 任何功能改动 → 先回头读对应 US,确认是否偏离用户价值
- 新增功能 → 加新 US(编号递增,如 US-DA-08)
- 验收标准变更 → 直接改本文档,commit message 注明"改 US-XX 验收标准"
- 旅程变更 → 改对应旅程图,commit message 注明"改旅程 X"
