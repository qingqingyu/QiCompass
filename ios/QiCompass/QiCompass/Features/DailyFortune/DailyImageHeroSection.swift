import SwiftUI

/// glass-v2 玻璃全信息卡(2026-08-31 用户拍板;2026-09-01 底图改单张固定资产,
/// 事实源 `~/.gstack/projects/qingqingyu-QiCompass/designs/daily-glass-20260831/glass-v2.html`):
/// 一张玻璃山水承载全部主信息——顶部大数字日期 + 周几/农历·干支 | 右上关系/冲 chips;
/// 中部呼吸留白;底部宜/忌双列清单(宋体,各 3 条)。外部三行头部取消(其信息全部入图)。
///
/// 玻璃配方(全程序化图层,效果不依赖生图端):
/// 1 基底滤镜:降饱和/提亮/压对比/1.3pt 柔焦(SwiftUI 原生 modifier)
/// 2 径向 mask:实心 58% → 94% 融纸,只留最外一线洇进宣纸
/// 3 纸色纱罩:呼吸 7s(动效三式 breathe 同源),整幅压灰
/// 4 宣纸压边 rim:四周纸色收边,保证整幅图都在玻璃下
/// 5 磨砂颗粒:PaperGrain(确定性噪点,ink@0.05)
/// 6 云雾:两团宣纸色软雾异速反向漂(26s/34s),山间岚气
/// 7 淡墨飞鸟:两笔简笔 30s 横渡 + 3.4s 沉浮
/// 入场:日期区/宜忌列 ink-in(blur 7→0)错峰。reduce-motion:循环动效全停。
///
/// 图内中文 = 宋体 Songti SC(「图内宋/文中楷」分层,2026-08-31 拍板,DESIGN.md 补录);
/// EN = New York 衬线列头 + Menlo 等宽条目(BaziFont.songDisplay / mono)。
struct DailyImageHeroSection: View {
    let businessDate: Date
    let lunarDate: String
    let dayPillar: String
    let dayRelation: String
    let dayChong: String?
    let dayChongTargets: [String]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// 卡高(glass-v2 同值):容纳日期区 + 呼吸留白 + 宜忌双列。
    private static let heroHeight: CGFloat = 402

    // 玻璃参数(glass-v2「浅绛彩色底」档;水墨档 sat 0.32,重晕档未移植——画布可回调)
    private static let gSaturation: Double = 0.92
    private static let gBrightness: Double = 0.03
    private static let gContrast: Double = 0.93
    private static let gBlur: CGFloat = 1.3

    // 循环动效状态(reduce-motion 时永不启动)
    @State private var breathe = false
    @State private var soak = false
    @State private var mistA = false
    @State private var mistB = false
    @State private var bob = false
    @State private var flyX: CGFloat = -34

