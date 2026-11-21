import SwiftUI

// 今日 tab 视觉改版(2026-11-21 拍板,设计事实源 docs/design-ref/wuxing-styles/
// 11-merged.html):数字对开(峰值 vs 谷值)+ 纸上气泡场(五行力量)+ 编辑导语
// 下半(信号双栏 / 十二时辰谱 / 宜忌明日三栏)。四项拍板:
// ①纸色仅今日 tab(todayPaper);②保留 72pt 大日期;③宜忌沿用 HeroYiJiColumns
// 静态十神查表;④HaloBackdrop 光晕退役出布局(代码留在 DailyImageHeroSection.swift)。
//
// 判定性文案(对开标签/信号建议/时辰短词)走本文件静态三语表,不进 xcstrings
// (对齐 HeroYiShiShenNotes / HeroYiJiColumns 既定模式);chrome 标题走 L10n。

// MARK: - 五行排名(共享纯函数)

/// 五行力量排名:值降序,并列按木火土金水显示序(后端 ELEMENT_ORDER 锚定,
/// 与旧 DailyElementStrengthSection 同款判定序,改须两侧同步)。
enum TodayElementRank {
    static let displayOrder = ["木", "火", "土", "金", "水"]

    /// 只收显示序内的键,按 (值 desc, 显示序 asc) 排;internal 供测试。
    /// 显示序下标在枚举时预携带进元组,排序闭包零强解包(键集演化时排序器安全)。
    static func ranked(_ strength: [String: Int]) -> [(element: String, value: Int)] {
        displayOrder.enumerated()
            .compactMap { idx, el in strength[el].map { (order: idx, element: el, value: $0) } }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.order < $1.order }
            .map { ($0.element, $0.value) }
    }
}

// MARK: - 数字对开(纯逻辑)

/// 峰值 vs 谷值对开(11-merged .duel):hi = 分布最高项,lo = 最低项(含 0 值行
/// ——「今日无此行」是事实)。guard:有效键 <2 / 全值相等 / 全 0 → nil(宿主
/// 连气泡场一起隐藏)。internal 供 TodayVizLayoutTests。
struct TodayStrengthDuel: Equatable {
    struct Side: Equatable {
        let element: String
        let value: Int
        /// 该五行的今日信号方向("up"/"down");day_signal 未命中 = nil(标签降级
        /// 为纯事实「今日最旺/最弱」,不编喜忌语义)。
        let signal: String?
    }

    let hi: Side
    let lo: Side

    static func make(strength: [String: Int], daySignal: [DaySignalItemDTO]?) -> TodayStrengthDuel? {
        let ranked = TodayElementRank.ranked(strength)
        guard ranked.count >= 2,
              ranked.first!.value > 0,
              ranked.first!.value != ranked.last!.value else { return nil }
        func side(_ entry: (element: String, value: Int)) -> Side {
            let dir = (daySignal ?? []).first { $0.element == entry.element }?.direction
            return Side(element: entry.element, value: entry.value, signal: dir)
        }
        return TodayStrengthDuel(hi: side(ranked[0]), lo: side(ranked[ranked.count - 1]))
    }

    /// 对开标签(信号方向前缀 + 事实基词):返回 (前缀, 基词) 两段,
    /// 前缀 nil = day_signal 未命中(纯事实标签,不编喜忌语义)。
    /// 视图层给前缀浓墨、基词 inkMuted。internal 供测试。
    static func tag(for side: Side, isHi: Bool,
                    language: AppLanguage = AppLanguage.current) -> (prefix: String?, base: String) {
        let base: String
        switch language {
        case .zh, .zhHant: base = isHi ? "今日最旺" : "今日最弱"
        case .en: base = isHi ? "Strongest today" : "Weakest today"
        }
        guard let dir = side.signal else { return (nil, base) }
        let prefix: String
        switch language {
        case .zh, .zhHant: prefix = dir == "up" ? "喜用 · " : "忌神 · "
        case .en: prefix = dir == "up" ? "Favorable · " : "Unfavorable · "
        }
        return (prefix, base)
    }

