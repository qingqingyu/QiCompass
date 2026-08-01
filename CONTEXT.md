# QiCompass — 玄机问道

AI 八字命理 iOS App,三模块(深度解析 / 合盘 / 每日运势)。所有排盘走后端 `lunar_python` 做确定性计算,LLM 只负责把结构化结果润色成中文命书,不做判断。

## Language

### 命理核心 (Bazi)

**八字 (Bazi)**:
按出生时刻排出的八个汉字(四柱 × 天干/地支),整张命盘的根。所有解读都从这里展开。
_Avoid_: 八字命盘 / 四柱八字(冗余)

**四柱 (Four Pillars)**:
年柱 / 月柱 / 日柱 / 时柱,每柱 = 1 个天干 + 1 个地支。日柱的天干是命主本人。
_Avoid_: pillars array / 干支组

**日主 (Day Master)**:
日柱天干,代表命主自己。所有十神 / 旺衰 / 喜忌都围绕日主展开。
_Avoid_: self / master(过度神秘化)

**十神 (Ten Gods)**:
以日主为基准,其他天干地支与日主的生克关系(正官/偏官/正印/偏印/比肩/劫财/食神/伤官/正财/偏财)。`lunar_python` 自带查表,不自写。
_Avoid_: shishen(拼音英文混)

**纳音 (Na Yin)**:
每对干支对应的五行意象(如"路旁土""杨柳木"),命盘装饰层信息。`lunar_python` 自带。
_Avoid_: nayan

**藏干 (Hidden Stems)**:
地支内藏的天干(本气/中气/余气)。`lunar_python` `getHideGan` 直接给出。
_Avoid_: hidden stems(英文翻译)

**十二长生 (Di Shi)**:
五行在十二地支中的旺衰周期(长生/沐浴/冠带/.../墓/绝)。`lunar_python` `getDiShi` 给出。
_Avoid_: life cycle / twelve stages

**旬空 (Xun Kong)**:
十干配十二支后空缺的两个地支,命盘稀薄处。`lunar_python` `getXunKong` 给出。

### 命主状态 (Strength & Favorable)

**旺衰 (Day Master Strength)**:
日主在命盘中的强弱判断,取值 `strong | weak | balanced | special_pattern`。后端规则引擎(扶抑 + 调候)给出,不交给 LLM。
_Avoid_: power level / level

**喜用 (Favorable Elements)**:
对命主有利的五行列表。后端确定性输出,LLM 严禁自行推断或修改。
_Avoid_: lucky elements / useful god

**忌讳 (Unfavorable Elements)**:
对命主不利的五行列表。同上,后端确定性输出。
_Avoid_: bad elements / taboo

**扶抑法**:
喜忌主规则。身强 → 用克泄耗;身弱 → 用生扶。输出固定喜用 + 忌五行。
_Avoid_: support-suppress method

**调候法**:
喜忌修正规则。生在极寒月(子/丑)或极热月(午/未)时叠加调候用神,优先级高于扶抑。
_Avoid_: climate adjustment

**五行平衡 (Element Balance)**:
本命四柱 8 字中木/火/土/金/水的计数分布,UI 以横向条形图展示。
_Avoid_: element distribution

### 命局结构 (Pattern)

**格局 (Pattern Classification)**:
传统命理对命盘的硬性分类(正官格 / 偏印格 / ...)。**v1 砍掉**,LLM 用"命局呈现××倾向"模糊叙事,严禁给硬分类结论。延后到 v2 立项。
_Avoid_: pattern / profile

**从格 / 专旺 (Special Pattern)**:
10% 边界命盘(日主同气 ≥6/8 为专旺;日主孤立 + 某行 ≥5/8 为从格)。检测命中输出 `day_master_strength="special_pattern"`,喜忌留空,LLM 诚实告知"各派不同,仅供参考"。**不是完整格局判定**,只是 3-4 条简单阈值。
_Avoid_: special chart / extreme pattern

**神煞 (Shen Sha)**:
20 个固定清单的吉凶星曜(11 吉 + 9 凶),《三命通会》单一来源起法,自写查表(`lunar_python` 不给)。命中输出 `{name, position, source}`。
_Avoid_: stars / spirits

**命宫 / 身宫 / 胎元 / 胎息**:
四柱之外的辅柱,`lunar_python` 自带。深度解析模块三小卡展示。

### 时间维度 (Time Pillars)

**大运 (Luck Pillars / Da Yun)**:
每 10 年一柱的人生阶段干支。`lunar_python` `getYun(gender).getDaYun()[i]` 给出。**第一步 `index=0` 是童限过渡**(`ganZhi=""`),前端跳过,从 `index=1` 开始展示。
_Avoid_: decade pillar

