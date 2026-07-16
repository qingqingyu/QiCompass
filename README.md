# QiCompass — 玄机问道

AI 八字命理 iOS App:深度解析 / 合盘 / 每日运势 三模块。Python FastAPI 后端(`lunar_python` 排盘 + Anthropic/OpenAI 解读代理)+ SwiftUI 前端(iOS 17.2+,SwiftData 持久化)。

主设计文档:[`bazi-app-design-doc.md`](./bazi-app-design-doc.md) · 命理引擎决策:[`命理引擎设计决策.md`](./命理引擎设计决策.md)

---

## 项目结构

```
backend/                     # FastAPI + lunar_python 排盘 + 双 AI provider 代理
  app/                       # 应用代码(api/engine/models)
  tests/                     # pytest 测试
  requirements.txt
  pytest.ini
ios/QiCompass/               # SwiftUI App
  QiCompass.xcodeproj
  QiCompass/                 # 源码(App / Features/{Compatibility,DailyFortune,DeepAnalysis})
archive/                     # 旧"玄机问道"卷轴方案归档(参考,不复用)
bazi-app-design-doc.md       # 主设计文档
命理引擎设计决策.md            # 命理层决策记录
docs/                        # CI/CD + TestFlight 操作指南
```

---

## 开发环境

- **后端**:Python 3.11+ · `pip install -r backend/requirements.txt` · `cd backend && pytest -q`
- **iOS**:Xcode 15+ · Swift 5.9+ · iOS 17.2+ 部署目标 · 打开 `ios/QiCompass/QiCompass.xcodeproj`
- **排盘对盘**:`lunar_python` 测试套件(主)+ 问真八字 App 抽样(辅)

### AI provider 配置

AI provider 由后端部署环境统一选择,客户端不能逐请求指定:

```bash
# Anthropic(默认,AI_PROVIDER 可省略)
AI_PROVIDER=anthropic
ANTHROPIC_API_KEY=...
ANTHROPIC_MODEL=claude-sonnet-4-6

# OpenAI Responses API
AI_PROVIDER=openai
OPENAI_API_KEY=...
OPENAI_MODEL=gpt-5.5
```

`AI_PROVIDER` 只接受 `anthropic` 或 `openai`,非法值会阻止应用启动。所选 provider 缺少 key 时,排盘与 health 等非 AI 路由仍可用,`POST /api/interpret` 明确返回 503;不会使用另一家的 key 自动 fallback。两家当前统一使用 15 秒超时和最多 1024 个输出 token。

`GET /api/health` 返回当前 `ai_provider` / `ai_model` 并设置 `Cache-Control: no-store`。iOS 在读取本地 AI 缓存前先解析该身份;客户端与后端缓存都按 `provider + model` 隔离,部署切换后不会误用另一供应商或另一模型生成的内容。

---

## CI

`.github/workflows/ci.yml` 单文件、两个并行 job:

