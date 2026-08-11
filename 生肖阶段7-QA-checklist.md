# 生肖 slice 阶段 7 — 全量 QA Checklist

> 工程清单(见 `生肖设计决策.md` line 139-143)最后一项。前 6 阶段已落地(commit `1b683f6` 把阶段 2 数据层 + 阶段 3 防错合并提交)。
>
> 阶段 7 是**手工 QA pass**,验证 4 件事:12 生肖正确性 / light-dark 视觉 / 失败路径 UX / 重置命盘流程。不写自动化测试(项目无 XCUITest target + 不引入 snapshot 库 + 抽 orchestrator protocol 违反 YAGNI)。

## 前置条件

- **环境**:iOS Simulator(iPhone 16, iOS 18.3.1)+ 本地后端 FastAPI(`cd backend && uvicorn main:app --reload`)
- **首次启动**:模拟器 → Device → Erase All Content and Settings(确保走完整 onboarding)
- **后端连通性**:模拟器 Safari 访问 `http://localhost:8000/health` 200 OK
- **日志监控**:Mac Console.app 过滤 `subsystem:com.qicompass.app`(或 Xcode console)

## 测试 1:12 生肖 onboarding 全流程

**目标**:验证 12 个生肖 asset / 文字 / 性别 subLabel 都正确。

**测试数据**(已避开立春边界 2月3-5日,任意年份都安全):

| # | 生肖 | 地支 | 出生日(任意年份) | 出生时 | 性别 | 期望 asset | 期望 mainLabel | 期望 subLabel |
|---|---|---|---|---|---|---|---|---|
| 1 | 鼠 | 子 | 2008-06-15 | 10:00 | 男 | Zodiac_Rat | 子 · 鼠 | 乾造(男) · 戊子年 |
| 2 | 牛 | 丑 | 2009-07-20 | 14:00 | 女 | Zodiac_Ox | 丑 · 牛 | 坤造(女) · 己丑年 |
| 3 | 虎 | 寅 | 2010-08-10 | 09:30 | 男 | Zodiac_Tiger | 寅 · 虎 | 乾造(男) · 庚寅年 |
| 4 | 兔 | 卯 | 2011-06-25 | 11:00 | 女 | Zodiac_Rabbit | 卯 · 兔 | 坤造(女) · 辛卯年 |
| 5 | 龙 | 辰 | 2000-06-15 | 14:30 | 男 | Zodiac_Dragon | 辰 · 龙 | 乾造(男) · 庚辰年 |
| 6 | 蛇 | 巳 | 2001-07-10 | 16:00 | 女 | Zodiac_Snake | 巳 · 蛇 | 坤造(女) · 辛巳年 |
| 7 | 马 | 午 | 2014-08-05 | 10:30 | 男 | Zodiac_Horse | 午 · 马 | 乾造(男) · 甲午年 |
| 8 | 羊 | 未 | 2015-06-20 | 13:00 | 女 | Zodiac_Goat | 未 · 羊 | 坤造(女) · 乙未年 |
| 9 | 猴 | 申 | 2016-07-15 | 15:30 | 男 | Zodiac_Monkey | 申 · 猴 | 乾造(男) · 丙申年 |
| 10 | 鸡 | 酉 | 2017-08-25 | 17:00 | 女 | Zodiac_Rooster | 酉 · 鸡 | 坤造(女) · 丁酉年 |
| 11 | 狗 | 戌 | 2006-06-10 | 09:00 | 男 | Zodiac_Dog | 戌 · 狗 | 乾造(男) · 丙戌年 |
| 12 | 猪 | 亥 | 2007-07-22 | 18:30 | 女 | Zodiac_Pig | 亥 · 猪 | 坤造(女) · 丁亥年 |

**每个生肖跑 3 个步骤**(共 12 次 onboarding):

- [ ] **1.1** 启动 App → OnboardingView → CTA → BirthFormView
- [ ] **1.2** 填表(性别 + 日期 + 城市"北京")→ 点"开始排盘" → **二次确认 sheet** 弹出
  - **验收**:sheet 显示分行 `出生时间 / 性别 / 出生地`,朱砂"确认排盘" + 灰色"返回修改"
  - **验收**:点"返回修改" → sheet dismiss,表单值保留
