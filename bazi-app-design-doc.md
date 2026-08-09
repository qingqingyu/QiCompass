# Design: 玄机问道 — AI 八字深度解析 / 合盘 / 每日运势

Generated on 2026-07-09 (revised after lunar-python spike; last revised 2026-08-01 after grill-me strategic review)
Repo: QiCompass (greenfield)
Status: DRAFT — API 契约已用 lunar-python 实测字段校准
Mode: Builder

> **2026-08-01 grill-me 决策**：本 doc 已同步战略 review 结论——入口改为今日运势 / B2 强制轻注册 / 深度解析改为 β 点击触发 / 三模块统一 Medium/Medium-deep 短句节奏 voice。详见 §Tab 结构 + 默认 Tab + Onboarding 流 + §Module Specifications 各模块 voice 注记。代码 diff 待办见 `STRATEGIC_DIFF.md`。

> **配套文档**：`命理引擎设计决策.md` 含喜忌/神煞/ChartSnapshot 三项核心命理决策的详细规范。本设计文档与之分工：本文件管"产品形态 + 工程实现"，决策文件管"命理算法"。

## Problem Statement

原生 iOS App，把中国传统八字命理做成三个深度模块：**深度解析**（单人命盘）、**合盘**（两人兼容性）、**每日运势**（流日 + 流时指引）。所有排盘计算在后端用 `lunar_python`（6tail 出品，纯 Python 无依赖）做**确定性**计算，命书解读由后端选择的 Anthropic 或 OpenAI 模型生成。客户端只渲染，不算历法。

目标用户：海外华人（25-45）+ 对东方文化好奇的西方人（18-35）。收敛聚焦：从"三占卜工具 + 卷轴自传"改为"八字深度垂直"——做得更深，而不是更宽。

## What Makes This Cool

三个模块共享同一份用户命盘数据——B2 强制轻注册生成 chart 后，今日运势 / 深度解析 / 合盘都能复用。今日运势是**高频回访入口 + 默认 Tab**（2026-08-01 决策），合盘是社交裂变入口（两人才能完成），深度解析是**可选功能**（β 点击触发，不再自动跑）。视觉方向见 `DESIGN.md`（宋瓷气质，现代东方极简）。

## Constraints

- 原生 iOS（Swift/SwiftUI，iOS 17+）
- 后端代理封装 Anthropic/OpenAI API + lunar_python，API key 不进客户端；provider 只能由部署环境选择
- 八字计算必须**确定性**：同一输入永远同一输出
- 三模块：深度解析 / 合盘 / 每日运势。不做六爻、灵签、卷轴
- 单人 side project

## Premises

1. **八字垂直 > 多占卜横向**
2. **后端权威计算 + 客户端纯渲染**。所有排盘走后端，客户端不算历法
3. **每日运势依赖已存档的命盘**。B2 强制轻注册（2026-08-01 决策）后，用户填出生表单即生成 `ChartSnapshot` 存档——**不要求**跑深度解析 AI 命书。每日运势 = 命盘 × 流日柱
4. **合盘前置**：用户自己的命盘必须已存档（B2 表单提交后 `ChartSnapshot` 即视为存档，不要求跑过深度解析 AI），对方命盘可临时输入（"半游客模式"）
5. **格局判定延后**（详见 `命理引擎设计决策.md` §4）
6. **感觉即产品**——美学方向以 `DESIGN.md` 为事实源（宋瓷气质，现代东方极简；**预先存在的 drift**：本 doc 早期版本写"宫观古董美学"，已在 DESIGN.md 演化为宋瓷基调，此 Premise 措辞待下次视觉 slice 清理）

## Architecture Overview

> 下图展示**数据流**（三模块共享 ChartSnapshot），不是 Tab 顺序。Tab 顺序见 §App 结构 + Onboarding 流。

```text
┌─────────────────────────────────────────────┐
│             iOS App (SwiftUI)               │
│                                             │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │ 今日运势  │ │ 深度解析  │ │  合盘      │  │
│  │ (默认Tab) │ │ (β触发)  │ │            │  │
│  └────┬─────┘ └────┬─────┘ └─────┬──────┘  │
│       └────────────┼─────────────┘         │
│                    ▼                        │
│         ┌──────────────────┐                │
│         │ SwiftData 本地存档 │                │
│         │ + ChartSnapshot   │                │
│ │   (内容寻址 immutable)    │                │
│         │ + UserSnapshotLink│                │
│         └──────────────────┘                │
└──────────────────┬──────────────────────────┘
                   │ HTTPS
                   ▼
┌─────────────────────────────────────────────┐
│              Backend Proxy                  │
│  ┌────────────────┐  ┌──────────────────┐   │
│  │ lunar_python   │  │ AIClient         │   │
│  │ 八字计算       │  │ Anthropic/OpenAI │   │
│  │ (确定性)       │  │ 命书解读          │   │
│  └────────────────┘  └──────────────────┘   │
└─────────────────────────────────────────────┘
```

### 后端库选型（已 spike 验证）

**`lunar_python`** (6tail/lunar-python, `pip install lunar_python`)。Spike 实测能力：

| 能力 | lunar_python 是否支持 | 说明 |
|---|---|---|
| 四柱（年月日时） | ✅ | `EightChar.getXxxGan/Zhi/WuXing/HideGan/NaYin` |
| 十神（天干 + 地支藏干） | ✅ | `getXxxShiShenGan` / `getXxxShiShenZhi`，**不用自己查表** |
| 纳音 | ✅ | `getXxxNaYin` |
| 藏干 | ✅ | `getXxxHideGan` |
| 十二长生 | ✅ | `getXxxDiShi` |
| 旬空 | ✅ | `getXxxXunKong` |
| 命宫/身宫/胎元/胎息 | ✅ | `getMingGong/ShenGong/TaiYuan/TaiXi` + NaYin |
| 大运 + 流年 + 流月 + 小运 | ✅ | `getYun(gender).getDaYun()[i].getLiuNian()/getLiuYue()/getXiaoYun()` |
| 子时换日规则 | ✅ | `setSect(1)`（子时换日）/ `setSect(2)`（早晚子时，**库默认**） |
| 流日流时 | ✅ | `Solar.fromDate(now).getLunar().getEightChar()` |
| 节气 + 立春换年 | ✅ | `getNextJieQi` / `getPrevJieQi` / `getYearInGanZhiByLiChun` |
| 黄历宜忌 / 吉神凶煞 / 方位 / 九星 | ✅ | `getDayYi/Ji` / `getDayJiShen/XiongSha` / `getDayPositionCai/Fu/Xi` / `getDayNineStar` |
| **决策 2 的八字神煞**（天乙/文昌/华盖等 20 个） | ❌ | 库不给，需自己写《三命通会》查表（详见 `命理引擎设计决策.md` §2） |
| **决策 1 的喜忌**（扶抑+调候） | ❌ | 库不给，需自己写规则引擎（详见 `命理引擎设计决策.md` §1） |

