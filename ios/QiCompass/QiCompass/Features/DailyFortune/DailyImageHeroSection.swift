import SwiftUI

/// 今日 hero「光晕」(**2026-10-14 用户拍板改用 B 版**,设计画布「今日页 · 窗影改稿」
/// B · 光晕;替换 2026-10-01 定稿的 glass-v2 浅绛山水画卡。**2026-10-15 拍板
/// 贴 B 稿终形**:去掉竖排签文(B 稿没有),光晕不再单独占舞台,改为铺在头部
/// 日期区 / chips / 宜忌后面的**衬底**——`HaloBackdrop` 由宿主
/// `DailyFortuneMainView` 挂在这一块的 `.background` 上。本 struct 只承载
/// 宜/忌双列字层;头部日期区与 chips 仍由 `DailyHeaderSection` 承担。
///
/// **光晕取色(确定性,0 AI;2026-10-15 用户五行光晕视觉规格版)**:主晕 =
/// 流日天干五行;辅一 = 今日信号里首个「喜用 ↑」且 ≠ 主五行的五行(引擎
/// 喜用命中优先),无则取我生(主五行所生);辅二 = 我克,与辅一撞车时改取
/// 我生。`dayElements` 缺失(老后端/老快照)→ 天干五行按日柱首字查表
/// (`ElementColors.ofGan`,纯展示查表非历法),查不到记日志回落 inkMuted。
/// 色板走 `HaloColors`(主色+伴色,比 ElementColors 饱和,仅 hero 光晕用)。
/// 「我生/我克」只是选色推法,**不落任何文字**——宜借属喜忌判断,只来自
/// 后端规则引擎,hero 不呈现命理结论。
///
/// **DESIGN.md 破例**:光晕是 RadialGradient + blur 的色团,属「禁止渐变背景」
/// 的显式豁免——它是 hero 艺术层(同旧画卡的径向 mask / 云雾层性质),不是
/// 页面背景;2026-10-15 起光晕铺在头部和宜忌文字后面,仍只覆盖页面顶部约
/// 420pt,页面底色仍是纯色宣纸(2026-10-14 用户拍板「光晕破例,字体保持
/// 中文字形」;10-18 晚起为宋体)。暗色:光晕透明度整体压低,避免夜宣纸上像霓虹。
/// reduce-motion:漂移全停。
struct DailyImageHeroSection: View {
    let dayRelation: String

    var body: some View {
        HeroYiJiColumns(dayRelation: dayRelation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: yiJiAccessibilityLabel))
    }

    /// 无障碍合并 label:宜/忌词(装饰光晕在 HaloBackdrop,不读)。
    private var yiJiAccessibilityLabel: String {
        let yiJi = HeroYiJiColumns.mapping[dayRelation] ?? HeroYiJiColumns.fallback
        return "\(L10n.DailyFortune.yiLabel) \(yiJi.yi.joined(separator: "、")), "
            + "\(L10n.DailyFortune.jiLabel) \(yiJi.ji.joined(separator: "、"))"
    }
}

// MARK: - 光晕衬底(2026-10-15 贴 B 稿)

/// 今日 hero 光晕衬底:四团流日五行色的柔光缓慢漂移,不带任何文字
/// (**2026-10-15 从 `DailyImageHeroSection` 的 340pt 独立舞台抽出**——
/// B 稿光晕铺在头部 / chips / 宜忌后面,由 `DailyFortuneMainView` 挂在
/// 这一块的 `.background` 上)。取色规则见文件头注与 `HaloPalette`。
struct HaloBackdrop: View {
    let dayPillar: String
    /// 流日天干五行(S6;2026-10-15 起只取 stemElement,branchElement 不再
    /// 参与取色;nil = 老后端/老快照,走日柱首字查表兜底)。
    var dayElements: DayElementsDTO? = nil
    /// 今日信号(喜用 ↑ / 忌 ↓),只用来挑辅一颜色(喜用命中优先)。
    var daySignal: [DaySignalItemDTO]? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// 光晕层高(设计坐标 390×420 原样,1:1 落位;2026-10-15 规格)。
    static let height: CGFloat = 420

    // 漂移状态(B 稿 12s alternate,四团错相——SwiftUI 无 animation-delay,
    // 用四个不同周期近似错相)
    @State private var driftA = false
    @State private var driftB = false
    @State private var driftC = false
    @State private var driftD = false

    var body: some View {
        haloLayer
            .onAppear(perform: startCycles)
    }

