import SwiftUI

/// 排盘口径说明页(T3,2026-11-22 竞品差评对照)。
///
/// 三节静态说明:真太阳时校正 / 立春 vs 农历新年换年 / 生肖年份五行 vs 日主——
/// 用户拿别家 App 或生肖网站对照本盘出现差异时,「不是算错,是口径不同」的
/// 解释页。正文三语在 xcstrings(chartBasis.*)。样式:hairline 分节,不用
/// 卡片、不用朱红(DESIGN.md 说明类信息纪律)。
///
/// 个性化行(T6):农历新年口径生肖与立春口径不一致的一句对照,由调用方拼好
/// 传入,挂在第二节正文后——本文件不读 DTO / 不拼盘面词(与 ZodiacRevealView
/// 同分工纪律,文案拼装归调用方)。
struct ChartBasisSheet: View {
    /// T6 个性化行(nil = 不显示)。格式见 `zodiac.lnyMismatch`(三语,由
    /// 调用方经 BaziTerms / yearSignLabel 拼好)。
    var lnyMismatchLine: String? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // ScrollView:三节长文(EN 正文最长约 570 字符)在 SE 级小屏默认字号下
        // 即超出 sheet 视口,不滚动会裁掉尾部与关闭按钮(BaziFont 定字号不随
        // Dynamic Type 缩放,同 AddHourSheet/PartnerPickerSheet 均滚动)。
        ScrollView {
            content
        }
        // sheet 底 = cardSurface(DESIGN.md §Color 角色行,同 AddHourSheet)
        .background(BaziTheme.cardSurface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xl) {
            Text(L10n.ChartBasis.title)
                .font(BaziFont.display(size: 20))
                .tracking(2)
                .foregroundStyle(BaziTheme.ink)

            section(
                title: L10n.ChartBasis.solarTitle,
                bodyText: L10n.ChartBasis.solarBody)

            hairline

            section(
                title: L10n.ChartBasis.yearTitle,
                bodyText: L10n.ChartBasis.yearBody,
                personalLine: lnyMismatchLine)

            hairline

            section(
                title: L10n.ChartBasis.dayMasterTitle,
                bodyText: L10n.ChartBasis.dayMasterBody)

            Button {
                dismiss()
            } label: {
                Text(L10n.ChartBasis.close)
                    .font(BaziFont.button())
                    .foregroundStyle(BaziTheme.onInkDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BaziTheme.Spacing.md)
                    .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(BaziTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            AppLogger.app.info("ChartBasisSheet.shown lny=\(lnyMismatchLine != nil, privacy: .public)")
        }
    }

    // MARK: - 子组件

    /// 分节 hairline(卡片让位 hairline 的页级纪律)。
    private var hairline: some View {
        Rectangle()
            .fill(BaziTheme.hairline)
            .frame(height: 0.5)
    }

    private func section(title: String, bodyText: String,
                         personalLine: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            Text(title)
                .font(BaziFont.body())
                .fontWeight(.semibold)
                .foregroundStyle(BaziTheme.ink)
            Text(bodyText)
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.inkMuted)
            if let personalLine {
                // 个性化行:本人的真实两口径对照(ink 提一档,与静态正文区分)
                Text(personalLine)
                    .font(BaziFont.caption(size: 13))
                    .foregroundStyle(BaziTheme.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
