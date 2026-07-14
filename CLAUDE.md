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

## Design System

**强制**:任何 UI / 视觉决策(颜色 / 字体 / 间距 / 圆角 / 动效)必须先读 `DESIGN.md`,偏离须用户明确批准。

关键约束(摘自 `DESIGN.md`):

- **美学方向**:现代东方极简(宋瓷气质),不是国内命理黑金套路
- **Memorable Thing**:"专业不忽悠,不像算命软件" — 每个设计决策服务这件事
- **色板**:`#F5EFE1` 宣纸米(主背景,替代黑渐变) / `#C33B3B` 朱砂(主 CTA,替代金) / `#2C5F3F` 墨青(吉神) / `#1D3A5F` 黛蓝 / `#1C1C1C` 浓墨文字
- **字体**:Songti SC(标题/八字,衬线文化分量) + PingFang SC(正文) + SF Pro Text tabular-nums(数字),iOS 系统自带,**不打包自定义字体**
- **间距**:8pt 基准网格,comfortable 密度
- **圆角**:默认 4pt(克制),Capsule 只留给 chip
- **分隔**:0.5pt hairline `#6B6557 @ 30%`,**不用阴影/neumorphism/玻璃态**
- **渐变**:禁止 `backgroundGradient` 渐变背景,纯色 only
- **AI slop 反模式**:不堆叠黑金/卷轴纹/古纹装饰,不用 Inter/Roboto 系列字体

iOS 落地代码骨架见 `DESIGN.md` § iOS SwiftUI 落地计划(BaziTheme token 重构 + 散点修复 + 逐模块优先级 + 验收清单)。