**两个坑（spike 发现）**：
1. **库默认 `sect=2`（早晚子时），必须强制 `ec.setSect(1)`** 才符合用户决策"默认 23:00 换日"
2. **大运第一步 `index=0` 的 `ganZhi=""`（空字符串）** = 起运前的童限过渡，前端必须跳过；真正第一步大运从 `index=1` 开始

### Backend API Contract

所有端点在用户已有的代理后。Bearer token 鉴权（构建时注入或 App 内配置）。

AI provider 为部署级全局配置,不允许客户端指定,也不做自动 fallback:

```bash
# 默认 Anthropic
AI_PROVIDER=anthropic
ANTHROPIC_API_KEY=...
ANTHROPIC_MODEL=claude-sonnet-4-6

# 切换 OpenAI Responses API
AI_PROVIDER=openai
OPENAI_API_KEY=...
OPENAI_MODEL=gpt-5.5
```

`AI_PROVIDER` 非法时启动失败；所选 provider 缺 key 时非 AI 路由仍可用,`/api/interpret` 返回 503。两种适配器共享 15 秒超时和 1024 输出 token 上限。

**POST /api/bazi/calculate** — 单人排盘
```json
Request: {
  "birth_datetime": "1990-03-15T14:30:00+08:00",
  "gender": "male",
  "city": "北京",
  "zi_hour_rule": "zi_next_day"
}
Response: {
  "content_hash": "sha256(...)",  // 内容寻址 ID（决策 3）
  "true_solar_time": "1990-03-15T14:33:12+08:00",
  "true_solar_offset_minutes": 3.2,
  "pillars": {
    "year":  {
      "gan_zhi": "庚午",
      "gan": "庚", "zhi": "午",
      "gan_element": "metal", "zhi_element": "fire",
      "hide_gan": ["丁", "己"],
      "shishen_gan": "伤官",
      "shishen_zhi": ["偏印", "比肩"],
      "nayin": "路旁土",
      "dishi": "临官",  // 十二长生
      "xunkong": "戌亥"
    },
    "month": { ... },
    "day":   { ... },  // day.shishen_gan = "日主"
    "hour":  { ... }
  },
  "ming_gong": { "gan_zhi": "癸未", "nayin": "杨柳木" },
  "shen_gong": { "gan_zhi": "丁亥", "nayin": "屋上土" },
  "tai_yuan": { "gan_zhi": "庚午", "nayin": "路旁土" },
  "element_balance": { "wood": 3, "fire": 2, "earth": 2, "metal": 2, "water": 0 },
  "favorable_elements": ["火", "土"],  // 决策 1 确定性输出
  "unfavorable_elements": ["水", "金"],
  "day_master_strength": "weak",  // strong | weak | balanced
  "tiaoshou_applied": false,
  "shensha": [  // 决策 2 八字神煞，20 个固定清单
    { "name": "天乙贵人", "position": "日柱", "source": "三命通会" },
    { "name": "文昌", "position": "时柱", "source": "三命通会" }
  ],
  "luck_pillars": [  // 大运，已跳过 index=0 童限
    { "gan_zhi": "戊寅", "start_year": 1993, "end_year": 2002, "start_age": 4, "end_age": 13 },
    { "gan_zhi": "丁丑", "start_year": 2003, "end_year": 2012, "start_age": 14, "end_age": 23 },
    ...
  ],
  "current_luck_pillar": { "gan_zhi": "乙亥", "start_year": 2023, "end_year": 2032 },
  "current_year_pillar": "丙午",  // 流年（按立春切换）
  "current_day_pillar": "甲申",   // 当日流日
  "current_hour_pillar": "辛未",  // 当前流时
  "calc_rule_snapshot": {
    "library": "lunar_python 1.4.8",
    "sect": 1,  // 子时换日规则
    "zi_hour_rule": "zi_next_day",
    "true_solar_longitude": 116.41,
    "true_solar_offset_minutes": -24.01,
    "schema_version": 1
    // 注:不含 calculated_at —— CLAUDE.md 确定性约束「同一输入永远同一输出」
    // 时间戳进日志,不进 snapshot。offset 示例为北京 3 月真值,文档示例数值为示意
  },
  "boundary_warning": null
}
```

**POST /api/bazi/compatibility** — 合盘
```json
Request: {
  "person_a_hash": "sha256(...)",  // 优先：引用已存档 snapshot
  "person_b": {  // 对方可临时输入
    "birth_datetime": "...", "gender": "...", "city": "...", "zi_hour_rule": "..."
  },
  "context": "general"  // general | marriage | business
}
Response: {
  "compatibility_hash": "sha256(...)",  // 内容寻址
  "person_a_chart": { ...同单人排盘 },
  "person_b_chart": { ...同单人排盘 },
  "qualitative_assessment": {  // 决策 A2：不给数字分，只给定性描述
    "five_elements": "互补佳",  // 一方多余是否另一方所需
    "day_master_relation": "相生",
    "zodiac_match": "六合",
    "branch_harmony": "无冲无刑"
  },
  "synced_fortune": [  // 流年同步性，未来 3 年定性
    { "year": 2026, "person_a": "乙亥运 丙午年", "person_b": "丁丑运 丙午年", "sync": "同步走强" },
    { "year": 2027, ... },
    { "year": 2028, ... }
  ],
  "calc_rule_snapshot": { ... }
}
```