    /// 四团光晕(2026-10-15 用户五行光晕视觉规格,设计坐标系 390×420):
    /// 主光 dominantMain 250×290 @(295,165) / 伴光 dominantTint 200×220
    /// @(60,100) / 辅光一 support0Main 150×170 @(115,345) / 辅光二
    /// support1Main 120×140 @(260,330);不透明度 0.60/0.70/0.55/0.50
    /// (主光 2026-10-18 S4 由 0.85 降——真机外评:压在「忌」朱红字后像污渍)。
    /// 中心按 W/390、H/420 换算(衬底高恰 420,sy≈1,四团光按规格坐标
    /// 1:1 落位),尺寸按 W/390 等比(宽高同比保椭圆形状),blur 半径固定
    /// 26 不随屏宽缩放。不 clip:blur 边缘自然洇进页边与下方内容,
    /// 不出现矩形切边。
    private var haloLayer: some View {
        let palette = HaloPalette(dayPillar: dayPillar, dayElements: dayElements, daySignal: daySignal)
        let dim = scheme == .dark ? 0.55 : 1.0
        return GeometryReader { geo in
            let sx = geo.size.width / 390   // 设计稿宽 390
            let sy = geo.size.height / 420  // 设计稿高 420(衬底高恰 420,sy≈1)
            ZStack(alignment: .topLeading) {
                // 绘制序(下→上):伴光 → 主光 → 辅光一 → 辅光二。
                // scale 必须在 position 之前:之后挂 scaleEffect 的锚点是
                // 舞台-sized 视图的中心(= 舞台中心),会把光团中心到舞台
                // 中心的距离一并放大,position 中心点被重复换算(plan §5 禁)。
                halo(palette.dominantTint, opacity: 0.70 * dim,
                     width: 200 * sx, height: 220 * sx)
                    .scaleEffect(driftScale(driftB))
                    .position(x: 60 * sx, y: 100 * sy)
                    .offset(drift(driftB))
                halo(palette.dominantMain, opacity: 0.60 * dim,
                     width: 250 * sx, height: 290 * sx)
                    .scaleEffect(driftScale(driftA))
                    .position(x: 295 * sx, y: 165 * sy)
                    .offset(drift(driftA))
                halo(palette.support0Main, opacity: 0.55 * dim,
                     width: 150 * sx, height: 170 * sx)
                    .scaleEffect(driftScale(driftC))
                    .position(x: 115 * sx, y: 345 * sy)
                    .offset(drift(driftC))
                halo(palette.support1Main, opacity: 0.50 * dim,
                     width: 120 * sx, height: 140 * sx)
                    .scaleEffect(driftScale(driftD))
                    .position(x: 260 * sx, y: 330 * sy)
                    .offset(drift(driftD))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 单团光晕:closest-side 径向(实心色 → 透明)+ blur 26(B 稿 filter 同值)。
    private func halo(_ color: Color, opacity: Double, width: CGFloat, height: CGFloat) -> some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [color.opacity(opacity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: min(width, height) / 2
                )
            )
            .frame(width: width, height: height)
            .blur(radius: 26)
    }

    /// 规格 keyframes:translate(8px,-10px) + scale 1→1.05 往返
    /// (2026-10-15 版补回 scale——伴色光团边界可辨,缩放可感知)。
    private func drift(_ on: Bool) -> CGSize {
        on ? CGSize(width: 8, height: -10) : .zero
    }

    private func driftScale(_ on: Bool) -> CGFloat {
        on ? 1.05 : 1
    }

    /// 四团错相:规格 12s 往返 + 负延迟;SwiftUI 无负延迟(`.delay(n)` 会先
    /// 静止 n 秒,禁用),用略不同的半程时长近似错相(光 1/2/3/4 = 6.0/
    /// 6.8/5.6/7.4s)。reduce-motion 时整体不启动(上方 guard)。
    private func startCycles() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 6.0).repeatForever(autoreverses: true)) { driftA = true }
        withAnimation(.easeInOut(duration: 6.8).repeatForever(autoreverses: true)) { driftB = true }
        withAnimation(.easeInOut(duration: 5.6).repeatForever(autoreverses: true)) { driftC = true }
        withAnimation(.easeInOut(duration: 7.4).repeatForever(autoreverses: true)) { driftD = true }
    }
}

// MARK: - 光晕取色

/// 光晕专用五行色(2026-10-15 用户五行光晕视觉规格;比 ElementColors 饱和,
/// 只用于 hero 光晕——ElementColors 是全 app 降饱和色系的设计,不动)。
/// 亮/暗同一组色值,暗色只靠 haloLayer 的透明度系数 dim 压低,不另调色。
/// key 用英文五行 key(同 ElementColors.rawValue);未知 key 返回 nil,
/// 调用方回落 inkMuted(HaloPalette init 已有 elementMiss 日志,不新增
/// 静默兜底)。构造写法与 ElementColors 一致(Color(red:r/255,…)),
/// 不新增全局 Color(rgb:) extension。internal 供测试钉色板完整性。
enum HaloColors {
    /// 主色(金 #CDAA64 / 木 #78A06E / 水 #5F87AF / 火 #D77855 / 土 #C8A069)。
    static func main(_ key: String) -> Color? {
        switch key {
        case "metal": return Color(red: 0xCD / 255, green: 0xAA / 255, blue: 0x64 / 255)
        case "wood":  return Color(red: 0x78 / 255, green: 0xA0 / 255, blue: 0x6E / 255)
        case "water": return Color(red: 0x5F / 255, green: 0x87 / 255, blue: 0xAF / 255)
        case "fire":  return Color(red: 0xD7 / 255, green: 0x78 / 255, blue: 0x55 / 255)
        case "earth": return Color(red: 0xC8 / 255, green: 0xA0 / 255, blue: 0x69 / 255)
        default: return nil
        }
    }

    /// 伴色(金 #B4BCC4 / 木 #BECD96 / 水 #A0BED2 / 火 #EBAF87 / 土 #B99878)。
    static func tint(_ key: String) -> Color? {
        switch key {
        case "metal": return Color(red: 0xB4 / 255, green: 0xBC / 255, blue: 0xC4 / 255)
        case "wood":  return Color(red: 0xBE / 255, green: 0xCD / 255, blue: 0x96 / 255)
        case "water": return Color(red: 0xA0 / 255, green: 0xBE / 255, blue: 0xD2 / 255)
        case "fire":  return Color(red: 0xEB / 255, green: 0xAF / 255, blue: 0x87 / 255)
        case "earth": return Color(red: 0xB9 / 255, green: 0x98 / 255, blue: 0x78 / 255)
        default: return nil
        }
    }
}

