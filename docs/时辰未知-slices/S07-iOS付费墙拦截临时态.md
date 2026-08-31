# S07 iOS 付费墙拦截(一期临时态)

- **类型**: AFK
- **Blocked by**: S04(入口/状态)、S05(展示层)、S06(免费 2 章降级叙事可用)
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
2. **合盘**:**任一方无时辰**(自己或该对对方,含日柱歧义)→ **整对拦**(对齐 Parent D5「任一方无时辰即拦该对」),呈现与付费墙同款拦截态。注意:免费部分**也拦**,不是 D5 同形态照给——现状后端 `ChartPayload` 契约无法表达无时辰盘(Literal 无 `unknown_hour`、`four_pillars` 必含 `hour`,见 S11 item 5 的 422 防线记录),任一方无时辰的对根本无法发起计算,「免费照给」物理上不成立;「免费照给/付费拦」形态只适用于双方有时辰的对。**此处是对 Parent D9 一期「合盘付费部分临时全拦」字面的有意偏离**:整对拦的依据是 D5 终态语义 + 后端契约物理不可计算,提前到一期是被迫的可行性收敛,不是范围蔓延。roster entry 级标记与发起前拦截的完整态归 S11(本 slice 拦在发起后的阶段 2 位置,行为一致、入口更浅)
3. **拦截条件单一事实源**:以 chart 存档的 `hour_known`(S04 payload)+ 日柱歧义标记为判据,**不重复推断**;entitlement/purchase 判据(2026-08-16:购买判据=exchange 完成)不动——拦截发生在 purchase 之前,与判据无交集
4. **redeem 路径**:StoreKit 同步端点照常(无拦截决策);App Store 促销码用户落到同一拦截页(权益记账正常、内容拦)——一期该场景为边缘,验收以不 crash 为准

## Acceptance criteria

- [ ] 无时辰用户(日柱确定):深度解析免费 2 章可读(S06 叙事),付费墙处无价格无购买按钮,`PurchaseManager.purchase` 全程不可达(路径断言)
- [ ] 日柱歧义用户:不进内容页,免费 2 章亦拦,直接拦截态(与付费墙拦截同款表达)
- [ ] 有时辰用户:付费墙与现状完全一致(价格/按钮/购买链路零变化)
- [ ] 合盘任一方无时辰 → 整对拦截态(免费亦拦);双方有时辰 → 免费可读、付费照常
- [ ] CTA 占位点击不 crash(一期占位行为)
- [ ] XCTest:判据分支(hour_known true/false × 日柱歧义 × 自己/对方)/ purchase 不可达 / 有时辰回归

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `iOS/QiCompass/QiCompass/Features/Paywall/PaywallView.swift` / `PaywallViewModel.swift` — 付费墙态机
- `iOS/QiCompass/QiCompass/Services/PurchaseManager.swift` — purchase 入口(拦截在调用之前)
- `iOS/QiCompass/QiCompass/Services/CompatibilityOrchestrator.swift` — 合盘阶段 2(免费/付费 module 选择处)
- ChartSnapshot payload `hour_known`(S04)/ 歧义标记(S05 解码)

## 红线与约束

- 拦购买 ≠ 拦内容:免费内容照给(MONETIZATION.md 设计哲学第一条)——限「有依据可给」的场景:深度解析限日柱确定者;日柱歧义与合盘任一方无时辰因降级依据/后端契约不成立而整拦(见上),不适用本条
- 不做按章节部分售卖(D5 写死);一期临时全拦,二期文案适配
- entitlement 重绑不做(mismatch_reject 独立课题)
- 拦截判据不做第二套来源(单一事实源 = payload)
- 拦截态新文案(「补充出生时刻后解锁」+ 为什么一句)进 L10n / xcstrings(中英)

## 测试

- `iOS/Tests/` Paywall 拦截态用例 + purchase 不可达断言 + 有时辰回归
