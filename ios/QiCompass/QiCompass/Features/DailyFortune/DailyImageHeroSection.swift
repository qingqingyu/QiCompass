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
/// 4c 四边融纸(2026-09-28 外评「顶部矩形切边」)
/// 5 磨砂颗粒:PaperGrain(确定性噪点,ink@0.05)
/// 6 云雾:两团宣纸色软雾异速反向漂(26s/34s),山间岚气
/// (7 飞鸟层 2026-09-29 D1 拍板删除:09-25 打磨后外评仍读成乱码,视觉减法)
/// 入场:日期区/宜忌列 ink-in(blur 7→0)错峰。reduce-motion:循环动效全停。
///
/// 图内中文 = 宋体 Songti SC(「图内宋/文中楷」分层,2026-08-31 拍板,DESIGN.md 补录);
/// EN = New York 衬线列头 + 衬线条目(2026-09-24 收敛:Menlo 等宽条目作废,
/// 评审「等宽与水墨不搭」,字体收敛到衬线一族)。
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

    /// 内容浮层水平内边距:与 DailyInterpretationSection 的 20pt 对齐
    /// (2026-09-28 外评:原 4pt 使「28」「Do」离屏 21pt,解读正文 37pt,差 16pt)。
    private static let contentInset: CGFloat = 20

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

    /// 十神释义 sheet(D3,2026-09-29 拍板):chip 轻触 / VO action 双入口同源。
    @State private var showShiShenNote = false

    var body: some View {
        ZStack {
            baseLayer
            veilLayer
            rimLayer
            bottomFadeLayer
            edgeFadeLayer
            mistLayer
            grainLayer

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
        // D3:十神 chip 在 accessibilityHidden 的内容浮层里,VO 用户走此命名
        // action 打开同一张释义 sheet——明暗双通道同源。
        .accessibilityAction(named: Text(L10n.DailyFortune.shiShenNoteAction)) {
            showShiShenNote = true
        }
        // D3:今日十神释义(确定性静态表 HeroShiShenNotes,LLM 不参与)。
        .sheet(isPresented: $showShiShenNote) {
            HeroShiShenNoteSheet(relation: dayRelation)
                .presentationDetents([.height(250), .large])
                .presentationBackground(BaziTheme.paper)
        }
    }

    /// 无障碍合并 label:干支 + 页首短标 + 冲(有则读,与 chips 同源构造)+ 宜/忌词。
    private var heroAccessibilityLabel: String {
        let yiJi = HeroYiJiColumns.mapping[dayRelation] ?? HeroYiJiColumns.fallback
        var label = "\(dayPillar) \(L10n.DailyFortune.shortLabel)"
        if let chong = dayChong {
            // 2026-09-28 S06:此前 label 不读冲,视觉 chips 有而 VoiceOver 无;
            // 复用 chongLabel(含 EN 动物名 + 柱位翻译)与视觉同源。
            label += ", \(L10n.DailyFortune.chongLabel(chong: chong, targets: dayChongTargets))"
        }
        label += ", \(L10n.DailyFortune.yiLabel) \(yiJi.yi.joined(separator: "、")), \(L10n.DailyFortune.jiLabel) \(yiJi.ji.joined(separator: "、"))"
        return label
    }

    // MARK: - 玻璃图层

    private var baseLayer: some View {
        // 固定底图(2026-09-01 用户拍板「单张固定图」):画布定稿浅绛山水烘进
        // Asset Catalog,不再调生图 API——零成本/零延迟/零 IMAGE_API_KEY 依赖。
        // 2026-09-01 晚改竖版:原 3:2 横幅(1536×1024)在 ~0.92:1 卡内 scaledToFill
        // 要放大到 603pt 宽裁掉 39% 画面;重生成竖版 916×1717(B「极简空灵」,
        // gpt-image-2)后按卡比例裁 916×1000,山顶落卡高 25%/山脚 63%,整幅完整呈现。
        // prompt 与裁窗溯源:designs/daily-glass-20260831/hero-provenance.md。
        // 2026-09-25 暗色走查 #2:Asset Catalog 加 dark variant(HeroLandscape_dark.png,
        // 夜景版:深墨底淡白山影+月光倒影,gpt-image-2 三候选按亮度剖面客观选型,
        // 裁窗 (0,411,1024,1529) 同「山顶落卡高 25%」语义;溯源同文件夜版章节)——
        // 修订 08-30「暗色保持纸底」拍板:亮画在夜里像一盏灯,且冷白浮层文字
        // 压亮画不可读;夜景版下浮层文字(米白)恢复对比。系统按外观自动换图。
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
    /// 2026-09-25 暗色走查 #2:暗色换夜景版底图后,亮色档的呼吸纱罩(0.33-0.46)
    /// 会把本已沉入夜色的山影压死——暗色只留一档轻纱统一色温,呼吸幅度同步收窄。
    private var veilLayer: some View {
        Rectangle()
            .fill(BaziTheme.paper)
            .opacity(scheme == .dark ? (breathe ? 0.20 : 0.12) : (breathe ? 0.46 : 0.33))
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

    /// 4b 底部提前融纸(2026-09-25 打磨):外评「山水下边缘和文字区域糊在
    /// 一起」——宜忌列所在的底缘自 78% 起线性压纸、93% 全纸,山脚(63%)
    /// 与整体融纸观感不动,文字区从此干净落纸。
    private var bottomFadeLayer: some View {
        LinearGradient(
            stops: [
                .init(color: BaziTheme.paper.opacity(0), location: 0.78),
                .init(color: BaziTheme.paper, location: 0.93),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// 4c 四边融纸(2026-09-28 外评「hero 顶部/左右矩形硬边」):bloomMask 圆心
    /// y=0.42、endRadius 400 下,卡顶距圆心约 169pt、左右约 178pt,都落在实心
    /// 阈 0.58 内——顶边与左右边完全不透明,rim 层同因,只有底边有
    /// bottomFadeLayer,山水在这三条边被直线切断。本层以纸色压顶(0→0.14)
    /// 与左右(0→0.07 / 0.93→1)极窄渐变融边;与 bottomFadeLayer 同性质
    /// (叠在图上的纸色遮罩,不是背景渐变),paper 为 dyn 双值,暗色自动夜宣纸。
    private var edgeFadeLayer: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: BaziTheme.paper, location: 0),
                    .init(color: BaziTheme.paper.opacity(0), location: 0.14),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: BaziTheme.paper, location: 0),
                    .init(color: BaziTheme.paper.opacity(0), location: 0.07),
                    .init(color: BaziTheme.paper.opacity(0), location: 0.93),
                    .init(color: BaziTheme.paper, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
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
                .padding(.horizontal, Self.contentInset)
                .padding(.top, 18)
            Spacer()
            HeroYiJiColumns(dayRelation: dayRelation)
                .padding(.horizontal, Self.contentInset)
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
                Text(verbatim: lunarLine)
                    .font(BaziFont.songDisplay(size: 11))
                    .tracking(0.5)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
            }
        }
    }

    /// 日期区第二行:农历·干支。zh/Hant 维持原拼接;EN(2026-09-24 i18n
    /// 拼接重设计)把农历汉字转写成 "5th Moon · 28th · Day of 辛丑"——
    /// 原 "Lunar 八月十四 · 辛丑 Day" 半中半英不可读。解析失败回落原拼接
    /// (宁可露中文不猜,记日志)。
    private var lunarLine: String {
        if AppLanguage.current == .en,
           let en = Self.enLunarLine(lunarDate: lunarDate, dayPillar: dayPillar) {
            return en
        }
        return "\(L10n.DailyFortune.lunarPrefix) \(lunarDate) · \(dayPillar)\(L10n.DailyFortune.dayPillarSuffix)"
    }

    /// 关系/冲 chips(放不下时整组换行,组内仍横排)。
    /// 2026-09-28 S06:①关系 chip 朱红违规(cinnabar 仅印章级授权场景)改 ink,
    /// 与冲 chip 的 inkMuted 靠墨色浓淡分主次;②hero 内文字均固定字号、卡高固定
    /// 402pt,chips 跟随 Dynamic Type 会在大字号档顶出卡边——cap 到 large
    /// (只作用 hero chips,不改 ChipView 本身,其他页面行为不变);
    /// 无障碍完整语义由 heroAccessibilityLabel 承担(含冲)。
    /// 2026-09-29 D3:十神 chip 可点,弹出今日十神释义(见 HeroShiShenNotes)。
    private var chips: some View {
        HStack(spacing: 7) {
            Button {
                showShiShenNote = true
            } label: {
                ChipView(text: Self.displayRelation(dayRelation), tint: BaziTheme.ink, iconName: Self.relationIcon(for: dayRelation))
            }
            .buttonStyle(.plain)
            if let chong = dayChong {
                let label = L10n.DailyFortune.chongLabel(chong: chong, targets: dayChongTargets)
                ChipView(text: label, tint: BaziTheme.inkMuted, iconName: "PlaqueChong")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
    }

    /// 关系 chip 配图:刃(PlaqueSha)= 克身之压力,只配官杀族(七杀/正官);
    /// 其余十神语义不合,回纯文字 chip。补全十神符牌图后删 gate(V1 拍板口径)。
    static func relationIcon(for relation: String) -> String? {
        relation == "七杀" || relation == "正官" ? "PlaqueSha" : nil
    }

    /// chip 十神显示名(2026-09-27 U3c 改走 BaziTerms 统一查表:zh 原形 /
    /// zh-hant 异形(劫財/傷官/偏財/正財/七殺)/ en 意译——en 显示中文十神的
    /// 2026-08-26 旧口径被 i18n-display-layer-handoff §3 术语显示矩阵取代;
    /// 本地 relationHant 异形表随之退役,BaziTerms.tenGods 的 zhHant 列为超集)。
    /// 未知关系 BaziTerms.display 显式回落原值 + 日志(非错误)。
    static func displayRelation(_ relation: String) -> String {
        BaziTerms.display(relation)
    }

    // MARK: - 农历 EN 转写(2026-09-24 i18n 拼接重设计)

    /// 农历月名 → 1-12。lunar_python `getMonthInChinese` 用传统月名
    /// **正/二/…/十/冬/腊**(2026-09-24 实测枚举,不是一..十二),
    /// 可带「闰」前缀(调用方剥离)。不认识返回 nil(不猜)。
    static func lunarMonthNumber(_ s: String) -> Int? {
        switch s {
        case "正": return 1
        case "二": return 2
        case "三": return 3
        case "四": return 4
        case "五": return 5
        case "六": return 6
        case "七": return 7
        case "八": return 8
        case "九": return 9
        case "十": return 10
        case "冬": return 11
        case "腊": return 12
        default: return nil
        }
    }

    /// 中文数字(≤2 位:一..九 / 十 / 十X / X十)→ Int。农历日用。
    /// 不认识的形状返回 nil(调用方记日志回落,不猜)。
    static func zhNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9,
        ]
        let chars = Array(s)
        switch chars.count {
        case 1:
            if let v = digits[chars[0]] { return v }
            return chars[0] == "十" ? 10 : nil
        case 2:
            if chars[0] == "十", let unit = digits[chars[1]] { return 10 + unit }
            if let tens = digits[chars[0]], chars[1] == "十" { return tens * 10 }
            return nil
        default:
            return nil
        }
    }

    /// 农历日中文 → 1-30(初X / 十X / 二十 / 廿X / 三十);nil = 不认识。
    /// lunar_python `getDayInChinese` ground truth(2026-09-24 实测枚举)。
    static func lunarDayNumber(_ s: String) -> Int? {
        if s.hasPrefix("初") {
            return zhNumber(String(s.dropFirst()))
        }
        if s.hasPrefix("廿") {
            let rest = String(s.dropFirst())
            guard !rest.isEmpty else { return 20 }
            return zhNumber(rest).map { 20 + $0 }
        }
        return zhNumber(s)  // 十一..十九 / 二十 / 三十
    }

    /// 农历整串("五月廿八" / "闰六月初十" / "冬月廿八")+ 日柱 → EN 单行
    /// "5th Moon · 28th · Day of 辛丑"。nil = 形状不符(调用方回落原拼接)。
    static func enLunarLine(lunarDate: String, dayPillar: String) -> String? {
        guard let idx = lunarDate.firstIndex(of: "月") else { return nil }
        var monthPart = String(lunarDate[..<idx])
        let dayPart = String(lunarDate[lunarDate.index(after: idx)...])
        var leap = false
        if monthPart.hasPrefix("闰") {
            leap = true
            monthPart.removeFirst()
        }
        guard let month = lunarMonthNumber(monthPart),
              let day = lunarDayNumber(dayPart),
              (1...30).contains(day)
        else {
            AppLogger.app.warning(
                "op=heroLunar.parseMiss lunarDate=\(lunarDate, privacy: .public) -> rawFallback"
            )
            return nil
        }
        let leapPrefix = leap ? "Leap " : ""
        return "\(leapPrefix)\(ordinal(month)) Moon · \(ordinal(day)) · Day of \(dayPillar)"
    }

    /// 1-30 序数后缀(11/12/13 走 th)。
    private static func ordinal(_ n: Int) -> String {
        if n % 100 == 11 || n % 100 == 12 || n % 100 == 13 { return "\(n)th" }
        switch n % 10 {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }
}

// MARK: - HeroYiJiColumns(宜/忌双列清单)

/// 图内宜/忌双列(参考图 Do/Don'ts 语言,2026-08-31 拍板支持 2-3 条/列)。
///
/// 数据源(v1 简化,同前):前端十神→关键词查表,扩为**每列 3 词**;
/// 后续可挪后端基于喜忌+流日关系确定性映射(不增加 v1 后端复杂度)。
/// 十神 key 始终中文(后端不翻译,i18n 决策 7);词表按 AppLanguage 切换。
/// internal(非 private)供 DailyImageHeroCopyTests 断言 EN 词表 ≤16 chars 预算。
struct HeroYiJiColumns: View {
    let dayRelation: String

    static let mappingZh: [String: (yi: [String], ji: [String])] = [
        "比肩": (["独立", "立界", "健身"], ["争执", "攀比", "随众"]),
        "劫财": (["行动", "开拓", "结伴"], ["冲动", "借贷", "硬拼"]),
        "食神": (["创造", "表达", "会友"], ["拖延", "熬夜", "争辩"]),
        "伤官": (["表达", "出新", "直言"], ["冲撞", "越界", "口快"]),
        "偏财": (["拓展", "试新", "让利"], ["孤注", "贪多", "赊账"]),
        "正财": (["守成", "记账", "务本"], ["短视", "贪快", "弃约"]),
        "七杀": (["果断", "担事", "攻坚"], ["犹豫", "树敌", "硬扛"]),
        "正官": (["担当", "守规", "复命"], ["退缩", "越级", "失约"]),
        "偏印": (["思考", "独处", "温故"], ["执拗", "多虑", "孤行"]),
        "正印": (["学习", "纳言", "养身"], ["依赖", "空想", "拖延"]),
    ]

    /// EN 词表(2026-09-24 三改):09-19 版被外评审点「像公司合规手册」
    /// (正官行 Own Your Duty / Play by the Rules / Report Back / Skip the
    /// Chain),整体换人味口吻——短祈使句、对自己说话的语气;每条 ≤16 chars
    /// (serif 15pt 双列 ~138pt/列单行内 @375pt 屏,2026-09-28 S03 内边距 20 +
    /// 列距 24 后的列宽,09-19 宽度约束延续)——
    /// 预算由 DailyImageHeroCopyTests 守护(2026-09-23 review #2)。
    /// 2026-09-28 外评:3 条与 EngineReadingTemplates 兜底模板语气打架
    /// (劫财 Act Now vs「just don't rush」/ Split the Gains vs「think
    /// twice before…splitting stakes」/ 七杀 Push Through vs「don't burn
    /// yourself out」),改 Take the Lead / Team Up / Face It Head-On。
    static let mappingEn: [String: (yi: [String], ji: [String])] = [
        "比肩": (["Go Your Own Way", "Set Boundaries", "Move Your Body"], ["Argue", "Compare Yourself", "Follow the Crowd"]),
        "劫财": (["Take the Lead", "Break New Ground", "Team Up"], ["Impulse Buys", "Lend Money", "Force It"]),
        "食神": (["Make Something", "Speak Your Mind", "See a Friend"], ["Put It Off", "Stay Up Late", "Pick Fights"]),
        "伤官": (["Show Your Work", "Say It Plain", "Be Frank"], ["Push Too Hard", "Cross the Line", "Blurt It Out"]),
        "偏财": (["Explore", "Try New Things", "Give a Little"], ["Bet It All", "Grab Too Much", "Buy on Credit"]),
        "正财": (["Keep Steady", "Track Your Money", "Tend Your Garden"], ["Cut Corners", "Rush the Deal", "Break Your Word"]),
        "七杀": (["Make the Call", "Take It On", "Face It Head-On"], ["Waver", "Make Enemies", "Burn Out"]),
        "正官": (["Own Your Part", "Play It Straight", "Close the Loop"], ["Shrink Back", "Skip the Line", "Miss Deadlines"]),
        "偏印": (["Sit with It", "Review Old Notes", "Take Quiet Time"], ["Get Stubborn", "Overthink", "Go It Alone"]),
        "正印": (["Learn Something", "Take Advice", "Rest Up"], ["Lean Too Hard", "Daydream", "Drag Your Feet"]),
    ]

    /// 繁体词表(T0):key 仍为后端简体十神(决策 7 不翻译),词表值由 mappingZh
    /// 转繁;用词对齐台湾惯用(記帳/賒帳/復命——复一对多:復命/複數/覆蓋,
    /// 「覆命」为误转,2026-09-23 review P1-4 修正)。
    static let mappingHant: [String: (yi: [String], ji: [String])] = [
        "比肩": (["獨立", "立界", "健身"], ["爭執", "攀比", "隨眾"]),
        "劫财": (["行動", "開拓", "結伴"], ["衝動", "借貸", "硬拼"]),
        "食神": (["創造", "表達", "會友"], ["拖延", "熬夜", "爭辯"]),
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
        // spacing 24(2026-09-28 S03):内容内边距 4→20 吃掉 32pt,列距 34→24
        // 补回 10pt;375pt 屏单列 ≈(375−24−40−24)/2 ≈ 138pt,EN 16 chars 预算内。
        HStack(alignment: .top, spacing: 24) {
            column(header: isEn ? "Do" : "宜", annotation: isEn ? "宜 yí" : nil, items: resolved.yi)
            column(header: isEn ? "Don't" : "忌", annotation: isEn ? "忌 jì" : nil, items: resolved.ji)
        }
        .inkIn(delay: 0.45)
    }

    /// 单列:宋体大字列头(EN 衬线)+ 条目纵堆(EN 衬线,2026-09-24 收敛
    /// 去 mono)+ EN 列头下加「宜 yí / 忌 jì」汉字注音小注(命理符号保留
    /// 中文 + 拼音点缀,对齐 ShichenDisplay 拼音先例)。
    private func column(header: String, annotation: String?, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(header)
                    .font(isEn ? .system(size: 30, weight: .regular, design: .serif) : BaziFont.songDisplay(size: 26, weight: .semibold))
                    .foregroundStyle(BaziTheme.ink)
                if let annotation {
                    Text(verbatim: annotation)
                        .font(BaziFont.songDisplay(size: 11))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text(item)
                        .font(isEn ? .system(size: 15, weight: .regular, design: .serif) : BaziFont.songDisplay(size: 17))
                        .tracking(isEn ? 0.3 : 1.7)
                        .foregroundStyle(BaziTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .padding(.vertical, 4.5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 十神释义静态表(D3,2026-09-29 拍板)

/// 今日十神释义(hero 十神 chip 点开的小卡正文)。
///
/// **确定性静态表,LLM 不参与**(「LLM 只润色不判断」边界:释义是判断性内容,
/// 必须查表,不走 AI)。键集合 == `BaziTerms.tenGods` 的 zh 键(11,含偏官=
/// 七杀同义),由 DailyImageHeroCopyTests 守护;键仍为后端简体十神(决策 7)。
///
/// 文案结构:「主星性。今日宜…;留意…」——宜/告诫口径与 HeroYiJiColumns
/// 词表同源(正面半句呼应宜词,告诫半句呼应忌词),S01「宜词不得落告诫半句」
/// 守护同款适用(本表为自有长句,EN 亦可子串比对)。查不到显式回落通用文案
/// + 日志(对齐 HeroYiJiColumns 哲学,不静默吞)。
enum HeroShiShenNotes {
    static let zh: [String: String] = [
        "比肩": "与日主同气之星,主独立与同伴。今日宜亲力亲为、守住边界;留意争执攀比,不必随众。",
        "劫财": "主同辈分利与竞争。今日行动力旺,宜带头开拓、与人结伴;留意钱财被分走,忌借贷硬拼。",
        "食神": "主生发与滋养。今日宜创作表达、与老友相聚;留意拖延与熬夜,莫因小事争辩。",
        "伤官": "主才华外露。今日思路锋利,宜出新与直言;留意口快冲撞,守住分寸边界。",
        "偏财": "主流动之财。今日财缘在外,宜拓展试新、适度让利;忌孤注一掷与贪多。",
        "正财": "主本分之财。今日宜守成务实、记账理物;留意短视贪快,承诺之事勿弃。",
        "七杀": "主克身之压力。今日重担在肩,宜果断攻坚、敢担事;留意树敌与硬扛,别耗尽自己。",
        "偏官": "主克身之压力。今日重担在肩,宜果断攻坚、敢担事;留意树敌与硬扛,别耗尽自己。",
        "正官": "主规矩与担当。今日宜守规复命、有始有终;留意退缩越级,重诺守时。",
        "偏印": "主沉思与直觉。今日宜独处温故、静中得思;留意多虑执拗,莫闭门孤行。",
        "正印": "主滋养与学识。今日宜学习纳言、休养生息;留意依赖空想,行胜于言。",
    ]

    /// 繁体(对齐 mappingHant 先例:台湾惯用 記帳;克身→剋身)。
    static let hant: [String: String] = [
        "比肩": "與日主同氣之星,主獨立與同伴。今日宜親力親為、守住邊界;留意爭執攀比,不必隨眾。",
        "劫财": "主同輩分利與競爭。今日行動力旺,宜帶頭開拓、與人結伴;留意錢財被分走,忌借貸硬拼。",
        "食神": "主生發與滋養。今日宜創作表達、與老友相聚;留意拖延與熬夜,莫因小事爭辯。",
        "伤官": "主才華外露。今日思路鋒利,宜出新與直言;留意口快衝撞,守住分寸邊界。",
        "偏财": "主流動之財。今日財緣在外,宜拓展試新、適度讓利;忌孤注一擲與貪多。",
        "正财": "主本分之財。今日宜守成務實、記帳理物;留意短視貪快,承諾之事勿棄。",
        "七杀": "主剋身之壓力。今日重擔在肩,宜果斷攻堅、敢擔事;留意樹敵與硬扛,別耗盡自己。",
        "偏官": "主剋身之壓力。今日重擔在肩,宜果斷攻堅、敢擔事;留意樹敵與硬扛,別耗盡自己。",
        "正官": "主規矩與擔當。今日宜守規復命、有始有終;留意退縮越級,重諾守時。",
        "偏印": "主沉思與直覺。今日宜獨處溫故、靜中得思;留意多慮執拗,莫閉門孤行。",
        "正印": "主滋養與學識。今日宜學習納言、休養生息;留意依賴空想,行勝於言。",
    ]

    /// EN(措辞呼应 mappingEn 词表:正面半句用宜短语同族表达,告诫半句用忌词)。
    static let en: [String: String] = [
        "比肩": "The peer star — independence and equals. Do it yourself and hold your line today; don't argue, compare, or follow the crowd.",
        "劫财": "The star of shared stakes. Strong drive today — take the lead and team up; watch your money, and skip the lending.",
        "食神": "The star of easy creation. Make something, speak your mind, see a friend; just don't put it off or stay up late.",
        "伤官": "The star of sharp talent. Show your work and say it plain; mind the quick tongue, and mind the lines you cross.",
        "偏财": "The star of flowing wealth. Explore, try new things, give a little; don't bet it all or grab too much.",
        "正财": "The star of steady wealth. Keep steady and track your money; no cutting corners, no broken word.",
        "七杀": "The star of pressure. A heavy day — make the call and take it on; don't make enemies, don't burn yourself out.",
        "偏官": "The star of pressure. A heavy day — make the call and take it on; don't make enemies, don't burn yourself out.",
        "正官": "The star of order and duty. Own your part and play it straight; don't shrink back or miss deadlines.",
        "偏印": "The star of quiet thought. Sit with it and review old notes; don't overthink, don't go it alone.",
        "正印": "The star of nourishment. Learn something, take advice, rest up; just don't lean too hard on anyone.",
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .zh:     return zh
        case .zhHant: return hant
        case .en:     return en
        }
    }

    /// 释义查询:查不到显式回落通用文案 + 日志(不静默吞)。
    static func note(for relation: String, language: AppLanguage = AppLanguage.current) -> String {
        if let text = table(for: language)[relation] {
            return text
        }
        AppLogger.app.warning(
            "op=heroShiShenNote.lookupMiss relation=\(relation, privacy: .public) -> fallback"
        )
        switch language {
        case .zh:     return "平稳之日,顺时而为,不强行事。"
        case .zhHant: return "平穩之日,順時而為,不強行事。"
        case .en:     return "A calm, even day — move with it rather than against it."
        }
    }
}

// MARK: - 十神释义小卡(D3)

/// hero 十神 chip 点开的释义卡:术语标题(楷体 display)+ 一句静态释义
/// (楷体 body)。EN 标题附汉字括注(对齐 shenshaChipText「意译 (漢字)」
/// 先例,chip 上放不下,sheet 里补足);detents 250 起步可拉大(AX 大字号
/// 下正文可完整展开)。presentationBackground 纸色由调用侧注入。
struct HeroShiShenNoteSheet: View {
    let relation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: titleText)
                .font(BaziFont.display(size: 21, weight: .medium))
                .foregroundStyle(BaziTheme.ink)
            Text(verbatim: HeroShiShenNotes.note(for: relation))
                .font(BaziFont.body(size: 15))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private var titleText: String {
        if AppLanguage.current == .en, let entry = BaziTerms.index[relation] {
            return "\(entry.en) (\(entry.zhHant))"
        }
        return DailyImageHeroSection.displayRelation(relation)
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
