# S06 golden queries 搜索质量 + 全量回归

- **类型**: AFK
- **Blocked by**: S03(S04/S05 落地后收尾最佳)
- **覆盖决策**: Q9(golden queries 单一事实源/XCTest 共享/全量回归)
- **Parent**: `docs/城市搜索设计决策.md`

## What to build

把搜索质量从「抽查」升格为「可回归的事实源」,并收口全系列回归:

1. **`tools/city-data/golden_queries.json`**(进 repo):搜索质量的单一事实源,格式建议:
   ```json
   [
     {"query": "乌鲁", "expect_top1": "乌鲁木齐", "note": "简体前缀"},
     {"query": "wlmq", "expect_top1": "乌鲁木齐", "note": "拼音首字母"},
     {"query": "三藩市", "expect_top1": "旧金山", "note": "别名"}
   ]
   ```
   首批 ≥80 条,覆盖矩阵:简体前缀/包含、繁体、全拼、首字母、英文、变音符、别名、同名消歧(Cambridge 英/美人口序)、脚本加权(汉字/拼音下中国城市优先)、空输入态热门(静态,不进 json)
2. **XCTest 消费同一份 JSON**(作为测试资源进 target):遍历跑 `CitySearchEngine`,断言首位命中(消歧类断言前 N 位含期望);跑失败的 query 进交付报告
3. **失败用例闭环**:golden queries 未命中的缺口 → 优先补 `curated_aliases.tsv` 回 S01 管线重建,而不是改排序公式打补丁(排序公式改动需显式列出影响了哪些既有 golden 用例)
4. **全量回归清单**(交付报告形式):
   - backend pytest 全量(30 对盘 + S02 DST/zoneinfo 套件)
   - iOS 全部单测 + 三入口冒烟
   - 真机/模拟器手工三例:乌鲁木齐拼音、洛杉矶时区修正、Cambridge 消歧 + 一例 1988 夏令时边界(出 boundary_warning)
5. **CLAUDE.md 增补一条规则**:动 `build_city_db.py` / `curated_aliases.tsv` / cities.sqlite / `CitySearchEngine.swift` 排序逻辑 → 必须跑 `check_city_db.py` + golden queries 且全 PASS(对齐 prompt 三边一致性的拦截文化)

## Acceptance criteria

- [ ] `golden_queries.json` ≥80 条进 repo,覆盖矩阵全类别
- [ ] XCTest 读同一份 JSON,首位命中率 100%(消歧类前 N 位含期望);全部绿
- [ ] 至少 3 个初始失败→修复闭环案例记录(如别名缺失补 tsv)
- [ ] backend pytest 全绿;iOS 测试全绿;三入口冒烟通过
- [ ] 手工回归三例 + 夏令时边界一例(见 What to build §4)记录在交付报告
- [ ] CLAUDE.md 增补守护栏规则(golden queries 必跑)
- [ ] 系列收尾:决策文档 `docs/城市搜索设计决策.md` Status 改 IMPLEMENTED,补「实施偏差记录」小节(如有)

## 实现锚点(现状快照 2026-08-15,实施以代码为准)

- `tools/city-data/` — golden_queries.json 与 curated_aliases.tsv 同目录
- S03 产出的 `Features/Place/CitySearchEngine.swift` — 被测对象,不为本 slice 特化
- `ios/Tests/` — 新增 GoldenQueriesTests.swift,JSON 进测试 target
- `CLAUDE.md` — 项目约束增补一条

## 红线与约束

- **单一事实源**:golden queries 只有一份 JSON,iOS 测试与未来任何回归工具共用;不复制第二份断言清单
- **确定性**:排序公式变更必须显式 diff golden 结果;禁止为单条 query 硬编码特例(hardcode 特例 = 违反确定性精神)
- **错误显式传播**:JSON 解析失败/引擎抛错 → 测试失败,不 catch 吞掉

## 测试

- 本 slice 本身即测试收口;交付物 = 全绿测试 + 交付报告(命中率、失败闭环案例、体积复核、手工回归记录)