**POST /api/bazi/daily-fortune** — 每日运势
```json
Request: {
  "chart_hash": "sha256(...)",  // 引用已存档命盘
  "target_date": "2026-07-09"
}
Response: {
  "day_pillar": "甲申",
  "day_relation_to_day_master": "偏官",  // 流日对日主关系
  "day_chong": "寅",  // 流日地支冲（lunar_python getDayChong）
  "hour_pillars": [  // 12 时辰
    { "hour": "子", "time_range": "23:00-01:00", "pillar": "甲子", "relation": "正官", "chong": "午" },
    { "hour": "丑", "time_range": "01:00-03:00", "pillar": "乙丑", "relation": "偏官", "chong": "未" },
    ...
  ],
  "current_hour_index": 5,
  "huangli_yi": ["嫁娶", "祭祀", "祈福", ...],  // 通用黄历宜（lunar_python getDayYi）
  "huangli_ji": ["赴任", "出行"],
  "calc_rule_snapshot": { ... }
}
```

**POST /api/interpret** — AI 命书解读（三模块共用）
```json
Request: {
  "content_hash": "命盘 hash / compatibility_hash",
  "module": "bazi_deep" | "compatibility" | "daily_fortune",
  "context": { ... 排盘结构化数据（含喜忌、神煞等后端确定性输出） ... },
  "target_date": "2026-07-16" | null,
  "question": null
}
Response: {
  "interpretation": "... 中文命书 ...",
  "prompt_version": 1,
  "cached": false,
  "generated_at": "2026-07-16T12:00:00+00:00",
  "provider": "anthropic" | "openai",
  "model": "claude-sonnet-4-6" | "gpt-5.5"
}
```

provider/model 由应用启动时装配的 `AIClient` 决定，请求体不接受 provider。所选 provider 缺 key 或上游调用失败统一返回显式错误，不自动调用另一供应商。

**GET /api/health**
```json
Response: {
  "status": "ok",
  "lunar_python_version": "1.4.8",
  "model": "bazi-calculate-v1",
  "ai_provider": "anthropic" | "openai",
  "ai_model": "claude-sonnet-4-6" | "gpt-5.5"
}
```

health 响应固定带 `Cache-Control: no-store`；其中 `model` 仍是排盘 API 版本，`ai_model` 才是当前解读模型。

## Module Specifications

### 1. 深度解析（单人命盘）

- **输入**：出生日期（DatePicker）、出生时辰（时辰选择器）、性别、出生城市（从城市经度表选）、子时规则（默认 zi_next_day，可改 zero_oclock）
- **计算**：后端 `lunar_python` 排盘，强制 `setSect(1)` 默认值
- **触发**：**β 点击触发**（2026-08-01 决策，对齐 B2"强制轻注册但不立刻跑深度 AI"）。用户切到深度解析 Tab → chart 立即可见（pillars/五行/十神/神煞，deterministic，instant）→ 顶部加 deterministic anchor sentence（"日主 X，命局 Y，喜 Z 忌 W"，0 AI 成本，字符串拼接）→ "生成免费解读"按钮显眼 → 用户点 → ~10s 跑免费 2 章 → fade in。返回用户走 `InterpretationCache`（决策 4）instant 命中缓存
- **显示**：
  - 顶部：命主信息 + 真太阳时（标注与输入时间的偏差分钟数）
  - **deterministic anchor sentence**（新增 2026-08-01）：1 句话总览，由后端 `day_master_strength` + `favorable_elements` + `unfavorable_elements` 拼接返回，0 AI 成本，instant（文案模板候选见 `STRATEGIC_DIFF.md` Open implementation question #2）
  - 四柱表：年/月/日/时四列，每列天干上 / 地支下，十神标在天干旁边，纳音小字在底部，藏干 chip 列表
  - 命宫/身宫/胎元小卡片（lunar_python 自带）
  - 五行平衡条形图
  - **喜忌区域**（决策 1）：`favorable_elements` + `unfavorable_elements`，标注"扶抑+调候"算法
  - 大运横向时间轴（跳过 index=0 童限）
  - 神煞 chip 列表（决策 2，20 个固定清单）
  - 流年/流日/流时当前状态小卡片
  - **"生成免费解读"按钮**（β 点击触发点）：默认显示，用户点击后跑 2 章免费 AI；点击后变成 disabled + "生成中..." skeleton
  - AI 命书区：**Medium-deep voice**（2026-08-01 决策）——每章 200-300 字，分 3-5 段，每段 2-3 短句，每段聚焦一个具体洞察（短句节奏 + 研究深度兼得，既不像 CoStar 那样 vague 短箴言，也不像传统命理师长文）。**砍掉旧 "300-500 字 + MVP 压缩 30%"**。7 章总 AI 内容 = 1400-2100 字/命盘（2 免费 400-600 + 5 付费 1000-1500，详见 §AI Voice 规范 表格）
  - **不做"再生成"按钮**（2026-08-01 决策）：用户不能换 prompt 风格再跑一次
- **持久化**：按决策 3 内容寻址生成 `ChartSnapshot`，不可变

### 2. 合盘（两人兼容）

- **输入**：A 盘从已存档 snapshot 选（必须），B 盘可临时输入或选已存档
- **context 选项**：general / marriage / business（**不影响计算**，只影响 LLM 命书侧重）
- **计算**：两个单人排盘 + 定性合盘描述 + 流年同步性
- **付费形态**：**半免费**（决策 2026-07-18 + 重申 2026-08-01）。基础相处模式 + 互补/冲突总览 = 免费；爱情深度 / 合作事业 / 财运合拍 / 流年同步 = 付费（与深度解析同形态）
- **显示**：
  - 双盘对比：A 盘左、B 盘右，四柱并排
  - 定性卡片（决策 A2）：五行互补、日主关系、生肖匹配、地支合冲——**只给定性描述，不给数字分**
  - 流年同步表：未来 3 年定性同步性
  - AI 合盘解读：**Medium voice**（2026-08-01 决策）——同短句节奏（每段 2-3 短句）但比深度解析 Medium-deep 更简洁，每章 200-300 字围绕相处场景 actionable。**砍掉旧 "400-500 字"**
- **持久化**：合盘结果按 `(min(a_hash, b_hash), max(a_hash, b_hash), context)` 内容寻址缓存

### 3. 每日运势（高频回访入口 / 视觉入口）

