# S03 iOS 界面品牌字样

- **类型**: AFK + HITL(启动页副题文案由用户选)
- **Blocked by**: S01(可与 S02 并行)
- **Parent**: `docs/App改名KnowFate设计决策.md`「改名的全部落点」

## What to build

### 1. 主屏幕名(CFBundleDisplayName)

- 现状:`Resources/Info.plist` **没有** `CFBundleDisplayName`,只有 `CFBundleName = $(PRODUCT_NAME)`(= QiCompass);pbxproj 里 `INFOPLIST_KEY_CFBundleDisplayName = QiCompass`(Debug / Release 两处),但该 target `GENERATE_INFOPLIST_FILE = NO`,这个 build setting 是否生效需要实测
- 做法:在 `Info.plist` 加 `CFBundleDisplayName = KnowFate`;新建 `InfoPlist.xcstrings`(或 `zh-Hans.lproj/InfoPlist.strings` 等)做本地化:zh-Hans「观命」、zh-Hant「觀命」、en「KnowFate」;pbxproj 两处 `INFOPLIST_KEY_CFBundleDisplayName` 同步改为 KnowFate 以免混淆
- **新 .xcstrings 文件须 pbxproj 4 处登记**
- 验收以**真机主屏幕**显示为准(模拟器也可),三个系统语言各截一张

### 2. 品牌字样替换

| 文件 | 位置 | 改动 |
|---|---|---|
| `Shared/SplashTransitionView.swift` | ~32 / 36 / 37 / 52 行 | `SealStamp("玄")` →「观」(繁体界面「觀」);`VText("玄机问道")` →「观命」(两字竖排,调 `tracking` 与右列间距使构图平衡);副题「问道于心 · 观命如水」→ 新副题(见下);`Text("QICOMPASS")` → KNOWFATE |
| `Features/Onboarding/OnboardingView.swift` | ~511–522 行 | 印 →「观 / 觀」;`Text("玄机问道")` →「观命」(字距从 8 适当加大);KNOWFATE;无障碍标签「观命印章」 |
| `Features/DeepAnalysis/DeepAnalysisHomeView.swift` | ~360 行 | 喜忌行 `SealStamp("玄")` →「观 / 觀」 |
| `Features/Profile/ProfileView.swift` | ~747 / 750 / 873 / 877 行 | 重启提示里的 QiCompass → 跟随主屏幕名(简「观命」/ 繁「觀命」/ en「KnowFate」);底部 KNOWFATE;「观命 · 专业不忽悠」 |
| `Resources/Localizable.xcstrings` | 6 条词条 | 键与三语值同步:`QICOMPASS` → `KNOWFATE`;`玄机问道` → `观命`(en = KNOWFATE,zh-Hant = 觀命);`玄机问道 · 专业不忽悠` → `观命 · 专业不忽悠`(zh-Hant:`觀命 · 專業不忽悠`)(en 值:`KNOWFATE · Classical craft, no guesswork`);`玄机问道印章` → `观命印章`(zh-Hant:`觀命印章`)(en:`KnowFate seal`);两条重启提示 |

> 行号是 2026-11-24 的快照,实施以代码为准。全量查找命令:`grep -rn "玄机问道\|QICOMPASS\|QiCompass 后\|\"玄\"" ios/QiCompass/QiCompass --include=*.swift`。删掉旧键后确认没有残留引用。

### 3. 启动页副题 —— ✅ 2026-11-25 用户选定「知人者智 · 自知者明」

简繁同形(八个字均在 GBK 与 Big5 子集内,仍需跑 `build_songti_fonts.py --verify` 确认);现状:副题是 `SplashTransitionView.swift` 里写死的中文字面量 `VText(phrase: "问道于心 · 观命如水", …)`,不进 `Localizable.xcstrings`,所以 zh / zh-Hant / en 三种界面都显示这句中文(与「品牌字保持中文不翻译」口径一致)。改名只替换字面量为「知人者智 · 自知者明」,不改变这一处理。

<details><summary>当时的候选</summary>


原副题「问道于心 · 观命如水」与「玄机问道」成对,改名后需要新的一句。候选:
- 「问道于心」(保留原副题前半句;原后半句「观命如水」已与新名重字,去掉)
- 「知人者智 · 自知者明」(《道德经》第三十三章;落在「认识自己」,贴合「专业不忽悠」)
- 「知其然 · 知其所以然」(落在「讲清原理」,贴合确定性排盘)

</details>

### 4. 字体与测试

- `python3 tools/build_songti_fonts.py --verify` PASS(新副题的字必须在子集内,否则重跑构建脚本)
- `grep -rn "玄机问道\|QICOMPASS" ios/Tests`:当前无断言;若有 UI 测试或快照测试引用旧字样,同步更新
- 现有测试全绿

## 进度(2026-11-25)

代码改动已完成(在 Linux 环境完成,**未编译、未截图**,须在 Mac 上验证):

- **品牌字单一入口**:`Shared/InkKit.swift` 新增 `enum BrandMark`(`sealCharacter` 繁体界面「觀」/ 其余「观」;`chineseName` 繁体「觀命」/ 其余「观命」),语言只经 `AppLanguage.current` 取。放在现有文件内,未新增 .swift 文件
- **启动页** `SplashTransitionView`:印 → `BrandMark.sealCharacter`;竖题 → `BrandMark.chineseName`(字距 11→16);副题 →「知人者智 · 自知者明」;KNOWFATE
- **引导页** `OnboardingView`:印 → `BrandMark.sealCharacter`;`Text("观命")`(字距 8→14,走 xcstrings);KNOWFATE;无障碍标签「观命印章」
- **深度解析主页**喜忌行印 → `BrandMark.sealCharacter`
- **「我的」页**:KNOWFATE;「观命 · 专业不忽悠」;两条重启提示改用「观命」
- **`Localizable.xcstrings`**:6 条词条按文本原位改名(文件里有一个重复键,不能用 JSON 读写,否则会丢条目)
- **主屏幕名**:`Info.plist` 加 `CFBundleDisplayName = KnowFate`;新增 `Resources/InfoPlist.xcstrings`(zh-Hans 观命 / zh-Hant 觀命 / en KnowFate),pbxproj 4 处登记(ID `9C…016A`);pbxproj 两处 `INFOPLIST_KEY_CFBundleDisplayName` 改为 KnowFate
- 描述现状的注释同步;历史记录性质的注释保留
- 守护脚本:`check_sku_sync.py` PASS;`build_songti_fonts.py --verify` PASS;「觀」及副题八字在 TC 子集内已逐字确认。`check_term_sync.py` 未跑(需后端依赖;本次未动术语表,非必跑项)

**待 Mac 上验证**(并入 S06):Xcode 编译通过;`InfoPlist.xcstrings` 生效(三种系统语言主屏名);两字竖题与字距的构图;下面验收项的 24 张截图

## Acceptance criteria

- [ ] 三个系统语言下主屏幕名分别为 观命 / 觀命 / KnowFate(截图)
- [ ] 启动页、引导页、深度解析主页、「我的」页四处在 zh / zh-Hant / en × 亮 / 暗共 24 张截图,与改名前同位置截图并排对比,构图无明显失衡
- [ ] 全仓 `ios/QiCompass/QiCompass` 下用户可见字符串中不再出现「玄机问道」「QICOMPASS」「QiCompass」(内部标识除外:`QiCompassApp`、`X-QiCompass-Lang`、文件名、注释)
- [ ] `build_songti_fonts.py --verify` PASS;`check_sku_sync.py` PASS(证明没碰内购)
- [ ] reduce-motion 下启动页、引导页的印章落定为静态呈现(行为不变)
