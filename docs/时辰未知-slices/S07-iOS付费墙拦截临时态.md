# S07 iOS 一期拦截临时态(付费墙 + 每日运势)

- **类型**: AFK
- **Blocked by**: S04(入口/状态)、S05(展示层)、S06(免费 2 章降级叙事可用)、S01(每日运势拦截判据读 payload;契约层 `ChartPayload` 亦在 S01)
- **覆盖决策**: D6(拦在付费墙那一步:不展示价格、不触发 purchase;主论证双重收费)/ D5(付费 8 章临时全拦;免费 2 章照给——限日柱确定者;合盘任一方无时辰整对拦)/ D9 一期范围
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

无时辰用户(hour_known=false)在付费墙位置的拦截态——**一期临时形态**(一句话 + 占位入口,S10 接线闭环)。**两类用户分开**:

- **日柱确定的无时辰用户**:免费 2 章照给(S06 降级叙事以日主为轴,日主完整)
- **日柱歧义用户**(late_night=是/不确定,或 S02 比对命中):**不进内容页,免费 2 章也拦**(没有日主,S06 降级叙事轴不存在,「免费降级不成立」同 Parent D5 每日运势全拦的逻辑链;对齐 S05 item 6)——直接呈现拦截态

1. **深度解析**(日柱确定路径):免费 2 章照给(S06 降级叙事);到付费墙(第 3 章起)→ PaywallView 进入拦截态:
   - **不展示价格、不展示购买按钮、不加载 StoreKit product**(不触发 purchase 链路)
   - 文案:「补充出生时刻后解锁」+ 一句为什么(时辰缺失影响喜忌分析精度)
   - CTA 占位(轻提示或 disabled,注释标 S10 接线到补时辰 sheet)
2. **合盘**:**任一方无时辰**(自己或该对对方,含日柱歧义)→ **整对拦**(对齐 Parent D5「任一方无时辰即拦该对」),呈现与付费墙同款拦截态。注意:免费部分**也拦**。理由已由 2026-09-01 review 更正并回写进 Parent D5——**不是**「`ChartPayload` 契约表达不了」(S01 已把该模型扩开,它同时是每日运势的请求模型),而是 **`_COMPATIBILITY_REQUIRED_FIELDS` 被 `compatibility` / `_free` / `_paid` 共用同一份**(`prompts.py:643` 注释明写「共享 header」),其中含 `hour_a` / `hour_b` / `day_master_strength_a` / `favorable_a`——免费章与付费章用同一套上下文,免费章物理上渲染不出来。「免费照给/付费拦」形态只适用于双方有时辰的对;要做合盘免费降级需单独一份 `compatibility_free` 字段集,属独立课题。roster entry 级标记与发起前拦截的完整态归 S11(本 slice 拦在发起后的阶段 2 位置,行为一致、入口更浅)
3. **每日运势一期临时全拦**(2026-09-01 review 补入,原分割漏项——**一期没有任何 slice 覆盖每日运势,而它是默认落地 Tab**):`RootTabView.swift:20` `selectedTab = .dailyFortune`,无时辰用户走完 onboarding 第一眼就是这屏。一期不做降级 prompt(那是 S09/二期),但**不能留空白**:
   - `hour_known=false`(含日柱确定与歧义两类)→ 每日运势走与付费墙同款拦截态,**不发起 interpret / daily-fortune 请求**
   - 拦截前置在 `DailyFortuneViewModel` 生成入口,`ChartPayloadDTO.from` 不被调用
   - 二期 S09 把「日柱确定」那一支从拦截换成降级内容,「日柱歧义」一支保持拦截(D5 终态)
4. **拦截条件单一事实源**:以 chart 存档的 `hour_known`(S04 payload)+ 日柱歧义标记为判据,**不重复推断**;entitlement/purchase 判据(2026-08-16:购买判据=exchange 完成)不动——拦截发生在 purchase 之前,与判据无交集
5. **redeem 路径**:StoreKit 同步端点照常(无拦截决策);App Store 促销码用户落到同一拦截页(权益记账正常、内容拦)——一期该场景为边缘,验收以不 crash 为准

## Acceptance criteria

- [ ] 无时辰用户(日柱确定):深度解析免费 2 章可读(S06 叙事),付费墙处无价格无购买按钮,`PurchaseManager.purchase` 全程不可达(路径断言)
- [ ] 日柱歧义用户:不进内容页,免费 2 章亦拦,直接拦截态(与付费墙拦截同款表达)
- [ ] 有时辰用户:付费墙与现状完全一致(价格/按钮/购买链路零变化)
- [ ] 合盘任一方无时辰 → 整对拦截态(免费亦拦);双方有时辰 → 免费可读、付费照常
- [ ] **无时辰用户(两类)进每日运势 Tab → 拦截态,不发起网络请求**(`ChartPayloadDTO.from` 未被调用的路径断言)
- [ ] 有时辰用户每日运势与现状完全一致(生成/缓存/历史回看零变化)
- [ ] 走完 onboarding 直接落地每日运势 Tab 不白屏、不 422、不 crash
- [ ] CTA 占位点击不 crash(一期占位行为)
- [ ] XCTest:判据分支(hour_known true/false × 日柱歧义 × 自己/对方)/ purchase 不可达 / 有时辰回归

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `iOS/QiCompass/QiCompass/Features/Paywall/PaywallView.swift` / `PaywallViewModel.swift` — 付费墙态机
- `iOS/QiCompass/QiCompass/Services/PurchaseManager.swift` — purchase 入口(拦截在调用之前)
- `iOS/QiCompass/QiCompass/Services/CompatibilityOrchestrator.swift` — 合盘阶段 2(免费/付费 module 选择处)
- `iOS/QiCompass/QiCompass/App/RootTabView.swift:20` — 默认 Tab = dailyFortune(为什么每日运势一期必须有终态)
- `iOS/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneViewModel.swift` — 生成入口(一期拦截位,S09 二期改降级)
- ChartSnapshot payload `hour_known`(S04)/ 歧义标记(S05 解码)

## 红线与约束

- 拦购买 ≠ 拦内容:免费内容照给(MONETIZATION.md 设计哲学第一条)——限「有依据可给」的场景:深度解析限日柱确定者;日柱歧义与合盘任一方无时辰因降级依据/后端契约不成立而整拦(见上),不适用本条
- 不做按章节部分售卖(D5 写死);一期临时全拦,二期文案适配
- entitlement 重绑不做(mismatch_reject 独立课题)
- 拦截判据不做第二套来源(单一事实源 = payload)
- 拦截态新文案(「补充出生时刻后解锁」+ 为什么一句)进 L10n / xcstrings(中英)

## 测试

- `iOS/Tests/` Paywall 拦截态用例 + purchase 不可达断言 + 有时辰回归