- **角色**：**默认 Tab + 首次注册后落地页**（2026-08-01 决策）。冷启动直接进入今日运势，不进深度解析
- **前置**：必须先完成 B2 强制轻注册（5 字段表单），生成 `ChartSnapshot` 存档。**不要求**跑深度解析 AI 命书——只要 chart 存在，今日运势就能拿到个性化层（流日对日主关系 + 喜忌层）
- **触发**：App 打开按需生成 + 24h 缓存（决策 A3，iOS Background Tasks 不可靠）。**瞬时层 + 异步 AI 流式追加**模式（Open Question 10 结论）：流日柱/冲/黄历宜忌 0 延迟显示，AI 总览 3-5s 流式追加
- **显示**：**Medium voice**（2026-08-01 决策，砍掉旧 150-200 字长段）：
  - 顶部：今日日期（农历 + 公历）+ 今日流日柱 + 流日对日主的关系（如"偏官日"）+ 流日冲
  - 中部：**AI 总览 50-80 字（3-5 短句，直言不绕弯）**——结合命局喜忌写"今日倾向 + 行动建议"，不堆术语
  - **宜/忌主视觉锚点**：每条 2-3 字 actionable bullet（如 "宜 果断 独处 / 忌 犹豫 争论"），东方黄历传统现代化，对应 CoStar 短句 actionable 但不是复制。**数据源待定**（Open implementation question）：候选 a = 后端基于 `favorable_elements` + 流日关系确定性映射到 actionable 词表（如 喜火+偏官日 → "宜 果断"）；候选 b = 由 AI 总览 50-80 字一起生成（但违背"UI 渲染而非 AI 输出"原则）；候选 c = 仍用 `getDayYi/Ji` 但前端做词汇风格转换。**推荐 a**（后端确定性 + iOS 渲染，与 anchor sentence 同源）
  - 12 时辰条：默认折叠，展开后显示每个时辰的流时柱 + 关系 + 冲。**当前时辰高亮**，手动下拉刷新（决策 B）
  - 通用黄历宜忌：lunar_python `getDayYi/Ji`（所有人一样，不个性化）
  - 底部：明日预告
- **缓存**：当日生成后缓存到 SwiftData，24h 内不重算
- **历史**：可回看过去 7 天（决策 B）
- **不做**：不在今日页强制阅读长命书段（CoStar 节奏）；不堆叠 12 时辰点评（保持折叠）

## App 结构 + Onboarding 流（2026-08-01 grill-me 决策）

### Tab 结构

4 个 Tab，从左到右：

| 顺序 | Tab | 角色 |
|---|---|---|
| 1 | **今日运势** | 默认 Tab（冷启动落地），高频回访入口 |
| 2 | **深度解析** | 第二功能，2 章 free + 5 章 paid |
| 3 | **合盘** | 第三功能，half-free |
| 4 | **我的** | 新增。多命盘管理（`UserSnapshotLink`）/ 已购 entitlements / 设置（zi_hour_rule default / 主题 / 语言）/ 关于。v1 无账号系统，此 Tab 不含账号功能 |

**默认选中**：`.dailyFortune`（2026-08-01 决策，旧 `.deepAnalysis` 改掉）。

**不做**：不做"再生成"按钮（任何模块）——用户不能换 prompt 风格重跑同一命盘。

### Onboarding 流（B2 强制轻注册）

```text
首次启动
  ↓
OnboardingView（4 页 sheet，禁下滑 dismiss）
  ├─ Page 1: WelcomePage（背景图 + 印章「玄」+ 经文）
  ├─ Page 2: StancePage（"不是算命软件" 留白叙事）
  ├─ Page 3: PrivacyPage（"数据在你设备上" 留白叙事）
  └─ Page 4: StartPage（印章「始」+ CTA "开始排盘")
       ↓ CTA 点击
BirthFormView（5 字段强制轻注册）
  ├─ 出生日期（DatePicker）
  ├─ 出生时辰（时辰选择器）
  ├─ 性别
  ├─ 出生城市（城市经度表）
  └─ 子时规则（默认 zi_next_day，可改 zero_oclock）
       ↓ 表单提交
后端 /api/bazi/calculate → ChartSnapshot 存档
       ↓
落地默认 Tab = 今日运势（已个性化，因 chart 已建）
       ↓
首次进入今日运势，AI 总览异步流式追加（3-5s）
```

**关键约束**：
- B2 表单**只**触发排盘计算（deterministic，instant），**不**触发深度解析 AI 命书生成
- 深度解析 AI 命书延后到用户**主动**切到深度解析 Tab + 点"生成免费解读"按钮（β 点击触发，2026-08-01 决策）
- 第二次冷启动起，`hasSeenOnboarding = true`，跳过 OnboardingView 直接到 TabView（落地今日运势）

## 排盘规则（Deterministic Calculation Rules）

详细规范见 `命理引擎设计决策.md`。摘要：

1. **子时换日**：默认 `sect=1`（子时属次日），可配置 `sect=2`（早晚子时）。规则随盘存档
2. **真太阳时**：城市经度表 + 均时差。边界提示
3. **十神**：直接用 `lunar_python` 的 `getXxxShiShenGan` / `getXxxShiShenZhi`（库自带，不必自己查表）
4. **喜忌**：后端确定性规则引擎，扶抑法 + 调候法（详见决策 1）。**从格/专旺检测命中**时输出 `day_master_strength="special_pattern"`，喜忌留空，LLM 诚实告知（详见决策 1b）
5. **格局判定**：MVP 砍掉，LLM 模糊叙事（详见决策 5）
6. **神煞**：20 个固定清单，《三命通会》单一来源，自写查表（详见决策 2）
7. **AI 缓存**：客户端 SwiftData + 后端 SQLite 两级缓存，至少按 `(content_hash, module, prompt_version, target_date, provider, model)` 隔离；后端另含 `prompt_hash` 防止不同上下文污染（详见决策 4）

## Data Model（SwiftData，按决策 3 + 3b 内容寻址 + schema 演化）

详细字段规范见 `命理引擎设计决策.md` §3 + §3b。摘要：

