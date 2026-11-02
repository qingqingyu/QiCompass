# TASK-10 商店文案免费章描述与实际不符(TASK-07 复核返工)

## 背景(复核发现)
`docs/appstore-metadata.md` 写「前两章免费:先读懂性格底色,再看事业方向」(en 同义:"understand your temperament, then your career direction")。
App 实际免费章是 v1 链 **M0 · 主线结构** 与 **M1 · 天赋能力**(`Models/ModuleDefinitions.swift`,`isFree` = m0 / m1;后端 `PAID_MODULES` 不含两者)。商店描述与功能不符,有 Guideline 2.3(元数据准确性)被拒风险。根因:`MONETIZATION.md`「免费 / 付费内容分界」段仍是旧 `bazi_deep_free`(性格底色 + 事业)口径。

## 要做
- `docs/appstore-metadata.md` 三语(zh-Hans / zh-Hant / en):把命书免费章描述改为主线结构 + 天赋能力;用户可读说法取 `ModuleDefinitions.swift` 中 M0 / M1 的副标题,zh-Hant / en 用 xcstrings 里对应译文,不另起译名
- 同步核对合盘「第一章免费」说法与 `MONETIZATION.md` §合盘(免费 = 基础相处模式 + 互补/冲突总览)及 App 实际是否一致,不一致一并改
- 改后重新程序化统计字符数并更新括注,仍须在限制内
- `MONETIZATION.md`「深度解析 免费 / 付费内容分界」段改为 v1 链口径(免费 M0 + M1,付费 M2–M7),文件头加一行更新说明;决策汇总表中「深度解析免费章节」一行同步

## 验收
- grep「性格底色」「temperament」在 `docs/appstore-metadata.md` 零命中(除非确属实际免费内容)
- 商店文案中每条免费 / 付费说法都能在代码中找到对应模块
- 措辞红线复扫:不出现「算命 / 预测 / 准确率 / 改运」

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
