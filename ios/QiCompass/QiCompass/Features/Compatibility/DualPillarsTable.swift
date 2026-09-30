import SwiftUI

/// 双盘对比柱数据源(D6)。
///
/// 抽出此结构后,DualPillarsTable 不依赖具体数据源:
/// A 盘从本地 ChartSnapshot 解;模式 A 下 B 盘同;模式 B 下 B 从 response.personBChart 取。
///
/// S05 时辰未知:任一侧柱数据缺失(时柱未知 / S02 柱歧义)→ 对应字段为 nil,
/// 渲染层走留白 + dashed 圆位(与 PillarsTable 同语义;不渲染占位干支)。
struct DualPillarSource: Identifiable, Equatable {
    let position: String       // 年/月/日/时柱位标签(L10n.Compatibility.dual*Pillar 本地化)
    let ganA: String?
    let zhiA: String?
    let nayinA: String?
    let ganElementA: String?   // 英文 key(给 ElementColors 取色)
    let zhiElementA: String?
    let ganB: String?
    let zhiB: String?
    let nayinB: String?
    let ganElementB: String?
    let zhiElementB: String?

    var id: String { position }
}

/// A 上 B 下紧凑双盘表(D6 + DESIGN.md §Color + §Ganzhi + §Layout,水墨孤本 H3 合印中轴版)。
///
/// iPhone 屏宽 ~375pt,8 列(2 人 × 4 柱)挤;改用「每柱一列,A 行上 B 行下」紧凑表。
/// 中轴(S4,2026-09-29):hairline — 「合」印 + 日主方向短语 — hairline。短语方向
/// 客户端派生(`DayMasterRelationPhrase` 纯五行生克查表,非历法计算),类别与后端
/// `dayMasterRelation` 一致才显示派生串,不等 → 只显后端标签(不静默不猜)。
/// 日柱列(S4):上下两格 hairline 描边强调(无实底色,卡片让位 hairline),
/// 柱头「日」ink 实色、其余 inkMuted。
/// 整段去卡片底,以底部 hairline 收边(卡片让位 hairline)。取数/数据绑定不变
/// (DualPillarSource 原样)。不复用 PillarsTable(信息密度过高)。
///
/// S10 触点接线注记:本表的时柱留白单元格**不挂**补时辰触点——任一方时辰未知的
/// 对在 `CompatibilityViewModel.computePair` 已被整对拦(S07),进不了 detail,
/// 该留白态对用户不可达;他人盘的补时辰触点落在换人 sheet 标记行(S11
/// `PartnerPickerSheet.onAddHour`)与结果区拦截卡(`PairSummaryCard.onAddHour`),
/// 那是无时辰他人盘真正可见可点的地方。
struct DualPillarsTable: View {
    let pillars: [DualPillarSource]  // 共 4 条(年/月/日/时)
    /// 两侧称呼(2026-09-27 A/B 代号 → 名字:A 恒「你/you」,B 为对方称呼)。
    /// 替代此前硬编码 "A"/"B" 行标——读者不再需要对照「谁是 A」。
    let labelA: String
    let labelB: String
    /// 后端日主关系标签(S4 中轴;qualitativeAssessment.dayMasterRelation 原值)。
    let dayMasterRelation: String

    /// S5 术语释义:中轴日主关系(相生/相克/同气)点击 → BaziTermNoteSheet。
    @State private var termNote: TermNoteRequest?

    /// 日柱列判定(position 标签单一事实源)。
    private var isDayPillar: (DualPillarSource) -> Bool {
        { $0.position == L10n.Compatibility.dualDayPillar }
    }

    /// 中轴短语:派生命中 → 方向串;派生失败/不一致 → 后端标签回退。
    private var axisText: String {
        guard let day = pillars.first(where: isDayPillar) else {
            // 日柱缺失(歧义盘理论进不了 detail):后端标签回退,不猜
            return dayMasterRelation
        }
        let phrase = DayMasterRelationPhrase.make(
            ganA: day.ganA, elementA: day.ganElementA,
            ganB: day.ganB, elementB: day.ganElementB,
            backendRelation: dayMasterRelation
        )
        return phrase.text ?? dayMasterRelation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Compatibility.dualTitle)
                .font(BaziFont.caption(size: 10))
                .tracking(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            VStack(spacing: 10) {
                // 柱位行:年 / 月 / 日 / 时(S4:日 ink 实色,其余 inkMuted)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(pillars) { p in
                        Text(p.position)
                            .font(.caption2)
                            .foregroundStyle(
                                isDayPillar(p) ? BaziTheme.ink : BaziTheme.inkMuted
                            )
                            .frame(maxWidth: .infinity)
                    }
                }

