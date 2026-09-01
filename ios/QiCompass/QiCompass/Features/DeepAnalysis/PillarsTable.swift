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

/// 四柱表(DESIGN.md §Typography + §Color + 方案 §一 PillarsTable)。
///
/// 每柱一列:天干上 / 地支下,天干十神 + 地支十神标旁,
/// 纳音小字,十二长生,旬空,藏干 chip(五行色)。
/// 日柱高亮:cinnabarSoft 底 + cinnabar 文字(替代五行色,DESIGN.md §04 mockup)。
///
/// S05 时辰未知:柱数据缺失(时柱未知 / S02 节气边界或日柱歧义级联)→ 该列
/// 留白 + dashed hairline 圆位(DESIGN.md dashed = 锁定/临时态语义)。留白是
/// 水墨表达**不是错误提示**:无红字无感叹号,不渲染任何占位干支(「?」柱或
/// 默认柱都属「猜」,红线禁止)。时柱列点击进补时辰(D7 触点 1,S10 已接线;
/// 静默态下留白列同样保留可点击——入口在,提示不在)。
struct PillarsTable: View {
    let pillars: PillarsDTO
    /// S10 接线:时柱未知留白列点击 → 打开补时辰 sheet(D7 触点 1)。
    /// nil = 无宿主(防御/测试渲染),点击仅记日志不 crash。
    var onAddHour: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("四柱")
                .zcoolCardTitle()
            HStack(alignment: .top, spacing: 10) {
                PillarColumn(title: "年", pillar: pillars.year)
                PillarColumn(title: "月", pillar: pillars.month)
                PillarColumn(title: "日", isDay: true, pillar: pillars.day)
                // isHourSlot:未知时该列是 D7 补时辰触点 1(S10 已接线)
                PillarColumn(title: "时", isHourSlot: true, pillar: pillars.hour, onAddHour: onAddHour)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BaziTheme.Spacing.cmd)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }
}

private struct PillarColumn: View {
    let title: String
    var isDay: Bool = false
    /// 时柱位列标记:未知时该列承接 D7 触点 1(点击进补时辰)
    var isHourSlot: Bool = false
    /// S05:nil = 柱未知(时辰未知 / S02 柱歧义)→ 留白表达
    let pillar: PillarDTO?
    /// S10:触点回调(宿主注入;仅 isHourSlot 且柱未知时消费)
    var onAddHour: (() -> Void)? = nil

    var body: some View {
        switch PillarSlotModel.resolve(pillar) {
        case .known(let pillar):
            knownContent(pillar)
        case .unknown:
            unknownPlaceholder
        }
    }

    // MARK: - 已知柱(渲染与 S05 之前一致)

    private func knownContent(_ pillar: PillarDTO) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            // 天干
            Text(pillar.gan)
                .font(BaziFont.ganzhi(size: 22))
                .foregroundStyle(ganColor(pillar))
            Text(pillar.shishenGan)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 地支
            Text(pillar.zhi)
                .font(BaziFont.ganzhi(size: 22))
                .foregroundStyle(zhiColor(pillar))
            // 地支十神(可能多个)
            VStack(spacing: 2) {
                ForEach(pillar.shishenZhi, id: \.self) { s in
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            // 纳音(次要信息,inkMuted)
            Text(pillar.nayin)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 十二长生
            Text("长生:\(pillar.dishi)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 旬空
            Text("旬空:\(pillar.xunkong)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 藏干 chip(Capsule 留给 chip)
            HStack(spacing: 4) {
                ForEach(pillar.hideGan, id: \.self) { gan in
                    Text(gan)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(hideGanColor(gan))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(hideGanColor(gan).opacity(0.15), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(BaziTheme.Spacing.sm)
        .background(
            isDay ? BaziTheme.cinnabarSoft : BaziTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(isDay ? BaziTheme.cinnabar.opacity(0.4) : BaziTheme.hairline,
                        lineWidth: 0.5)
        )
    }

    // MARK: - 未知柱留白(S05)

    /// 留白 + dashed hairline 圆位:标题 + 一个虚线圆环占干支之位,其余全部空。
    /// 十神/纳音/长生/旬空/藏干均依赖柱数据,不猜不编一行。
    /// VoiceOver 只读「时辰未知」(无可见文案——四柱少一柱在视觉上不言自明,D7)。
    private var unknownPlaceholder: some View {
        let base = VStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            // 圆位:dashed 圆环 = 干支之位空着(与 NumeralBadge locked 同语义)
            Circle()
                .stroke(
                    BaziTheme.hairlineDashed,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
                .frame(width: 30, height: 30)
        }
        .frame(maxWidth: .infinity)
        .padding(BaziTheme.Spacing.sm)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(
            // dashed hairline = 锁定/临时态语义(DESIGN.md §Layout)
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        return Group {
            if isHourSlot {
                base
                    .contentShape(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                    .onTapGesture {
                        // S10 接线:点击进补时辰流程(D7 触点 1,只补时辰不重填全表)。
                        // 无宿主回调 = 防御/测试渲染路径,记日志不 crash
                        guard let onAddHour else {
                            AppLogger.app.warning("pillarsTable.hourSlotTapped no_handler(S10 回调未注入)")
                            return
                        }
                        HapticEngine.light()
                        onAddHour()
                    }
            } else {
                base
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.Common.hourUnknown)
    }

    // MARK: - 取色(仅已知柱)

    /// 日柱天干用 cinnabar(日主强调);其他柱走五行色。
    private func ganColor(_ pillar: PillarDTO) -> Color {
        if isDay { return BaziTheme.cinnabar }
        guard let key = ElementColors.ofGan(pillar.gan) else { return BaziTheme.ink }
        return ElementColors.from(key)?.color ?? BaziTheme.ink
    }

    /// 日柱地支用 cinnabar(日主强调);其他柱走五行色。
    private func zhiColor(_ pillar: PillarDTO) -> Color {
        if isDay { return BaziTheme.cinnabar }
        return ElementColors.from(pillar.zhiElement)?.color ?? BaziTheme.ink
    }

    private func hideGanColor(_ gan: String) -> Color {
        guard let key = ElementColors.ofGan(gan) else { return BaziTheme.inkMuted }
        return ElementColors.from(key)?.color ?? BaziTheme.inkMuted
    }
}