    /// 小注(HTML .duel .c):匹配流日干支字——「子水正印入命 / 丙火食神泄身」。
    /// 干支字都匹配不上(该五行纯由月令/藏干推旺)→ 降级只显十神,不猜。
    /// internal 供测试。
    static func subnote(for side: Side, isHi: Bool, dayPillar: String,
                        dayRelation: String, language: AppLanguage = AppLanguage.current) -> String {
        let relation = BaziTerms.display(dayRelation, language: language)
        guard let char = TodayPillarChar.match(element: side.element, dayPillar: dayPillar) else {
            switch language {
            case .zh, .zhHant: return "\(relation)主事"
            case .en: return "\(relation) presides"
            }
        }
        switch language {
        case .zh:
            return "\(char)\(side.element)\(relation)\(isHi ? "入命" : "泄力")"
        case .zhHant:
            return "\(char)\(side.element)\(relation)\(isHi ? "入命" : "洩力")"
        case .en:
            // 基座标识层 EN 零汉字:干支字走无调拼音连字(D4 口径),如 "Zi Water"
            let latin = BaziTerms.romanizedHyphen(String(char)) ?? ""
            let el = ElementColors.fromZh(side.element)
                .flatMap { ElementColors(rawValue: $0)?.englishLabel } ?? side.element
            let joiner = latin.isEmpty ? "" : " "
            return "\(latin)\(joiner)\(el) · \(relation) \(isHi ? "presides" : "drains")"
        }
    }
}

// MARK: - 流日干支字匹配(对开小注 / 信号行共用)

/// 流日天干/地支字与五行的匹配(纯展示查表,非历法计算):干优先于支
/// (天干是主气)。都不匹配返回 nil。
enum TodayPillarChar {
    static func match(element: String, dayPillar: String) -> Character? {
        guard let key = ElementColors.fromZh(element) else { return nil }
        let chars = Array(dayPillar)
        guard chars.count >= 2 else { return nil }
        if ElementColors.ofGan(String(chars[0])) == key { return chars[0] }
        if ElementColors.ofZhi(String(chars[1])) == key { return chars[1] }
        return nil
    }
}

// MARK: - 数字对开(视图)

/// 数字对开区:hi/lo 两枚大数字(宋体 display,元素色)+ 中缝/底部 hairline。
/// 尺寸 64pt:低于头部大日期 72(字号梯度锚点不动,对开是第二层级)。
struct TodayDuelSection: View {
    let duel: TodayStrengthDuel
    let dayPillar: String
    let dayRelation: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                sideView(duel.hi, isHi: true)
                Rectangle().fill(BaziTheme.hairline).frame(width: 1)
                sideView(duel.lo, isHi: false)
            }
            Rectangle().fill(BaziTheme.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel))
    }

    private func sideView(_ side: TodayStrengthDuel.Side, isHi: Bool) -> some View {
        let color = Self.elementColor(side.element)
        let tag = TodayStrengthDuel.tag(for: side, isHi: isHi)
        var tagText: Text
        if let prefix = tag.prefix {
            tagText = Text(verbatim: prefix).bold()
                + Text(verbatim: tag.base)
        } else {
            tagText = Text(verbatim: tag.base)
        }
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(side.value)")
                .font(BaziFont.songDisplay(size: 64, weight: .medium))
                .foregroundStyle(color)
                .opacity(isHi ? 1 : 0.85)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(verbatim: BaziTerms.display(side.element))
                .font(BaziFont.songDisplay(size: 20))
                .foregroundStyle(color)
                .padding(.top, 2)
            tagText
                .font(.system(size: 10))
                .tracking(0.5)
                .foregroundStyle(BaziTheme.inkMuted)
                .padding(.top, 10)
            Text(verbatim: TodayStrengthDuel.subnote(
                for: side, isHi: isHi, dayPillar: dayPillar, dayRelation: dayRelation))
                .font(.system(size: 10))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineSpacing(3)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.trailing, isHi ? 18 : 0)
        .padding(.leading, isHi ? 0 : 18)
    }

    static func elementColor(_ element: String) -> Color {
        ElementColors.fromZh(element).flatMap { HaloColors.main($0) } ?? BaziTheme.inkMuted
    }

    /// a11y 合并朗读:两侧行 = tag(前缀+基词,三语) + 五行 + 数值。
    private var a11yLabel: String {
        func line(_ side: TodayStrengthDuel.Side, isHi: Bool) -> String {
            let tag = TodayStrengthDuel.tag(for: side, isHi: isHi)
            let head = [tag.prefix, tag.base].compactMap { $0 }.joined()
            return "\(head) \(BaziTerms.display(side.element)) \(side.value)"
        }
        let sep = AppLanguage.current.isChinese ? "、" : ", "
        return line(duel.hi, isHi: true) + sep + line(duel.lo, isHi: false)
    }
}