/// 光晕四色取色(主/辅一/辅二,规则见 DailyImageHeroSection 头注)。
/// internal 供测试钉取色规则。不变式:dominant 非 nil 时三者两两不同
/// (sheng/ke 均不自映射、互不重叠,辅二撞车回落我生,测试守护)。
struct HaloPalette {
    let dominantKey: String?   // 主五行(流日天干)
    let support0Key: String?   // 辅一(喜用信号命中优先,否则我生)
    let support1Key: String?   // 辅二(我克;与辅一撞车改我生)

    /// 五行相生(木→火→土→金→水→木),英文 key 口径同 ElementColors。
    static let sheng: [String: String] = [
        "wood": "fire", "fire": "earth", "earth": "metal", "metal": "water", "water": "wood",
    ]

    /// 五行相克(我克:金→木、木→土、土→水、水→火、火→金)。
    static let ke: [String: String] = [
        "wood": "earth", "earth": "water", "water": "fire", "fire": "metal", "metal": "wood",
    ]

    init(dayPillar: String, dayElements: DayElementsDTO?, daySignal: [DaySignalItemDTO]?) {
        let dominant: String?
        if let stem = dayElements?.stemElement {
            dominant = ElementColors.fromZh(stem)
        } else {
            dominant = dayPillar.first.flatMap { ElementColors.ofGan(String($0)) }
        }
        if dominant == nil {
            AppLogger.app.warning(
                "op=heroHalo.elementMiss dayPillar=\(dayPillar, privacy: .public) -> inkMuted"
            )
        }

        // 辅一:引擎喜用信号(↑ 且 ≠ 主五行)命中优先;否则我生。
        // dominant 为 nil 时信号仍可命中(≠ nil 恒真),规则 4 的豁免项。
        let signal0 = (daySignal ?? [])
            .filter { $0.direction == "up" }
            .compactMap { ElementColors.fromZh($0.element) }
            .first { dominant == nil || $0 != dominant }
        let support0 = signal0 ?? dominant.flatMap { Self.sheng[$0] }

        // 辅二:我克;信号先占了 ke[d] 则回落我生。dominant 为 nil 时无从
        // 推导(sheng/ke 都以 dominant 为键),保持 nil。
        let support1 = dominant.flatMap { d in
            Self.ke[d] == support0 ? Self.sheng[d] : Self.ke[d]
        }

        self.dominantKey = dominant
        self.support0Key = support0
        self.support1Key = support1
    }

    var dominantMain: Color { Self.mainColor(dominantKey) }
    var dominantTint: Color { Self.tintColor(dominantKey) }
    var support0Main: Color { Self.mainColor(support0Key) }
    var support1Main: Color { Self.mainColor(support1Key) }

    private static func mainColor(_ key: String?) -> Color {
        key.flatMap(HaloColors.main) ?? BaziTheme.inkMuted
    }

    private static func tintColor(_ key: String?) -> Color {
        key.flatMap(HaloColors.tint) ?? BaziTheme.inkMuted
    }
}

// MARK: - 今日五行条(S3,2026-10-25)

/// 今日五行力量五根条(对比稿 docs/design-ref/today-type/今日五行条.html 定稿)。
///
/// 数据全部确定性,零 AI:「过旺」标 = 分布最高项(后端 `day_element_strength`
/// 纯历法推算:流日干 ×1.0 + 流日支藏干 主1.0/中0.5/余0.25 + 月令藏干 ×2,
/// 归一化最高=100);「宜借」标/hint = `day_signal ↑`(规则引擎产物)——
/// **不是**光晕选色推法(我生/我克),后者按 10-15 拍板永不落文字
/// (DESIGN.md Decisions Log 2026-10-25 翻案记录:分布数据本批补齐,
/// 宜借文字改引引擎产物后原「未采纳」理由不再成立)。
/// 键序由后端 ELEMENT_ORDER 锚定(木火土金水 = 条从左到右);今日无某行
/// (值 0)条空着,诚实保留;条色 = HaloColors(光晕同款五行色板)。
struct DailyElementStrengthSection: View {
    /// 五行力量(键 = 中文五行字,后端简体口径)。空 → 宿主不渲染本块。
    let strength: [String: Int]
    /// 今日信号(↑ = 宜借标);空(时辰未知/从格)→ 只标过旺,hint 收起
    /// 「宜借」半句(不编造喜忌语义)。
    var daySignal: [DaySignalItemDTO]? = nil

    /// 显示序固定(dict 无序;与后端 ELEMENT_ORDER 逐字对齐,改须两侧同步)。
    static let displayOrder: [String] = ["木", "火", "土", "金", "水"]

    private var peakValue: Int {
        Self.displayOrder.compactMap { strength[$0] }.max() ?? 0
    }

    /// 分布最高项;并列取显示序首个(确定性,同日后端同值)。
    /// internal 供 DailyImageHeroCopyTests 钉判定序。
    var dominant: String? {
        guard peakValue > 0 else { return nil }
        return Self.displayOrder.first { strength[$0] == peakValue }
    }