| Job | Runner | 触发 | 做什么 |
|---|---|---|---|
| `backend-test` | `ubuntu-latest`(1x 计费) | 每次 push + PR | `pip install` + `pytest -q` |
| `ios-build` | `macos-latest`(10x 计费) | ios/** 或 ci.yml 变更 | `xcodebuild build CODE_SIGNING_ALLOWED=NO`(编译检查,不签名) |

### iOS 自动化

`QiCompass` shared scheme 已包含 `QiCompassTests` target。除无签名编译检查外,本地可执行:

```bash
xcodebuild test \
  -scheme QiCompass \
  -project ios/QiCompass/QiCompass.xcodeproj \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO
```

### 省 macOS minute 策略

macOS runner 对私有 repo **10x 计费**(Free 计划 2000 min/mo 实际只够 ~200 macOS min)。本项目策略:

- **首选:把 repo 设为 public** → macOS runner 免费、无限制
- **私有降级**:iOS job 只在 `ios/**` 或 `.github/workflows/ci.yml` 变更时跑(见 ci.yml 的 `detect-ios-changes` job);backend 每次都跑但跑在 ubuntu(1x)
- **接近上限时**:升级 GitHub Pro($4/mo → 3000 min)

### CI 不做的事

- 不做 signing / archive / upload(那是本地或 release workflow 的事)
- 当前 workflow 仍只做 iOS 无签名编译检查;`QiCompassTests` 可在本地或后续 CI 执行
- 不自动上传 TestFlight(side project 阶段手动 archive 更简单,见下)

---

## TestFlight 配置

详见 [`docs/archive-testflight.md`](./docs/archive-testflight.md)(人工 archive/upload 完整步骤)和 [`docs/testflight-seed-users.md`](./docs/testflight-seed-users.md)(5 个种子用户邀请模板 + 反馈渠道)。

### 前置条件清单(用户做)

> **如暂无 Apple Developer Program 会员,在此停下,先去 Apple 入会($99/年)。以下步骤全部依赖入会。**

- [ ] **Apple Developer Program 会员**($99/年)
- [ ] **Xcode 登录 Apple ID**:Xcode → Settings → Accounts → 添加 Apple ID
- [ ] **设置 Signing Team**:Xcode → 项目 target → Signing & Capabilities → 勾 Automatically manage signing → 选 Team
  - 这会把 Team ID 写进 `ios/QiCompass/QiCompass.xcodeproj/project.pbxproj` 的 `DEVELOPMENT_TEAM`(当前为空字符串)
- [ ] **Bundle ID 已注册**:Bundle Identifier 当前为 `com.qicompass.app`,首次 signing 时 Xcode 会向 Apple 注册;或在 App Store Connect → Identifiers 手动注册
- [ ] **App Store Connect 创建 App**:Apps → 新建 → 填名称 `QiCompass` → Bundle ID 选 `com.qicompass.app`

### 本地 archive 流程(主路径)

> side project 阶段推荐手动 archive,一周一次成本远低于配 CI secrets 的维护成本。

1. 递增 build number:`project.pbxproj` 里 `CURRENT_PROJECT_VERSION`(当前 `1`)每次上传必须 +1,否则 Apple 拒收
2. Xcode 顶部设备选 **Any iOS Device (arm64)** 或 **Generic iOS Device**
3. **Product → Archive**(必须 release config + 真机 target,simulator 不能 archive)
4. Organizer 自动弹出 → 选刚生成的 archive → **Distribute App** → **App Store Connect** → **Upload**
5. Apple processing ~15-30 min,完成后 TestFlight 标签页可见该 build

完整步骤(含截图位置、失败诊断)见 [`docs/archive-testflight.md`](./docs/archive-testflight.md)。

### CI 自动 upload(可选,后续上)

**side project 阶段不上 CI upload。** 后续如需,要求:

- secrets:`APP_STORE_CONNECT_API_KEY_ID`、`ISSUER_ID`、`KEY_CONTENT`(base64 的 `.p8` 密钥)
- 社区 action `apple-actions/app-store-upload` 或 `xcrun altool`
- `workflow_dispatch` 手动触发,**不**在 push 上跑
- 需要先在 App Store Connect → Users and Access → Integrations → API Keys 生成 `.p8` 并记下 Issuer ID + Key ID

### 邀请 tester(外部测试组)

详见 [`docs/testflight-seed-users.md`](./docs/testflight-seed-users.md)。

1. App Store Connect → App → **TestFlight** 标签页
2. **外部测试组** → 新建组(组名 `Seed Beta`)→ 添加 5 个 email
3. Apple 自动发邀请邮件给 tester
4. 首次 build 需 **beta review**(~1 天);内部测试组免 review 但要求 tester 在 Team 里,代价高,**不选**

### 常见失败路径

| 症状 | 原因 | 解决 |
|---|---|---|
| Archive 灰掉 | 选了 simulator 或 Debug config | 设备选 Any iOS Device,scheme 的 Archive config 设为 Release |
| Upload 报 "No profiles for com.qicompass.app were found" | Bundle ID 未注册或 team 未选 | Xcode Signing & Capabilities 重选 Team,勾 Automatically manage signing |
| Upload 报 "The build number must be higher than..." | `CURRENT_PROJECT_VERSION` 未递增 | 每次上传前 +1 |
| `DEVELOPMENT_TEAM = ""` 报错 | 未填 team ID | Xcode 选 Team 后会自动写入 pbxproj |
| TestFlight 看不到 build | processing 未完成(15-30 min) | 等;若超 1 小时查 App Store Connect 状态,可能被拒(查邮件) |
| 首次上传被拒 | 未填 App Privacy(数据采集声明) | App Store Connect → App 隐私 → 填问卷 |
| External tester 收不到邀请 | 邮箱在垃圾箱 / 邀请链接过期 | 重新发送;或用公开邀请链接(TestFlight → 外部测试组 → 启用公开链接) |

---

## 文档索引

- [`bazi-app-design-doc.md`](./bazi-app-design-doc.md) — 主设计文档(架构 / API 契约 / SwiftData / prompt 模板 / §Distribution Plan)
- [`命理引擎设计决策.md`](./命理引擎设计决策.md) — 命理层决策(喜忌 / 神煞 / ChartSnapshot / 从格边界)
- [`CLAUDE.md`](./CLAUDE.md) — 项目约束(八字确定性 / LLM 边界 / SwiftData / 测试策略)
- [`docs/archive-testflight.md`](./docs/archive-testflight.md) — 人工 archive + upload TestFlight 完整步骤
- [`docs/testflight-seed-users.md`](./docs/testflight-seed-users.md) — 5 个种子用户邀请模板 + 反馈渠道 + SLA
- [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) — CI workflow(backend pytest + iOS 编译检查)