**流年 / 流月 / 流日 / 流时**:
当前正在走的年/月/日/时干支。`lunar_python` 同步给出。流年按立春切换。
_Avoid_: annual pillar / current year

**童限 (Pre-运 Period)**:
大运 `index=0` 的空 `ganZhi`,起运前的过渡,前端不展示。
_Avoid_: childhood period

**子时规则 (Zi Hour Rule / Sect)**:
子时(23:00-01:00)归属哪一日。`zi_next_day` (后端 `setSect(1)`,23:00 换日,默认值) vs `zero_oclock` (后端 `setSect(2)`,早晚子时,库默认)。**库默认 `sect=2` 与产品决策冲突,必须强制 `setSect(1)`**。
_Avoid_: midnight rule

**真太阳时 (True Solar Time)**:
按出生地经度修正后的本地真太阳时(均时差 + 经度时差)。所有排盘以真太阳时为准。
_Avoid_: local solar time / corrected time

### 数据实体 (Core Data Entities)

**ChartSnapshot**:
不可变的命盘值对象,SwiftData `@Model`。身份 = `content_hash`(按出生信息算,**不含** schema_version);`schemaVersion` 是独立字段;易变结构(pillars/十神/纳音/神煞/喜忌/luck_pillars)走 `payload` JSON Data。修改 = 新建,旧 snapshot 保留。
_Avoid_: chart model / bazi record

**content_hash**:
`ChartSnapshot` 的内容寻址 ID,`SHA256(birth_datetime + gender + city_longitude + zi_hour_rule)`。同一出生信息 = 同一 hash = 共享缓存,跨用户去重。
_Avoid_: snapshot_id / chart_id

**compatibility_hash**:
合盘的内容寻址 ID,`SHA256(min(a_hash,b_hash) + "|" + max(a_hash,b_hash) + "|" + context)`。
_Avoid_: comp_id

**UserSnapshotLink**:
用户与命盘的多对多关联表(`user_id + snapshot_hash + alias`),让归属关系与 snapshot 本身解耦。一个用户可挂多个 snapshot(自己 + 家人 + 伴侣)。
_Avoid_: user_chart

**InterpretationCache**:
客户端 SwiftData AI 缓存表。键 = `(content_hash, module, prompt_version, target_date?, provider, model)`。读前必须 `GET /api/health` 解析当前 provider/model 身份,nil 旧行永不命中。
_Avoid_: ai_cache

**CompatibilitySnapshot**:
合盘结果不可变快照,SwiftData `@Model`。身份 = `compatibility_hash`。

**DailyFortuneSnapshot**:
每日运势不可变快照,SwiftData `@Model`。`cachedUntil` = 24h。
_Avoid_: daily_fortune_record

**Entitlement**:
付费解锁记录(消耗型 IAP),绑定 `(transaction_id, content_hash, module)`。客户端 SwiftData + 后端 SQLite 双存,退款 webhook 置 `is_active=0`。
_Avoid_: purchase / unlock

**calc_rule_snapshot**:
命盘生成时使用的计算规则版本快照(library 版本 + sect + 真太阳时 offset + schema_version)。**不含 `calculated_at` 时间戳**(同一输入必须永远同一输出,时间戳进日志不进 snapshot)。
_Avoid_: rule version

**schema_version**:
ChartSnapshot 数据结构版本号,Int,从 1 递增。独立于 `content_hash`,保证多用户共享缓存命中率最大。加字段 = `payload` JSON 加 key + version +1 + 老 snapshot lazy 重算。
_Avoid_: model_version

**prompt_version**:
AI prompt 模板版本号。改 prompt → version +1 → 老缓存自然失效(desired behavior,因为输出也变了)。
_Avoid_: prompt_id

### 业务模块 (Product Modules)

**深度解析 (Deep Analysis / bazi_deep)**:
单人命盘完整解读模块。Tab 1。输入 = 出生日期 + 性别 + 城市 + 子时规则;输出 = 四柱 / 十神 / 纳音 / 神煞 / 喜忌 / 大运 / AI 命书。AI 拆 `bazi_deep_free`(2 章)+ `bazi_deep_paid`(5 章)。
_Avoid_: deep dive / chart reading

**合盘 (Compatibility / compatibility)**:
两人命盘对比 + 流年同步模块。Tab 2。输入 = `person_a_hash` + `person_b` + `context`(general/marriage/business);输出 = 双盘对比 + 4 维定性评估 + 3 年流年同步 + AI 合盘解读。**只给定性描述,不给数字分**。
_Avoid_: relationship reading / synastry

**每日运势 (Daily Fortune / daily_fortune)**:
基于已存档命盘 × 当日流日柱的每日运势模块。Tab 3。**按需生成 + 24h 缓存**(iOS Background Tasks 不可靠,不用)。包含流日柱 / 12 时辰 / 通用黄历宜忌 / AI 解读 / 7 天历史回看。
_Avoid_: daily horoscope