// MARK: - 气泡场(纯布局)

/// 纸上气泡场(11-merged .field):五枚色圆,直径 ∝ 力量(35→64 / 100→150
/// 两点线性,clamp 44-150),按排名落 5 个固定槽位(设计坐标 390×290,
/// mockup 气泡框中心)。排名并列沿用 TodayElementRank 确定性序。
/// 值 0 = 44pt 淡影圆(诚实呈现「今日无此行」,同旧五行条空轨道语义)。
/// internal 供 TodayVizLayoutTests。
enum TodayBubbleLayout {
    static let designWidth: CGFloat = 390
    static let designHeight: CGFloat = 290

    /// 槽位中心(设计坐标;rank 0..4 = 最大..最小)。最下一行留出小标空间。
    static let slotCenters: [CGPoint] = [
        CGPoint(x: 191, y: 75),   // rank 0:顶部主位
        CGPoint(x: 67, y: 121),   // rank 1:左中
        CGPoint(x: 299, y: 145),  // rank 2:右中
        CGPoint(x: 85, y: 217),   // rank 3:左下
        CGPoint(x: 218, y: 214),  // rank 4:右下
    ]

    /// 直径映射:过 (35,64)(100,150) 两点的线性,d = 17.7 + 1.3231×v,
    /// clamp [44,150](v=0 → 44 淡影)。internal 供测试钉锚点。
    static func diameter(for value: Int) -> CGFloat {
        let d = 17.7 + 1.3231 * Double(value)
        return min(max(d, 44), 150)
    }

    static func make(strength: [String: Int], daySignal: [DaySignalItemDTO]?) -> [TodayBubble] {
        let ranked = TodayElementRank.ranked(strength)
        return ranked.enumerated().map { idx, entry in
            TodayBubble(
                element: entry.element,
                value: entry.value,
                diameter: diameter(for: entry.value),
                center: slotCenters[min(idx, slotCenters.count - 1)],
                signal: (daySignal ?? []).first { $0.element == entry.element }?.direction
            )
        }
    }
}

struct TodayBubble: Equatable {
    let element: String
    let value: Int
    let diameter: CGFloat
    /// 设计坐标中心。
    let center: CGPoint
    /// "up"/"down"/nil(同 day_signal 口径)。
    let signal: String?
}

// MARK: - 气泡场(视图)