    /// 宜借集 = day_signal ↑ 命中的五行(保持 ↑ 顺序,去重)。
    /// internal 供 DailyImageHeroCopyTests 钉判定序。
    /// 命名避开 `borrow`:新 toolchain 里它是 accessor 关键字,语句位
    /// (`borrow.map` 起句)会被当 accessor 解析而编译失败(实证 376 行)。
    var borrowElements: [String] {
        var seen = Set<String>()
        // insert().inserted == 首次出现 → 保留;重复项 false → 丢弃(保序去重)
        return (daySignal ?? [])
            .filter { $0.direction == "up" && seen.insert($0.element).inserted }
            .map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headRow
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Self.displayOrder, id: \.self) { element in
                    bar(element)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: a11yLabel))
    }

    /// 区标 + hint:「土气偏旺 · 宜借金土」。宜借半句只在 day_signal ↑ 非空
    /// 时出现;五行关键词浓墨 semibold,其余 inkMuted。
    private var headRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.DailyFortune.elementsTitle)
                .font(.system(size: 13, weight: .medium))
                .tracking(AppLanguage.current.isChinese ? 1.5 : 0)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer(minLength: 12)
            hint
        }
    }

    @ViewBuilder
    private var hint: some View {
        // Text 拼装走普通函数(ViewBuilder 体内不能跑 append);逐段带样式
        // 后用 +(Text 拼接,保留分段浓墨)合成单段——Text 无 [Text] 初始化器。
        if let merged = hintText() {
            merged
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    /// hint 单段 Text(nil = 两半句皆空,不渲染);空数组不 reduce(无首段可取)。
    private func hintText() -> Text? {
        let parts = hintParts()
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first, +)
    }

    /// hint 逐段 Text(弱段显式 .font 12,浓墨段 semibold 12;「 · 」仅在
    /// 过旺半句存在时插入,dominant 缺席不产生前导分隔符)。
    private func hintParts() -> [Text] {
        let strong = Self.formatParts(L10n.DailyFortune.elementsStrongFormat)
        let lean = Self.formatParts(L10n.DailyFortune.elementsBorrowFormat)
        var parts: [Text] = []
        if let dom = dominant {
            parts.append(Text(verbatim: BaziTerms.display(dom))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BaziTheme.ink))
            parts.append(Text(verbatim: strong.tail)
                .font(.system(size: 12))
                .foregroundStyle(BaziTheme.inkMuted))
        }
        if !borrowElements.isEmpty {
            if dominant != nil {
                parts.append(Text(verbatim: " · ")
                    .font(.system(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted))
            }
            parts.append(Text(verbatim: lean.head)
                .font(.system(size: 12))
                .foregroundStyle(BaziTheme.inkMuted))
            parts.append(Text(verbatim: borrowJoined)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(BaziTheme.ink))
        }
        return parts
    }

    /// 宜借多词连接:zh/zh-hant 直连(金土);en 逗号分隔(Metal, Earth)。
    private var borrowJoined: String {
        borrowElements.map { BaziTerms.display($0) }
            .joined(separator: AppLanguage.current.isChinese ? "" : ", ")
    }

    /// 单根条:顶标签(过旺/宜借/空)+ 6×72 轨道 + 五行字。
    /// 最高项字重 ink 浓墨;宜借 0.75 透明度;其余 0.4;值 0 = 空轨道。
    private func bar(_ element: String) -> some View {
        let value = strength[element] ?? 0
        let isDominant = (element == dominant)
        let isBorrow = borrowElements.contains(element)
        let tag: String? = isDominant
            ? L10n.DailyFortune.elementsTagPeak
            : (isBorrow ? L10n.DailyFortune.elementsTagLean : nil)
        let opacity: Double = isDominant ? 1.0 : (isBorrow ? 0.75 : 0.4)
        let color = ElementColors.fromZh(element)
            .flatMap { HaloColors.main($0) } ?? BaziTheme.inkMuted

        return VStack(alignment: .center, spacing: 9) {
            Text(verbatim: tag ?? "")
                .font(.system(size: 10))
                .tracking(1)
                .foregroundStyle(isDominant ? BaziTheme.ink : BaziTheme.inkMuted)
                .frame(height: 13)
            Capsule()
                .fill(BaziTheme.ink.opacity(0.07))
                .frame(width: 6, height: 72)
                .overlay(alignment: .bottom) {
                    // 值 0 = 空轨道(今日无此行,诚实保留)
                    if value > 0 {
                        Capsule()
                            .fill(color)
                            .opacity(opacity)
                            .frame(width: 6, height: 72 * Double(value) / 100)
                    }
                }
            Text(verbatim: BaziTerms.display(element))
                .font(BaziFont.songDisplay(size: 15, weight: isDominant ? .medium : .regular))
                .foregroundStyle(isDominant ? BaziTheme.ink : BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
    }

    /// 单 %@ 格式串拆头尾(zh "%@气偏旺" → ("", "气偏旺");en "lean on %@"
    /// → ("lean on ", ""))。hint 要给 %@ 位置的词单独上浓墨,所以拆开
    /// 拼装而不是整句 String(format:);a11y 整句朗读不拆,直接格式化。
    private static func formatParts(_ format: String) -> (head: String, tail: String) {
        let parts = format.components(separatedBy: "%@")
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    /// a11y 合并朗读:hint 全文(整句格式化,不拆浓墨)+ 五根条读数
    /// (「木 8、火 33、土 100、金 67、水 0」;分隔符随语言)。
    private var a11yLabel: String {
        var out: [String] = []
        if let dom = dominant {
            out.append(String(format: L10n.DailyFortune.elementsStrongFormat,
                              BaziTerms.display(dom)))
        }
        if !borrowElements.isEmpty {
            out.append(String(format: L10n.DailyFortune.elementsBorrowFormat,
                              borrowJoined))
        }
        let reading = Self.displayOrder.compactMap { el -> String? in
            guard let v = strength[el] else { return nil }
            return "\(BaziTerms.display(el)) \(v)"
        }
        if !reading.isEmpty {
            out.append(reading.joined(
                separator: AppLanguage.current.isChinese ? "、" : ", "))
        }
        return out.joined(separator: ",")
    }
}

// MARK: - 头部区(2026-10-01 Today 定稿 D3:信息一行看全,出图上纸面)

/// Today 头部区:大字日 + 右侧三行 meta(星期全名 / 月年 / 农历·日柱),
/// 下接左对齐 chips 行(十神/冲两枚 chip 均可点出释义,冲 2026-10-06 起接入)。
/// 视觉事实源:designs/review-fix-20261001/today-final.html(.date-row/.chips-row,
/// 393px 逻辑宽 px≈pt 1:1)。日期区与 chips 原先住在 hero 画内(glass-v2
/// 全信息卡),定稿拆出——画做减法(D1),信息上纸面。
struct DailyHeaderSection: View {
    let businessDate: Date
    let lunarDate: String
    let dayPillar: String
    let dayRelation: String
    let dayChong: String?
    let dayChongTargets: [String]

    /// 十神释义 sheet(D3,2026-09-29 拍板;chips 出图后随 chip 落位本区):
    /// chip 轻触打开。原 hero 上的 VO 命名 action 随 chips 出图退役——
    /// Button 本身即无障碍可达,明暗双通道同源不破。
    @State private var showShiShenNote = false

    /// 冲释义 sheet(2026-10-06 用户反馈「冲 chip 点击无反应」):与十神 chip
    /// 同款交互——两枚 chip 都应可点出解释。内容 = HeroChongNote 确定性静态表。
    /// 挂在 chips 节点而非外层 VStack:iOS 14.5 前同节点多 sheet 只留最后一个,
    /// 分节点挂是从坑里长出的习惯,17.2 下双保险。
    @State private var showChongNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dateRow
            chips
                .sheet(isPresented: $showChongNote) {
                    // chongChip 仅在 dayChong 非 nil 时渲染,sheet 内容同判;
                    // nil 时 sheet 为空(理论不可达,按钮不存在)。
                    if let chong = dayChong {
                        HeroChongNoteSheet(chong: chong)
                            .presentationDetents([.height(250), .large])
                            .presentationBackground(BaziTheme.paper)
                    }
                }
        }
        // D3:今日十神释义(确定性静态表 HeroShiShenNotes,LLM 不参与)。
        .sheet(isPresented: $showShiShenNote) {
            HeroShiShenNoteSheet(relation: dayRelation)
                .presentationDetents([.height(250), .large])
                .presentationBackground(BaziTheme.paper)
        }
    }

    // MARK: 日期行

    /// 大字日(serif medium 72)+ 右侧纵排三行 meta(星期全名 14 medium ink /
    /// 月年 12.5 inkMuted / 农历·日柱 12.5 inkMuted)。
    /// **2026-10-25 字号梯度修订**(外评 7 条,对比稿 docs/design-ref/
    /// today-type/今日页字号梯度.html):58→72——全页大字只留两处之一(另一处
    /// = 解读主句 24);右侧三行由顶对齐改**底部对齐数字基线**(alignmentGuide
    /// 把 HStack 的 .bottom 锚到数字 firstTextBaseline)——修外评「星期六顶部
    /// 高过数字、农历行离数字底线远,整块像飘着」;行距 3,与数字间距 16。
    /// serif 走 songDisplay:zh=宋体、EN=New York 系(图外题记同为衬线族)。
    private var dateRow: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Text(verbatim: "\(Calendar.current.component(.day, from: businessDate))")
                .font(BaziFont.songDisplay(size: 72, weight: .medium))
                .foregroundStyle(BaziTheme.ink)
                .alignmentGuide(.bottom) { $0[.firstTextBaseline] }
            VStack(alignment: .leading, spacing: 3) {
                Text(BaziDateFormatter.weekdayFull.string(from: businessDate))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
                Text(BaziDateFormatter.monthYear.string(from: businessDate))
                    .font(.system(size: 12.5))
                    .foregroundStyle(BaziTheme.inkMuted)
                Text(verbatim: lunarLine)
                    .font(.system(size: 12.5))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
                    // EN 长形态(Leap Twelfth…≈46 chars)12.5pt 超出 375pt 屏
                    // 可用宽,缩放兜底防尾部日柱被省略号吃掉(对齐 domainRow/
                    // signalRow 标签 0.85 先例;2026-10-25 字号梯度随 11→12.5 引入)
                    .minimumScaleFactor(0.85)
            }
        }
    }

    /// 日期区第三行:农历·干支。zh/Hant 维持原拼接;EN(2026-10-01 D4
    /// 基座零汉字)转写 "Eighth lunar month, day 11 · Wu-Shen day"——
    /// 月名序数词、日数字、日柱无调拼音连字(取代 09-24 的
    /// "5th Moon · 28th · Day of 辛丑" 半中半英形态)。解析失败回落原拼接
    /// (宁可露中文不猜,记日志)。
    private var lunarLine: String {
        if AppLanguage.current == .en,
           let en = Self.enLunarLine(lunarDate: lunarDate, dayPillar: dayPillar) {
            return en
        }
        return "\(L10n.DailyFortune.lunarPrefix) \(lunarDate) · \(dayPillar)\(L10n.DailyFortune.dayPillarSuffix)"
    }

    // MARK: chips 行

    /// chips 行(D3):左对齐、等高 26、hairline 描边 capsule、文案 11pt。
    /// 放不下时两 chip 上下堆叠左对齐——堆叠候选把 chip 拆成 VStack 的
    /// **独立子元素**(HStack 永不换行,整行包单子元素是布局 no-op),
    /// 横排候选挂 fixedSize 报足理想宽(2026-10-01 T1 教训延续)。
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                relationChip
                if let chong = dayChong {
                    chongChip(chong)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 7) {
                relationChip
                if let chong = dayChong {
                    chongChip(chong)
                }
            }
        }
    }

    /// 十神 chip:可点出今日十神释义(D6)。
    private var relationChip: some View {
        Button {
            showShiShenNote = true
        } label: {
            TodayChip(text: Self.displayRelation(dayRelation))
        }
        .buttonStyle(.plain)
    }

    /// 冲 chip(2026-10-06 起可点开释义,与十神 chip 对齐;EN = 生肖动物名 +
    /// 英文柱位,零汉字)。
    private func chongChip(_ chong: String) -> some View {
        Button {
            showChongNote = true
        } label: {
            TodayChip(text: L10n.DailyFortune.chongLabel(chong: chong, targets: dayChongTargets))
        }
        .buttonStyle(.plain)
    }

    /// chip 十神显示名(2026-09-27 U3c 改走 BaziTerms 统一查表:zh 原形 /
    /// zh-hant 异形(劫財/傷官/偏財/正財/七殺)/ en 意译)。符牌小图随定稿
    /// 退役(mockup chips 纯文字)。未知关系 BaziTerms.display 显式回落
    /// 原值 + 日志(非错误)。
    static func displayRelation(_ relation: String) -> String {
        BaziTerms.display(relation)
    }

    // MARK: - 农历 EN 转写(2026-09-24 i18n 拼接重设计;2026-10-01 D4 改版)

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

    /// 农历月名 EN 序数词(1-12;mockup "Eighth lunar month")。
    private static let enLunarMonthWords = [
        "First", "Second", "Third", "Fourth", "Fifth", "Sixth",
        "Seventh", "Eighth", "Ninth", "Tenth", "Eleventh", "Twelfth",
    ]

    /// 农历整串("五月廿八" / "闰六月初十" / "冬月廿八")+ 日柱 → EN 单行
    /// "Eighth lunar month, day 11 · Wu-Shen day"。nil = 形状不符或日柱不在
    /// 22 干支表(调用方回落原拼接)。日柱拼音化 = BaziTerms.romanizedHyphen
    /// (无调连字,基座标识性;释义卡内带调拼音是另一层,见 HeroShiShenPinyin)。
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
              (1...30).contains(day),
              let pillar = BaziTerms.romanizedHyphen(dayPillar)
        else {
            AppLogger.app.warning(
                "op=heroLunar.parseMiss lunarDate=\(lunarDate, privacy: .public) pillar=\(dayPillar, privacy: .public) -> rawFallback"
            )
            return nil
        }
        let leapPrefix = leap ? "Leap " : ""
        return "\(leapPrefix)\(Self.enLunarMonthWords[month - 1]) lunar month, day \(day) · \(pillar) day"
    }
}

