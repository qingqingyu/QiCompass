# 每日运势页 · 设计评审修复 slices(2026-09-28)

> 来源:外部设计评审(EN 截图,劫财日 · 冲猪 · AI 解读失败态)+ 本仓库代码核对。
> 本文是**实施事实源**。执行方按 S01-S06 顺序施工;「未拍板项」一律**不做**。
> 完成后由评审方(Claude)按文末「Review 清单」逐条验收。

## 0. 执行须知(硬约束,违反即打回)

- **分支**:`claude/daily-fortune-design-review-iilz1q`。每个 slice 一个 commit,不要把多个 slice 揉成一个。
- **Commit 三段式**(CLAUDE.md):body 必须有 Why / What(改了哪些函数/类/文件)/ Impact。
- **只动 iOS 前端**:本轮不碰 `backend/`、`app/ai/prompts.py`、`PromptContextBuilder*.swift`、`ModuleDefinitions.swift`(因此无需跑 `check_prompt_sync.py` / evalkit)。不改 `BaziTerms.swift`(术语翻译属于 D5,未拍板)。
- **不新建 .swift 文件**:新测试写进已有测试文件(见各 slice),避免 pbxproj 4 处登记。确实必须新建时,四处 24 位 ID 一致登记,并在 commit body 写明。
- **不加依赖**。
- **错误显式传播**:不得删除现有 `AppLogger` 日志;查表 miss 的日志 + fallback 逻辑保持。
- **DESIGN.md**:所有视觉改动必须符合 DESIGN.md;本文 S01-S06 已核对合规。收尾时在 DESIGN.md Decisions Log 追加**一行** 2026-09-28 记录(见 S06)。
- **三语**:凡改文案,zh-Hans / zh-Hant / en 三份同时改;xcstrings 新 key 三语 `state: translated`。
- **验证**:能跑 Xcode 就跑 `DailyFortune` 下全部测试 + 本文新增测试,并出截图(见各 slice 验收)。**跑不了就在 commit body / 回报里明说「未运行」**,不要写「已验证」。

文件缩写:
- `HERO` = `ios/QiCompass/QiCompass/Features/DailyFortune/DailyImageHeroSection.swift`
- `INTERP` = `ios/QiCompass/QiCompass/Features/DailyFortune/DailyInterpretationSection.swift`
- `XCS` = `ios/QiCompass/QiCompass/Resources/Localizable.xcstrings`
- `L10N` = `ios/QiCompass/QiCompass/L10n/L10n.swift`

---

## S01 · P0 宜忌词表与兜底文案互相矛盾

**问题**:劫财日图内「宜」列有「分利 / Split the Gains」,同屏解读兜底文案写「借贷与分利之事,尤其慢一拍」/「think twice before…splitting stakes」。EN「宜 Act Now」对「just don't rush」同样打架。两张表(`HERO` `HeroYiJiColumns.mapping*` 与 `INTERP` `EngineReadingTemplates.*`)各自维护,无一致性守护。

已核对全部 10 个十神(zh 脚本 + 人工 EN),需改的只有下表 4 处,其余不动:

| 十神 | 表 | 原 | 新 | 理由 |
|---|---|---|---|---|
| 劫财 | `mappingZh` 宜 | 分利 | **结伴** | 与模板「分利慢一拍」直接矛盾;比劫=同辈,结伴取其正面 |
| 劫财 | `mappingHant` 宜 | 分利 | **結伴** | 同上 |
| 劫财 | `mappingEn` 宜 | Act Now | **Take the Lead**(13) | 「Act Now」语气压过模板的「don't rush」 |
| 劫财 | `mappingEn` 宜 | Split the Gains | **Team Up**(7) | 同 zh |
| 食神 | `mappingZh` 宜 | 见新友 | **会友** | 模板写「与老友相见」,新/老打架 |
| 食神 | `mappingHant` 宜 | 見新友 | **會友** | 同上 |
| 七杀 | `mappingEn` 宜 | Push Through | **Face It Head-On**(15) | 「Push Through」与模板「don't burn yourself out」、忌列「Burn Out」打架 |

- 兜底模板 `EngineReadingTemplates.zh/hant/en` **不改**。
- 同步更新 `HERO` 里 `mappingEn` 上方的注释(说明 2026-09-28 因宜忌⟷模板矛盾改 3 条)。

