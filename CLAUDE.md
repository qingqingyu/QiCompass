# QiCompass — 玄机问道

AI 八字命理 iOS App：深度解析 / 合盘 / 每日运势 三模块。

## 关键文档

- `bazi-app-design-doc.md` — 主设计文档（架构 / API 契约 / SwiftData / prompt 模板 / Next Steps）
- `命理引擎设计决策.md` — 命理层决策（决策 1 喜忌 / 决策 2 神煞 / 决策 3 ChartSnapshot / 决策 3b Schema 演化 / 决策 4 AI 缓存 / 决策 1b 从格边界）
- `archive/` — 旧"玄机问道"卷轴方案归档（参考用，不复用）
- `DESIGN.md` — 视觉设计系统事实源(美学 / 色板 / 字体 / 间距 / iOS SwiftUI 落地计划)
- `USER_STORIES.md` — 用户故事 + 验收标准 + 旅程地图(review 依据)

## 全局约束（继承 ~/.claude/CLAUDE.md）

- **Git commit 三段式**：每个 commit 必须含 Description body，覆盖 Why（动机）/ What（改了哪些函数/类/文件）/ Impact（设计影响）
- **错误显式传播**：不静默吞异常，该报错就报错，该向上抛就向上抛。禁止空 catch / 吞异常 / 用默认值掩盖失败
- **不擅自加依赖**：引入任何新库/框架/外部依赖前必须征得同意。提出时说明：引入理由 / 替代方案 / 不引入的代价

## 项目特定约束

### 八字计算必须确定性

- 同一输入永远同一输出（含 `calcRuleSnapshot` 规则快照）
- 所有排盘走后端 `lunar_python`，客户端不做历法计算
- `lunar_python` **强制 `setSect(1)`**（库默认 `sect=2` 早晚子时，与产品决策"默认 23:00 换日"冲突）
- 大运 `index=0` 的 `ganZhi=""` 是童限过渡，前端跳过，从 `index=1` 开始展示

### LLM 边界：只润色不判断

- **喜忌**：后端确定性规则引擎（扶抑法 + 调候法 + 从格检测 D3），LLM 只润色话术，**禁止**自行推断喜忌
- **格局**：MVP 砍掉，LLM 用"命局呈现××倾向"模糊叙事，**禁止**给出"正官格 / 偏印格"等硬分类结论
- **神煞**：20 个固定清单（11 吉 + 9 凶），《三命通会》单一来源，自写查表（库不给）
- **从格检测**：3-4 条 if 检测特征（专旺：日主同气 ≥6/8；从格：日主孤立 + 某行 ≥5/8），命中输出 `day_master_strength="special_pattern"`，喜忌留空，LLM 诚实告知

### prompt 三边一致性（2026-08-14 拍板）

- prompt 文本单一事实源在 backend（`app/ai/prompts.py`），iOS 与 promo-site（`tmp/promo-site/`，gitignore）都只是消费者；但**上下文字段映射**有三份实现（backend `REQUIRED_FIELDS` / iOS `PromptContextBuilder*.swift` / promo `context_builder.py`），v1 module 清单也是三处各写
- **强制**：动了以下任一文件，必须跑 `python3 tools/check_prompt_sync.py` 且 PASS 才算完成——backend `app/ai/prompts.py`（REQUIRED_FIELDS / PROMPT_VERSIONS / 模板）、iOS `PromptContextBuilder*.swift` / `ModuleDefinitions.swift`、promo `context_builder.py` / `v1_chain.py`
- 校验内容：三模块 REQUIRED ⊆ builder keys（iOS 静态提取，promo 运行时调 builder）+ v1 module ID 三边相等；promo 缺失（CI 场景）自动 SKIP
- 不接 GitHub Actions（用户工作流本地优先，2026-08-14 决定），拦截靠本规则

### 城市数据库守护栏（2026-08-15，城市搜索 S06）