/// 气泡场区:统一小标行 + 画布 + 图例小注。画布按 390×290 设计坐标渲染后
/// 整体 scaleEffect 等比缩放(内容宽 < 390 的设备缩下来,圆不失形)。
/// 淡染手法对齐 mockup 径向渐变:RadialGradient(0.34→0.17→0.07) + 1pt
/// 元素色描边 + 同色柔影;暗色整体 ×1.35 提亮(夜宣纸上压暗不可见,实证)。
struct TodayBubbleFieldSection: View {
    let bubbles: [TodayBubble]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.DailyFortune.fieldTitle)
                    .font(.system(size: 13, weight: .medium))
                    .tracking(AppLanguage.current.isChinese ? 1.5 : 0)
                    .foregroundStyle(BaziTheme.inkMuted)
                Spacer(minLength: 12)
                Text(L10n.DailyFortune.fieldLegend)
                    .font(.system(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            GeometryReader { geo in
                let s = geo.size.width / TodayBubbleLayout.designWidth
                ZStack(alignment: .topLeading) {
                    ForEach(bubbles, id: \.element) { bubble in
                        bubbleView(bubble)
                            .position(x: bubble.center.x, y: bubble.center.y)
                    }
                }
                .frame(width: TodayBubbleLayout.designWidth,
                       height: TodayBubbleLayout.designHeight,
                       alignment: .topLeading)
                .scaleEffect(s, anchor: .topLeading)
            }
            // 高度随缩放等比收(content 宽 < 390 的设备画布高 = 宽 × 290/390,
            // 不留缩放死空间;aspectRatio fit 与内部 scale 同比例)
            .aspectRatio(TodayBubbleLayout.designWidth / TodayBubbleLayout.designHeight,
                          contentMode: .fit)
            .accessibilityHidden(true)
            Text(L10n.DailyFortune.fieldCaption)
                .font(BaziFont.caption(size: 10.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel))
    }

    /// 单枚气泡:淡染圆 + 元素字/数值居中(11-merged .zl)。值 0 → 整体
    /// 0.35 透明度 + 去阴影(淡影圆,「今日无此行」)。
    private func bubbleView(_ bubble: TodayBubble) -> some View {
        let d = bubble.diameter
        let c = TodayDuelSection.elementColor(bubble.element)
        // 暗色反向提亮:淡染基数(0.34/0.17/0.07)在夜宣纸上压暗会不可见
        // (2026-11-21 暗色截屏实证;光晕的 ×0.55 不适用——那边基数 0.5-0.7)
        let dim = scheme == .dark ? 1.35 : 1.0
        let ghost = bubble.value == 0
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            c.opacity(0.34 * dim),
                            c.opacity(0.17 * dim),
                            c.opacity(0.07 * dim),
                        ],
                        center: UnitPoint(x: 0.34, y: 0.30),
                        startRadius: 0,
                        endRadius: d / 2
                    )
                )
                .overlay(Circle().stroke(c.opacity(0.55 * dim), lineWidth: 1))
            VStack(spacing: 2) {
                Text(verbatim: BaziTerms.display(bubble.element))
                    .font(BaziFont.songDisplay(size: 10 + d * 0.107))
                    .foregroundStyle(c)
                Text(verbatim: "\(bubble.value)")
                    .font(BaziFont.numeric(size: 9 + d * 0.04))
                    .foregroundStyle(c)
            }
        }
        .frame(width: d, height: d)
        .shadow(color: c.opacity(ghost ? 0 : 0.20 * dim),
                radius: ghost ? 0 : 10 + d / 12, y: ghost ? 0 : d / 12)
        .overlay(alignment: .bottom) {
            // 喜/忌小标:day_signal 命中才出现(空表 → 全场无标,不编喜忌语义);
            // 底对齐后下移 16pt,悬在圆外(mockup .tag bottom:-22 的近似)
            if let dir = bubble.signal {
                Text(verbatim: Self.tagText(dir))
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
                    .fixedSize()
                    .offset(y: 22)
            }
        }
        .opacity(ghost ? 0.35 : 1)
    }

    private static func tagText(_ direction: String) -> String {
        switch direction {
        case "up": return AppLanguage.current == .en ? "Favorable" : "喜用"
        default: return AppLanguage.current == .en ? "Unfav." : "忌"
        }
    }

    private var a11yLabel: String {
        let zh = AppLanguage.current.isChinese
        let sep = zh ? "、" : ", "
        let reading = bubbles.map { b -> String in
            var s = "\(BaziTerms.display(b.element)) \(b.value)"
            if let dir = b.signal {
                // 小标三语(与 tagText 同口径,不留 zh 硬编码给 EN 朗读)
                s += dir == "up"
                    ? (zh ? "(喜用)" : " (favorable)")
                    : (zh ? "(忌)" : " (unfavorable)")
            }
            return s
        }
        return reading.joined(separator: sep)
    }
}