                // A 盘行(命主;日柱格 hairline 描边强调)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(pillars) { p in
                        pillarCell(
                            gan: p.ganA, zhi: p.zhiA, nayin: p.nayinA,
                            ganElement: p.ganElementA, zhiElement: p.zhiElementA,
                            label: labelA
                        )
                        .frame(maxWidth: .infinity)
                        .dayColumnEmphasis(isDay: isDayPillar(p))
                    }
                }

                // 中轴(S4):hairline 分隔 + 「合」印 + 日主方向短语
                // (原型 .vs:朱文空心、-3° 微侧;短语 = 客户端派生方向 + 后端类别标签)
                // S5:关系词表收录(相生/相克/同气)→ 整块可点出一句释义
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                    axisView
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                }

                // B 盘行(对方;日柱格 hairline 描边强调)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(pillars) { p in
                        pillarCell(
                            gan: p.ganB, zhi: p.zhiB, nayin: p.nayinB,
                            ganElement: p.ganElementB, zhiElement: p.zhiElementB,
                            label: labelB
                        )
                        .frame(maxWidth: .infinity)
                        .dayColumnEmphasis(isDay: isDayPillar(p))
                    }
                }
            }
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                // 段落收边 hairline(原型 .pillars border-bottom)
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(height: 0.5)
            }
        }
        .fadeIn()
        // S5 术语释义(交互先例 = 今日页 HeroShiShenNoteSheet,2026-09-29 D3)
        .sheet(item: $termNote) { req in
            BaziTermNoteSheet(term: req.term)
                .presentationDetents([.height(250), .large])
                .presentationBackground(BaziTheme.paper)
        }
    }

    /// 中轴块:「合」印 + 方向短语;关系值在词表内 → 可点出释义。
    @ViewBuilder
    private var axisView: some View {
        let content = VStack(spacing: 3) {
            SealStamp(character: "合", size: 22, rotation: -3, stampDelay: nil)
            Text(axisText)
                .font(BaziFont.caption(size: 10))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
        }
        if BaziTermNotes.note(for: dayMasterRelation) != nil {
            Button {
                HapticEngine.light()
                termNote = TermNoteRequest(term: dayMasterRelation)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint(String(localized: "查看释义"))
        } else {
            content
        }
    }

    /// 单人柱单元格:标签 + 干支(Kaiti SC)+ 纳音。
    /// S05:干支缺失(时柱未知 / S02 柱歧义)→ dashed 圆位留白,纳音行空,
    /// 不渲染占位干支(不猜);VoiceOver 读「时辰未知」。
    private func pillarCell(
        gan: String?, zhi: String?, nayin: String?,
        ganElement: String?, zhiElement: String?,
        label: String
    ) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(1)
                // 兜底名(「对方 · 1990-03-15」)过长时缩字号而非截断成「对方…」
                .minimumScaleFactor(0.7)
            if let gan, let zhi {
                HStack(spacing: 2) {
                    Text(gan)
                        .foregroundStyle(BaziTheme.elementColor(ganElement ?? ""))
                    Text(zhi)
                        .foregroundStyle(BaziTheme.elementColor(zhiElement ?? ""))
                }
                .font(BaziFont.ganzhi(size: 16))
            } else {
                // 圆位:dashed 圆环 = 干支之位空着(与 PillarsTable 留白同语义)
                Circle()
                    .stroke(
                        BaziTheme.hairlineDashed,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: 18, height: 18)
            }
            if let nayin {
                Text(nayin)
                    .font(.system(size: 9))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            (gan == nil || zhi == nil)
                ? "\(label) \(L10n.Common.hourUnknown)"
                : "\(label) \(gan ?? "")\(zhi ?? "")"
        )
    }
}

// MARK: - 日柱列强调(S4)

private extension View {
    /// 日柱格 hairline 描边(RoundedRectangle cornerRadius 4,无实底色——
    /// 卡片让位 hairline;非日柱格原样)。
    func dayColumnEmphasis(isDay: Bool) -> some View {
        self.overlay {
            if isDay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(BaziTheme.hairline, lineWidth: 0.8)
                    .padding(.horizontal, -2)
                    .padding(.vertical, -3)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 从 BaziResponse 提炼 4 柱

extension DualPillarSource {
    /// 从 A、B 两份 BaziResponse 提炼 4 柱对比源。
    /// S05:柱缺失(时辰未知 / S02 柱歧义)→ 对应侧字段 nil(渲染层留白);
    /// 老盘四柱齐全 → 输出与 S05 之前逐字段一致。
    static func from(a: BaziResponse, b: BaziResponse) -> [DualPillarSource] {
        let pa = a.pillars
        let pb = b.pillars
        return [
            DualPillarSource(
                position: L10n.Compatibility.dualYearPillar,
                ganA: pa.year?.gan, zhiA: pa.year?.zhi, nayinA: pa.year?.nayin,
                ganElementA: pa.year?.ganElement, zhiElementA: pa.year?.zhiElement,
                ganB: pb.year?.gan, zhiB: pb.year?.zhi, nayinB: pb.year?.nayin,
                ganElementB: pb.year?.ganElement, zhiElementB: pb.year?.zhiElement
            ),
            DualPillarSource(
                position: L10n.Compatibility.dualMonthPillar,
                ganA: pa.month?.gan, zhiA: pa.month?.zhi, nayinA: pa.month?.nayin,
                ganElementA: pa.month?.ganElement, zhiElementA: pa.month?.zhiElement,
                ganB: pb.month?.gan, zhiB: pb.month?.zhi, nayinB: pb.month?.nayin,
                ganElementB: pb.month?.ganElement, zhiElementB: pb.month?.zhiElement
            ),
            DualPillarSource(
                position: L10n.Compatibility.dualDayPillar,
                ganA: pa.day?.gan, zhiA: pa.day?.zhi, nayinA: pa.day?.nayin,
                ganElementA: pa.day?.ganElement, zhiElementA: pa.day?.zhiElement,
                ganB: pb.day?.gan, zhiB: pb.day?.zhi, nayinB: pb.day?.nayin,
                ganElementB: pb.day?.ganElement, zhiElementB: pb.day?.zhiElement
            ),
            DualPillarSource(
                position: L10n.Compatibility.dualHourPillar,
                ganA: pa.hour?.gan, zhiA: pa.hour?.zhi, nayinA: pa.hour?.nayin,
                ganElementA: pa.hour?.ganElement, zhiElementA: pa.hour?.zhiElement,
                ganB: pb.hour?.gan, zhiB: pb.hour?.zhi, nayinB: pb.hour?.nayin,
                ganElementB: pb.hour?.ganElement, zhiElementB: pb.hour?.zhiElement
            ),
        ]
    }
}