// MARK: - 定稿 chip(2026-10-01 D3)

/// Today 定稿 chip:等高 26、radius 13(half-height capsule)、hairline 描边、
/// 11pt sans ink、**无底填充**(取代旧 ChipView 的 tint 填充版;符牌小图与
/// tint 底随 mockup 定稿一并退役)+ 尾缀 7pt chevron(2026-10-18 S6:两个
/// chip 都是可点释义入口,外观无暗示被外评点「看不出能点」;chevron
/// accessibilityHidden,语义朗读只读词本身)。固定字号 = hero 家族口径
/// (防 Dynamic Type 顶破单行胶囊;语义朗读不受字号影响)。
private struct TodayChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(BaziTheme.ink)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(BaziTheme.inkMuted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
    }
}

// MARK: - HeroYiJiColumns(宜/忌双列字层)

/// hero 底部宜/忌双列字层(**2026-10-01 Today 定稿 D2**:从「亮纸框」改为
/// 压在 hero 融纸渐隐区上的字层——画在下、字在上)。
/// 规格(mockup .yj @393px,px≈pt;2026-10-01 真机反馈微调,用户拍板):
/// 两列 grid 列距 26、左右内边距 22(宿主注入)、底部 28(mockup 18——真机
/// 读作贴底,整体上移);表头 = 统一小标 sans 13 medium tracking 1.5
/// (Do=墨青 / Don't=朱红;zh=宜/忌;**2026-10-25 字号梯度**,原 serif 16——
/// 外评「标签与词条同大,宜像第一个词条」);条目 serif zh 17 / EN 15
/// (原 15;EN 16 chars 预算按 serif 15pt 列宽核算,375pt 屏单列 ≈135pt 仍
/// 单行,EN 尺寸随走查拍板)、条目间 0.5pt hairline 分隔(表头下也一条)、
/// 每条上下 padding 9(2026-10-25 收紧,原 11)。
///
/// 数据源(v1 简化,同前):前端十神→关键词查表,每列 3 词;
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
    /// (serif 15pt 双列 ~135pt/列单行内 @375pt 屏,2026-10-01 定稿内边距 22 +
    /// 列距 26 后的列宽,09-19 宽度约束延续;09-28 S03 曾按 20/24≈138 核算)——
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
        fallback(for: AppLanguage.current)
    }

    /// 显式语言版 fallback(D4 EN 零 CJK 扫描测试用,不依赖设备语言)。
    static func fallback(for language: AppLanguage) -> (yi: [String], ji: [String]) {
        switch language {
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
        // 列距 26(定稿 .yj gap 0 26);375pt 屏单列 ≈(375−34−44−26)/2 ≈ 135pt,
        // EN 16 chars 预算内(词表零新增,预算由 DailyImageHeroCopyTests 守护)。
        HStack(alignment: .top, spacing: 26) {
            column(isYi: true, header: isEn ? "Do" : "宜", items: resolved.yi)
            column(isYi: false, header: isEn ? "Don't" : "忌", items: resolved.ji)
        }
    }

    /// 单列:表头 + 条目纵堆。
    /// **2026-10-25 字号梯度修订**(外评「宜/忌标签与词条一样大,只靠颜色
    /// 区分,宜读起来像第一个词条」):表头 serif 16 降为**统一小标**——
    /// sans 13 medium tracking 1.5(与解读 kicker/领域行/信号行标签同一种),
    /// 保留墨青/朱红语义色;条目 serif 15→17(zh 族;EN 15 不动,尺寸待
    /// 真机走查拍板),上下 padding 11→9(大字下收紧行距,修订 2026-10-18
    /// S3 的 11);表头下补一条 hairline(条目 0 也画顶线,标签与词条分家)。
    /// EN 表头的「宜 yí / 忌 jì」汉字小注 2026-10-01 D4 删(EN 基座零汉字)。
    /// serif 一族:zh=宋体(图内宋)、EN=New York(songDisplay 自动路由)。
    private func column(isYi: Bool, header: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(header)
                .font(.system(size: 13, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(isYi ? BaziTheme.jade : BaziTheme.cinnabar)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                    Text(item)
                        .font(BaziFont.songDisplay(size: isEn ? 15 : 17))
                        .foregroundStyle(BaziTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .padding(.vertical, 9)
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
        "偏财": "主流动之财。今日财缘在外,宜拓展试新、适度让利;留意孤注一掷与贪多。",
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
        "偏财": "主流動之財。今日財緣在外,宜拓展試新、適度讓利;留意孤注一擲與貪多。",
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

// MARK: - 十神带调拼音(D6 释义卡教学层,2026-10-01 定稿)

/// 十神拼音(带调、小写、空格分词):EN 释义卡头部的「piān cái」行。
/// 与基座层无调连字 `BaziTerms.romanizedHyphen`(Wu-Shen)分层是有意的——
/// 卡内教学性、基座标识性(定稿 D4/D6)。键集合 == `BaziTerms.tenGods`
/// 的 zh 键(11,含偏官=七杀同义),由 DailyImageHeroCopyTests 守护;
/// 键仍为后端简体十神(决策 7)。
enum HeroShiShenPinyin {
    static let table: [String: String] = [
        "比肩": "bǐ jiān",
        "劫财": "jié cái",
        "食神": "shí shén",
        "伤官": "shāng guān",
        "偏财": "piān cái",
        "正财": "zhèng cái",
        "七杀": "qī shā",
        "偏官": "piān guān",
        "正官": "zhèng guān",
        "偏印": "piān yìn",
        "正印": "zhèng yìn",
    ]
}

// MARK: - 十神释义小卡(D3;EN 三段头 2026-10-01 D6)

/// 十神 chip 点开的释义卡。zh/zh-Hant:术语标题(宋体 display 21)+ 一句
/// 静态释义(宋体 body)。EN(D6):三段头 = 汉字(宋体 17,EN 层收汉字的
/// 容器)+ 带调拼音(italic 11)+ EN 小标(caps 10 semibold)+ 释义正文
/// (sans 13.5)——这正是 EN 基座收汉字后的教学出口。detents 250 起步可拉大
/// (AX 大字号下正文可完整展开)。presentationBackground 纸色由调用侧注入。
struct HeroShiShenNoteSheet: View {
    let relation: String

    private var isEn: Bool { AppLanguage.current == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isEn {
                enHeader
            } else {
                Text(verbatim: DailyHeaderSection.displayRelation(relation))
                    .font(BaziFont.display(size: 21, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
            }
            Text(verbatim: HeroShiShenNotes.note(for: relation))
                .font(isEn ? .system(size: 13.5) : BaziFont.body(size: 15))
                .foregroundStyle(isEn ? BaziTheme.ink : BaziTheme.inkMuted)
                .lineSpacing(isEn ? 8 : 6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    /// EN 卡头(D6 三段):汉字(始终宋体——品牌层不走 EN 衬线路由)+
    /// 带调拼音(italic 11,ink-faint)+ EN 小标(右对齐 caps)。mockup
    /// .ns-head「偏财 / piān cái / INDIRECT WEALTH」同构。
    private var enHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: relation)
                .font(BaziFont.brush(size: 17))
                .foregroundStyle(BaziTheme.ink)
            if let pinyin = Self.enPinyin(for: relation) {
                Text(verbatim: pinyin)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            Spacer(minLength: 12)
            Text(verbatim: BaziTerms.display(relation, language: .en))
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    /// 拼音查表:miss 记日志只缺拼音行(释义正文照常,不静默吞)。
    private static func enPinyin(for relation: String) -> String? {
        if let hit = HeroShiShenPinyin.table[relation] {
            return hit
        }
        AppLogger.app.warning(
            "op=heroShiShenPinyin.lookupMiss relation=\(relation, privacy: .public)"
        )
        return nil
    }
}

// MARK: - 冲释义静态表(2026-10-06,冲 chip 可点)

/// 冲 chip 点开的六冲释义(**确定性模板,LLM 不参与**——「LLM 只润色不
/// 判断」边界同 HeroShiShenNotes:释义是判断性内容,必须查表)。
///
/// 与 HeroShiShenNotes 分表不同:冲释义对 12 地支是**同一句话**(只有被冲
/// 地支/生肖随流日变),故为参数化单模板而非 12 键词表;生肖查表走
/// ZodiacHelper(地支→生肖,单一事实源对齐 backend),miss 记日志后省略
/// 生肖段(不猜,对齐 chongLabel.zhiMiss 哲学)。三语静态文案不进
/// xcstrings(对齐 HeroYiJiColumns / HeroShiShenNotes 既定模式)。
enum HeroChongNote {
    /// 释义正文。chong = 被冲地支字(如 "未"),来自 backend day_chong。
    /// EN 正文用生肖名不用拼音(对齐 chip「Clashes with Goat」口径;拼音只在
    /// 卡头教学行,HeroShiShenNoteSheet 同款分层)。
    static func note(chong: String, language: AppLanguage = AppLanguage.current) -> String {
        let zodiac = ZodiacHelper.zodiacName(forZhi: chong)
        if zodiac == nil {
            // 三语同为"省略生肖段"(en 落通用句/zh 略生肖短语),日志语言中性。
            AppLogger.app.warning(
                "op=heroChongNote.zhiMiss zhi=\(chong, privacy: .public) -> omitZodiac"
            )
        }
        switch language {
        case .zh:
            let who = zodiac.map { "属\(ZodiacHelper.animalChar(forZodiac: $0))或" } ?? ""
            return "六冲主变动。今日冲\(chong),\(who)命局带\(chong)者易遇波折变动。"
                + "冲是动不是凶,顺势而行;大事能缓则缓。"
        case .zhHant:
            let who = zodiac.map { "屬\(ZodiacHelper.animalCharHant(forZodiac: $0))或" } ?? ""
            return "六沖主變動。今日沖\(chong),\(who)命局帶\(chong)者易遇波折變動。"
                + "沖是動不是凶,順勢而行;大事能緩則緩。"
        case .en:
            // 生肖查表 miss → 通用句(不猜动物;被冲地支原字仍在 chip 上
            // 由 chongLabel 透出,释义正文保持纯英文)。
            guard let zodiac else {
                return "A clash day: today's energy opposes an uncommon branch. "
                    + "Charts carrying that branch may see plans and travel shift. "
                    + "A clash is motion, not bad luck; flow with it."
            }
            return "A clash day: today's energy opposes the \(zodiac). "
                + "\(zodiac) natives — or charts carrying that branch — may see "
                + "plans and travel shift. "
                + "A clash is motion, not bad luck; flow with it."
        }
    }
}

// MARK: - 冲释义小卡(2026-10-06)

/// 冲 chip 点开的释义卡,与 HeroShiShenNoteSheet 同构:zh/zh-Hant 术语标题
/// (宋体 display 21)+ 一句静态释义(宋体 body);EN 三段头(D6 同款)=
/// 汉字「冲未」(宋体 17,EN 层收汉字的显式容器)+ 带调拼音(italic 11)+
/// EN 小标(caps "Day Clash")+ sans 13.5 正文。detents 250 起步可拉大,
/// presentationBackground 纸色由调用侧注入(两卡一致)。
struct HeroChongNoteSheet: View {
    let chong: String

    private var isEn: Bool { AppLanguage.current == .en }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isEn {
                enHeader
            } else {
                Text(verbatim: titleText)
                    .font(BaziFont.display(size: 21, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
            }
            Text(verbatim: HeroChongNote.note(chong: chong))
                .font(isEn ? .system(size: 13.5) : BaziFont.body(size: 15))
                .foregroundStyle(isEn ? BaziTheme.ink : BaziTheme.inkMuted)
                .lineSpacing(isEn ? 8 : 6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    /// 标题 = chip 同源短形(不带 targets 括号):「冲未」。走 chongLabel
    /// 同一函数,与 chip 显示字永远一致(xcstrings format 跟设备语言,
    /// 两处同源不漂移)。
    private var titleText: String {
        L10n.DailyFortune.chongLabel(chong: chong, targets: [])
    }

    /// EN 卡头(D6 三段同构):汉字「冲未」(始终宋体——品牌层不走 EN
    /// 衬线路由)+ 带调拼音 "chōng wèi"(冲不在 22 干支表,拼音固定;
    /// 地支查 romanized,miss 只缺拼音行)+ 右对齐 caps 小标。
    private var enHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "冲\(chong)")
                .font(BaziFont.brush(size: 17))
                .foregroundStyle(BaziTheme.ink)
            if let pinyin = Self.enPinyin(for: chong) {
                Text(verbatim: pinyin)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            Spacer(minLength: 12)
            Text(verbatim: "Day Clash")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    /// 拼音查表:miss 记日志只缺拼音行(释义正文照常,不静默吞——
    /// HeroShiShenNoteSheet.enPinyin 同款手法)。romanized 表是词首大写
    /// ("未"→"Wèi"),教学行与 HeroShiShenPinyin 同款全小写("piān cái"),
    /// 首字母转小写后拼装。internal:小写化钉样例归 DailyImageHeroCopyTests
    /// (对齐 HeroYiJiColumns 为测试改 internal 的先例)。
    static func enPinyin(for chong: String) -> String? {
        guard let branchPinyin = BaziTerms.romanized(chong) else {
            AppLogger.app.warning(
                "op=heroChongNoteSheet.pinyinMiss zhi=\(chong, privacy: .public)"
            )
            return nil
        }
        let lower = branchPinyin.prefix(1).lowercased() + branchPinyin.dropFirst()
        return "chōng \(lower)"
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

// ChipView / PlaqueIcon(旧 tint 填充 chip + 古篆符牌小图)随 2026-10-01
// Today 定稿退役:定稿 chips = 纯文字 hairline 描边版(TodayChip,见上);
// 全仓无其他使用方(Assets 内 PlaqueSha/PlaqueChong imageset 保留不动)。
