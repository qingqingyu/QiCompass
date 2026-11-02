# TASK-09 隐私申报补「邮箱地址」(TASK-01 / TASK-03 复核返工)

## 背景(复核发现)
Sign in with Apple(首次登录)与 Google 登录(每次)返回的 email 会上传后端并落库:
- iOS:`Services/AccountManager.swift`(`gidUser.profile?.email` 等)
- 后端:`backend/app/api/auth.py` 解出 email → `backend/app/auth/user_store.py` 的 `email TEXT` 列

但 `PrivacyInfo.xcprivacy` 与 `docs/archive-testflight.md` §5 都未申报 Email Address——申报不实,有审核风险。(漏项源于任务书 TASK-01 本身,非实现方失误。)
姓名:后端不存 fullName(仅本机 Keychain),**不**申报 Name;实现时再 grep 一次后端确认。

## 要做
- `ios/QiCompass/QiCompass/Resources/PrivacyInfo.xcprivacy` 的 `NSPrivacyCollectedDataTypes` 增:
  - `NSPrivacyCollectedDataTypeEmailAddress`,Linked = true,Tracking = false,Purpose = `NSPrivacyCollectedDataTypePurposeAppFunctionality`
- `docs/archive-testflight.md` §5 申报清单同步加「Email Address(仅登录用户;Apple 私密转发地址亦属此项)」
- 顺手修:`project.pbxproj` 中 `PrivacyInfo.xcprivacy` 的两个对象 ID(`9C0000000000000000000FF` / `9C1000000000000000000FF`)只有 23 位,改为不冲突的 24 位 ID(4 处引用一致替换)

## 验收
- Xcode Archive → Generate Privacy Report 中出现 Email Address
- `project.pbxproj` 中所有 PrivacyInfo 相关 ID 为 24 位且全文件唯一
- Release 构建成功

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