- **强制**：动了 `tools/build_city_db.py` / `tools/city-data/`（curated_aliases.tsv / golden_queries.json / countries_zh.tsv）/ `cities.sqlite` / iOS `CitySearchEngine.swift` 排序逻辑任一，必须全过才算完成：
  1. `python3 tools/build_city_db.py`（数据或脚本变更时重跑，产出 byte-identical）
  2. `python3 tools/check_city_db.py` PASS（结构 / manifest hash / 抽查）
  3. `python3 tools/check_golden_queries.py` PASS（全量条目 ≥80，XCTest 前的快速预检）
  4. iOS `GoldenQueriesTests` PASS（读同一份 golden_queries.json）
- 搜索质量缺口修复路径：优先补 `curated_aliases.tsv` 回管线重建；**禁止**为单条 query 改排序公式特例（排序公式变更必须显式过全量 golden 表）

### Prompt 回归守护栏（2026-08-18，evalkit S06）

- **强制**：动了 `app/ai/prompts.py` 的 M0-M7 模板（`m0_structure` ~ `m7_manual`）任一，必须 `cd backend && python -m evalkit.runner` 跑一轮且**无 regression**（退出码 0）才算完成
- 改模板必须同时 bump 对应 `PROMPT_VERSIONS`（老缓存自然失效，同时让 run 身份可辨认；evalkit 响应缓存按渲染后 prompt hash 失效，只重跑改动模块及下游）
- 有 regression 的正确处理：`cd backend && ./eval.sh` 起 UI（127.0.0.1:8899）看退化清单逐条判断——真退化就改模板，判据误报就修 `evalkit/checks/`；**禁止**直接改 BASELINE 掩盖退化
- 首轮基线未定（真实跑 20 盘 × 8 模块 = 160 次调用 + L2 failure 全量人工复核 + S05 裁判校准，属真人步骤）；基线定了之后 `backend/evalkit/runs/BASELINE` 进 git
- L3 裁判配置：`JUDGE_PROVIDER` / `JUDGE_MODEL` / `JUDGE_API_KEY`（默认回落 `AI_*`）；真实 run 默认开裁判，`--skip-judge` 跳过
- 不接 GitHub Actions（对齐 2026-08-14「本地优先」决定），拦截靠本规则
- 事实源：`docs/prompt评测机设计决策.md`（含实施偏差记录）+ `docs/prompt评测机-slices/`

### SwiftData

- 最低 iOS 17.2（17.0/17.1 SwiftData `@Relationship` 有 crash）
- `IPHONEOS_DEPLOYMENT_TARGET = 17.2`
- **ChartSnapshot 用 D1 设计**：`contentHash`（按出生信息算，**不含** schema_version）+ `schemaVersion` 独立字段 + `payload` JSON Data 承载易变结构（pillars/十神/纳音/神煞/喜忌/luck_pillars）
- **不用** VersionedSchema / SchemaMigrationPlan（D1 减轻依赖，演化靠 JSON payload + lazy 重算）

### AI 解读缓存（D2）

- 客户端 SwiftData `InterpretationCache` + 后端 SQLite 两级缓存
- 缓存键：`(content_hash, module, prompt_version)`，每日运势多一维 `target_date`
- prompt 改 → `prompt_version +1` → 老缓存自然失效（desired behavior）
- **不做** singleflight / Redis（v2 再说）

### 后端

- FastAPI + `lunar_python`（同步 CPU-bound 库，用 `anyio.to_thread.run_sync()` 或 `starlette.concurrency.run_in_threadpool` 包，避免阻塞 event loop）
- 排盘调用 + AI 解读调用都走后端，API key 不进客户端

### 测试策略

- **对盘 ground truth**：`6tail/lunar-python` 仓库 `test/` 目录 22 个测试文件（含 `LunarTest.py` 完整 `toFullString` 断言）作为主数据源
- 辅以问真八字 App 抽样 5-10 个真实命盘做行业标杆对标
- 三层对盘验证：封装层 / 库层 / 行业层