// MARK: - 信号双栏

/// 今日信号双栏(11-merged .sigs):↑左 / ↓右,每条 2pt 元素色左边线 +
/// 「↑ 子水」头行;每栏一条静态建议短句(方向级,非逐条——两条↑共用一劝)。
/// day_signal 空(时辰未知/从格)→ 宿主不渲染本区。
struct TodaySignalColumnsSection: View {
    let daySignal: [DaySignalItemDTO]
    let dayPillar: String

    var body: some View {
        let ups = daySignal.filter { $0.direction == "up" }
        let downs = daySignal.filter { $0.direction != "up" }
        HStack(alignment: .top, spacing: 20) {
            if !ups.isEmpty {
                column(items: ups, isUp: true)
            }
            if !downs.isEmpty {
                column(items: downs, isUp: false)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel(ups: ups, downs: downs)))
    }

    private func column(items: [DaySignalItemDTO], isUp: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                row(item, isUp: isUp)
            }
            Text(verbatim: TodaySignalAdvice.text(isUp: isUp))
                .font(.system(size: 11))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单条:2pt 元素色左边线 + 「↑ 子水」头行(mockup 头行的「· 正印」省略——
    /// day_signal DTO 无逐条十神字段,硬凑会拿错;干支字匹配不上 → 只显五行)。
    private func row(_ item: DaySignalItemDTO, isUp: Bool) -> some View {
        let color = TodayDuelSection.elementColor(item.element)
        return HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(color).frame(width: 2)
            Text(verbatim: headerText(item, isUp: isUp))
                .font(BaziFont.songDisplay(size: 15))
                .foregroundStyle(BaziTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .padding(.vertical, 1)
        }
    }

    private func headerText(_ item: DaySignalItemDTO, isUp: Bool) -> String {
        let arrow = isUp ? "↑" : "↓"
        let el = BaziTerms.display(item.element)
        if let char = TodayPillarChar.match(element: item.element, dayPillar: dayPillar) {
            return AppLanguage.current == .en
                ? "\(arrow) \(BaziTerms.romanizedHyphen(String(char)) ?? el) \(el)"
                : "\(arrow) \(char)\(item.element)"
        }
        return "\(arrow) \(el)"
    }

    private func a11yLabel(ups: [DaySignalItemDTO], downs: [DaySignalItemDTO]) -> String {
        let sep = AppLanguage.current.isChinese ? "、" : ", "
        var out: [String] = []
        if !ups.isEmpty {
            out.append(L10n.DeepChart.xijiFavorableA11y + " "
                + ups.map { BaziTerms.display($0.element) }.joined(separator: sep))
        }
        if !downs.isEmpty {
            out.append(L10n.DeepChart.xijiUnfavorableA11y + " "
                + downs.map { BaziTerms.display($0.element) }.joined(separator: sep))
        }
        return out.joined(separator: sep)
    }
}

/// 信号建议短句(方向级,三语静态表;LLM 不参与——判断性内容查表)。
enum TodaySignalAdvice {
    static func text(isUp: Bool, language: AppLanguage = AppLanguage.current) -> String {
        switch (language, isUp) {
        case (.zh, true): return "顺势而行，重要的事放今天。"
        case (.zhHant, true): return "順勢而行，重要的事放今天。"
        case (.en, true): return "Go with it — save the big moves for today."
        case (.zh, false): return "精力折损快，日程留白。"
        case (.zhHant, false): return "精力折損快，日程留白。"
        case (.en, false): return "Energy drains fast — keep the day light."
        }
    }
}

// MARK: - 十二时辰谱

/// 十二时辰单行谱(11-merged .hours-line):上下 1pt ink 线,12 格均分
/// 「子 同 · 丑 劫 …」;当前时辰 cinnabar + ◂(朱红「当前时辰点」是
/// BaziTheme 注释明准的用途)。仅 businessDate = 今天才标当前;EN 只显
/// 地支拼音(十神全名一行放不下,且解读段已有;基座零汉字)。
struct TodayHourLineSection: View {
    let hourPillars: [HourPillarDTO]
    /// 服务端恒 null;客户端本地算(businessDate 为今天时)。
    var currentHourIndex: Int?
    var isToday: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(BaziTheme.ink).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(hourPillars.enumerated()), id: \.offset) { idx, pillar in
                    cell(pillar, isCurrent: idx == resolvedCurrentIndex)
                }
            }
            .padding(.vertical, 12)
            Rectangle().fill(BaziTheme.ink).frame(height: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel))
    }

    private var resolvedCurrentIndex: Int? {
        isToday ? currentHourIndex : nil
    }

    private func cell(_ pillar: HourPillarDTO, isCurrent: Bool) -> some View {
        let isEn = AppLanguage.current == .en
        let main: String = isEn
            ? (BaziTerms.romanizedHyphen(pillar.hour) ?? pillar.hour)
            : pillar.hour
        let secondary: String? = isEn ? nil : HourRelationShort.short(pillar.relation)
        var text = main
        if let secondary { text += " \(secondary)" }
        if isCurrent { text += " ◂" }
        return Text(verbatim: text)
            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? BaziTheme.cinnabar : BaziTheme.inkMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
    }

    private var a11yLabel: String {
        let isEn = AppLanguage.current == .en
        let sep = AppLanguage.current.isChinese ? "、" : ", "
        // EN 与可见 cell 同口径:地支走拼音(D4 基座零汉字),十神走 EN 词表
        let parts = hourPillars.map { p -> String in
            let hour = isEn ? (BaziTerms.romanizedHyphen(p.hour) ?? p.hour) : p.hour
            return "\(hour) \(BaziTerms.display(p.relation))"
        }
        var out = parts.joined(separator: sep)
        if let idx = resolvedCurrentIndex, hourPillars.indices.contains(idx) {
            let hour = isEn ? (BaziTerms.romanizedHyphen(hourPillars[idx].hour)
                ?? hourPillars[idx].hour) : hourPillars[idx].hour
            out += isEn ? ", now \(hour)" : ",当前 \(hour)时"
        }
        return out
    }
}

