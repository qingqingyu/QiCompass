# TestFlight 人工 Archive + Upload 操作指南

本文档描述从源码到 TestFlight 可安装 build 的完整人工流程。**side project 阶段主路径**:一周一次手动 archive,不上 CI 自动 upload。

> 前置条件清单见 [`README.md`](../README.md#前置条件清单用户做)(Apple Developer Program 会员 / Xcode 登录 / Signing Team / Bundle ID / App Store Connect App)。本文档假设前置条件已全部完成。

---

## 1. 递增 build number(每次上传必须)

Apple 规则:同一 app,后上传 build 的 `CURRENT_PROJECT_VERSION`(build number)必须严格大于已上传的最大值,否则拒收。`MARKETING_VERSION`(version number,如 `0.1.0`)不必每次改,只在功能性版本升级时改。

在 `ios/QiCompass/QiCompass.xcodeproj/project.pbxproj` 里(当前值 `CURRENT_PROJECT_VERSION = 1`),每次上传前把两个 config(Debug / Release)的 `CURRENT_PROJECT_VERSION` +1,或用 agvtool:

```bash
cd ios/QiCompass
xcrun agvtool next-version -all       # 当前 build number +1
# 或指定值
xcrun agvtool new-version -all 2
```

> agvtool 要求 target 的 `VERSIONING_SYSTEM = apple-generic`,若未设置就手改 pbxproj 的两处 `CURRENT_PROJECT_VERSION`。

---

## 2. 选 Archive 目标

Archive 要求 **Release config + 真机 target**(simulator 不能 archive):

1. Xcode 打开 `ios/QiCompass/QiCompass.xcodeproj`
2. 顶部设备下拉 → **Any iOS Device (arm64)** 或 **Generic iOS Device**(不是任何 simulator)
3. 菜单 **Product → Scheme → Edit Scheme** → 左侧选 **Archive** → 右侧 **Build Configuration** 确认为 **Release**(默认是)

---

## 3. Archive

菜单 **Product → Archive**(⇧⌘B 旁边的菜单)。流程:

- Xcode 编译 Release → 生成 `.xcarchive`(默认在 `~/Library/Developer/Xcode/Archives/<date>/`)
- 成功后 **Organizer** 窗口自动弹出,显示刚生成的 archive

archive 失败的常见原因:
- Code signing 未配(回 README 前置条件清单第 3 步)
- 选了 simulator target(回第 2 步)
- 第三方依赖(SPM)解析失败(检查 Package.swift / 网络)

---

## 4. Distribute App → App Store Connect → Upload

Organizer 里选刚生成的 archive → 右上 **Distribute App** → 选 **App Store Connect** → **Upload** → 一路 Next:

- **App Store Connect API**:不勾(用 Apple ID 鉴权即可)
- **Upload symbols**:勾(上传 dSYM,供 crash 符号化)
- **Manage Version and Build Number**:不勾(让 Apple 自动用 pbxproj 里的值)

点 **Upload**,Xcode 上传 `.ipa` + symbols,~2-5 分钟(视网络)。

上传成功后,Apple 在服务端 **processing** ~15-30 分钟。处理期间 TestFlight 标签页看不到 build;完成后 build 出现,状态变绿。

---

## 5. 验证(TestFlight 可见)

1. App Store Connect → App → **TestFlight** 标签页 → 左侧 **iOS** → 看新 build 是否出现,状态是否 "Available"
2. **首次上传**会被要求填 **App Privacy**(数据采集声明):App Store Connect → App → App 隐私 → 按实际填(QiCompass 本地存命盘数据,**不**上云,可按此口径填)
3. 首次 external tester build 需 **beta review**(~1 天);内部测试组免 review

---

## 6. 出问题怎么办

| 症状 | 诊断步骤 |
|---|---|
| Archive 失败:signing error | Xcode → target → Signing & Capabilities → Team 重选;删 `~/Library/MobileDevice/Provisioning Profiles` 重新拉 |
| Upload 失败:"No applicable devices found" | `.ipa` 缺架构,确认 Archive 选的是 Generic iOS Device 不是 simulator |
| Upload 成功但 processing 失败(邮件通知) | 邮件含具体原因(常见:Info.plist 缺权限说明 / 用了过期 API);修后递增 build number 重新 archive |
| TestFlight 超过 1 小时仍 processing | 多半是 reject,查注册 Apple ID 的邮箱;或 App Store Connect → TestFlight → 看 build 状态 |
| Installer 在 tester 设备上崩溃 | 上传时勾了 Upload symbols 后,TestFlight → build → Crashes 看符号化堆栈 |

---

## 7. 何时考虑 CI 自动 upload

当手动 archive 频率 > 一周 2-3 次,或多人协作需要稳定发布节奏时,考虑 CI 自动 upload。要求:

- App Store Connect → Users and Access → Integrations → **API Keys** → 生成 `.p8` 密钥,记下 **Issuer ID** + **Key ID**
- repo secrets 配 `APP_STORE_CONNECT_API_KEY_ID`、`ISSUER_ID`、`KEY_CONTENT`(base64 编码整个 `.p8`)
- 新增 workflow `release.yml`,`workflow_dispatch` 手动触发,跑 archive + upload
- 推荐 action:`apple-actions/app-store-upload`(社区维护,stars 高)

**当前阶段明确不做**:secrets 维护成本 + CI archive 时间(~15-20 macOS min/次)远大于一周一次手动 archive。
