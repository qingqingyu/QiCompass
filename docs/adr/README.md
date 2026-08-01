# Architecture Decision Records

QiCompass 的关键架构与算法决策。每条记录"为什么这样定" — 不是写文档凑数。

详细命理算法规范见 `../命理引擎设计决策.md`,付费系统见 `../../MONETIZATION.md`,视觉系统见 `../../DESIGN.md`。

## Index

| # | Title | Date | Status |
|---|---|---|---|
| [0001](0001-lunar-python-as-bazi-engine.md) | lunar_python 作为后端权威排盘库,客户端不做历法 | 2026-07-09 | accepted |
| [0002](0002-zi-hour-rule-sect-1.md) | 强制 `setSect(1)` — 子时换日(产品默认) | 2026-07-09 | accepted |
| [0003](0003-skip-dayun-index-0-tongxian.md) | 大运 `index=0` 童限跳过,前端从 `index=1` 起 | 2026-07-09 | accepted |
| [0004](0004-fuyi-tiaoshou-deterministic-xiji.md) | 喜忌 = 后端确定性规则引擎(扶抑 + 调候),LLM 只润色 | 2026-07-09 | accepted |
| [0005](0005-shensha-20-fixed-list.md) | 神煞 = 20 个固定清单,《三命通会》单一来源 | 2026-07-09 | accepted |
| [0006](0006-geju-cut-v1-fuzzy-narrative.md) | 格局判定 v1 砍掉,LLM 模糊叙事 | 2026-07-09 | accepted |
| [0007](0007-congge-threshold-honest-degradation.md) | 从格检测 = 简单阈值 + 诚实降级(决策 1b / D3) | 2026-07-10 | accepted |
| [0008](0008-chartsnapshot-content-addressing.md) | ChartSnapshot 内容寻址 + schema/identity 分离(决策 3 / 3b / D1) | 2026-07-10 | accepted |
| [0009](0009-ai-cache-two-tier.md) | AI 解读缓存 = 客户端 SwiftData + 后端 SQLite 两级(决策 4 / D2) | 2026-07-10 | accepted |
| [0010](0010-ai-provider-single-no-fallback.md) | AI provider 单选(anthropic \| openai),不自动 fallback | 2026-07-09 | accepted |
| [0011](0011-compatibility-qualitative-no-score.md) | 合盘定性不给数字分,4 维评估 + 流年同步标签 | 2026-07-09 | accepted |
| [0012](0012-daily-fortune-on-demand-24h.md) | 每日运势按需生成 + 24h 缓存,不用 Background Tasks | 2026-07-09 | accepted |
| [0013](0013-monetization-consumable-iap-per-hash.md) | 付费 = 消耗型 IAP per-content_hash,不做订阅 | 2026-07-18 | accepted |
