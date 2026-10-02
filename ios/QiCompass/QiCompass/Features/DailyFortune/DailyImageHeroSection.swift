import SwiftUI

/// glass-v2 玻璃画卡(2026-08-31 用户拍板;2026-09-01 底图改单张固定资产;
/// **2026-10-01 Today 定稿改版**,视觉事实源 `~/.gstack/projects/qingqingyu-
/// QiCompass/designs/review-fix-20261001/today-final.html`,px≈pt 1:1 @393):
/// 头部日期区与 chips **出图上纸面**(见 `DailyHeaderSection`,D3);画内只留
/// 右上干支竖排落款(艺术层,D1)+ 底部宜/忌双列字层(压在融纸渐隐区上,D2)。
///
/// **2026-10-02 留白修复**(docs/today-hero-留白修复-plan.md,外评「画卡上部
/// 太空」):卡比例 916:1000→916:780 **底对齐裁顶部空天**(实测山顶在全图
/// 38%,顶部 ~135pt 空天撑不住画面,像图没加载完);落款 16→22pt 靠山;
/// 底部融纸提前(0.66→0.46 起步)保宜忌对比度。图层配方与顺序不变,参数随
/// 新卡高(@393pt 屏 ≈306,原 ≈392)重校。
///
/// 玻璃配方(全程序化图层,效果不依赖生图端;底图与滤镜逐像素不动——定稿
/// 验收项,baseLayer 滤镜四参数禁改;2026-10-02 起裁切对齐方式属布局参数):
/// 1 基底滤镜:降饱和/提亮/压对比/1.3pt 柔焦(SwiftUI 原生 modifier)
/// 2 径向 mask:实心 58% → 94% 融纸,只留最外一线洇进宣纸
/// 3 纸色纱罩:呼吸 7s(动效三式 breathe 同源),整幅压灰
/// 4 宣纸压边 rim:四周纸色收边,保证整幅图都在玻璃下
/// 4b 底部融纸渐隐(D1 加高):纯纸渐变 ≈ 卡高 1/3,给宜忌字层让位
/// 4c 四边融纸(2026-09-28 外评「顶部矩形切边」)
/// 5 磨砂颗粒:PaperGrain(确定性噪点,ink@0.05)
/// 6 云雾:两团宣纸色软雾异速反向漂(26s/34s),山间岚气
/// (7 飞鸟层 2026-09-29 D1 拍板删除:09-25 打磨后外评仍读成乱码,视觉减法)
/// 定稿起 hero 上**无任何印章**(D1 拍板);入场 ink-in 由宿主按块错峰。
/// reduce-motion:循环动效全停。
///
/// 图内中文 = 宋体 Songti SC(「图内宋/文中楷」分层,2026-08-31 拍板,DESIGN.md 补录);
/// 落款题款 = 始终楷体(BaziFont.brush,品牌层不走 EN 路由);
/// EN = New York 衬线表头 + 衬线条目(2026-09-24 收敛,字体一族衬线)。
struct DailyImageHeroSection: View {
    let dayPillar: String
    let dayRelation: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    /// 卡高:916×780(2026-10-02 裁顶部空天:原 916×1000 底对齐裁顶 220 asset
    /// 单位 ≈86pt @393)。宽 = 屏宽−34(hero 区 17pt 边距),高随宽自适配
    /// (393pt 屏 ≈306,原 ≈392)。实测资产山顶在全图 38%/山脚 81%(baseLayer
    /// 旧注释「25%/63%」是裁窗设计意图,与生成成品不符,2026-10-02 像素剖面
    /// 核实);裁后山顶落新卡高 ≈20.5%、山脚 ≈75.6%,底部水面与月光倒影不动
    /// (scale 两版相同 359/916,文字锚定卡底,文字背后像素与裁前逐点一致)。
    private static let imageAspectRatio: CGFloat = 916.0 / 780.0

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