## 不做的事（v1 范围外，明确砍掉）

- 六爻 / 灵签 / 卷轴命运地图（旧"玄机问道"方案已归档到 `archive/`）
- 格局判定规则引擎（延后立项，等付费用户反馈）
- 紫微斗数 / 流月流年深度运势 / 账号系统 + 云同步 / 英文国际化 / 命盘导出图片（v2+）
- 多人命盘管理 UI（v1 通过 `UserSnapshotLink` 数据层支持多 snapshot，UI 进 v2）
- Background Tasks 预生成每日运势（iOS 不可靠，改用按需生成 + 24h 缓存）

## 当前阶段

设计文档已完成并经过 plan-eng-review（P0 D1/D2/D3 + P1 神煞工作量/iOS 17.2/对盘数据源 已锁定）。
库选型 spike 已完成（`lunar_python` 1.4.8 实测字段对照表已校准 API 契约）。后端排盘核心 slice 已实现（`backend/`,30 用例对盘通过:库层 20 + 封装层 10）。
准备进入下一 slice,按 10 个 vertical slice 推进(见 `bazi-app-design-doc.md` Next Steps)。
2026-08-18:prompt 回归评测机 evalkit 已落地（S01-S06,`backend/evalkit/`,pytest 全绿;见上方「Prompt 回归守护栏」与 `docs/prompt评测机设计决策.md`）,首轮真实基线待跑。

## Design System

**强制**:任何 UI / 视觉决策(颜色 / 字体 / 间距 / 圆角 / 动效)必须先读 `DESIGN.md`,偏离须用户明确批准。

**2026-08-26 换轨**:宋瓷暖白 → **水墨孤本**。参考屏与决策记录在 `docs/design-ref/shuimo/`(approved.json 为事实源)。

关键约束(摘自 `DESIGN.md`):

- **美学方向**:水墨孤本(禅意水墨极简),不是国内命理黑金套路
- **Memorable Thing**:"专业不忽悠,不像算命软件" — 宣纸上的焦墨圆、一枚朱印、一行竖排楷体
- **色板**:`#E7E2D5` 国画旧宣纸(主背景,2026-08-31 换轨,原冷宣纸 `#F3F1EC`) / `#17161A` 焦墨(CTA 底,`inkDeep`;暗色反转) / `#A83226` 印章朱红(`cinnabar`,**仅印章级小元素:SealStamp/付费标/聚焦线/当前时辰点,禁止 CTA 与大面积**) / `#2F5E4A` 墨青(吉) / `#1C1B1E` 浓墨文字;Dark = 夜宣纸(dyn 双值保留)
- **字体**:Kaiti SC(楷体,全展示层,`Font.custom("Kaiti SC")`,iOS 自带不打包) + SF Pro Text tabular-nums(数字) + latinCaps 大字距小写标(QICOMPASS)
- **品牌指纹**:墨圆 EnsoView / 朱印 SealStamp / 竖排 VText / 大写数字编号(壹-捌)
- **布局**:卡片让位 hairline(ink@18%);dashed hairline 专用于锁框/临时态;Capsule 只留 chip;CTA radius 5
- **动效三式**:ink-in(blur 7→0) / stamp(1.9→1 spring) / breathe(7s);reduce-motion 全降级
- **渐变**:禁止 `backgroundGradient` 渐变背景,纯色 only
- **AI slop 反模式**:不堆叠黑金/卷轴纹/古纹装饰,不用 Inter/Roboto 系列字体,朱红不做大色块

iOS 落地代码骨架见 `DESIGN.md` § iOS SwiftUI 落地计划(token 换值 + 散点修复 + 四阶段优先级 + 验收清单)。**新 .swift 文件须 pbxproj 4 处登记一致 24 位 ID**(objectVersion 56 传统结构,漏登记=静默不编译)。

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