    var body: some View {
        ZStack {
            baseLayer
            veilLayer
            rimLayer
            mistLayer
            grainLayer
            birdLayer

            // 内容浮层
            contentOverlay
                .accessibilityHidden(true)
        }
        .frame(height: Self.heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .onAppear(perform: startCycles)
        // 无障碍:合并为单元素,宜忌词一并进 label(不被 .ignore 吞掉)。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: heroAccessibilityLabel))
    }

    /// 无障碍合并 label:干支 + 页首短标 + 宜/忌词。
    private var heroAccessibilityLabel: String {
        let yiJi = HeroYiJiColumns.mapping[dayRelation] ?? HeroYiJiColumns.fallback
        return "\(dayPillar) \(L10n.DailyFortune.shortLabel), \(L10n.DailyFortune.yiLabel) \(yiJi.yi.joined(separator: "、")), \(L10n.DailyFortune.jiLabel) \(yiJi.ji.joined(separator: "、"))"
    }

    // MARK: - 玻璃图层

    private var baseLayer: some View {
        // 固定底图(2026-09-01 用户拍板「单张固定图」):画布定稿浅绛山水烘进
        // Asset Catalog,不再调生图 API——零成本/零延迟/零 IMAGE_API_KEY 依赖。
        // 2026-09-01 晚改竖版:原 3:2 横幅(1536×1024)在 ~0.92:1 卡内 scaledToFill
        // 要放大到 603pt 宽裁掉 39% 画面;重生成竖版 916×1717(B「极简空灵」,
        // gpt-image-2)后按卡比例裁 916×1000,山顶落卡高 25%/山脚 63%,整幅完整呈现。
        // prompt 与裁窗溯源:designs/daily-glass-20260831/hero-provenance.md。
        // 1 基底滤镜 → clip → 2 径向 mask → 墨渗缩放(晕团在玻璃内缓胀)
        Group {
            Image("HeroLandscape")
                .resizable()
                .scaledToFill()
                .saturation(Self.gSaturation)
                .brightness(Self.gBrightness)
                .contrast(Self.gContrast)
                .blur(radius: Self.gBlur)
                .frame(height: Self.heroHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .mask { bloomMask }
                .scaleEffect(soak ? 1.05 : 1.01)
        }
    }

    /// 径向融纸 mask:实心到 58%,94% 全透明(CSS ellipse 152%/130% 的圆形近似,
    /// 半径按 402pt 卡高的对角覆盖取值;偏差由 rim 层兜底)。
    private var bloomMask: some View {
        Rectangle().fill(
            RadialGradient(
                stops: [
                    .init(color: .black, location: 0.58),
                    .init(color: .clear, location: 0.94),
                ],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0,
                endRadius: 400
            )
        )
    }

    /// 3 纸色纱罩 + 呼吸(paper 是 dyn 双值,夜宣纸自动换底)。
    private var veilLayer: some View {
        Rectangle()
            .fill(BaziTheme.paper)
            .opacity(breathe ? 0.46 : 0.33)
            .allowsHitTesting(false)
    }

    /// 4 宣纸压边:四周以纸色收边,只留最外一线融纸。
    private var rimLayer: some View {
        Rectangle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.58),
                        .init(color: BaziTheme.paper, location: 0.97),
                    ],
                    center: UnitPoint(x: 0.5, y: 0.45),
                    startRadius: 0,
                    endRadius: 430
                )
            )
            .allowsHitTesting(false)
    }

    /// 6 云雾:两团宣纸色软雾,异速反向横漂(26s / 34s 半程)。
    private var mistLayer: some View {
        ZStack {
            mistBlob(width: 300, height: 190, y: 76, x: mistA ? 52 : -52, opacity: 0.5)
            mistBlob(width: 255, height: 165, y: 178, x: mistB ? -46 : 46, opacity: 0.38)
        }
        .allowsHitTesting(false)
    }

    private func mistBlob(width: CGFloat, height: CGFloat, y: CGFloat, x: CGFloat, opacity: Double) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: BaziTheme.paper, location: 0),
                        .init(color: BaziTheme.paper.opacity(0), location: 0.72),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 180
                )
            )
            .frame(width: width, height: height)
            .blur(radius: 16)
            .opacity(opacity)
            .offset(x: x, y: y)
    }

    /// 5 磨砂颗粒(确定性 Canvas 噪点;亮=multiply 细噪 / 暗=screen 亮噪)。
    private var grainLayer: some View {
        PaperGrain(opacity: 0.05)
            .blendMode(scheme == .dark ? .screen : .multiply)
            .allowsHitTesting(false)
    }

    /// 7 淡墨飞鸟:两笔简笔横渡天空,3.4s 微沉浮。
    private var birdLayer: some View {
        GeometryReader { geo in
            BirdShape()
                .stroke(BaziTheme.ink, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 26, height: 10)
                .offset(y: bob ? -3 : 0)
                .position(x: flyX + 13, y: 89)
                .opacity(0.38)
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                        bob = true
                    }
                    withAnimation(.linear(duration: 30).repeatForever(autoreverses: false)) {
                        // 单程横渡后 snap 回左缘重飞(autoreverses:false),画缘由 .clipped() 剪裁
                        flyX = geo.size.width + 40
                    }
                }
        }
        .allowsHitTesting(false)
    }

    /// 循环动效启动(呼吸/墨渗/云雾)。duration = 半程,与画布 alternate 全程 2× 一致。
    private func startCycles() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) { breathe = true }
        withAnimation(.easeInOut(duration: 5.5).repeatForever(autoreverses: true)) { soak = true }
        withAnimation(.easeInOut(duration: 13).repeatForever(autoreverses: true)) { mistA = true }
        withAnimation(.easeInOut(duration: 17).repeatForever(autoreverses: true)) { mistB = true }
    }

    // MARK: - 内容浮层(日期区 + 宜忌双列)

    private var contentOverlay: some View {
        VStack(spacing: 0) {
            dateRow
                .padding(.horizontal, 4)
                .padding(.top, 18)
            Spacer()
            HeroYiJiColumns(dayRelation: dayRelation)
                .padding(.horizontal, 4)
                .padding(.bottom, 22)
        }
    }

    /// 顶部:大数字日期(参考图「30」语言)+ 周几/农历·干支 | 关系/冲 chips。
    /// EN 长文案(如 "Clashes: 亥 (Year Branch 亥)")单行放不下时,chips 整组换到
    /// 日期行下方右对齐(2026-09-19 S02:原布局 chip 内折三行,胶囊恒单行)。
    private var dateRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                dateInfo
                Spacer(minLength: 8)
                chips
                    .padding(.top, 8)
            }
            VStack(alignment: .trailing, spacing: 7) {
                HStack(alignment: .top, spacing: 12) {
                    dateInfo
                    Spacer(minLength: 8)
                }
                chips
            }
        }
        .inkIn(delay: 0.2)
    }

    /// 日期区:大数字 + 周几 / 农历·干支两行。
    private var dateInfo: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(Calendar.current.component(.day, from: businessDate))")
                .font(.system(size: 62, weight: .ultraLight))
                .tracking(-0.6)
                .foregroundStyle(BaziTheme.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text(BaziDateFormatter.weekdayShort.string(from: businessDate))
                    .font(BaziFont.songDisplay(size: 13))
                    .tracking(1.5)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.top, 4)
                Text(verbatim: "\(L10n.DailyFortune.lunarPrefix) \(lunarDate) · \(dayPillar)\(L10n.DailyFortune.dayPillarSuffix)")
                    .font(BaziFont.songDisplay(size: 11))
                    .tracking(0.5)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    /// 关系/冲 chips(放不下时整组换行,组内仍横排)。
    private var chips: some View {
        HStack(spacing: 7) {
            ChipView(text: Self.displayRelation(dayRelation), tint: BaziTheme.cinnabar, iconName: Self.relationIcon(for: dayRelation))
            if let chong = dayChong {
                let label = L10n.DailyFortune.chongLabel(chong: chong, targets: dayChongTargets)
                ChipView(text: label, tint: BaziTheme.inkMuted, iconName: "PlaqueChong")
            }
        }
    }

    /// 关系 chip 配图:刃(PlaqueSha)= 克身之压力,只配官杀族(七杀/正官);
    /// 其余十神语义不合,回纯文字 chip。补全十神符牌图后删 gate(V1 拍板口径)。
    static func relationIcon(for relation: String) -> String? {
        relation == "七杀" || relation == "正官" ? "PlaqueSha" : nil
    }

    /// 十神简→繁显示表(T0):后端 `day_relation` 恒为简体(i18n 决策 7,十神 key
    /// 不翻译),繁体环境 chip 显示异形字——劫財/傷官/偏財/正財/七殺 5 个异形,
    /// 其余同形仍显式进表(对齐 D1 显式注册口径)。未知关系原样透出
    /// (与下方 pair 查表 miss 的防御口径一致,非错误)。
    static let relationHant: [String: String] = [
        "比肩": "比肩", "劫财": "劫財", "食神": "食神", "伤官": "傷官",
        "偏财": "偏財", "正财": "正財", "七杀": "七殺", "正官": "正官",
        "偏印": "偏印", "正印": "正印",
    ]

    /// chip 十神显示名:繁体查异形表,简体/英文原样(en 分支显示中文十神是
    /// 既有决策——命理符号保留中文,2026-08-26 英文 locale 路由同款口径)。
    static func displayRelation(_ relation: String) -> String {
        AppLanguage.current == .zhHant ? (relationHant[relation] ?? relation) : relation
    }
}