    var body: some View {
        ZStack {
            baseLayer
            veilLayer
            rimLayer
            bottomFadeLayer
            edgeFadeLayer
            mistLayer
            grainLayer

            // 内容浮层(落款 + 宜忌字层)
            contentOverlay
                .accessibilityHidden(true)
        }
        .aspectRatio(Self.imageAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .onAppear(perform: startCycles)
        // 无障碍:合并为单元素,落款 + 宜忌词一并进 label(不被 .ignore 吞掉)。
        // 冲与十神释义入口由出图后的独立 chips(DailyHeaderSection)承担。
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: heroAccessibilityLabel))
    }

    /// 无障碍合并 label:干支落款 + 页首短标 + 宜/忌词。
    private var heroAccessibilityLabel: String {
        let yiJi = HeroYiJiColumns.mapping[dayRelation] ?? HeroYiJiColumns.fallback
        return "\(dayPillar) \(L10n.DailyFortune.shortLabel), "
            + "\(L10n.DailyFortune.yiLabel) \(yiJi.yi.joined(separator: "、")), "
            + "\(L10n.DailyFortune.jiLabel) \(yiJi.ji.joined(separator: "、"))"
    }

    // MARK: - 玻璃图层

    private var baseLayer: some View {
        // 固定底图(2026-09-01 用户拍板「单张固定图」):画布定稿浅绛山水烘进
        // Asset Catalog,不再调生图 API——零成本/零延迟/零 IMAGE_API_KEY 依赖。
        // 2026-09-01 晚改竖版:原 3:2 横幅(1536×1024)在 ~0.92:1 卡内 scaledToFill
        // 要放大到 603pt 宽裁掉 39% 画面;重生成竖版 916×1717(B「极简空灵」,
        // gpt-image-2)后按卡比例裁 916×1000,山顶落卡高 25%/山脚 63%,整幅完整呈现。
        // prompt 与裁窗溯源:designs/daily-glass-20260831/hero-provenance.md。
        // 2026-10-02 实测修正:生成资产实际山顶在 38%/山脚 81%(上文「25%/63%」
        // 为裁窗设计意图,与成品不符,像素剖面核实),顶部 0-25% 为纯空天——
        // 由此起卡比例改 916:780 并底对齐裁顶(见 imageAspectRatio 注释)。
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
                // 底对齐裁切(2026-10-02):scaledToFill 默认居中裁,卡变矮会把
                // 底部水面/月光倒影一起裁掉;底对齐只裁顶部空天(方案 §1.2)。
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .clipped()
                .mask { bloomMask }
                .scaleEffect(soak ? 1.05 : 1.01)
        }
    }

    /// 径向融纸 mask:实心到 58%,94% 全透明(CSS ellipse 152%/130% 的圆形近似;
    /// 2026-10-02 随新卡高重校:圆心 y 0.42→0.50 跟山体视觉重心,半径按
    /// ≈306pt 卡高的对角覆盖 400→340,偏差由 rim 层兜底)。
    private var bloomMask: some View {
        Rectangle().fill(
            RadialGradient(
                stops: [
                    .init(color: .black, location: 0.58),
                    .init(color: .clear, location: 0.94),
                ],
                center: UnitPoint(x: 0.5, y: 0.50),
                startRadius: 0,
                endRadius: 340
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

    /// 4 宣纸压边:四周以纸色收边,只留最外一线融纸(2026-10-02 随新卡高
    /// 重校:圆心 y 0.45→0.50、半径 430→370,与 bloomMask 同步)。
    private var rimLayer: some View {
        Rectangle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: .clear, location: 0.58),
                        .init(color: BaziTheme.paper, location: 0.97),
                    ],
                    center: UnitPoint(x: 0.5, y: 0.50),
                    startRadius: 0,
                    endRadius: 370
                )
            )
            .allowsHitTesting(false)
    }

    /// 4b 底部融纸渐隐(2026-09-25 打磨 → 09-28/10-01 两轮提前 → **2026-10-02
    /// 三停点提前**):卡高变矮(392→306)后宜忌字层占卡高比例变大(~37%→
    /// ~47%),旧 0.66 单起步下「记账/务本」压在山脚残墨上(外评对比度不足)。
    /// 新曲线 0.46 起 → 0.66 处 85% 纸 → 0.90 全纸;按新卡高真实像素数值验证:
    /// 最坏 1% 像素下宜忌第 2/3 行对 ink 文字对比 ≥12:1(验收线 4.5:1,亮暗
    /// 双底图均过;像素剖面脚本结论,截图复核归验收清单)。比例式而非写死 pt,
    /// 随屏宽/卡高自适配。
    private var bottomFadeLayer: some View {
        LinearGradient(
            stops: [
                .init(color: BaziTheme.paper.opacity(0), location: 0.46),
                .init(color: BaziTheme.paper.opacity(0.85), location: 0.66),
                .init(color: BaziTheme.paper, location: 0.90),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }

    /// 4c 四边融纸(2026-09-28 外评「hero 顶部/左右矩形硬边」;2026-10-02
    /// 数值随新 mask 更新):bloomMask 圆心 y=0.50、endRadius 340 下,卡顶
    /// 距圆心 ≈153pt、左右 ≈180pt,都落在实心阈 0.58×340≈197pt 内——顶边与
    /// 左右边完全不透明,rim 层同因,只有底边有 bottomFadeLayer,山水在这
    /// 三条边被直线切断。本层以纸色压顶(0→0.14)与左右(0→0.07 / 0.93→1)
    /// 极窄渐变融边;与 bottomFadeLayer 同性质(叠在图上的纸色遮罩,不是
    /// 背景渐变),paper 为 dyn 双值,暗色自动夜宣纸。
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

    /// 6 云雾:两团宣纸色软雾,异速反向横漂(26s / 34s 半程)。2026-10-02 随
    /// 新卡高(≈306)重校 y 偏移 76/178→40/120:雾心分别落山脚(≈63%)与
    /// 水面字层区(≈89%),不再飘出卡顶;下团纸雾垫在宜忌字层背后,顺带提对比。
    private var mistLayer: some View {
        ZStack {
            mistBlob(width: 300, height: 190, y: 40, x: mistA ? 52 : -52, opacity: 0.5)
            mistBlob(width: 255, height: 165, y: 120, x: mistB ? -46 : 46, opacity: 0.38)
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

    // MARK: - 内容浮层(落款 + 宜忌字层)

    /// 字层结构(D1/D2 定稿):右上竖排落款 + 底部宜忌双列,画在下、字在上。
    /// 落款距顶 = 卡高 10%(2026-10-02:相对值随卡高自适配,GeometryReader 取
    /// 卡高,不写死 pt——落款下端落在山顶右侧 ≈29% 处,与山呼应)。
    private var contentOverlay: some View {
        ZStack {
            GeometryReader { geo in
                pillarSignature
                    .padding(.top, geo.size.height * 0.10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            HeroYiJiColumns(dayRelation: dayRelation)
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    /// 右上干支竖排落款(D1):「戊申」,Kaiti 22pt、ink 82%、竖排字距 4、
    /// 距顶 = 卡高 10%(见 contentOverlay)、距右 22pt(与宜忌左右内边距对齐)。
    /// 2026-10-02 适度放大 16→22(≈1.4×):顶部空天裁掉后落款独自撑上部
    /// 留白,16pt 过小像图没加载完;仍显著小于大字日 58pt——落款是题款,
    /// 不喧宾夺主,也不放大 2-3×(外评 B 采纳但收幅度)。无印章、无朱红
    /// (D1:hero 上无任何印章)。品牌层汉字始终楷体(BaziFont.brush,不走
    /// EN 衬线路由——VText 的 display 会随 EN 落衬线,故自绘两字竖排);
    /// 落款属画上题款艺术层,是 D4「EN 基座零汉字」的显式豁免位;固定字号
    /// 不随 Dynamic Type 缩放(装饰层,XXL 档下仍远离宜忌字层,无重叠)。
    private var pillarSignature: some View {
        VStack(spacing: 4) {
            ForEach(Array(dayPillar.enumerated()), id: \.offset) { _, char in
                Text(verbatim: String(char))
                    .font(BaziFont.brush(size: 22))
                    .foregroundStyle(BaziTheme.ink.opacity(0.82))
            }
        }
        .padding(.trailing, 22)
    }
}

// MARK: - 头部区(2026-10-01 Today 定稿 D3:信息一行看全,出图上纸面)

/// Today 头部区:大字日 + 右侧三行 meta(星期全名 / 月年 / 农历·日柱),
/// 下接左对齐 chips 行(十神 chip 可点出释义 + 冲 chip)。
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dateRow
            chips
        }
        // D3:今日十神释义(确定性静态表 HeroShiShenNotes,LLM 不参与)。
        .sheet(isPresented: $showShiShenNote) {
            HeroShiShenNoteSheet(relation: dayRelation)
                .presentationDetents([.height(250), .large])
                .presentationBackground(BaziTheme.paper)
        }
    }

    // MARK: 日期行

    /// 大字日(serif medium 58,行高 0.95)+ 右侧纵排三行 meta
    /// (Thursday 14 medium ink / October 2026 12 inkMuted / 农历·日柱 11 inkMuted)。
    /// serif 走 songDisplay:zh=宋体、EN=New York 系(图外题记同为衬线族)。
    private var dateRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(Calendar.current.component(.day, from: businessDate))")
                .font(BaziFont.songDisplay(size: 58, weight: .medium))
                .foregroundStyle(BaziTheme.ink)
            VStack(alignment: .leading, spacing: 0) {
                Text(BaziDateFormatter.weekdayFull.string(from: businessDate))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
                    .padding(.top, 9)
                Text(BaziDateFormatter.monthYear.string(from: businessDate))
                    .font(.system(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.top, 3)
                Text(verbatim: lunarLine)
                    .font(.system(size: 11))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
                    .padding(.top, 6)
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

    /// 冲 chip(纯展示;EN = 生肖动物名 + 英文柱位,零汉字)。
    private func chongChip(_ chong: String) -> some View {
        TodayChip(text: L10n.DailyFortune.chongLabel(chong: chong, targets: dayChongTargets))
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
/// tint 底随 mockup 定稿一并退役)。固定字号 = hero 家族口径(防 Dynamic
/// Type 顶破单行胶囊;语义朗读不受字号影响)。
private struct TodayChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(BaziTheme.ink)
            .lineLimit(1)
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
/// 读作贴底,整体上移);表头 serif 16 medium(Do=墨青 / Don't=朱红;zh=宜/忌;
/// mockup 15);条目 serif 15(mockup 14;EN 16 chars 预算本就按 serif 15pt
/// 列宽核算,375pt 屏单列 ≈135pt 仍单行)、行距 1.5、条目间 0.5pt hairline
/// 分隔、每条上下 padding 9。
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

    /// 单列:表头(Do=墨青 / Don't=朱红;zh/zh-Hant 表头仍「宜/忌」,现状
    /// 逻辑)+ 条目纵堆(hairline 分隔、上下 padding 9)。
    /// EN 表头的「宜 yí / 忌 jì」汉字小注 2026-10-01 D4 删(EN 基座零汉字)。
    /// serif 一族:zh=宋体(图内宋)、EN=New York(songDisplay 自动路由)。
    private func column(isYi: Bool, header: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header)
                .font(BaziFont.songDisplay(size: 16, weight: .medium))
                .foregroundStyle(isYi ? BaziTheme.jade : BaziTheme.cinnabar)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    if idx > 0 {
                        Rectangle()
                            .fill(BaziTheme.hairline)
                            .frame(height: 0.5)
                    }
                    Text(item)
                        .font(BaziFont.songDisplay(size: 15))
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

/// 十神 chip 点开的释义卡。zh/zh-Hant:术语标题(楷体 display 21)+ 一句
/// 静态释义(楷体 body)。EN(D6):三段头 = 汉字(Kaiti 17,EN 层收汉字的
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

    /// EN 卡头(D6 三段):汉字(始终楷体——品牌层不走 EN 衬线路由)+
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
