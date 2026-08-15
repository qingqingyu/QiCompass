# Reddit 种草帖(英文,草稿 v0.1)

> 目标 sub:r/bazi(核心)、r/ChineseAstrology、r/astrology 的 bazi 话题(慎发,版规严)。
> 铁律:**先贡献,后提及**。帖子本身要有独立价值,App 只是「我顺手做了个工具」。

## 人设

Independent developer studying BaZi seriously — built a deterministic engine + structured interpretation tool because everything else out there is either paywalled fortune-telling or vague content-farm apps.

## 帖子 1 · 工具分享型(r/bazi,首帖,不带链接)

**Title:** I got frustrated with BaZi apps that give different charts for the same birth time, so I built one with a deterministic engine

**Body(草稿):**

> Every app I tried had at least one of these problems:
> - Charts that change depending on who interprets them
> - "Master" framings with fatalistic language (注定-type talk)
> - Zero explanation of WHERE a conclusion comes from
>
> So I built QiCompass around three rules:
> 1. **Deterministic calculation.** True solar time correction, early/late Zi handling, same input → same chart, always. No vibes.
> 2. **Every claim cites the chart.** Ten Gods structure, hidden stems, element balance — each interpretation point traces back to a specific pillar.
> 3. **No fortune-telling language.** It describes structure (how you gain/spend energy, how you operate), not fate. Banned-words system literally blocks 必然/注定-type output.
>
> Happy to answer questions about the calculation decisions (true solar time, the 23:00 day-change rule, how I handle births during China's 1986–1991 DST era — that one trips up most apps).
>
> (App is in testing; not posting a link per sub rules — ask in comments if curious.)

**发帖备注**:DST 1986-1991 那句是技术钩子,评论区必有人问 → 回复里展开(见 copy-bank)。

## 帖子 2 · 知识干货型(r/bazi 或 r/ChineseAstrology)

**Title:** The 1986–1991 China DST problem in BaZi charts (and why your hour pillar might be wrong)

**Body 要点:**
- 中国 1986-1991 实行夏令时;这期间 4-9 月出生的人,钟面时间 ≠ 标准时
- 大多数工具直接按 UTC+8 算 → 绝对时刻差 1 小时 → 时柱可能整个错
- 正确做法:按出生年份的 IANA 历史时区规则取偏移(举例对比两张盘)
- 结尾一句:「This is fixable with historical tz data; most apps just don't bother.」

**配套图**:promo-site 生成同一人 DST 修正前/后两张盘对比图(强差异内容,自带传播性)

## 帖子 3 · 结构解读展示型

**Title:** I mapped my Ten Gods structure into a core loop — this framing finally made BaZi click for me

**Body 要点:**
- 用自己的盘(或编的盘)展示「十神主线三层 + A→B→A 能量循环」
- 配 promo-site 十神结构章截图(1080px,水印在)
- 讲清这套语言比「你今年犯太岁」有用在哪

## 评论区打法

| 对方说 | 回 |
|---|---|
| Link? | 按版规给 TestFlight/App Store 链接(已过审后);未过审给 waiting list 表述 |
| Isn't this just fortune telling? | 见 copy-bank §质疑应对 Q1 |
| How is this different from X app? | 列三点:确定性引擎/依据可追溯/禁宿命话术,语气平和不贬低 |
| Astrology is fake | 不争论。回「BaZi as a structured self-reflection framework is what we focus on — the tool doesn't claim prediction」然后止住 |

## 节奏

- 每帖间隔 ≥3 天,同一 sub 每周 ≤2 帖
- 帖前先在该 sub 攒 1-2 周评论历史(技术向回复),账号不能是「出厂即发广告」