// MARK: - HeroYiJiColumns(宜/忌双列清单)

/// 图内宜/忌双列(参考图 Do/Don'ts 语言,2026-08-31 拍板支持 2-3 条/列)。
///
/// 数据源(v1 简化,同前):前端十神→关键词查表,扩为**每列 3 词**;
/// 后续可挪后端基于喜忌+流日关系确定性映射(不增加 v1 后端复杂度)。
/// 十神 key 始终中文(后端不翻译,i18n 决策 7);词表按 AppLanguage 切换。
private struct HeroYiJiColumns: View {
    let dayRelation: String

    static let mappingZh: [String: (yi: [String], ji: [String])] = [
        "比肩": (["独立", "立界", "健身"], ["争执", "攀比", "随众"]),
        "劫财": (["行动", "开拓", "分利"], ["冲动", "借贷", "硬拼"]),
        "食神": (["创造", "表达", "见新友"], ["拖延", "熬夜", "争辩"]),
        "伤官": (["表达", "出新", "直言"], ["冲撞", "越界", "口快"]),
        "偏财": (["拓展", "试新", "让利"], ["孤注", "贪多", "赊账"]),
        "正财": (["守成", "记账", "务本"], ["短视", "贪快", "弃约"]),
        "七杀": (["果断", "担事", "攻坚"], ["犹豫", "树敌", "硬扛"]),
        "正官": (["担当", "守规", "复命"], ["退缩", "越级", "失约"]),
        "偏印": (["思考", "独处", "温故"], ["执拗", "多虑", "孤行"]),
        "正印": (["学习", "纳言", "养身"], ["依赖", "空想", "拖延"]),
    ]

