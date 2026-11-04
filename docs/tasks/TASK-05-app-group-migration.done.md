# TASK-05 配置 App Group + SwiftData 存储迁入共享容器

## 背景
v1 不做 Widget,但先把数据放进 App Group,v2 做「今日宜忌」小组件时免迁移。TestFlight 已有用户,**必须**迁移老数据。

## 要做
- `ios/QiCompass/QiCompass/QiCompass.entitlements` 加 `com.apple.security.application-groups` = `group.<bundle id>`
- `Persistence/ModelContainerFactory.swift`:持久化 `ModelConfiguration` 改用 `groupContainer: .identifier("group.<bundle id>")`(in-memory 配置不变)
- 启动时迁移:
  - 检测旧默认路径下的 store 文件(含 `-wal` / `-shm`),存在且 group 路径无 store → 迁入
  - 迁移失败:显式报错 + 保留原文件 + 日志,**不得**静默新建空库
  - 迁移成功后才删除旧文件
- 本期**不建** Widget target

## 需要真人完成(写进 PR 描述)
- Apple Developer 后台注册 App Group,并更新 App ID 能力与 provisioning profile

## 测试
- 单元测试覆盖迁移函数:无旧库 / 有旧库迁移成功 / 目标已存在 / 迁移失败保留原文件

## 验收
- 真机:装旧版 build 写入数据 → 覆盖安装新版 → 命盘、解读缓存、Entitlement、合盘名单全部还在

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 除 TelemetryDeck(仅 TASK-06)外不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
