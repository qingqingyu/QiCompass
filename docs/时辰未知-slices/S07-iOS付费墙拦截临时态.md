# S07 iOS 付费墙拦截(一期临时态)

- **类型**: AFK
- **Blocked by**: S04(入口/状态)、S05(展示层)、S6→S06(免费 2 章降级叙事可用)
- **覆盖决策**: D6(拦在付费墙那一步:不展示价格、不触发 purchase;主论证双重收费)/ D5(付费 8 章 + 合盘付费临时全拦;免费 2 章照给)/ D9 一期范围
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

无时辰用户(hour_known=false,含日柱歧义用户)在付费墙位置的拦截态——**一期临时形态**(一句话 + 占位入口,S10 接线闭环):

1. **深度解析**:免费 2 章照给(S06 降级叙事);到付费墙(第 3 章起)→ PaywallView 进入拦截态:
   - **不展示价格、不展示购买按钮、不加载 StoreKit product**(不触发 purchase 链路)
   - 文案:「补充出生时刻后解锁」+ 一句为什么(时辰缺失影响喜忌分析精度)
   - CTA 占位(轻提示或 disabled,注释标 S10 接线到补时辰 sheet)
2. **合盘**:无时辰用户(自己或该对对方)→ 合盘付费部分同款拦截态;免费部分照给(D5 同形态)——本 slice 只做「自己无时辰」路径的付费墙拦截;roster 对级标记完整态归 S11
3. **拦截条件单一事实源**:以 chart 存档的 `hour_known`(S04 payload)+ 日柱歧义标记为判据,**不重复推断**;entitlement/purchase 判据(2026-08-16:购买判据=exchange 完成)不动——拦截发生在 purchase 之前,与判据无交集
4. **redeem 路径**:StoreKit 同步端点照常(无拦截决策);App Store 促销码用户落到同一拦截页(权益记账正常、内容拦)——一期该场景为边缘,验收以不 crash 为准

## Acceptance criteria

- [ ] 无时辰用户:深度解析免费 2 章可读(S06 叙事),付费墙处无价格无购买按钮,`PurchaseManager.purchase` 全程不可达(路径断言)
- [ ] 有时辰用户:付费墙与现状完全一致(价格/按钮/购买链路零变化)
- [ ] 日柱歧义用户:同无时辰拦截(走同一判据)
- [ ] 合盘付费部分拦截态生效;免费部分可读
- [ ] CTA 占位点击不 crash(一期占位行为)
- [ ] XCTest:判据分支(hour_known true/false × 日柱歧义)/ purchase 不可达 / 有时辰回归

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `iOS/QiCompass/QiCompass/Features/Paywall/PaywallView.swift` / `PaywallViewModel.swift` — 付费墙态机
- `iOS/QiCompass/QiCompass/Services/PurchaseManager.swift` — purchase 入口(拦截在调用之前)
- `iOS/QiCompass/QiCompass/Services/CompatibilityOrchestrator.swift` — 合盘阶段 2(免费/付费 module 选择处)
- ChartSnapshot payload `hour_known`(S04)/ 歧义标记(S05 解码)

## 红线与约束

- 拦购买 ≠ 拦内容:免费内容照给(MONETIZATION.md 设计哲学第一条)
- 不做按章节部分售卖(D5 写死);一期临时全拦,二期文案适配
- entitlement 重绑不做(mismatch_reject 独立课题)
- 拦截判据不做第二套来源(单一事实源 = payload)

## 测试

- `iOS/Tests/` Paywall 拦截态用例 + purchase 不可达断言 + 有时辰回归