    /// EN 词表(2026-09-19 S02/#12 重写):中文双字词自带语境,单词直译语义散失
    /// (`Push`/`Feud`),换带语境短语;每条 ≤16 chars,mono 14.5pt 双列(~163pt/列)单行内。
    static let mappingEn: [String: (yi: [String], ji: [String])] = [
        "比肩": (["Work Solo", "Set Boundaries", "Train"], ["Argue", "Compare", "Follow the Crowd"]),
        "劫财": (["Act Now", "Branch Out", "Share the Gain"], ["Snap Buys", "Lend Money", "Force It"]),
        "食神": (["Create", "Speak Up", "Meet Someone New"], ["Delay", "Stay Up Late", "Debate"]),
        "伤官": (["Speak Out", "Debut Something", "Be Frank"], ["Clash", "Overstep", "Blurt It Out"]),
        "偏财": (["Explore", "Try New Things", "Give Ground"], ["Bet It All", "Overreach", "Buy on Credit"]),
        "正财": (["Keep Steady", "Track Spending", "Stay Grounded"], ["Cut Corners", "Rush Deals", "Break Promises"]),
        "七杀": (["Make the Call", "Take It On", "Push Through"], ["Waver", "Start Feuds", "Burn Out"]),
        "正官": (["Own Your Duty", "Play by the Rules", "Report Back"], ["Shrink Back", "Skip the Chain", "Miss Deadlines"]),
        "偏印": (["Reflect", "Sit with It", "Review Old Notes"], ["Get Stubborn", "Overthink", "Go It Alone"]),
        "正印": (["Study Up", "Take Advice", "Rest Well"], ["Lean Too Hard", "Daydream", "Drag Your Feet"]),
    ]

    /// 繁体词表(T0):key 仍为后端简体十神(决策 7 不翻译),词表值由 mappingZh
    /// 转繁;用词对齐台湾惯用(記帳/賒帳/復命——复一对多:復命/複數/覆蓋,
    /// 「覆命」为误转,2026-09-23 review P1-4 修正)。
    static let mappingHant: [String: (yi: [String], ji: [String])] = [
        "比肩": (["獨立", "立界", "健身"], ["爭執", "攀比", "隨眾"]),
        "劫财": (["行動", "開拓", "分利"], ["衝動", "借貸", "硬拼"]),
        "食神": (["創造", "表達", "見新友"], ["拖延", "熬夜", "爭辯"]),
        "伤官": (["表達", "出新", "直言"], ["衝撞", "越界", "口快"]),
        "偏财": (["拓展", "試新", "讓利"], ["孤注", "貪多", "賒帳"]),
        "正财": (["守成", "記帳", "務本"], ["短視", "貪快", "棄約"]),
        "七杀": (["果斷", "擔事", "攻堅"], ["猶豫", "樹敵", "硬扛"]),
        "正官": (["擔當", "守規", "復命"], ["退縮", "越級", "失約"]),
        "偏印": (["思考", "獨處", "溫故"], ["執拗", "多慮", "孤行"]),
        "正印": (["學習", "納言", "養身"], ["依賴", "空想", "拖延"]),
    ]

    static var mapping: [String: (yi: [String], ji: [String])] {
        switch AppLanguage.current {
        case .zh:     return mappingZh
        case .zhHant: return mappingHant
        case .en:     return mappingEn
        }
    }