/// 十神单字短词(时辰谱密度用;键集合 == BaziTerms.tenGods zh 键(11),
/// 由 TodayVizLayoutTests 守护;两表键都是后端简体十神(决策 7 不翻译),
/// 只有值转繁——对齐 HeroYiJiColumns mappingZh/mappingHant 先例)。
enum HourRelationShort {
    static let zh: [String: String] = [
        "比肩": "同", "劫财": "劫", "食神": "食", "伤官": "伤",
        "偏财": "财", "正财": "才", "七杀": "杀", "偏官": "杀",
        "正官": "官", "正印": "印", "偏印": "枭",
    ]
    static let hant: [String: String] = [
        "比肩": "同", "劫财": "劫", "食神": "食", "伤官": "傷",
        "偏财": "財", "正财": "才", "七杀": "殺", "偏官": "殺",
        "正官": "官", "正印": "印", "偏印": "梟",
    ]

    static func short(_ relation: String, language: AppLanguage = AppLanguage.current) -> String? {
        let table = language == .zhHant ? hant : zh
        if let hit = table[relation] { return hit }
        AppLogger.app.warning(
            "op=hourRelationShort.lookupMiss relation=\(relation, privacy: .public) -> omit"
        )
        return nil
    }
}

// MARK: - 宜/忌/明日 三栏

/// 底部三栏(11-merged .bottom):宜/忌复用 HeroYiJiColumns 静态十神查表
/// (2026-11-21 拍板:不换后端黄历),第三栏 = tomorrowPreview(日柱 + 十神 + 冲)。
struct TodayBottomColumnsSection: View {
    let dayRelation: String
    let tomorrow: TomorrowPreviewDTO

