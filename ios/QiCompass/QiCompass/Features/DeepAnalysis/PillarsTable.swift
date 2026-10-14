import SwiftUI

/// 柱位渲染模型(S05 时辰未知):known = 照常渲染;unknown = 留白 + dashed 圆位。
/// 抽纯函数便于分支测试(测试 target 无 ViewInspector 依赖,视图分支经此模型断言)。
enum PillarSlotModel: Equatable {
    case known(PillarDTO)
    case unknown

    static func resolve(_ pillar: PillarDTO?) -> PillarSlotModel {
        pillar.map(PillarSlotModel.known) ?? .unknown
    }
}

/// 四柱表(2026-10-14 表格化重构,仿盘面细目 HTML 目标稿)。
///
/// 左侧行标签列(主星/天干/地支/藏干/纳音/星运/空亡)+ 四柱等宽列,SwiftUI Grid
/// 逐行对齐——旧版每柱独立 VStack,藏干行数不同导致纳音/长生/旬空四列高度错位、
/// 「长生:」「旬空:」前缀还会硬折行、藏干 Capsule chip 三个即被裁切;行标签承载
/// 语义后格内只放裸值,藏干改「干 + 十神」小行(zip(hideGan, shishenZhi),
/// 后端 pillars.py 平行列表保证对齐)。
///
/// 日主强调 = **整列 cinnabarSoft 淡底 + 左右朱红 hairline**(首行上圆角/末行下
/// 圆角),干支字色保持五行色——旧版日柱干支被 cinnabar 覆盖,与「四柱横向比
/// 五行色」的语义冲突(2026-10-14 用户拍板移除)。
///
/// S05 时辰未知:柱缺失 → 该列留白(表头保留 + 天干行 dashed 圆位,其余行空
/// cell,行结构仍在 → 对齐不破)。时柱列点击进补时辰(D7 触点 1,S10 已接线;
/// 静默态下留白列同样保留可点击——入口在,提示不在)。留白是水墨表达**不是错误
/// 提示**:无红字无感叹号,不渲染任何占位干支(「?」柱或默认柱都属「猜」,红线禁止)。
struct PillarsTable: View {
    let pillars: PillarsDTO
    /// S10 接线:时柱未知留白列点击 → 打开补时辰 sheet(D7 触点 1)。
    /// nil = 无宿主(防御/测试渲染),点击仅记日志不 crash。
    var onAddHour: (() -> Void)? = nil

    /// S5 术语释义:十神(主星/藏干)点击 → BaziTermNoteSheet(共享词表)。
    @State private var termNote: TermNoteRequest?

    /// 一列的渲染输入(标题 = 年/月/日/时;isDay = 日主列;isHourSlot = 未知时
    /// 该列承接 D7 补时辰触点)。pillars.<pos> 为 nil 时经 PillarSlotModel 走留白。
    struct Column {
        let title: String
        let isDay: Bool
        let isHourSlot: Bool
        let pillar: PillarDTO?
    }

    var columns: [Column] {
        [
            Column(title: L10n.DeepChart.pillarYear, isDay: false, isHourSlot: false, pillar: pillars.year),
            Column(title: L10n.DeepChart.pillarMonth, isDay: false, isHourSlot: false, pillar: pillars.month),
            Column(title: L10n.DeepChart.pillarDay, isDay: true, isHourSlot: false, pillar: pillars.day),
            Column(title: L10n.DeepChart.pillarHour, isDay: false, isHourSlot: true, pillar: pillars.hour),
        ]
    }

    /// 日列淡朱底的圆角形态:首行上圆角、末行下圆角(Radius.lg),中间行直角
    /// (verticalSpacing 0 → 各 cell 背景无缝拼成通栏)。
    struct DayBand {
        let topCorner: Bool
        let bottomCorner: Bool

        var shape: UnevenRoundedRectangle {
            UnevenRoundedRectangle(
                topLeadingRadius: topCorner ? BaziTheme.Radius.lg : 0,
                bottomLeadingRadius: bottomCorner ? BaziTheme.Radius.lg : 0,
                bottomTrailingRadius: bottomCorner ? BaziTheme.Radius.lg : 0,
                topTrailingRadius: topCorner ? BaziTheme.Radius.lg : 0
            )
        }
    }