**每日一问 (Daily Question / daily_question)**:
基于命盘 + 当日运势回答用户具体提问的模块(规划中,M5 slice)。每天 1 次,跟 `DailyReadCounter` 共用全局每日 10 次池。
_Avoid_: ask feature

### AI 边界 (AI Boundary)

**LLM 只润色不判断**:
项目核心约束。喜忌 / 神煞 / 大运走势由后端确定性给出,LLM 只把结构化结果润色成中文命书,严禁自行推断喜忌、严禁给硬性格局结论、严禁给"必成/必分"等绝对化用语。
_Avoid_: AI 智能解读(过度承诺)

**确定性输出 (Deterministic Output)**:
同一输入永远同一输出。所有排盘走后端 `lunar_python`,客户端不做历法计算;`calc_rule_snapshot` 不含时间戳;缓存键包含 `prompt_version + provider + model`,切换身份自然 miss。

**CachedInterpretationReader**:
客户端读 AI 缓存的唯一入口 module。集中执行 ADR-0009 强约束(读前必须 health 解析身份),把执行点从 N=5 个调用点收敛到 1 处。interface:`read(contentHash:module:targetDate:maxAge:) async throws -> InterpretationCache?`。`maxAge=nil` 不过期(`DeepAnalysis` 瞬时显示用);其他传 `24 * 3600`。命中后的 module-specific sync(写 `CompatibilitySnapshot` / `DailyFortuneSnapshot`)仍在 caller,因为 sync 类型不同无法合并。
_Avoid_: cache reader / interpretation service / cache manager

### 外部依赖 (External Dependencies)

**lunar_python**:
6tail/lunar-python 出品的纯 Python 八字历法库(v1.4.8)。提供四柱 / 十神 / 纳音 / 藏干 / 大运 / 流年 / 流月 / 黄历宜忌 / 节气等。**不给喜忌 + 不给 20 个神煞**,需自写。**库默认 `sect=2`**,必须强制 `setSect(1)`。同步 CPU-bound 库,FastAPI 用 `run_in_threadpool` 包。
_Avoid_: lunar library / bazi lib

**AIClient**:
后端 provider-neutral AI 客户端抽象。启动时按 `AI_PROVIDER=anthropic|openai` 单选,**不自动 fallback**。Anthropic 走 Messages API(默认 `claude-sonnet-4-6`),OpenAI 走 Responses API(默认 `gpt-5.5`),统一 15 秒超时 + 1024 输出 token 上限。
_Avoid_: AI gateway / llm client

**StoreKit 2**:
iOS 系统自带 IAP 框架,Swift 原生。StoreKit 2 本地校验 JWS 签名,后端再用 App Store Server API 二次校验 entitlement。

### 设计系统 (Design System)

**BaziTheme**:
iOS SwiftUI 全局视觉 token 集合(`paper` / `cardSurface` / `ink` / `inkMuted` / `cinnabar` / `jade` / `daiBlue` / `hairline` / `cinnabarSoft`)。详见 `DESIGN.md`。
_Avoid_: theme / colors

**Memorable Thing**:
产品记忆点 — **"专业不忽悠,不像算命软件"**。用户首次打开 3 秒后闭上眼应记住的事:克制、真诚、像翻一本古籍的研究工具。每个 UI 决策都要服务这件事。

## Context Relationships

```
┌─────────────┐   HTTPS    ┌──────────────┐
│  iOS App    │ ─────────→ │   Backend    │
│ (SwiftUI +  │            │ (FastAPI +   │
│  SwiftData) │            │  lunar_python│
│             │            │  + AIClient) │
└─────────────┘            └──────────────┘
      │                            │
      │ SwiftData 本地存档          │ SQLite 缓存 + entitlement
      │ ChartSnapshot              │ interpretation_cache
      │ InterpretationCache        │ entitlement
      │ Entitlement                │
      │                            ▼
      │                     ┌──────────────┐
      │                     │ Anthropic /  │
      │                     │ OpenAI       │
      │                     └──────────────┘
      │
      ▼
   App Store
   (StoreKit 2 IAP)
```

- **iOS → Backend**:所有排盘 + AI 解读走后端,API key 不进客户端
- **Backend → AI Provider**:单选 provider,不 fallback,显式错误传播
- **iOS ↔ App Store**:StoreKit 2 完成 IAP,后端二次校验 entitlement(越狱保护)
- **客户端缓存 ↔ 后端缓存**:同 content_hash 跨用户共享(后端 SQLite 最大价值)

详细决策记录见 `docs/adr/`。命理算法规范见 `命理引擎设计决策.md`,付费系统见 `MONETIZATION.md`,视觉系统见 `DESIGN.md`,用户故事见 `USER_STORIES.md`。