```swift
@Model
class ChartSnapshot {
    @Attribute(.unique) var contentHash: String  // SHA(birth+gender+lon+rule)，不含 schema_version
    var schemaVersion: Int = 1                   // 决策 3b：数据结构版本，独立字段
    var birthSolarTime: Date
    var gender: String
    var cityLongitude: Double
    var ziHourRule: String  // zi_next_day | zero_oclock

    var calcRuleSnapshot: Data  // JSON: library 版本、sect、offset、calculated_at
    var payload: Data           // JSON: pillars/mingGong/shenGong/taiYuan/elementBalance/喜忌/神煞/luckPillars（决策 3b 易变结构集中）
    // payload schema:
    //   {
    //     "pillars": {...}, "mingGong": {...}, "shenGong": {...}, "taiYuan": {...},
    //     "elementBalance": {...},
    //     "favorable_elements": [...], "unfavorable_elements": [...],
    //     "day_master_strength": "strong|weak|balanced|special_pattern",  // 决策 1b
    //     "tiaoshou_applied": false,
    //     "shensha": [...],
    //     "luck_pillars": [...]  // 跳过 index=0 童限
    //   }
}

@Model
class UserSnapshotLink {
    @Attribute(.unique) var id: UUID
    var userId: String
    var snapshotHash: String  // FK → ChartSnapshot.contentHash
    var alias: String  // "我自己" | "妈妈" | "男友"
    var createdAt: Date
}

@Model
class InterpretationCache {  // 决策 4：客户端 AI 缓存
    @Attribute(.unique) var id: UUID
    var contentHash: String       // 单盘 hash / 合盘 compatibility_hash
    var module: String            // bazi_deep | compatibility | daily_fortune
    var promptVersion: Int        // 后端 prompt 改了，老缓存失效
    var targetDate: Date?         // 每日运势专用，其他模块 nil
    var provider: String?         // optional 仅为轻量迁移；nil 旧行永不命中
    var model: String?            // 新写入必须有非空身份
    var interpretation: String
    var generatedAt: Date
}

@Model
class CompatibilitySnapshot {
    @Attribute(.unique) var compatibilityHash: String
    var personAHash: String
    var personBHash: String
    var context: String  // general | marriage | business
    var qualitativeAssessment: Data
    var syncedFortune: Data
    var interpretation: String?
    var interpretationProvider: String?  // 旧历史文本可为 nil
    var interpretationModel: String?
    var createdAt: Date
}

@Model
class DailyFortuneSnapshot {
    @Attribute(.unique) var id: UUID
    var chartHash: String  // FK → ChartSnapshot
    var targetDate: Date
    var dayPillar: String
    var dayRelation: String
    var hourPillars: Data
    var huangliYi: [String]
    var huangliJi: [String]
    var interpretation: String
    var interpretationProvider: String?  // 旧历史文本可为 nil
    var interpretationModel: String?
    var cachedUntil: Date  // 24h
}
```

**演化策略**（决策 3b）：加字段 = `payload` JSON 加 key + `schemaVersion +1`，老 snapshot lazy 重算。SwiftData 核心 schema 几乎不变。

**AI 缓存层**（决策 4）：客户端 `InterpretationCache` + 后端 SQLite 两级缓存。iOS 每次读取本地 AI 缓存前都用忽略 URL 缓存的 health 请求解析当前身份，只接受 provider/model 完全匹配的行；health 失败进入 AI error 状态。后端键为 `(content_hash, module, prompt_version, target_date, prompt_hash, provider, model)`，每日运势使用非空 `target_date`。旧 nil 身份行和历史 snapshot 文本可回看，但不能充当当前 provider 的缓存命中。

## 阅读次数限制

每日 AI 解读上限 10 次（UserDefaults + 日期 key，午夜重置）：
- 深度解析：1 次
- 合盘：1 次（不管两人，决策 B）
- 每日运势：1 次（缓存命中不消耗）
- AI 失败重试：**不消耗**次数（决策 B，用户没拿到结果不该扣）
- 达上限："今日机缘已尽，明日再来" + 倒计时

## Error Handling

按用户全局规范"错误显式传播，不静默吞"：

- **网络超时（>15s）/ 离线**：墨溅式错误卡 "天意未明"，重试按钮。排盘**不存档**
- **后端排盘库错误**：结构化 error，前端显示"排盘异常"，日志记录 library + input + error
- **AI 解读失败**：排盘已存档，AI 解读空缺。前端显示"命书生成失败" + 重试（重试不消耗次数）
- **城市经度表无该城市**：让用户选"最接近的城市"或手动输入经度
- **达日上限**：友好提示，不算错误

## Tech Stack

| 层 | 技术 |
|---|---|
| 前端 | Swift 5.9+ / SwiftUI / iOS 17.2+ |
| 持久化 | SwiftData（D1 设计：JSON payload + lazy 重算，**不用** VersionedSchema / SchemaMigrationPlan） |
| 字体 | iOS 系统衬线 Songti SC（显示/标题）+ PingFang SC（正文）+ SF Pro Text tabular-nums（数字），不打包自定义字体（详见 `DESIGN.md` §Typography） |
| 触感 | UIImpactFeedbackGenerator |
| 后端 | Python FastAPI |
| 八字计算 | **lunar_python 1.4.8+**（已 spike 验证 + 后端排盘核心已实现 + 30 用例对盘通过） |
| AI | provider-neutral `AIClient`；Anthropic Messages API（默认 `claude-sonnet-4-6`）或 OpenAI Responses API（默认 `gpt-5.5`）经后端代理 |
| 部署 | TestFlight → App Store |

## Visual Design Tokens

> **2026-08-09 清理**：本节原列旧黑金色板（bgTop/bgMid/gold/亮金 等），与 `DESIGN.md` 决策的"现代东方极简 · 宋瓷气质"（paper #FDFCFA / cinnabar #C33B3B / jade #2C5F3F）**直接矛盾**。
> 视觉事实源已迁移到 `DESIGN.md` §Color（含 Light + Dark 墨夜瓷釉双值色板）/ §Typography / §Spacing / §Layout。
> iOS SwiftUI 落地 token 见 `ios/QiCompass/QiCompass/App/RootTabView.swift` `enum BaziTheme`，与 DESIGN.md 一一对应。
> 本节不再维护色板表，所有视觉决策以 `DESIGN.md` 为准。

## AI Voice 规范（2026-08-01 grill-me 决策）

**实施源**：`backend/app/ai/prompts.py` 是 prompt 模板的单一事实源。本节是 voice spec，不复制模板原文（避免双份维护漂移）。