**新增守护测试**(写进 `ios/Tests/DailyFortune/DailyImageHeroCopyTests.swift`):

```swift
/// 宜词不得出现在兜底模板的告诫半句(分号后)——2026-09-28 外评「宜分利 vs 分利慢一拍」。
/// zh / zh-Hant 两表逐键检查;EN 为短语无法子串比对,靠人工 review(见 slices 文档 S01)。
func testYiItemsNotContradictedByEngineTemplateCaution() {
    let pairs: [([String: (yi: [String], ji: [String])], [String: String])] = [
        (HeroYiJiColumns.mappingZh, EngineReadingTemplates.zh),
        (HeroYiJiColumns.mappingHant, EngineReadingTemplates.hant),
    ]
    for (mapping, templates) in pairs {
        XCTAssertEqual(Set(mapping.keys), Set(templates.keys))
        for (relation, cols) in mapping {
            guard let text = templates[relation] else { continue }  // 键集合不等已由上方断言报出
            guard let semi = text.firstIndex(where: { $0 == ";" || $0 == "；" }) else {
                XCTFail("模板缺分号(告诫半句分隔):\(relation)")
                continue
            }
            let caution = text[semi...]
            let hits = cols.yi.filter { caution.contains($0) }
            XCTAssertTrue(hits.isEmpty, "\(relation) 宜词出现在模板告诫半句:\(hits)")
        }
    }
}
```

(`mappingZh` / `mappingHant` / `EngineReadingTemplates` 若为 private 需放宽到 internal;当前均为 `static let` internal,应可直接访问。)

**验收**:
- 新测试 PASS;把「结伴」临时改回「分利」时该测试 FAIL(执行方自测一次后还原,回报中写明做过)。
- `testMappingEnBudgetAllWithin16Chars` 仍 PASS。

---

## S02 · P0 失败态小注措辞:「Reading failed」与正文并存像自相矛盾

**背景(不可推翻)**:2026-09-24 拍板「AI 失败 → 正文位显示引擎确定性模板 + 底部小注如实标状态,模板不冒充 AI 解读」。所以**不删正文、也不删状态注**。
**问题**:小注现在直接显示 `.failed(message)` 的原始错误标题(EN =「Reading failed」),没告诉用户上面那段是什么。

**改法**(`INTERP` `case .failed(let message)` 分支):
1. 新 xcstrings key `dailyfortune.interpret.fallbackNote`,`L10N` 加 `static let interpretFallbackNote`(注释写 zh / en 原文):
   - zh-Hans:`AI 解读暂未生成 · 以上为今日通用参考`
   - zh-Hant:`AI 解讀暫未生成 · 以上為今日通用參考`
   - en:`AI reading unavailable · above is general guidance for today`
2. 非静默重试分支:小注 `Text(message)` → `Text(L10n.DailyFortune.interpretFallbackNote)`;原 `message` 不丢,挂到该 HStack 的 `.accessibilityHint(Text(message))`。Retry 按钮不变。
3. 静默重试分支的 `dailyfortune.interpret.retrying` 文案同步改,让两态都说清「上面是通用参考」:
   - zh-Hans:`以上为今日通用参考 · AI 解读重试中`
   - zh-Hant:`以上為今日通用參考 · AI 解讀重試中`
   - en:`General guidance above · retrying AI reading`
   同步更新 `L10N` 中该 key 的注释。
4. 小注允许折两行(去掉任何单行限制,保持 `.frame(maxWidth: .infinity, alignment: .leading)`);Retry 用 `.firstTextBaseline` 对齐不变。
5. 确认 VM 失败路径仍有 `AppLogger` 记录原始错误(`DailyFortuneViewModel.swift` 进入 `.failed` 处);若某条路径没有日志,**补一条**,不许因为 UI 不再显示原文而让错误彻底不可见。

**验收**:
- EN / zh 两张失败态截图:正文 + 新小注 + Retry,无「Reading failed」字样。
- `DailyFortuneFailureFallbackTests` 全 PASS(VM 语义未变)。
- `python3 tools/check_term_sync.py` 不受影响(不涉及),不需要跑;xcstrings 由 Xcode 打开一次确认无 stale / 无 orphan。

