# 合盘「五行共振」章节改造 — 实施分割

Parent 设计事实源：`docs/合盘五行共振章节决策.md`（Q1-Q7 已 ACCEPTED 待实施）。
本文件为 to-issues 分割产物：3 个 AFK vertical slice，串行依赖，每个独立可 demo。

## 实施顺序

| Slice | 标题 | Blocked by | 一句话 |
|---|---|---|---|
| S1 | 「五行共振」章节替换（核心 tracer bullet） | 无 | paid/alias 第一章改名换内容 + prompt_version +1 + iOS 付费墙文案，端到端可 demo |
| S2 | 全局护栏（不预设关系类型） | S1 | 3 模板通用要求加护栏句 + 渲染测试断言 |
| S3 | 局部护栏（2 个高风险章节） | S2 | 基础相处模式 + 合作事业各加局部护栏 + 断言 |

## 全系列红线（每个 slice 内均有）

- **D4（合盘多选决策）**：每对独立 entitlement / 付费墙 / 后端计费零改动；module 名 `compatibility_free` / `compatibility_paid` 不变
- **LLM 边界（CLAUDE.md）**：只润色不判断——「五行共振」章的机制内容（谁补喜神/谁消耗/日主生克）以后端定性评估为锚，LLM 展开叙事，不新增判断维度
- **绝对禁忌不变**：「必成/必分/必破财」等禁词约束原样保留，本系列只加关系类型护栏，不动禁词
- **prompt_version 策略**：**S1 统一把 3 个 module（compatibility / compatibility_free / compatibility_paid）从 2 → 3，S2/S3 不再 bump**。理由：三 slice 是同一次产品迭代连续落地，S1 与 S3 之间用户几乎不可能生成并复用缓存，一次失效足够；避免三次 bump 造成免费用户多次扣全局池次数（缓存 miss → 重新调 API）
- **i18n**：iOS 新文案跟随现状中文硬编码（i18n plan Slice 3 统一补 key）
- **不做**：双轨模板 / 章节名改「磁场合拍」 / deep_analysis 爱情章节联动（backlog：姻缘独立模块）/ 客户端 ForbiddenWords 扩充（护栏在 prompt 源头，上线后抽查再定）

---

# S1 「五行共振」章节替换（核心 tracer bullet）

- **类型**: AFK
- **Blocked by**: 无 — 可立即开始
- **覆盖决策**: Q1（定位升级为两人磁场合拍）/ Q2（单轨替换，不拆双轨）/ Q3（章节名「五行共振」）/ Q4（内容维度与模板全文）/ Q6（付费墙文案）/ prompt_version 策略

## What to build

合盘 AI 解读付费第一章从「爱情深度」整体替换为「五行共振」，异性/同性统一单轨叙事；付费墙与 6 章提示文案同步；prompt_version +1 让老缓存自然失效。

「五行共振」章节模板全文（决策文档 §Q4 锁定，直接抄，勿改写）：

```
**第一章：五行共振**（200-300 字）
两人五行的生克共振：谁给谁补喜神、谁的旺相消耗对方、日主生克链路，
以及这些共振在两人互动中的体现。分 3-5 段，每段 2-3 短句。
每段聚焦一个具体共振点（滋养点 / 张力点 / 时间维度的稳定性）。
不预设关系类型（婚恋/友谊/合作），聚焦能量互动本身。
```

- 后端 `COMPATIBILITY_PAID_TEMPLATE` 第一章（原「爱情深度」）用上文替换
- 后端 `COMPATIBILITY_TEMPLATE`（alias 6 章版）第三章（原「爱情深度」）用上文替换，仅「第一章/第三章」序号按其在 alias 模板中的位置调整，内容一字不改
- `PROMPT_VERSIONS` 中 `compatibility` / `compatibility_free` / `compatibility_paid` 三个 key 全部 2 → 3（free 虽未改内容，一并升，见全系列红线 prompt_version 策略）
- 渲染测试：原断言「爱情深度」在 paid 渲染 prompt 中出现的改为断言「五行共振」；原断言「爱情深度」不在 free 渲染 prompt 中的改为断言「五行共振」不在 free prompt 中
- iOS `CompatibilityInterpretationSection` 两处文案：
  - 付费墙 `previewChapters` 首项「爱情深度」→「五行共振」，`title` →「五行共振·付费章节」
  - 6 章提示 →「6 章解读:基础相处 / 互补冲突 / 五行共振 / 合作事业 / 财运合拍 / 流年同步」

## Acceptance criteria

- [ ] `pytest` 渲染测试通过：paid 渲染 prompt 含「五行共振」章全文要素（补喜神/旺相消耗/日主生克链路/不预设关系类型句），不含「爱情深度」
- [ ] alias 模板渲染 prompt 同样含「五行共振」、不含「爱情深度」
- [ ] free 渲染 prompt 不含「五行共振」（该章是付费内容，不得泄漏到免费 2 章）
- [ ] `PROMPT_VERSIONS` 三 key 均为 3
- [ ] iOS 编译通过；付费墙章节列表显示 `["五行共振","合作事业","财运合拍","流年同步"]`，title「五行共振·付费章节」
- [ ] iOS 6 章提示文案含「五行共振」不含「爱情深度」
- [ ] module 名 / entitlement / 付费墙逻辑 / 后端 API 契约零改动（红线 D4）

## 实现锚点（现状快照 2026-08-14，实施以代码为准）