    private var isEn: Bool { AppLanguage.current == .en }

    var body: some View {
        let pair = Self.yiJiPair(dayRelation)
        HStack(alignment: .top, spacing: 14) {
            yiJiColumn(header: isEn ? "Do" : "宜", isYi: true, items: pair.yi)
            yiJiColumn(header: isEn ? "Don't" : "忌", isYi: false, items: pair.ji)
            tomorrowColumn
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel(pair: pair)))
    }

    /// 查表(HeroYiJiColumns 同款防御:miss 记日志 fallback,不静默)。
    static func yiJiPair(_ dayRelation: String) -> (yi: [String], ji: [String]) {
        if let matched = HeroYiJiColumns.mapping[dayRelation] {
            return matched
        }
        AppLogger.app.warning(
            "op=todayBottomColumns.lookupMiss day_relation=\(dayRelation, privacy: .public) -> fallback"
        )
        return HeroYiJiColumns.fallback
    }

    private func yiJiColumn(header: String, isYi: Bool, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader(header, tint: isYi ? BaziTheme.jade : BaziTheme.cinnabar)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(BaziFont.songDisplay(size: isEn ? 11 : 12))
                        .foregroundStyle(BaziTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .padding(.vertical, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 三栏表头(11-merged .bt .k):统一小标 + 表头下 hairline(标签与词条分家,
    /// 同旧 HeroYiJiColumns 表头下线先例)。
    private func columnHeader(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .tracking(1.5)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
            .overlay(alignment: .bottom) {
                Rectangle().fill(BaziTheme.hairline).frame(height: 1)
            }
    }

    /// 明日栏:日柱(宋体)+ 十神 + 冲(chong nil → 只显十神,tomorrowPreview
    /// DTO 非可选,无栏级空态)。
    private var tomorrowColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            columnHeader(L10n.DailyFortune.tomorrowTitle, tint: BaziTheme.inkMuted)
            VStack(alignment: .leading, spacing: 4) {
                if isEn {
                    Text(verbatim: BaziTerms.romanizedHyphen(tomorrow.dayPillar) ?? tomorrow.dayPillar)
                        .font(BaziFont.songDisplay(size: 13))
                        .foregroundStyle(BaziTheme.ink)
                    Text(verbatim: BaziTerms.display(tomorrow.dayRelation, language: .en))
                        .font(.system(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMuted)
                } else {
                    Text(verbatim: tomorrow.dayPillar)
                        .font(BaziFont.songDisplay(size: 13))
                        .foregroundStyle(BaziTheme.ink)
                    Text(verbatim: BaziTerms.display(tomorrow.dayRelation))
                        .font(.system(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                if let chong = tomorrow.dayChong {
                    Text(verbatim: chongText(chong))
                        .font(.system(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
        }
    }

    private func chongText(_ chong: String) -> String {
        switch AppLanguage.current {
        case .zh: return "冲\(chong)"
        case .zhHant: return "沖\(chong)"
        case .en:
            let zodiac = ZodiacHelper.zodiacName(forZhi: chong)
            return zodiac.map { "clashes \($0)" } ?? "clashes \(chong)"
        }
    }

    private func a11yLabel(pair: (yi: [String], ji: [String])) -> String {
        let sep = AppLanguage.current.isChinese ? "、" : ", "
        return "\(L10n.DailyFortune.yiLabel) \(pair.yi.joined(separator: sep))\(sep)"
            + "\(L10n.DailyFortune.jiLabel) \(pair.ji.joined(separator: sep))\(sep)"
            + "\(L10n.DailyFortune.tomorrowTitle) \(tomorrow.dayPillar) "
            + BaziTerms.display(tomorrow.dayRelation)
            + (tomorrow.dayChong.map { " " + chongText($0) } ?? "")
    }
}
