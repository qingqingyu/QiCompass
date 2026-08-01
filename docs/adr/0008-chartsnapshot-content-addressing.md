# 0008 — ChartSnapshot 内容寻址 + schema/identity 分离(决策 3 / 3b / D1)

Status: accepted (2026-07-10)

`ChartSnapshot` 是不可变值对象,SwiftData `@Model`。身份 = `contentHash = SHA256(birth_datetime + gender + city_longitude + zi_hour_rule)`(**不含** schema_version),`schemaVersion` 是独立 Int 字段,易变复杂结构(pillars / 十神 / 纳音 / 神煞 / 喜忌 / luck_pillars)走 `payload` JSON `Data` 字段。修改 = 新建,旧 snapshot 保留。

**Why**:
1. 内容寻址 → 同一出生信息 = 同一 hash = 跨用户共享缓存(后端 SQLite 跨用户缓存最大价值)
2. 不可变 → 改生日 / 切时辰 / 换城市不会污染旧 snapshot 的命书 / 运势 / 合盘记录
3. schema/identity 分离 → SwiftData 要求 schema 可演化,但 hash 嵌 schema_version 会让跨用户共享命中率断崖式下跌。分离后 hash 永远稳定,schema 升级靠 `payload` JSON + lazy 重算

**Surprising without context**: 这是 B+C 融合方案,不是任何一个极端。看起来"为什么不直接 SwiftData VersionedSchema?" — 因为 SwiftData `@Relationship`(UserSnapshotLink ↔ ChartSnapshot)在 iOS 17.0/17.1 有 crash,VersionedSchema 依赖加深;D1 减轻了这部分依赖。

**Real trade-off**:
- ✅ B+C 融合 — hash 稳定 + payload 灵活 + SwiftData 核心 schema 几乎不变
- ❌ Hash 嵌 schema_version — 跨用户共享缓存命中率断崖
- ❌ 纯 SwiftData 原生 migration — snapshot 不再严格不可变,复杂嵌套结构 migration 易错
- ❌ 完全 JSON 兜底(无 SwiftData 字段)— 失去 query 能力

**Consequences**: 加字段 = `payload` JSON 加 key + `schemaVersion +1` + 老 snapshot lazy 重算(按需触发,启动时不批量)。改字段类型需一次性 migration script。最低 iOS 17.2(17.0/17.1 SwiftData `@Relationship` 有 crash)。详见 `命理引擎设计决策.md` §3b。