    /// 防御:未知关系(理论上后端必返回十神之一,但保护)。
    static var fallback: (yi: [String], ji: [String]) {
        switch AppLanguage.current {
        case .en:     return (["Flow", "Rest"], ["Force", "Rush"])
        case .zh:     return (["顺势", "养气"], ["强求", "硬拼"])
        case .zhHant: return (["順勢", "養氣"], ["強求", "硬拼"])
        }
    }

    /// 查表命中失败时记日志,不静默 fallback(对齐 CLAUDE.md 错误显式传播约束)。
    private var pair: (yi: [String], ji: [String]) {
        if let matched = Self.mapping[dayRelation] {
            return matched
        }
        AppLogger.app.warning(
            "op=heroYiJi.lookupMiss day_relation=\(dayRelation, privacy: .public) -> fallback"
        )
        return Self.fallback
    }

    private var isEn: Bool { AppLanguage.current == .en }

    var body: some View {
        let resolved = pair
        HStack(alignment: .top, spacing: 34) {
            column(header: isEn ? "Do" : "宜", items: resolved.yi)
            column(header: isEn ? "Don't" : "忌", items: resolved.ji)
        }
        .inkIn(delay: 0.45)
    }

    /// 单列:宋体大字列头(EN 衬线)+ 条目纵堆(EN 等宽)。
    private func column(header: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(isEn ? .system(size: 30, weight: .regular, design: .serif) : BaziFont.songDisplay(size: 26, weight: .semibold))
                .foregroundStyle(BaziTheme.ink)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(isEn ? BaziFont.mono(size: 14.5) : BaziFont.songDisplay(size: 17))
                        .tracking(isEn ? 0.3 : 1.7)
                        .foregroundStyle(BaziTheme.ink)
                        .padding(.vertical, 4.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 飞鸟形状(两笔简笔,同画布 SVG path)

private struct BirdShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 26
        let sy = rect.height / 10
        var p = Path()
        p.move(to: CGPoint(x: 1.5 * sx, y: 7.5 * sy))
        p.addQuadCurve(to: CGPoint(x: 12 * sx, y: 6.5 * sy), control: CGPoint(x: 7 * sx, y: 1.5 * sy))
        p.addQuadCurve(to: CGPoint(x: 15.5 * sx, y: 6.5 * sy), control: CGPoint(x: 13.5 * sx, y: 8.2 * sy))
        p.addQuadCurve(to: CGPoint(x: 24.5 * sx, y: 7.5 * sy), control: CGPoint(x: 20.5 * sx, y: 1.5 * sy))
        return p
    }
}

// MARK: - ink-in 入场(blur 7→0,动效三式 ink-in;reduce-motion 压缩去 blur)

private struct InkInModifier: ViewModifier {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .blur(radius: visible || reduceMotion ? 0 : 7)
            .onAppear {
                withAnimation(
                    .easeOut(duration: reduceMotion ? 0.15 : 1.1)
                    .delay(reduceMotion ? 0 : delay)
                ) {
                    visible = true
                }
            }
    }
}

extension View {
    /// 图内文字入场:opacity + blur 7→0(DESIGN.md §Motion ink-in)。
    func inkIn(delay: Double = 0) -> some View {
        modifier(InkInModifier(delay: delay))
    }
}

// MARK: - ChipView / PlaqueIcon(自 DailyFortuneHeaderView 迁入,2026-09-01 外部头部删除)

/// 古篆符牌小图(V1,2026-08-31 拍板):Asset Catalog 双 variant,
/// 夜宣纸自动切亮迹版,无需运行时 blend 处理。
struct PlaqueIcon: View {
    let iconName: String
    let height: CGFloat

    var body: some View {
        Image(iconName)
            .resizable()
            .scaledToFit()
            .frame(height: height)
    }
}

/// 通用 chip:小标签 + 可选符牌小图 + tint 描边(Capsule 留给 chip,DESIGN.md §Layout)。
struct ChipView: View {
    let text: String
    let tint: Color
    var iconName: String?

    init(text: String, tint: Color, iconName: String? = nil) {
        self.text = text
        self.tint = tint
        self.iconName = iconName
    }

    var body: some View {
        HStack(spacing: 4) {
            if let iconName {
                PlaqueIcon(iconName: iconName, height: 13)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 0.5))
    }
}
