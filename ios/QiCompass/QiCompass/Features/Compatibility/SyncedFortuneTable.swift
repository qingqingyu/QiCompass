import SwiftUI

/// 3 年流年同步表(D8 + DESIGN.md §Color/§Layout,水墨孤本 hairline 语言)。
///
/// 去卡片化(卡片让位 hairline,同屏 DualPillarsTable/AssessmentCardGrid 同族):
/// kicker 小标 + hairline 行分隔 + 底部 hairline 收边,无容器底色、无圆角描边框,
/// 列头规格与 DualPillarsTable 柱位行一致。取数/数据绑定不变(SyncedFortuneDTO 原样)。
///
/// 颜色 + 符号双编码(token 化,不自造颜色;符号不只靠颜色,BP #5 2026-10-01):
/// - 同步走强 → ● jade 文字(吉兆墨青)
/// - 同步承压 → ○ pressureWarning 文字
/// - 运势分化 → ◐ inkMuted
/// - 难以定性 → — inkMuted(从格诚实降级)
struct SyncedFortuneTable: View {
    let synced: [SyncedFortuneDTO]
    /// 对方称呼(2026-09-27 A/B 代号 → 名字;B 列头「{name}的流年」)。
    /// A 列头恒「你的流年/Your year」固定文案(命主本人称呼无需注入)。
    let nameB: String

    /// 年份列固定宽(4 位数字对齐),A/B 均分余宽,同步列尾对齐;
    /// 表头与数据行共用同一列框架保证纵向对齐。
    private let yearColumnWidth: CGFloat = 44
    private let syncColumnWidth: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Compatibility.syncedTitle)
                .font(BaziFont.caption(size: 10))
                .tracking(1.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            VStack(spacing: 0) {
                header

                ForEach(Array(synced.enumerated()), id: \.element.year) { _, sf in
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                    row(sf)
                }
            }
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                // 段落收边 hairline(与 DualPillarsTable 底部收边同一语言)
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(height: 0.5)
            }
        }
        .fadeIn()
    }

    /// 列头:年份 / 你的流年(A 固定文案) / {B 名}的流年 / 同步(caption2 弱墨,
    /// 同 DualPillarsTable 柱位行;2026-09-27 A/B 代号 → 名字)。
    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.Compatibility.syncedYear)
                .frame(width: yearColumnWidth, alignment: .leading)
            Text(L10n.Compatibility.syncedYourYear)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.Compatibility.syncedPersonYear(nameB))
                .lineLimit(1)
                // 兜底名(「对方 · 1990-03-15」)过长时缩字号而非截断
                // (与 DualPillarsTable 行标同款处理)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.Compatibility.syncedSync)
                .frame(width: syncColumnWidth, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(BaziTheme.inkMuted)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// 单行:年份(SF tabular 数字)+ A + B + 同步状态(符号 + 文字双编码,
    /// 不只靠颜色——BP #5,2026-10-01;色觉无碍与 VoiceOver 都可读)。
    private func row(_ sf: SyncedFortuneDTO) -> some View {
        let mark = SyncMark.syncMark(for: sf.sync)

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(sf.year))
                .font(BaziFont.numeric(size: 13, weight: .medium))
                .foregroundStyle(BaziTheme.ink)
                .frame(width: yearColumnWidth, alignment: .leading)

            Text(sf.personA)
                .font(.caption)
                .foregroundStyle(BaziTheme.ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sf.personB)
                .font(.caption)
                .foregroundStyle(BaziTheme.ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let mark {
                    Text(mark.glyph)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(mark.color)
                }
                Text(sf.sync)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(mark?.color ?? BaziTheme.inkMuted)
            }
            .frame(width: syncColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    // MARK: 同步四态符号(iOS 侧映射,后端枚举不动)

    /// 四态:走强 ● / 承压 ○ / 分化 ◐ / 难以定性 —(从格诚实降级态,
    /// 设计稿未画但产品决策必须有)。未知标签 → nil 无符号纯文字
    /// (yuyan 后端结构化 synced 字段时,分化可再拆 ◐/◑ 方向——方向判据
    /// a_good/b_good 后端现成,客户端 DTO 没有,不在本层猜)。
    enum SyncMark {
        case strong
        case pressure
        case diverged
        case unclear

        var glyph: String {
            switch self {
            case .strong: return "●"
            case .pressure: return "○"
            case .diverged: return "◐"
            case .unclear: return "—"
            }
        }

        var color: Color {
            switch self {
            case .strong: return BaziTheme.jade
            case .pressure: return BaziTheme.pressureWarning
            case .diverged, .unclear: return BaziTheme.inkMuted
            }
        }

        static func syncMark(for label: String) -> SyncMark? {
            switch label {
            case "同步走强": return .strong
            case "同步承压": return .pressure
            case "运势分化": return .diverged
            case "难以定性": return .unclear
            default: return nil
            }
        }
    }
}
