# TASK-11 老库迁移两处边界情况(TASK-05 复核小问题)

## 背景(复核发现)
`ios/QiCompass/QiCompass/Persistence/ModelContainerFactory.swift` 的 `LegacyStoreMigrator.migrate`:

1. **只有边车文件、没有主库**:`present` 只要命中 `default.store-wal` / `default.store-shm` 任一就进入迁移——会把孤立的边车拷到 App Group 再删源。目标没有 `default.store`,下次启动 SwiftData 新建空库,孤立边车被当成新库的 WAL,行为不确定;源边车也被删,没法人工排查。
2. **拷贝全部成功、删源失败**:最后的删源循环 `try fileManager.removeItem` 失败直接上抛 → `ModelContainerFactory.make` 抛错 → **本次启动失败**,而此时数据其实已完整在目标目录(下次启动走 `destinationExists` 能正常打开)。用户感知为"无故打不开一次"。

## 要做
### 1. 无主库不迁
- 判定改为:源目录**没有** `default.store` → 不迁移、不删任何文件
  - 若有孤立边车:记 `fault` 日志(列出文件名),返回新 action `orphanSidecars`(显式结果,不是静默忽略)
  - 没有任何文件:仍返回 `noSource`
- 有主库时,边车有几个拷几个(保持现状)

### 2. 删源失败不阻断启动
- 拷贝全部成功后删源:逐个删,失败的收集起来,**不上抛**
- 返回新 action `migratedWithLeftovers`,`Outcome` 增字段 `leftoverSourceFiles: [String]`;记 `error` 日志(含文件名)
- 调用方 `make()` 对该 action 记日志后继续打开容器
- 这不算吞错:失败有显式返回值 + 日志,且数据已安全;遵守「错误显式传播」的同时不因清理失败阻断启动
- `destinationExists` 路径**不**自动删残留源文件(无法确认两边哪份更新),只在检测到源目录仍有 store 文件时记 `info` 日志

### 3. 不变的部分
- 拷贝阶段失败的回滚 + 上抛语义不变
- App Group 不可用直接抛 `appGroupUnavailable` 不变

## 测试(扩展 `ios/Tests/Shared/LegacyStoreMigratorTests.swift`)
- 源只有 `-wal` / `-shm` → `orphanSidecars`,源文件仍在,目标无文件
- 删源失败(注入会在 `removeItem` 抛错的 FileManager 子类)→ `migratedWithLeftovers`,目标三个文件齐全,`leftoverSourceFiles` 正确
- 原有 5 个用例保持全绿

## 验收
- `LegacyStoreMigratorTests` 全绿;Release 构建成功

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