### 通用原则（所有 module 共享）

- **短句节奏**：每段 2-3 句，每句尽量短（避免 50+ 字长句）
- **直言不绕弯**：不用"传统认为..."、"古人云..."；直接"你是..."
- **核心术语保留但不主动解释**：日主 / 十神 / 喜忌 / 流日等术语直接用，假设读者基础（对齐目标用户"想认真研究命理"画像）
- **不确定性保留**：用"倾向 / 可能 / 容易"，禁用"必 / 一定 / 肯定"
- **段落聚焦洞察**：每段聚焦一个具体 actionable 洞察，不泛泛

### Module-specific voice

| Module | 篇幅 | 段落结构 | Voice |
|---|---|---|---|
| `bazi_deep_free`（2 章免费：性格底色 / 事业） | 200-300 字/章 × 2 = **400-600 字总** | 每章 3-5 段 × 2-3 短句 | **Medium-deep**：每段聚焦"日主本质 / 事业倾向"的一个具体 actionable 洞察 |
| `bazi_deep_paid`（5 章付费：财运 / 爱情 / 健康 / 六亲 / 晚年） | 200-300 字/章 × 5 = **1000-1500 字总** | 每章 3-5 段 × 2-3 短句 | **Medium-deep**：每章聚焦该领域的具体倾向 + 流年时间窗口 |
| `compatibility` | 200-300 字/章 × 6 章（2 免费 + 4 付费，详见 `MONETIZATION.md` §合盘）= **1200-1800 字总** | 每章 3-5 段 × 2-3 短句 | **Medium**：合盘特化，围绕相处模式 + 互补/冲突具体场景。免费章节给基础相处总览，付费章节给爱情/合作/财运/流年同步 |
| `daily_fortune` | **50-80 字** | 3-5 短句（不分段或弱分段） | **Medium**：今日倾向 + 行动建议，直言 actionable。**砍掉旧 150-200 字 + 12 时辰点评** |

**为什么 Medium-deep 而不是 CoStar 式极短**（2026-08-01 决策）：

- 今日页 = 高频回访入口 → 50-80 字短句匹配 CoStar 节奏
- 深度解析章节 = 低频深读场景 + 付费内容载体 → 200-300 字保留研究深度，但用短句节奏避免长文迂回感
- 全栈一致 CoStar 化会让 $18 = 5 章 × 80 字 = 400 字总，价值感薄
- 短句 ≠ 必须短文——一段 200 字如果用短句分段写，仍然有 CoStar 的节奏感

### 禁止事项（所有 module 共享）

- 不堆 5+ 字术语链（"伤官见官" 需拆开或换说法）
- 不写"必成 / 必分 / 必破财 / 必有大灾"等绝对结论
- 不自创格局硬分类（"正官格 / 偏印格" 禁用，用"命局呈现××倾向"模糊叙事）
- **喜忌不得自行推断或修改**——严格按后端 `favorable_elements` / `unfavorable_elements`
- **从格诚实降级**：`day_master_strength == "special_pattern"` 时只叙事不下硬性喜忌结论（对齐 CLAUDE.md "从格检测…LLM 诚实告知"）

### B2 触发约束（2026-08-01 决策）

- **深度解析 AI 命书不在表单提交时自动跑**——延后到用户主动点深度解析 Tab 的"生成免费解读"按钮（β 点击触发）
- **今日运势 AI 总览在表单提交后立即异步触发**——用户落地今日页时流式追加（3-5s）
- chart 排盘本身是 deterministic + instant，不阻塞 B2 流程

## Open Questions

**已拍板（参考 `命理引擎设计决策.md`）**：
1. **产品名**：保留"玄机问道"（决策 B，MVP 跑通后再决定）
2. **付费模型**：MVP 全免费（决策 B）

**P0 已锁定（plan-eng-review 2026-07-10）**：
3. **Schema 演化策略**：D1 → B+C 融合（决策 3b）
4. **AI 缓存层**：D2 → 客户端 + 后端 SQLite（决策 4）
5. **喜忌 10% 从格边界**：D3 → 检测特征 + 诚实降级（决策 1b）

**P1 已锁定（plan-eng-review 后续 2026-07-10）**：
6. **神煞代码化工作量**：**2.5-3 工作日**。先写通用模板（日干查表/三合局查表）+ 对盘脚手架（1 天）→ 填数据（1-1.5 天）→ 对盘测试（0.5 天）。原估合理，不调整
7. **iOS 最低版本**：**iOS 17.2+**（Xcode `IPHONEOS_DEPLOYMENT_TARGET = 17.2`）。SwiftData `@Relationship` 在 17.0/17.1 有 crash；D1 减轻了 VersionedSchema 依赖，但 `@Relationship`（UserSnapshotLink ↔ ChartSnapshot）仍要用
8. **对盘 ground truth 数据源**：**lunar_python 测试套件（主）+ 问真八字 App 抽样 5-10 个（辅）**。库的 `test/` 目录有 22 个测试文件，`LunarTest.py` 含完整 `toFullString` 断言（自带四柱/纳音/方位/冲煞全字段答案），可信度极高

**2026-08-01 grill-me 战略 review 锁定**：
9. **视觉层不动**：DESIGN.md "宋瓷气质，不取 CoStar 纯黑白" 决策保持。CoStar 启发只取表层 copy 腔调，不动 IA / 视觉 token / 色板
10. **CoStar 腔调 = 宜/忌传统现代化**（不是复制 CoStar）：短句 actionable + 直言不绕弯 + 每段聚焦一个具体洞察。深度 + 短句 可共存（不推翻"研究型用户"画像）
11. **入口 = 今日运势**（默认 Tab）：旧"深度解析为基础"叙事改为"今日运势为视觉入口，深度解析为可选功能"
12. **B2 强制轻注册**：首次打开必须填出生信息（5 字段）→ chart 创建（deterministic, instant）→ 落地今日运势（已个性化）。**不**立刻跑深度解析 AI
13. **深度解析 Tab = β 点击触发**：用户切 Tab → chart 可见 + deterministic anchor sentence → 点"生成免费解读"按钮 → 跑免费 2 章。**不**自动跑（cost control + 显式 intent 匹配研究型用户心理）
14. **三模块统一 Medium / Medium-deep voice**：今日页 AI 总览 50-80 字 / 深度章节 200-300 字 × 7 章 / 合盘 200-300 字 × 6 章。**砍掉旧 300-500 字 / 400-500 字 / 150-200 字**
15. **不做"再生成"按钮**：任何模块都不放。用户不能换 prompt 风格重跑同一命盘
16. **每日一问出 v1**：移到 v2 backlog（详见 `MONETIZATION.md` 标记 + §Next Steps 调整）
17. **Tab 结构 4 个**：今日运势 / 深度解析 / 合盘 / 我的（新增"我的"含多命盘管理 / entitlements / 设置 / 关于）
18. **Onboarding 保留现有 4 页设计**：WelcomePage（背景图 + 印章「玄」+ 经文）/ StancePage / PrivacyPage / StartPage。`hasSeenOnboarding` 已实现首启动 flag

