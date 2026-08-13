# 合盘多选改造 — 实施分割索引

Parent 设计事实源：`docs/合盘多选设计决策.md`（D1-D13，ACCEPTED 待实施）。
本目录为 2026-08-13 to-issues 分割产物：6 个 AFK vertical slice，每个独立可 demo。

## 实施顺序

| Slice | 标题 | Blocked by | 一句话 |
|---|---|---|---|
| S01 | [多选名单与批量计算结果列表](S01-多选名单与批量计算结果列表.md) | 无 | golden path：B 多选 → 串行批量 → 卡片列表 |
| S02 | [详情页导航复用](S02-详情页导航复用.md) | S01 | 点卡片进详情，复用 CompatibilityMainView，AI 逐对按需 |
| S03 | [对级错误隔离与重试](S03-对级错误隔离与重试.md) | S01（可与 S02 并行） | 单对失败卡片失败态 + 单对重试 |
| S04 | [多临时人与称呼](S04-多临时人与称呼.md) | S01 | 多临时人 + 可选称呼 + 兜底名，不建 link |
| S05 | [增量预查](S05-增量预查.md) | S01 | canonicalKey 预查命中跳过 API + store.list 查询 |
| S06 | [跨启动恢复与名单持久化](S06-跨启动恢复与名单持久化.md) | S01、S05 | UserDefaults 持久化 + 恢复列表 = 已算对 ∩ 名单 |

## 全系列红线（每个 slice 文档内均有）

- **D4**：付费每对独立 $11.99 entitlement + 每对 AI 扣全局池 1 次，**零改动**
- **D12**：后端零改动（多选 = 客户端循环调 1 对 1 接口）
- **D6**：临时人**不建 UserSnapshotLink**（零 schema 演化、零 sync 影响）
- **i18n**：新 UI 文案跟随现状中文硬编码，i18n plan Slice 3 统一补 key
- **视觉**：一切 UI 决策先读 `DESIGN.md`（纸白/hairline/4pt 圆角/朱砂点缀，无阴影无渐变）

## 不做（v2+，勿在本系列实现）

打包价 SKU / A 盘多选矩阵 / per-pair context / 列表滑动删除 / 临时人一键转正式 / 纯游客合盘。
