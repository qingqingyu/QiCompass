# TASK-20 SwiftData 旧库迁移目标改为「实际落盘位置」(防本地命盘丢失)

> **2026-11-28 复核:❌ 尚未实施**。`ModelContainerFactory.swift` 迁移目标仍是 `groupRoot`,迁移相关代码自本任务写成后无任何提交。**上架前必修,请优先处理。**
>
> **同日补记(复核后已实施)**:该复核写于实施前。随后 `a5d589a` 已把迁移目标改为 `config.url` 实际落盘目录并把 `groupRoot` 错位库归位,`5749c1d` 收口归档——即本 `.done.md` 的实施记录,「未实施」结论自此过时。

> 2026-11-27 外评复核。来源:App 改名 S03 在 Mac 上编译验证时发现(`docs/App改名-slices/S03-iOS界面品牌字样.md`「Mac 验证结果」),当时记为「修法留用户拍板」,至今未处理。**上架前必须完成。**

## 背景(风险)

`ios/QiCompass/QiCompass/Persistence/ModelContainerFactory.swift` 的 `make()` 先调用 `LegacyStoreMigrator.migrate(sourceDirectory:destinationDirectory:)`,把旧版本地库搬进 App Group 共享容器,再用 `ModelConfiguration(groupContainer: .identifier(AppGroup.identifier))` 打开 SwiftData。

迁移目标写死为**共享容器根目录** `groupRoot`,前提是假设 SwiftData 会把 `default.store` 放在共享容器根。`LegacyStoreMigratorTests.test_persistentGroupContainerStoreLocationPin` 就是为锁住这个假设而写的。

2026-11-25 在 Mac 上实测:新版模拟器运行时下,SwiftData 把 store 放到了 `<共享容器>/Library/Application Support/`,这个 pin 测试因此失败(842/843 中唯一的失败项)。假设被打破的后果:

- 迁移代码把旧数据搬到 `groupRoot/default.store`
- SwiftData 在 `Library/Application Support/` 下新建一个**空库**并读取它
- 用户看到的是「命盘、已购章节、问事记录全没了」;旧数据其实还在 `groupRoot`,只是 App 读不到

App 尚未上架,受影响的只有 TestFlight 用户,但上架前不修,首批正式用户升级时同样会触发。

## 方案

**核心原则:迁移目标不再靠假设,而是问 SwiftData 自己——`ModelConfiguration.url` 就是 store 的实际路径。**

### 1. 迁移目标改为 `config.url` 所在目录

在 `ModelContainerFactory.make()` 里:

1. 先构造 `ModelConfiguration`(与现在参数完全相同),**此时不打开容器**
2. 用 `config.url.deletingLastPathComponent()` 作为 `destinationDirectory` 调用 `LegacyStoreMigrator.migrate`
3. 迁移完成后再 `ModelContainer(for:configurations:)` 打开
4. 日志记录 `config.url` 的路径(`privacy: .private`),便于真机排查

`LegacyStoreMigrator.migrate` 本身的语义不变(源存在 / 目标已有 store / 孤立边车 / 半途回滚 / 删源失败留残),只是调用方传入的目标目录变了。

### 2. 补救已被搬错位置的数据(TestFlight 用户)

在新布局的设备上,旧版本可能已经把数据搬到了 `groupRoot/default.store`。在第 1 步迁移之前增加一次补救:

- 条件:`groupRoot/default.store` 存在,**且** `config.url` 所在目录与 `groupRoot` 不同,**且** `config.url` 处还没有 store
- 动作:复用 `LegacyStoreMigrator.migrate(sourceDirectory: groupRoot, destinationDirectory: config.url 所在目录)`——同一套「全部拷贝成功才删源、失败回滚」逻辑,不另写一份
- `config.url` 处已有 store 时不动(`destinationExists` 分支),两份数据都保留,记 fault 日志,留人工排查,**不做自动合并**
- 这一步的结果同样写进日志(action + 搬运文件名)

> ⚠️ **HITL**:补救动作会移动 TestFlight 用户的数据文件。实现前把上面的条件与动作发给用户确认一次;用户同意后再写代码。

### 3. pin 测试改为锁住「迁移目标 == 实际落盘位置」

`test_persistentGroupContainerStoreLocationPin` 不再断言「store 在共享容器根」,改为断言:用相同参数构造的 `ModelConfiguration`,其 `url` 所在目录就是 `make()` 传给迁移器的目标目录,并且打开容器后 store 文件确实出现在 `config.url`。这样 SwiftData 以后再改布局,测试也不会因位置变化而失败,数据也不会丢。

## 测试

- `LegacyStoreMigratorTests`:
  - 改写后的 pin 测试在新旧两种模拟器布局下都通过
  - 新增:补救路径——`groupRoot` 有 store、`config.url` 目录无 store → 搬过去,源删除
  - 新增:补救路径——两处都有 store → 不动,返回 `destinationExists`
  - 新增:`config.url` 目录就是 `groupRoot`(旧布局)→ 补救步骤不触发
- 原有迁移用例(无源 / 孤立边车 / 半途回滚 / 删源失败)全部保持通过

## 验收

- iOS 单元测试全绿(843/843)
- **真机验证(HITL,并入改名 S06 走查)**:在装着旧版、有命盘和已购章节的手机上覆盖安装新版 → 命盘、已购章节、问事次数都还在;日志里能看到实际 store 路径与迁移结果
- 未改 SKU / entitlement 映射(`tools/check_sku_sync.py` 不触发);未改 App Group 标识与 Bundle ID

## 全局约束(必读)

- 开工前读 `CLAUDE.md` 全文;SwiftData 相关约束见其「SwiftData」一节(不用 VersionedSchema / SchemaMigrationPlan)
- 历史背景:`docs/tasks/TASK-05-app-group-migration.done.md`、`docs/tasks/TASK-11-legacy-store-migrator-edge-cases.done.md`
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败;迁移失败一律上抛,不静默回落本地库
- 不得新增任何依赖;新 .swift 文件须 `project.pbxproj` 4 处登记一致 24 位 ID

## 实施记录(2026-11-28 收口,commit `a5d589a`)

按任务书全套实施(含 §2 补救步骤,2026-11-28 用户拍板「全套实施」):

- `make()` 顺序改为:构造 `ModelConfiguration` → `migrationDestination(for:)`
  (= `config.url` 所在目录)→ 错位库归位 → TASK-05 老本地库迁移 → 打开容器。
  归位先于迁移:容器一旦在落盘目录建空库,老数据再无自动迁移窗口。
- `remediateMisplacedGroupStore` 比任务书多两条不触发路径的显式测试:
  groupRoot 无 store(干净设备常态)、落盘目录即 groupRoot(旧布局运行时)。
- pin 测试改写为**布局无关锚定**(不再断言任何具体目录):迁移目标 ==
  `config.url` 所在目录 + 容器初始化后 store 确实出现在 `config.url`;
  新(容器根)/旧(`<group>/Library/Application Support/`)两种布局都必须成立,
  SwiftData 再改布局此测试先红。清理只删本次新建文件,不动既有库。
- 验证:`LegacyStoreMigratorTests` 11/11(模拟器 DA0476D9,zh-Hans);全量
  875 用例绿(其中 1 个 M0 fixture 回归系 main 侧 60f3a2e 自带,另以
  `ed15dc9` 单独修复,与本任务无交集)。遗留:4 条 SwiftData 控制台
  save-failed 权限日志,不挂任何断言,归属待观察。
- **真人步骤(HITL,未做)**:真机老设备覆盖安装走查——按任务书验收条款
  并入改名 S06 走查;日志核对 store 实际路径与 remediation action。