**P1/P2 未决（不阻塞开工）**：
21. **喜忌规则引擎权重**：得令/得地/得势的权重值需要标定（spike 阶段跑 50 个真实命盘）
22. **从格检测阈值**：决策 1b 的初值（专旺 ≥6/8、从格 ≥5/8）需用真实命盘验证

**已关闭的 P1/P2 项**（保留索引，不占未决编号）：
- ~~每日运势冷启动 UX~~ ✅ 已拍板（2026-08-01 grill-me 决策 #14 配套）：瞬时显示流日基本信息（流日柱/冲/黄历宜忌，0 延迟）+ AI 总览异步流式追加（3-5s）。已并入 §Module Specifications §3
- ~~CI/CD~~ ✅ 已拍板（2026-07-13）：选 **GitHub Actions**。详见 §Distribution Plan
- ~~19. 大运第一步（童限）展示~~ ✅ 已关闭（2026-08-09）：选**跳过 index=0**。后端 `backend/app/engine/luck.py` 已跳过 `ganZhi=""` 童限项，测试 `test_bazi_calculate.py` / `test_dui_pan.py` 验证；iOS `LuckPillarsTimeline.swift` 防御性二次过滤
- ~~20. lunar_python 同步库 × FastAPI async~~ ✅ 已实现：排盘调用已用 `starlette.concurrency.run_in_threadpool` 包（详见 backend 排盘代码）
- ~~23. 城市经度表数据源~~ ✅ 已关闭（2026-08-09）：选**自己整理**。`BirthFormView.swift` `CityList.cities` 50+ 个城市(中国一线/省会/重要城市 + 海外主要城市)，未引入外部 cities.json 依赖

**已清理的 doc drift**（2026-08-09 PR #12 完成）：
- ~~§Visual Design Tokens 旧黑金色板~~ ✅ 已清理，本节改为引用 `DESIGN.md` §Color
- ~~§V1 Minimum Viable Aesthetic "金底深色 + ZCOOL XiaoWei"~~ ✅ 已清理，本节改为已实现范围清单

## Success Criteria

- TestFlight 可用，三模块跑通端到端
- 排盘确定性：同一输入跑 100 次，结果完全一致（含规则快照）
- **对盘验证（双重 ground truth）**：
  - **lunar_python 测试套件**（30-50 个用例自带答案）：我们的封装输出 = 测试套件期望答案，四柱/十神/纳音/大运 100% 一致
  - **问真八字 App 抽样**（5-10 个真实命盘）：与行业标杆 100% 一致（注意 `sect=1` 默认值）
- AI 命书：包含五行分析、十神配置、神煞提示、大运流年走势、后端给出的喜忌，无硬性格局结论
- 首次使用（B2 流）到落地今日运势：瞬时层（流日柱/冲/黄历）< 1 秒，AI 总览流式完成 < 5 秒（2026-08-01 决策更新：不再测 "首次到出深度解析"，深度解析改为 β 点击触发）
- 深度解析 β 点击触发后：免费 2 章 < 15 秒（~10s AI + 渲染）

## Distribution Plan

> 2026-07-13 拍板。原 Open Question 12（CI/CD 选型）结论并入本章节，集中描述 CI + TestFlight 发布路径。操作级细节见 repo 根 `README.md`、`docs/archive-testflight.md`、`docs/testflight-seed-users.md`。

### CI/CD 选型：GitHub Actions

| 维度 | Xcode Cloud | GitHub Actions（选） |
|---|---|---|
| 与 Xcode 集成 | 原生 | 写 YAML |
| 后端 pytest | ❌ 完全管不到 | ✅ ubuntu 跑 |
| 一站式覆盖 backend + iOS | 不行 | 单 workflow 双 job |
| 计费（私有 repo） | 25 compute min/mo 免费 | Free 2000 min/mo，macOS runner 10x 计费 |

**选 GitHub Actions 的理由**：本项目有 FastAPI 后端，Xcode Cloud 无法覆盖 backend pytest；单 workflow 同时跑 backend（ubuntu）+ iOS（macos）符合双端形态。

### CI workflow（`.github/workflows/ci.yml`）

| Job | Runner | 触发 | 做什么 |
|---|---|---|---|
| `backend-test` | `ubuntu-latest`（1x 计费） | 每次 push + PR | `pip install` + `pytest -q` |
| `ios-build` | `macos-latest`（10x 计费） | `ios/**` 或 ci.yml 变更 | `xcodebuild build CODE_SIGNING_ALLOWED=NO`（编译检查，不签名） |

**前置条件（用户必须先做）**：iOS scheme 当前未 Shared（`xcshareddata/xcschemes/` 不存在）。用户必须在 Xcode → Product → Scheme → Manage Schemes 勾 Shared，并 commit `QiCompass.xcscheme` 到 repo，否则 CI `xcodebuild -scheme QiCompass` 找不到 scheme。

**省 macOS minute 策略**（私有 repo 关键，macOS runner 10x 计费）：
- 首选：repo 设为 **public**（macOS 免费、无限制）
- 私有降级：iOS job 仅在 `ios/**` 或 ci.yml 变更时跑（见 ci.yml 的 `detect-ios-changes` job，原生 bash 实现，零第三方 action）；backend 跑在 ubuntu（1x）每次都跑
- 接近上限：升级 GitHub Pro（$4/mo → 3000 min）