    /// 日柱已知才有列底;日柱歧义(S05)→ 无高亮(与旧版一致)。
    private var dayKnown: Bool { pillars.day != nil }
    private var middleBand: DayBand? { dayKnown ? DayBand(topCorner: false, bottomCorner: false) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(horizontalSpacing: 6, verticalSpacing: 0) {
                headerRow

                // 主星 = 天干十神(shishenGan;日柱字面值「日主」cinnabar semibold)
                pillarRow(label: L10n.DeepChart.rowStar, band: middleBand, unknownCircle: false) { col, pillar in
                    shiShenText(pillar.shishenGan, isDay: col.isDay, size: 12)
                        .padding(.vertical, 1)
                }

                // 天干(未知列的 dashed 圆位落在本行——干支之位)
                pillarRow(label: L10n.DeepChart.rowStem, band: middleBand, unknownCircle: true) { _, pillar in
                    Text(pillar.gan)
                        // BaziFont.kaiti 的 custom 路径不接 weight,字重经 Text.fontWeight 生效
                        .font(BaziFont.ganzhi(size: 28))
                        .fontWeight(.bold)
                        .foregroundStyle(ganColor(pillar))
                        .padding(.vertical, 2)
                }

                // 地支
                pillarRow(label: L10n.DeepChart.rowBranch, band: middleBand, unknownCircle: false) { _, pillar in
                    Text(pillar.zhi)
                        .font(BaziFont.ganzhi(size: 28))
                        .fontWeight(.bold)
                        .foregroundStyle(zhiColor(pillar))
                        .padding(.vertical, 2)
                }

                // 藏干 = zip(hideGan, shishenZhi) 逐行「干 + 十神」(替代旧 Capsule chip,修裁切)
                pillarRow(label: L10n.DeepChart.rowHidden, band: middleBand, unknownCircle: false) { _, pillar in
                    VStack(spacing: 4) {
                        ForEach(Array(zip(pillar.hideGan, pillar.shishenZhi)), id: \.0) { gan, shiShen in
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text(gan)
                                    .font(BaziFont.ganzhi(size: 14))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(hideGanColor(gan))
                                shiShenText(shiShen, isDay: false, size: 11)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                }

                // 纳音(topBorder:行顶 hairline 分隔;日列段朱红)
                pillarRow(label: L10n.DeepChart.rowNayin, band: middleBand, unknownCircle: false, topBorder: true) { _, pillar in
                    smallValue(BaziTerms.display(pillar.nayin))
                }

                // 星运(十二长生,行标签承载语义,值不再带「长生:」前缀)
                pillarRow(label: L10n.DeepChart.rowStage, band: middleBand, unknownCircle: false) { _, pillar in
                    smallValue(BaziTerms.display(pillar.dishi))
                }

                // 空亡(末行,列底下圆角)
                pillarRow(label: L10n.DeepChart.rowVoid,
                          band: dayKnown ? DayBand(topCorner: false, bottomCorner: true) : nil,
                          unknownCircle: false) { _, pillar in
                    smallValue(pillar.xunkong, isLast: true)
                }
            }

            // 表脚注
            Text(L10n.DeepChart.pillarsCaption)
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .padding(.top, 10)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // S5 术语释义(交互先例 = 今日页 HeroShiShenNoteSheet,2026-09-29 D3)
        .sheet(item: $termNote) { req in
            BaziTermNoteSheet(term: req.term)
                .presentationDetents([.height(250), .large])
                .presentationBackground(BaziTheme.paper)
        }
    }

    // MARK: - 表头行(年柱/月柱/日柱/时柱;未知柱也保留表头——「时柱」标题
    // 不依赖柱数据。日柱头 cinnabar semibold + 列底上圆角)

    private var headerRow: some View {
        GridRow {
            Color.clear
                .frame(width: 30, height: 1)
                .frame(maxHeight: .infinity)
            ForEach(columns.indices, id: \.self) { idx in
                let col = columns[idx]
                headerCell(title: col.title, isDay: col.isDay)
                    .frame(maxWidth: .infinity)
                    .modifier(DayBandBackground(band: col.isDay && dayKnown
                        ? DayBand(topCorner: true, bottomCorner: false)
                        : nil))
            }
        }
    }

    // MARK: - 数据行构造(标签 cell + 四柱 cell;未知柱走留白分支)

    /// 通用数据行。cell 闭包只在柱已知时调用;unknownCircle = 未知柱在该行画
    /// dashed 圆位(仅天干行)。
    private func pillarRow<Cell: View>(
        label: String,
        band: DayBand?,
        unknownCircle: Bool,
        topBorder: Bool = false,
        @ViewBuilder cell: @escaping (Column, PillarDTO) -> Cell
    ) -> some View {
        GridRow {
            // 行标签(垂直居中:Grid 行高由最高 cell 决定,其余 cell 内容居中对齐)
            Text(label)
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .frame(width: 30, alignment: .leading)
                .frame(maxHeight: .infinity)

            ForEach(columns.indices, id: \.self) { idx in
                let col = columns[idx]
                Group {
                    switch PillarSlotModel.resolve(col.pillar) {
                    case .known(let pillar):
                        cell(col, pillar)
                            .frame(maxWidth: .infinity)
                    case .unknown:
                        EmptyPlaceholder(showsCircle: unknownCircle,
                                         isHourSlot: col.isHourSlot,
                                         onTap: addHourTapped)
                    }
                }
                .modifier(DayBandBackground(band: col.isDay ? band : nil))
                .modifier(TopHairline(enabled: topBorder,
                                       accent: col.isDay && band != nil))
            }
        }
    }

    // MARK: - cell 样式

    /// 表头 cell(年柱/月柱/日柱/时柱;日柱 cinnabar semibold)。
    private func headerCell(title: String, isDay: Bool) -> some View {
        Text(L10n.DeepChart.pillarTitle(title))
            .font(BaziFont.caption(size: 12))
            .foregroundStyle(isDay ? BaziTheme.cinnabar : BaziTheme.inkMuted)
            .fontWeight(isDay ? .semibold : .regular)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    /// 纳音/星运/空亡 共用小字 cell(12pt inkMuted)。
    private func smallValue(_ text: String, isLast: Bool = false) -> some View {
        Text(text)
            .font(BaziFont.caption(size: 12))
            .foregroundStyle(BaziTheme.inkMuted)
            .padding(.top, 8)
            .padding(.bottom, isLast ? 12 : 8)
    }

    // MARK: - 十神 cell(S5 术语释义)

    /// 十神 caption:词表收录 → 可点出释义;未收录 → 纯文本(宁缺毋滥)。
    /// 日柱主星「日主」cinnabar semibold(日主强调);藏干十神一律 inkMuted 11pt。
    @ViewBuilder
    private func shiShenText(_ term: String, isDay: Bool, size: CGFloat) -> some View {
        if BaziTermNotes.note(for: term) != nil {
            Button {
                openTermNote(term)
            } label: {
                styledShiShen(term, isDay: isDay, size: size)
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "查看释义"))
        } else {
            styledShiShen(term, isDay: isDay, size: size)
        }
    }

    private func styledShiShen(_ term: String, isDay: Bool, size: CGFloat) -> some View {
        Text(BaziTerms.display(term))
            .font(BaziFont.caption(size: size))
            .foregroundStyle(isDay ? BaziTheme.cinnabar : BaziTheme.inkMuted)
            .fontWeight(isDay ? .semibold : .regular)
    }

    /// 词表有的术语才弹释义(未收录不挂入口,宁缺毋滥)。
    private func openTermNote(_ term: String) {
        guard BaziTermNotes.note(for: term) != nil else { return }
        HapticEngine.light()
        termNote = TermNoteRequest(term: term)
    }

    // MARK: - 未知柱触点(S10)

    private func addHourTapped() {
        // S10 接线:点击进补时辰流程(D7 触点 1,只补时辰不重填全表)。
        // 无宿主回调 = 防御/测试渲染路径,记日志不 crash
        guard let onAddHour else {
            AppLogger.app.warning("pillarsTable.hourSlotTapped no_handler(S10 回调未注入)")
            return
        }
        HapticEngine.light()
        onAddHour()
    }

    // MARK: - 取色(仅已知柱;日柱不再覆盖为 cinnabar,保持五行色)

    private func ganColor(_ pillar: PillarDTO) -> Color {
        ElementColors.from(pillar.ganElement)?.color ?? BaziTheme.ink
    }

    private func zhiColor(_ pillar: PillarDTO) -> Color {
        ElementColors.from(pillar.zhiElement)?.color ?? BaziTheme.ink
    }

    private func hideGanColor(_ gan: String) -> Color {
        guard let key = ElementColors.ofGan(gan) else { return BaziTheme.inkMuted }
        return ElementColors.from(key)?.color ?? BaziTheme.inkMuted
    }
}

// MARK: - cell 修饰器

/// 日列淡朱底:cinnabarSoft fill + 左右 0.5pt cinnabar hairline(clip 到圆角
/// 形状防角部出方头)。verticalSpacing 0 时各 cell 背景无缝拼通栏。
private struct DayBandBackground: ViewModifier {
    let band: PillarsTable.DayBand?

    func body(content: Content) -> some View {
        content.background {
            if let band {
                band.shape
                    .fill(BaziTheme.cinnabarSoft)
                    .overlay {
                        HStack(spacing: 0) {
                            Rectangle().fill(BaziTheme.cinnabar.opacity(0.3)).frame(width: 0.5)
                            Spacer()
                            Rectangle().fill(BaziTheme.cinnabar.opacity(0.3)).frame(width: 0.5)
                        }
                    }
                    .clipShape(band.shape)
            }
        }
    }
}

/// 纳音行顶 hairline(日列段用朱红,其余 hairline;0.5pt,随 cell 宽分段,
/// 与 HTML 目标稿 grid 列间隙分段一致)。
private struct TopHairline: ViewModifier {
    let enabled: Bool
    let accent: Bool

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if enabled {
                Rectangle()
                    .fill(accent ? BaziTheme.cinnabar.opacity(0.3) : BaziTheme.hairline)
                    .frame(height: 0.5)
            }
        }
    }
}