---

## S03 · P1 hero 内容与解读卡左边距不对齐

**问题**:hero 内容浮层内边距 4pt(`HERO` `contentOverlay` 两处 `.padding(.horizontal, 4)`),解读卡内边距 20pt;两框外缘同为 17pt,所以「28」「Do」离屏幕 21pt,解读正文 37pt,差 16pt。

**改法**:
1. `contentOverlay` 两处 `.padding(.horizontal, 4)` → `.padding(.horizontal, 20)`(与 `INTERP` 的 `.padding(.horizontal, 20)` 同值;最好在 `HERO` 里抽一个 `private static let contentInset: CGFloat = 20` 并注释「与 DailyInterpretationSection 内边距对齐,2026-09-28」)。
2. 宽度补偿:`HeroYiJiColumns.body` 的 `HStack(spacing: 34)` → `spacing: 24`。
   预算:375pt 屏(SE/mini)单列 = (375 − 34 − 40 − 24)/2 ≈ 138pt;EN 最长条目 16 字符 New York 15pt ≈ 120-128pt,放得下。
3. EN 条目 `Text(item)` 加 `.lineLimit(1)` + `.minimumScaleFactor(0.9)` 作兜底(防个别设备字宽超预算折行)。
4. 更新 `DailyImageHeroCopyTests.testMappingEnBudgetAllWithin16Chars` 头注释中的列宽数字(~163pt → ~138pt @375 屏),预算 16 不变。

**验收**:EN / zh 截图,「28」左缘、「Do/宜」左缘、「Today's Reading」左缘、解读正文左缘四者在同一竖线(±1pt);375pt 与 402pt 两种宽度 EN 宜忌条目均单行、未被缩小到明显可见。

---

## S04 · P1 「T o d a y ' s  R e a d i n g」字距过宽

**问题**:`INTERP` 标题 `.tracking(4)` 是给中文楷体小标定的;英文大小写混排 + 4pt 字距很难读。DESIGN.md 的大字距只适用于**全大写** Latin caps。

**改法**(`INTERP` 标题 Text):
- 中文(zh / zh-Hant):保持 `BaziFont.caption(size: 10)` + `.tracking(4)` 不变。
- EN:`BaziFont.latinCaps(size: 10)` + `.textCase(.uppercase)` + `.tracking(2)`。
- 语言判断用 `AppLanguage.current.isChinese`(与 `BaziFont` 同源)。
- 只改本文件这一处;**不**全仓扫改其他页面的同类写法(另开 slice)。

**验收**:EN 截图显示「TODAY'S READING」,字距约 0.2em;zh 截图不变。

---

## S05 · P1 hero 顶部 / 左右出现矩形硬边

**问题**:`bloomMask` 圆心 y=0.42、endRadius 400,卡顶离圆心约 169pt(0.42 < 实心阈 0.58),左右离圆心约 178pt(0.45 < 0.58)——顶边和左右边**完全不透明**;`rimLayer` 同理在这三条边上仍透明。只有底边有 `bottomFadeLayer`,所以截图里顶部和左侧能看到山水被直线切断。

**改法**(`HERO`):
1. 新增 `edgeFadeLayer`(放在 `bottomFadeLayer` 之后、`mistLayer` 之前),纸色压边,不改底图与 mask:
   - 顶边:`LinearGradient` paper → paper.opacity(0),stops 0 → 0.14,`.top` → `.bottom`。
   - 左右:`LinearGradient` paper → clear(0 → 0.07)与 clear → paper(0.93 → 1),`.leading` → `.trailing`。
   - 两个梯度 `ZStack` 叠放,`.allowsHitTesting(false)`。颜色一律 `BaziTheme.paper`(dyn 双值,暗色自动夜宣纸)。
2. 顶部类型注释的「玻璃配方」列表补一行 `4c 四边融纸(2026-09-28 外评「顶部矩形切边」)`。
3. **不用** `backgroundGradient` 做背景;这里是叠在图上的纸色遮罩层,与现有 `bottomFadeLayer` 同性质,合规。

**验收**:亮 / 暗两张截图,hero 顶边、左边、右边都看不到直线切口;日期数字与 chips 可读性不下降。