**CI 不做的事**：不做 signing/archive/upload（本地手动或后续 release workflow）；不跑 iOS unit test（目前无）；不自动上传 TestFlight（side project 阶段手动）。

### TestFlight 发布路径（手动 archive 主路径）

完整步骤见 `docs/archive-testflight.md`，操作流：
1. **前置**：Apple Developer Program 会员（$99/年）+ Xcode 选 Signing Team（填 `DEVELOPMENT_TEAM`，当前为空）+ Bundle ID `com.qicompass.app` 注册 + App Store Connect 创建 App
2. **递增 build number**：每次上传前 `CURRENT_PROJECT_VERSION` +1（Apple 强制），否则拒收
3. **Archive**：Xcode → Any iOS Device → Product → Archive → Distribute App → App Store Connect → Upload
4. **Processing**：Apple 服务端处理 ~15-30 min → TestFlight 标签页可见
5. **邀请 tester**：外部测试组，首次 build 需 beta review（~1 天）

### 种子用户（5 人，外部测试组）

详见 `docs/testflight-seed-users.md`。选外部测试组（非内部）：只需 email 不占 Team 席位，代价首次 build 需 beta review。反馈主推 TestFlight 内置反馈（自动带截图 + build 号 + 设备信息），SLA：单人开发 48h ack / 1 周集中回复。

### v1 不做的事（Distribution 相关）

- CI 自动 upload TestFlight（secrets 维护成本 + macOS archive 时间，side project 一周一次手动更简单）
- 内部测试组（tester 必须在 Apple Team，占席位 / 权限风险）
- TestFlight 公开邀请链接默认启用（泄露则任何人可装，默认关闭，需要时临时开）
- App Store 正式上架（TestFlight 内测验证后再说）

## Next Steps

1. ~~库选型 spike~~ ✅ 完成（lunar_python 1.4.8，所有期望字段已验证）
2. ~~plan-eng-review P0~~ ✅ 完成（2026-07-10，D1/D2/D3 三项锁定）
3. ~~plan-eng-review P1~~ ✅ 完成（2026-07-10，神煞工作量/iOS 17.2/对盘数据源三项锁定）
4. ~~后端排盘原型~~ ✅ 完成（30 用例对盘通过：库层 20 + 封装层 10）
5. ~~喜忌规则引擎~~ ✅ 完成（扶抑 + 调候 + D3 从格检测）
6. ~~神煞查表~~ ✅ 完成（《三命通会》20 个神煞）
7. ~~三模块 + 付费 + 可观测性~~ ✅ 完成（深度解析 / 合盘 / 每日运势 / M3 付费墙 / iOS 全量日志）
8. ~~CI/CD + TestFlight 基础设施~~ ✅ 完成（GitHub Actions，详见 §Distribution Plan）
9. ~~2026-08-01 grill-me 战略 review~~ ✅ 完成（详见 §Open Questions §2026-08-01 锁定段）
10. **B2 onboarding 重构**（中等）：RootTabView 改 default Tab = `.dailyFortune` + 加 `.profile`（我的）Tab + onboarding CTA 后接 BirthFormView 强制轻注册 + 表单提交后落地今日运势（不跑深度解析 AI）。代码 diff 见 `STRATEGIC_DIFF.md`
11. **深度解析 β 点击触发重构**（中等）：DeepAnalysisView / ViewModel 从 auto-generate 改为 click-to-generate（"生成免费解读"按钮），加 chart 顶部 deterministic anchor sentence
12. **三模块 prompt voice 重写**（中等）：`backend/app/ai/prompts.py` 5 个模板按 §AI Voice 规范 重写。bump `PROMPT_VERSIONS` 让老缓存自动失效。**必须用真实命盘 spike 验证**：跑 20 个盘看输出 voice 是否落地 Medium / Medium-deep，长句占比 < 20%
13. **今日页 UI Medium 重排**（小）：DailyFortuneView 重排——AI 总览压到 50-80 字 / 宜/忌升为主视觉锚点 / 12 时辰保持默认折叠。参 §Module Specifications §3
14. **合盘页 UI Medium 重排**（小）：CompatibilityView 同 Medium 节奏调整
15. **MVP 视觉打磨**（3-5 天）
16. **TestFlight 内测**（流程见 §Distribution Plan）
17. **根据真实命书质量迭代 prompt**

**移到 v2 backlog**（2026-08-01 决策）：
- 每日一问（详见 `MONETIZATION.md` Slice M5 标记）

**预先存在的 doc drift 待清理**（不在本次 grill 范围）：
- §Visual Design Tokens + §V1 Minimum Viable Aesthetic 还是旧黑金色板，与 DESIGN.md 决策矛盾。下次视觉相关 slice 起手时清理

## V1 Minimum Viable Aesthetic

> **2026-08-09 清理**：本节原写"金底深色（不可协商）+ ZCOOL XiaoWei 显示字体"，与 `DESIGN.md` 决策的"极浅暖白 paper + Songti SC 系统衬线"**直接矛盾**。
> V1 视觉方向已锁定为"现代东方极简 · 宋瓷气质"，详见 `DESIGN.md` §现代东方极简装饰核心。
> 落地范围（已实现）：
> - 8pt 基准网格 + 圆角 4pt 克制层级 + 0.5pt hairline 分隔
> - 朱砂 / 墨青 / 黛蓝 三强调色克制使用（CTA + 当前柱 + 吉神）
> - Songti SC + PingFang SC 双字体分工（标题/八字 vs 正文）
> - Dark mode 墨夜瓷釉（Light/Dark 双值 token，PR #9 落地）
> - 淡入过渡（fadeIn / riseIn modifier，不做粒子/笔锋/烟雾）
> - 触感反馈（UIImpactFeedbackGenerator.medium 在 CTA + 错误重试）
>
> 后期迭代 backlog（v2+）：粒子、笔锋、烟雾、SVG 动画

## Future Considerations（v2+，不在 v1 数据模型里）

- 紫微斗数（独立立项）
- 流月、流年深度运势
- 账号系统 + 云端同步（合盘邀请另一半需要）
- 严谨格局引擎（基于 v1 用户反馈立项）
- 英文国际化
- 命盘导出图片分享
- 多人命盘管理（v1 已通过 UserSnapshotLink 支持，UI 进 v2）