- [ ] **1.3** 点"确认排盘" → 排盘 loading → **ZodiacRevealView** 出现
  - **验收**:印章图正确(对应上表 asset,light/dark 自动选对)
  - **验收**:主文字 `子 · 鼠` 等格式正确(Songti SC display 44pt)
  - **验收**:次文字 `乾造(男) · 戊子年` 等格式正确
  - **验收**:盖章动效(scale 0.8 → 1.05 → 1.0 + 朱砂光晕 + HapticEngine.medium)
  - **验收**:CTA"查看今日运势" → 落地今日运势 tab
  - **验收**:ProfileView 命主卡顶部生肖图(同 reveal 屏图)正确显示
  - **验收**:深度解析 tab ChartHeader 显示对应 yearPillarLabel(如 `戊子年`)

**失败排查**:
- 生肖图错位 → 查 console `op=zodiacCalculator` 日志确认 zhi 值;若触发 `fatalError`,看 crash report `生肖字段缺失`
- 二次确认 sheet 不弹 → 查 `FirstLaunchBirthFormView.onSubmit` 是否走 `showSubmitConfirm = true`
- 立春边界(2月3-5日出生用户)→ 单独验证 2000-02-03 / 2000-02-05 生肖切换

## 测试 2:Light / Dark 模式

**目标**:24 张 asset(12 light + 12 dark)正确切换 + 文字对比度可读。

- [ ] **2.1** 在测试 1 流程中,任选 1 生肖(推荐龙, asset `Zodiac_Dragon`)→ 模拟器菜单 `Features → Toggle Appearance`
  - **验收 light**:背景 `#FDFCFA`,印章图走 `_light.webp`
  - **验收 dark**:背景深色,印章图走 `_dark.webp`(墨夜瓷釉配色,色板见 `DESIGN.md`)
  - **验收**:切换无闪烁, asset 即时切换
- [ ] **2.2** 同样切换走 ProfileView 命主卡(64pt 小尺寸)
  - **验收**:小尺寸 asset 细节可见,light/dark 切换正确
- [ ] **2.3** 切换走深度解析 ChartHeader
  - **验收**:yearPillarLabel 文字在 light/dark 都可读(`BaziTheme.ink` 颜色双值)

**已知风险**:`.tmp-zodiac-samples/` 里 24 张原图是 prompt 生成的,Asset Catalog 在 commit `34f823a` 注册了 appearance set。若某生肖 dark 版对比度不够(看不清印章),回 `.tmp-zodiac-samples/gen_all_dark.py` 调 prompt 重新生成。

## 测试 3:失败路径(retry + 3 次失败 persistentFailure)

**目标**:验证 `failureCount` 累加 + `persistentFailure` UI 切换 + 重启 App 清零。

- [ ] **3.1** 后端 FastAPI 停掉(`Ctrl+C` uvicorn 进程)→ App onboarding 提交
  - **验收**:首次失败 → ErrorStateView 显示 `排盘异常 / 排盘引擎暂不可用,请稍后重试` + "重试"按钮
  - **验收**:console 日志 `deepVM.calculate.failed count=1 error=...`
- [ ] **3.2** 点"重试"(两次)
  - **验收**:第 2 次失败 console `count=2`,仍可重试
  - **验收**:第 3 次失败 console `count=3`,UI 切换为:
    - 主文字 `反复失败`
    - 副文字 `多次排盘未成功,请检查网络后重启 App`
    - 图标 `exclamationmark.octagon.fill`(八边形,区别于单次 `.triangle`)
    - **retry 按钮隐藏**(对齐 dailyLimitReached 模式)
- [ ] **3.3** 杀掉 App(`Cmd+Shift+H` 双击拖走)→ 重启 App → 重新走 onboarding 提交
  - **验收**:failureCount 已清零(VM 实例生命周期 = 计数器生命周期,非持久化)
  - **验收**:首次失败 console 又是 `count=1`
- [ ] **3.4** 二次确认 sheet 取消按钮
  - **验收**:点"返回修改" sheet dismiss,表单值保留可继续编辑
  - **验收**:console 日志 `BirthInfoConfirmSheet.shown` 出现过一次

**失败排查**:
- `persistentFailure` 不触发 → 看 `DeepAnalysisViewModel.calculate()` catch 块 `failureCount >= 3` 分支
- retry 按钮仍显示 → 看 `ErrorStateView.swift` `if case .persistentFailure` 分支是否命中
- 杀 App 后状态保留 → `failureCount` 是 VM 实例变量,VM 随 onboarding view 重建,**不该**持久化。若保留,说明误存到 SwiftData / UserDefaults

