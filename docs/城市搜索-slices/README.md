# 全球城市搜索 + 出生地时区改造 — 实施分割索引

Parent 设计事实源:`docs/城市搜索设计决策.md`(Q1-Q9,ACCEPTED 待实施)。
本目录为 2026-08-15 to-issues 分割产物:6 个 AFK vertical slice,每个独立可 demo。

## 实施顺序

| Slice | 标题 | Blocked by | 一句话 |
|---|---|---|---|
| S01 | [城市数据库构建管线](S01-城市数据库构建管线.md) | 无 | `build_city_db.py` 产 cities.sqlite + manifest,`check_city_db.py` 守护栏,验收含实测体积(≤25MB→cities1000,超标停下报告) |
| S02 | [后端契约改造(zoneinfo)](S02-后端契约改造zoneinfo.md) | **无(与 S01 并行)** | 裸钟面+timezone 契约、删城市表、DST 历史规则用例,pytest 独立全绿 |
| S03 | [iOS 搜索组件与深度解析入口(tracer bullet)](S03-iOS搜索组件与深度解析入口.md) | S01、S02 | `CityPickerField`/`CitySearchSheet` 端到端:搜索→选中→新契约→排盘正确,砍北京默认 |
| S04 | [合盘与 onboarding 入口换装](S04-合盘与onboarding入口换装.md) | S03 | 其余两入口机械复制组件,删 `CityList` enum |
| S05 | [自定义地点高级模式](S05-自定义地点高级模式.md) | S03(可与 S04 并行) | sheet 内「自定义地点」入口:经度 + IANA 时区必填,替换旧手动经度开关 |
| S06 | [golden queries 搜索质量与全量回归](S06-golden-queries搜索质量与全量回归.md) | S03(S04/S05 后收尾最佳) | golden_queries.json 进 repo,XCTest 共享断言 + 全链路回归 |

## 全系列红线(每个 slice 文档内均有)

- **确定性**:同一输入永远同一输出;搜索纯本地纯函数;`content_hash` 基于归一化物理量(UTC 时刻 + 经度固定精度 + 时区 + 性别 + zi_hour_rule)
- **客户端不做历法计算**:时区解释(裸钟面→绝对时刻)只发生在后端 `zoneinfo`;iOS 只保 WYSIWYG 显示(DatePicker 挂出生城市 Calendar)
- **错误显式传播**:DST 歧义/不存在小时不静默吞,降级 `boundary_warning`;tz 非法/经度越界显式报错;构建/校验脚本失败必须非零退出
- **不擅自加依赖**:运行时**零**新库(`zoneinfo` 是 Python stdlib);`pypinyin` 仅构建期(grill-me 已批准);不引入 FTS
- **零兼容垫片**:pre-launch 无存量用户,旧 `city` 字段直接删,不写双格式兼容层
- **i18n**:新 UI 文案直接进 `Localizable.xcstrings`(v1 中英,对齐决策 Q9;注意与合盘系列「跟随硬编码」红线不同)
- **视觉**:一切 UI 决策先读 `DESIGN.md`(纸白卡片/hairline/4pt 圆角/朱砂点缀,无阴影无渐变)
- **许可**:GeoNames CC-BY 4.0,关于页 attribution(S03 落地)
- **prompt 三边一致性**:本系列不动 `prompts.py`/`PromptContextBuilder`/`context_builder.py`,不触发 check_prompt_sync

## 不做(勿在本系列实现)

GPS 定位 / 错别字混拼纠错(backlog)/ 市辖区独立条目 / 先选国家再搜 / admin1 中文名专项工程 / 1949 前 LMT 显式提示 / 在线搜索兜底 / FTS5 / 后端城市种子表。