- `backend/app/ai/prompts.py:246` — `COMPATIBILITY_PAID_TEMPLATE` 第一章「爱情深度」
- `backend/app/ai/prompts.py:198` — `COMPATIBILITY_TEMPLATE`（alias）第三章「爱情深度」
- `backend/app/ai/prompts.py:43-45` — `PROMPT_VERSIONS` 三 key 现值 2
- `backend/tests/test_interpret_render.py:169,181` — 「爱情深度」断言（free not-in / paid in）
- `ios/QiCompass/QiCompass/Features/Compatibility/CompatibilityInterpretationSection.swift:56` — previewChapters + title
- `ios/QiCompass/QiCompass/Features/Compatibility/CompatibilityInterpretationSection.swift:107` — 6 章提示文案

## 红线与约束

- 模板全文逐字使用决策文档 §Q4 版本（决策性内容，实施不得自由发挥措辞）
- alias 模板第三章序号文案「第三章：五行共振」，其余与上文一字不差
- 不动免费 2 章、不动通用要求段（S2 范围）、不动其他 3 个付费章

## 测试

- `test_interpret_render.py` 断言替换（paid 含「五行共振」/ free 不含「五行深度」与「爱情深度」）
- 后端全量 `pytest` 无回归
- iOS `build-for-testing` 编译通过（本 slice 无新增 iOS 测试，纯文案）

---

# S2 全局护栏（不预设关系类型）

- **类型**: AFK
- **Blocked by**: S1（同文件顺序改，S1 先稳定章节结构）
- **覆盖决策**: Q5 全局护栏部分 / Q1 定位（叙事用「两人」）

## What to build

3 个合盘模板（`COMPATIBILITY_PAID_TEMPLATE` / `COMPATIBILITY_FREE_TEMPLATE` / `COMPATIBILITY_TEMPLATE`）的「通用要求」段，各加一句全局护栏（决策文档 §Q5 锁定文案）：

```
- 叙事用「两人」而非「情侣/夫妻/朋友/合伙人」；不预设关系类型（婚恋/友谊/合作/亲情）
```

- 插入位置：通用要求列表首项（最显眼，LLM 注意力最靠前）
- **不 bump prompt_version**（S1 已统一升至 3，见全系列红线策略）

## Acceptance criteria

- [ ] 3 个模板渲染后的 prompt 均含护栏句原文
- [ ] 护栏句位于通用要求段首项
- [ ] 渲染测试新增断言：3 个 module 的渲染 prompt 含「不预设关系类型」
- [ ] prompt_version 仍为 3（本 slice 不 bump）
- [ ] 后端全量 pytest 无回归

## 实现锚点（现状快照 2026-08-14，实施以代码为准）

- `backend/app/ai/prompts.py` — 3 个模板各自的「通用要求：」段（paid 约 :259 / free 约 :232 / alias 约 :210，S1 落地后行号会移位）
- `backend/tests/test_interpret_render.py` — 追加护栏断言

## 红线与约束

- 护栏句逐字使用决策文档 §Q5 版本
- 只加通用要求一处，不加章节内（章节内局部护栏是 S3 范围）
- 不动 iOS（护栏纯后端 prompt 层）

## 测试

- 渲染测试：3 module × 护栏句存在断言
- 后端全量 pytest

---

# S3 局部护栏（2 个高风险章节）

- **类型**: AFK
- **Blocked by**: S2（同文件顺序改）
- **覆盖决策**: Q5 局部护栏部分

## What to build

给 LLM 最易跑偏的 2 个章节各加一句针对性局部护栏（决策文档 §Q5 锁定文案）：

1. **基础相处模式**（免费第 1 章，`COMPATIBILITY_FREE_TEMPLATE`）追加：
```
聚焦互动节奏本身，不写同居/伴侣等具体生活场景预设。
```
2. **合作事业**（付费第 2 章 + alias 第 4 章）追加：
```
聚焦公共目标层面的协作（涵盖夫妻共业/朋友共谋/合伙人共事），不写具体关系预设。
```

- 每句追加在对应章节指令末尾（新起一行）
- **不 bump prompt_version**（S1 已统一升至 3）

## Acceptance criteria

- [ ] free 渲染 prompt 含「不写同居/伴侣等具体生活场景预设」
- [ ] paid / alias 渲染 prompt 均含「涵盖夫妻共业/朋友共谋/合伙人共事」
- [ ] 中低风险章节（互补冲突 / 财运合拍 / 流年同步 / 五行共振）不加局部护栏（避免过度工程，决策文档 §Q5 明确）
- [ ] prompt_version 仍为 3
- [ ] 后端全量 pytest 无回归

## 实现锚点（现状快照 2026-08-14，实施以代码为准）

- `backend/app/ai/prompts.py` — `COMPATIBILITY_FREE_TEMPLATE` 第一章「基础相处模式」（约 :224）/ `COMPATIBILITY_PAID_TEMPLATE` 第二章「合作事业」（约 :251）/ `COMPATIBILITY_TEMPLATE`（alias）第四章（约 :202；S1/S2 落地后行号移位）
- `backend/tests/test_interpret_render.py` — 追加 2 句局部护栏断言

## 红线与约束

- 2 句护栏逐字使用决策文档 §Q5 版本
- 只改这 2 个章节，其余章节不动
- 不动 iOS / 不动通用要求段（S2 已完成）

## 测试

- 渲染测试：免费局部护栏断言 + paid/alias 合作事业护栏断言
- 后端全量 pytest
