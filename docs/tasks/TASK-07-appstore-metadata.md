# TASK-07 起草 App Store 元数据(文档任务,不改代码)

## 要做
新建 `docs/appstore-metadata.md`,zh-Hans / zh-Hant / en 三语各一套:
- **名称**(≤30 字符):「QiCompass 八字命书」/ 繁中对应写法 /「QiCompass: Bazi Reading」;桌面显示名保持 `QiCompass` 不变
- **副标题**(≤30)
- **关键词**(≤100 字符,逗号分隔,不重复名称中已有的词)
- **描述**(含免费 / 付费边界说明:命书 2 章免费、合盘半免费、问事装机赠 3 次)
- **截图标题** 5-6 张:第一张按「读懂自己」方向——「一本只属于你的命书」/「Your chart, read like a book」,其余配套(今日宜忌 / 合盘 / 问事 / 排盘确定性)

## 措辞红线
- 不写「算命 / 预测 / 准确率 / 改运」
- 不给「正官格 / 偏印格」等格局硬分类
- 用「倾向 / 参考 / 命局呈现」;附「内容仅供娱乐参考」
- 定位:「专业不忽悠,不像算命软件」

## 附:待真人完成的 App Store Connect 操作清单(写在文档末尾)
- 各目标地区 App Store 搜同名 / 近名查重
- 销售范围去掉中国大陆
- 按 TASK-03 口径填 App Privacy 标签
- Offer Codes:为 `deep_analysis.single` / `compatibility.single` 生成测评码
- 三语元数据与截图上传

## 验收
- 每项字段字符数在限制内(文档内标注字数)

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 除 TelemetryDeck(仅 TASK-06)外不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