// MARK: - 未知柱留白 cell(S05)

/// 留白 cell:showsCircle 时画 dashed 圆环(= 干支之位,与 NumeralBadge locked
/// 同语义,仅天干行),其余行纯空。时柱位(isHourSlot)整 cell 挂补时辰触点
/// (入口在,提示不在);VoiceOver 只在圆位 cell 读一次「时辰未知」(无可见
/// 文案——四柱少一柱在视觉上不言自明,D7),其余留白 cell 对读屏隐藏。
private struct EmptyPlaceholder: View {
    let showsCircle: Bool
    let isHourSlot: Bool
    let onTap: () -> Void

    var body: some View {
        Group {
            if isHourSlot {
                inner
                    // 触点盖满整个 cell(整列可点,对齐旧版 unknownPlaceholder 口径)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onTap)
            } else {
                inner
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .modifier(A11y(showsCircle: showsCircle))
    }

    @ViewBuilder
    private var inner: some View {
        if showsCircle {
            circle
        } else {
            Color.clear
        }
    }

    /// dashed 圆环占位(DESIGN.md dashed = 锁定/临时态语义)。
    private var circle: some View {
        Circle()
            .stroke(
                BaziTheme.hairlineDashed,
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .frame(width: 30, height: 30)
    }

    /// 圆位 cell 读「时辰未知」,其余留白 cell 读屏隐藏(避免逐格重复)。
    private struct A11y: ViewModifier {
        let showsCircle: Bool

        func body(content: Content) -> some View {
            if showsCircle {
                content
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.Common.hourUnknown)
            } else {
                content.accessibilityHidden(true)
            }
        }
    }
}
