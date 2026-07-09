# Design: 玄机问道 — AI 八字深度解析 / 合盘 / 每日运势

Generated on 2026-07-09 (revised after lunar-python spike)
Repo: QiCompass (greenfield)
Status: DRAFT — API 契约已用 lunar-python 实测字段校准
Mode: Builder

> **配套文档**：`命理引擎设计决策.md` 含喜忌/神煞/ChartSnapshot 三项核心命理决策的详细规范。本设计文档与之分工：本文件管"产品形态 + 工程实现"，决策文件管"命理算法"。

## Problem Statement

原生 iOS App，把中国传统八字命理做成三个深度模块：**深度解析**（单人命盘）、**合盘**（两人兼容性）、**每日运势**（流日 + 流时指引）。所有排盘计算在后端用 `lunar_python`（6tail 出品，纯 Python 无依赖）做**确定性**计算，命书解读由 Claude API 生成。客户端只渲染，不算历法。

目标用户：海外华人（25-45）+ 对东方文化好奇的西方人（18-35）。收敛聚焦：从"三占卜工具 + 卷轴自传"改为"八字深度垂直"——做得更深，而不是更宽。

## What Makes This Cool

三个模块共享同一份用户命盘数据——做完一次深度解析，合盘和每日运势都能复用。每日运势是高频回访入口（每天子时更新），合盘是社交裂变入口（两人才能完成），深度解析是基础。宫观古董美学继承自旧方案，V1 先上 MVP 视觉。

## Constraints

- 原生 iOS（Swift/SwiftUI，iOS 17+）
- 后端代理封装 Claude API + lunar_python，API key 不进客户端
- 八字计算必须**确定性**：同一输入永远同一输出
- 三模块：深度解析 / 合盘 / 每日运势。不做六爻、灵签、卷轴
- 单人 side project

## Premises