---

## S06 · P1 关系 chip 朱红违规 + 大字号下 chip 失控 + 无障碍补冲

三件都在 `HERO` chips / 无障碍附近,合并一个 slice。

**(a) 朱红违规**:`chips` 里关系 chip `tint: BaziTheme.cinnabar`。DESIGN.md 色板规定朱红**仅印章级**(SealStamp / 付费标 / 聚焦线 / 当前时辰点 / 在读态),验收清单要求「cinnabar 仅授权场景」。十神关系 chip 不在授权清单内。
→ 改 `tint: BaziTheme.ink`(冲 chip 保持 `inkMuted`,主次靠墨色浓淡区分)。

**(b) 大字号失控**:`ChipView` 用 `.caption.weight(.medium)`(跟随 Dynamic Type),而 hero 内其余文字都是固定字号、卡高固定 402pt。用户系统开大字号时 chip 比「Do」列头还显眼、「Clashes with Pig」顶到卡边。
→ 在 `HERO` `chips` 上加 `.dynamicTypeSize(...DynamicTypeSize.large)`(只作用于 hero chips,不改 `ChipView` 本身,其他页面行为不变)。chip 信息由 (c) 保证无障碍可达。

**(c) 无障碍补冲**:`heroAccessibilityLabel` 目前只读干支 + 短标 + 宜忌,**没读冲**。有 `dayChong` 时,在干支后追加 `L10n.DailyFortune.chongLabel(chong:targets:)` 的结果。

**DESIGN.md Decisions Log**:追加一行 2026-09-28,概括 S01-S06(宜忌⟷模板一致性守护 / 失败小注改「通用参考」/ hero 内边距 20 对齐 / EN 小标大写 2pt 字距 / hero 四边融纸 / 关系 chip 朱红改墨 + chips 字号上限 + a11y 补冲)。

**验收**:
- `grep -n "cinnabar" HERO` 结果中不再有 chips。
- 系统字号调到 AX 最大档截图:chips 与 hero 其余文字比例正常、不出卡。
- VoiceOver 读 hero 时包含「Clashes with …」/「冲…」。

---

## 未拍板项(本轮**不做**,等用户决定)

| # | 事项 | 为什么要拍板 |
|---|---|---|
| D1 | 飞鸟:删除 / 改为静止固定在山顶 | 09-25 已打磨过一次,仍被外评读成乱码;删除属视觉减法,需用户同意 |
| D2 | 导航标题「Daily Fortune」:隐藏 / 改衬线 | 系统导航栏全局外观,影响全部四个 tab |
| D3 | 十神 chip 点开看解释(如「劫财日:主动出击,但留意钱财被分走」) | 新功能;解释文案须确定性静态表(LLM 只润色不判断),需产品定义 |
| D4 | Chart tab 图标辨识度 | tab-icons-20260830 定稿物,改图标走设计流程 |
| D5 | 「Rob Wealth」英文术语是否换更温和的译名 | 术语单一事实源在 backend `term_translations.py` + `check_term_sync.py`,改动跨端 |

---

## Review 清单(评审方验收用)

- [ ] 6 个 commit,一 slice 一个,均为三段式 body
- [ ] `git diff` 只触及:`HERO` / `INTERP` / `L10N` / `XCS` / `DailyImageHeroCopyTests.swift` / (必要时)`DailyFortuneViewModel.swift` 日志 / `DESIGN.md`;无 pbxproj 变更(除非明确说明)
- [ ] S01 词表 7 处与上表逐字一致;模板未改;新测试存在且逻辑与本文一致
- [ ] S02 新 key 三语齐全;原始错误进 accessibilityHint;VM 失败路径均有日志
- [ ] S03 两处 padding=20、spacing=24、EN 条目 lineLimit+minimumScaleFactor
- [ ] S04 仅 EN 分支变化,zh 保持 tracking 4
- [ ] S05 新增纸色压边层,无 backgroundGradient,无新增朱红
- [ ] S06 chips 无 cinnabar;dynamicTypeSize 只加在 hero chips;a11y label 含冲
- [ ] 未拍板项 D1-D5 一项都没动
- [ ] 回报里写清:哪些测试跑了 / 结果;哪些截图出了;没跑的明确说没跑