## 测试 4:重置命盘流程

**目标**:验证 ProfileView 重置按钮清空 6 张 SwiftData 表 + hasSeenOnboarding = false + 重新走 onboarding。

- [ ] **4.1** 完成 onboarding 进 App → 跑一次深度解析(生成 InterpretationCache)→ 跑一次合盘(生成 CompatibilitySnapshot)→ 看一次每日运势(生成 DailyFortuneSnapshot)
  - **目的**:让 6 张表都有数据
- [ ] **4.2** Tab "我的" → 找"重置命盘"按钮(设置 section,destructive role)
  - **验收**:点按钮 → 二次确认 alert `确定要清空所有命盘和解读记录吗?`
  - **验收**:alert message 包含 `此操作不可恢复。所有命盘、合盘记录、解读缓存都会被清空。`
- [ ] **4.3** 点"取消"
  - **验收**:alert dismiss,所有数据保留(ProfileView 命主卡仍有图)
- [ ] **4.4** 再次点"重置命盘" → 点"确定重置"
  - **验收**:App 自动回到 onboarding(StartPage)
  - **验收**:console 日志记录 6 张表 fetchAndDeleteAll 顺序执行
- [ ] **4.5** 重新走 onboarding 提交(可用任意测试数据,如 2000-06-15 男 北京)
  - **验收**:ZodiacRevealView 出现 → 落地今日运势
  - **验收**:今日运势重新生成(不读旧 DailyFortuneSnapshot,因为已清空)
  - **验收**:深度解析 tab 是初始态(命盘已清空,需要重新提交;B2 流的设计是 hasSeenOnboarding=true 不再强制 onboarding,但 chart 已没,深度解析 tab 内的 BirthFormView 显示)

**失败排查**:
- 重置后 App 卡白屏 → `ProfileView.resetAllData()` 的 SwiftData delete 顺序是否触发 cascade?查 `UserSnapshotLink` / `ChartSnapshot` 的 `@Relationship` 配置
- 重置后 onboarding 没弹 → 看 `@AppStorage("hasSeenOnboarding")` 是否被 reset
- 数据残留 → SwiftData ModelContext 没保存?看 `try context.save()` 是否在 fetchAndDeleteAll 之后调用

## 已知限制

阶段 7 在 simulator 能覆盖大部分逻辑,以下场景必须**真机 + TestFlight**才能完整验证:

1. **真机网络切换体验**:飞行模式开关、弱网(3G/EDGE)、WiFi ↔ 蜂窝切换时的 retry 行为
2. **真机 light/dark 自动切换**:`Auto` appearance 跟随日落 / 系统主题
3. **真机 HapticEngine**:盖章动效的 medium 触感(simulator 无触感)
4. **App Store review 体验**:首次启动权限弹窗(通知 / 位置)、首屏加载时长
5. **iOS 17.2 边界**:最低部署目标真机验证(若 TestFlight 跑 iOS 17.5+ 设备,17.2 实机另行测试)
6. **生肖图视觉品质**:24 张 asset 在 OLED / LCD 屏的色彩还原(simulator 走 Mac 屏,色域不同)
7. **重置命盘后 IAP 状态**:`Entitlement` 表清空后,StoreKit transaction 是否仍保留?(需要 sandbox 账号测试)

## 结果记录

每次跑完整个 checklist,在下方追加一行:

| 日期 | 测试人 | 环境 | 结果 | 备注 / 截图 |
|---|---|---|---|---|
| YYYY-MM-DD | (名字) | sim iPhone 16 / iOS 18.3.1 / backend commit XXX | ✅ pass / ❌ fail | 截图 link / 失败项 |

跑完发现的问题,在 `bazi-app-design-doc.md` §Open Questions 或新建 GitHub issue 跟进。

## 后续(超出阶段 7 范围)

- 真机 + TestFlight QA:见 memory `project_ci_distribution_plan.md`(2026-07-13 决策:GitHub Actions + TestFlight 手动 archive 主路径)
- 自动化测试基础设施(若 v2 引入):XCUITest target + snapshot test 库 + orchestrator protocol 抽取 — 当前 v1 不做