1. **八字垂直 > 多占卜横向**
2. **后端权威计算 + 客户端纯渲染**。所有排盘走后端，客户端不算历法
3. **每日运势依赖已存档的命盘**。用户必须先做深度解析生成命盘，每日运势 = 命盘 × 流日柱
4. **合盘前置**：用户自己的命盘必须已存档，对方命盘可临时输入（"半游客模式"）
5. **格局判定延后**（详见 `命理引擎设计决策.md` §4）
6. **感觉即产品**——宫观古董美学是核心差异化

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│             iOS App (SwiftUI)               │
│                                             │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐  │
│  │ 深度解析  │ │  合盘    │ │ 每日运势    │  │
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
│  │ lunar_python   │  │ Claude API       │   │
│  │ 八字计算       │  │ 命书解读          │   │
│  │ (确定性)       │  │                  │   │
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
    "library": "lunar_python 1.3.6",
    "sect": 1,  // 子时换日规则
    "zi_hour_rule": "zi_next_day",
    "true_solar_city": "北京",
    "true_solar_longitude": 116.41,
    "true_solar_offset_minutes": 3.2,
    "calculated_at": "2026-07-09T12:00:00+08:00"
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
  "module": "bazi_deep" | "compatibility" | "daily_fortune",
  "context": { ... 排盘结构化数据（含喜忌、神煞等后端确定性输出） ... },
  "question": null
}
Response: { "interpretation": "... 中文命书 ..." }
```

**GET /api/health**
```json
Response: { "status": "ok", "lunar_python_version": "1.3.6", "model": "claude-sonnet-4-6" }
```

## Module Specifications

### 1. 深度解析（单人命盘）

- **输入**：出生日期（DatePicker）、出生时辰（时辰选择器）、性别、出生城市（从城市经度表选）、子时规则（默认 zi_next_day，可改 zero_oclock）
- **计算**：后端 `lunar_python` 排盘，强制 `setSect(1)` 默认值
- **显示**：
  - 顶部：命主信息 + 真太阳时（标注与输入时间的偏差分钟数）
  - 四柱表：年/月/日/时四列，每列天干上 / 地支下，十神标在天干旁边，纳音小字在底部，藏干 chip 列表
  - 命宫/身宫/胎元小卡片（lunar_python 自带）
  - 五行平衡条形图
  - **喜忌区域**（决策 1）：`favorable_elements` + `unfavorable_elements`，标注"扶抑+调候"算法
  - 大运横向时间轴（跳过 index=0 童限）
  - 神煞 chip 列表（决策 2，20 个固定清单）
  - 流年/流日/流时当前状态小卡片
  - AI 命书区：300-500 字（MVP 压缩 30%）
- **持久化**：按决策 3 内容寻址生成 `ChartSnapshot`，不可变

### 2. 合盘（两人兼容）

- **输入**：A 盘从已存档 snapshot 选（必须），B 盘可临时输入或选已存档
- **context 选项**：general / marriage / business（**不影响计算**，只影响 LLM 命书侧重）
- **计算**：两个单人排盘 + 定性合盘描述 + 流年同步性
- **显示**：
  - 双盘对比：A 盘左、B 盘右，四柱并排
  - 定性卡片（决策 A2）：五行互补、日主关系、生肖匹配、地支合冲——**只给定性描述，不给数字分**
  - 流年同步表：未来 3 年定性同步性
  - AI 合盘解读：400-500 字
- **持久化**：合盘结果按 `(min(a_hash, b_hash), max(a_hash, b_hash), context)` 内容寻址缓存

### 3. 每日运势（高频回访入口）

- **前置**：必须先完成深度解析生成命盘（无命盘显示 CTA）
- **触发**：App 打开按需生成 + 24h 缓存（决策 A3，iOS Background Tasks 不可靠）
- **显示**：
  - 顶部：今日日期（农历 + 公历）+ 今日流日柱 + 流日对日主的关系（如"偏官日"）+ 流日冲
  - 中部：今日总览（AI 生成 ~150-200 字）
  - 12 时辰条：默认折叠，展开后显示每个时辰的流时柱 + 关系 + 冲。**当前时辰高亮**，手动下拉刷新（决策 B）
  - 通用黄历宜忌：lunar_python `getDayYi/Ji`（所有人一样，不个性化）
  - 底部：明日预告
- **缓存**：当日生成后缓存到 SwiftData，24h 内不重算
- **历史**：可回看过去 7 天（决策 B）

## 排盘规则（Deterministic Calculation Rules）

详细规范见 `命理引擎设计决策.md`。摘要：

1. **子时换日**：默认 `sect=1`（子时属次日），可配置 `sect=2`（早晚子时）。规则随盘存档
2. **真太阳时**：城市经度表 + 均时差。边界提示
3. **十神**：直接用 `lunar_python` 的 `getXxxShiShenGan` / `getXxxShiShenZhi`（库自带，不必自己查表）
4. **喜忌**：后端确定性规则引擎，扶抑法 + 调候法（详见决策 1）
5. **格局判定**：MVP 砍掉，LLM 模糊叙事（详见决策 5）
6. **神煞**：20 个固定清单，《三命通会》单一来源，自写查表（详见决策 2）

## Data Model（SwiftData，按决策 3 内容寻址）

详细字段规范见 `命理引擎设计决策.md` §3。摘要：

```swift
@Model
class ChartSnapshot {
    @Attribute(.unique) var contentHash: String  // 内容寻址 ID
    var birthSolarTime: Date
    var gender: String
    var cityLongitude: Double
    var ziHourRule: String  // zi_next_day | zero_oclock
    
    var pillars: Data  // 四柱完整结构（含 gan/zhi/wuxing/hide_gan/shishen_gan/shishen_zhi/nayin/dishi/xunkong）
    var mingGong: Data
    var shenGong: Data
    var taiYuan: Data
    var elementBalance: [String: Int]
    
    // 决策 1 喜忌
    var dayMasterStrength: String
    var favorableElements: [String]
    var unfavorableElements: [String]
    var tiaoshouApplied: Bool
    
    var shensha: Data  // 决策 2 神煞列表
    var luckPillars: Data  // 跳过 index=0
    
    var calcRuleSnapshot: Data
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
class CompatibilitySnapshot {
    @Attribute(.unique) var compatibilityHash: String
    var personAHash: String
    var personBHash: String
    var context: String  // general | marriage | business
    var qualitativeAssessment: Data
    var syncedFortune: Data
    var interpretation: String?
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
    var cachedUntil: Date  // 24h
}
```

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
| 前端 | Swift 5.9+ / SwiftUI / iOS 17+ |
| 持久化 | SwiftData（VersionedSchema） |
| 字体 | ZCOOL XiaoWei（显示）/ 系统衬线（正文） |
| 触感 | UIImpactFeedbackGenerator |
| 后端 | Python FastAPI |
| 八字计算 | **lunar_python 1.3.6+**（已 spike 验证） |
| AI | Claude API（claude-sonnet-4-6）经后端代理 |
| 部署 | TestFlight → App Store |

## Visual Design Tokens

继承自旧方案（不变）：

| Token | 值 | 用途 |
|---|---|---|
| 背景 | `#0d0b08 → #12100d → #0a0c10` | 主渐变 |
| 主金 | `#c9a03c` | 强调、边框、按钮 |
| 亮金 | `#f5d785` | 标题、激活态 |
| 正文 | `#e8dcc8` | 命书、描述 |
| 木 | `#5d9b6b` | 木五行 |
| 火 | `#c04e3a` | 火五行 |
| 土 | `#b8881a` | 土五行 |
| 金 | `#8c836e` | 金五行 |
| 水 | `#3a7ca5` | 水五行 |

## Claude API Prompt 模板

### 深度解析

```
你是一位精通中国传统四柱八字命理的大师。请基于以下排盘数据进行深度命书解读。

命主：{gender}，出生于 {city}，真太阳时 {true_solar_time}

四柱：
- 年柱：{year_gan}{year_zhi}（{year_gan_element}/{year_zhi_element}），十神 {year_shishen_gan}，藏干 {year_hide_gan}
- 月柱：{month_gan}{month_zhi}（...），十神 {month_shishen_gan}
- 日柱：{day_gan}{day_zhi}（日主 {day_gan_element}），地支十神 {day_shishen_zhi}
- 时柱：{hour_gan}{hour_zhi}（...），十神 {hour_shishen_gan}

纳音：年 {year_nayin} / 月 {month_nayin} / 日 {day_nayin} / 时 {hour_nayin}
命宫：{ming_gong}（{ming_gong_nayin}）
神煞：{shensha_list}  // 决策 2 输出
五行统计：{element_balance}
日主旺衰：{day_master_strength}  // 决策 1 确定性输出
喜用五行：{favorable_elements}  // 决策 1 确定性输出，你只需润色
忌讳五行：{unfavorable_elements}
调候是否触发：{tiaoshou_applied}
当前大运：{current_luck_pillar}
当前流年：{current_year_pillar}

写作要求：
1. 日主旺衰、喜忌、神煞、大运流年走势
2. **重要：格局作为叙事概念模糊处理**，用"命局呈现××倾向"，**不得**给出"正官格/偏印格"等硬性分类
3. **重要：喜忌已由后端确定性给出，你必须严格按后端的 favorable/unfavorable 写**，不得自行推断或修改
4. 古朴典雅，引用术语配解释，面向有基础的海外华人用户
5. 约 300-500 字（MVP 压缩 30%）
```

### 合盘

```
你是一位精通八字合婚/合盘的大师。请基于以下两人命盘进行 {context_label} 合盘解读。

A 盘（{gender_a}，{city_a}，{birth_a}）：日主 {day_master_a}，{day_master_strength_a}，喜 {favorable_a}
- 年柱：{year_a} 月柱：{month_a} 日柱：{day_a} 时柱：{hour_a}
- 五行：{element_balance_a}

B 盘（{gender_b}，{city_b}，{birth_b}）：日主 {day_master_b}，{day_master_strength_b}，喜 {favorable_b}
- 年柱：{year_b} 月柱：{month_b} 日柱：{day_b} 时柱：{hour_b}
- 五行：{element_balance_b}

定性评估（后端已给，你负责展开）：
- 五行互补：{five_elements_assessment}  // 如"互补佳"
- 日主关系：{day_master_relation}  // 如"相生"
- 生肖匹配：{zodiac_match}  // 如"六合"
- 地支合冲：{branch_harmony}

流年同步性（未来 3 年）：
{synced_fortune_table}

写作要求：
1. 围绕 {context_label} 维度展开
2. 客观陈述五行互补、日主关系、地支合冲的具体表现
3. 流年同步性：指出同步进好运/坏运的年份
4. **绝对禁忌**：不得给出"必成 / 必分 / 必破财"等绝对结论
5. 约 400-500 字
```

### 每日运势

```
你是一位精通流日推断的命理师。请基于以下信息为命主解读今日运势。

命主：日主 {day_master}（{day_master_element}），{day_master_strength}
命局喜：{favorable_elements}  // 后端确定性输出
命局忌：{unfavorable_elements}

今日：{date}（农历 {lunar_date}）
今日流日柱：{day_pillar}（流日天干 {day_stem} 属 {day_stem_element}，流日地支 {day_branch} 属 {day_branch_element}）
流日对日主关系：{day_relation}（如偏官日 / 正印日）
流日冲：{day_chong}  // lunar_python getDayChong

12 时辰（按 zi_hour_rule 排序）：
{hour_pillars_with_relations}

通用黄历宜：{huangli_yi}
通用黄历忌：{huangli_ji}

写作要求：
1. 今日总览：流日对日主的生克影响（结合后端给出的喜忌），是否冲克命局、是否有贵人扶持
2. 个性化宜忌（结合命主命局，**不是通用黄历的复述**）：3-5 条
3. 情绪/状态提示：基于流日对日主的关系
4. 12 时辰强弱：简短点评（一句话/时辰）
5. 约 200-300 字 + 12 句时辰点评
```

## Open Questions

1. **产品名**：保留"玄机问道"（决策 B，MVP 跑通后再决定）
2. **付费模型**：MVP 全免费（决策 B）
3. **大运第一步（童限）展示**：跳过？还是单独标注"起运前"？
4. **神煞起法的代码化**：决策 2 的 20 个神煞要从《三命通会》代码化，工作量未估
5. **喜忌规则引擎的权重**：得令/得地/得势的权重值需要标定（spike 阶段跑 50 个真实命盘）
6. **城市经度表数据源**：自己整理 vs 用现成 cities.json

## Success Criteria

- TestFlight 可用，三模块跑通端到端
- 排盘确定性：同一输入跑 100 次，结果完全一致（含规则快照）
- 与问真八字 App 对盘：30 个标准测试用例，四柱、十神、纳音、大运 100% 一致（注意 `sect=1` 默认值）
- AI 命书：包含五行分析、十神配置、神煞提示、大运流年走势、后端给出的喜忌，无硬性格局结论
- 首次使用到出深度解析 < 30 秒
- 每日运势冷启动 < 5 秒（按需生成）

## Next Steps

1. ~~库选型 spike~~ ✅ 完成（lunar_python 1.3.6，所有期望字段已验证）
2. **后端排盘原型**（3-4 天）：FastAPI + lunar_python + `setSect(1)` + 内容寻址 ID + 跳过 index=0 童限
3. **喜忌规则引擎**（2-3 天）：扶抑 + 调候，50 个真实命盘标定权重
4. **神煞查表**（2-3 天）：《三命通会》20 个神煞代码化
5. **Prompt 验证 spike**（2-3 天）：20 个真实命盘跑深度解析 prompt，请懂命理的人审核输出质量
6. **Xcode 项目脚手架**（1 天）：SwiftUI + SwiftData + Tab 结构
7. **深度解析模块**（1 周）
8. **每日运势模块**（3-4 天）
9. **合盘模块**（1 周）
10. **MVP 视觉打磨**（3-5 天）
11. **TestFlight 内测**
12. **根据真实命书质量迭代 prompt**

## V1 Minimum Viable Aesthetic

继承旧方案：
- 金底深色（不可协商）
- ZCOOL XiaoWei 显示字体，系统衬线正文
- 淡入过渡（不做粒子/笔锋）
- 触感反馈
- 后期迭代 backlog：粒子、笔锋、烟雾、SVG 动画

## Future Considerations（v2+，不在 v1 数据模型里）

- 紫微斗数（独立立项）
- 流月、流年深度运势
- 账号系统 + 云端同步（合盘邀请另一半需要）
- 严谨格局引擎（基于 v1 用户反馈立项）
- 英文国际化
- 命盘导出图片分享
- 多人命盘管理（v1 已通过 UserSnapshotLink 支持，UI 进 v2）
