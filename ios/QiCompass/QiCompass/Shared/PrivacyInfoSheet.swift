import SwiftUI

/// 隐私说明 sheet(T11,2026-11-23 竞品差评对照第二批)。
///
/// 四条隐私口径(`profile.about.privacy1-4`,与「我的」页关于区展开区共用
/// 同一组 key——**不要复制两份文案**);标题 `profile.about.privacyTitle`。
/// 样式:hairline 分节,不用卡片、不用朱红(DESIGN.md 说明类信息纪律,
/// 对齐 ChartBasisSheet)。消费方:BirthInfoConfirmSheet 的「隐私说明 ›」
/// (T12)与老用户补授权 sheet(T12)。
struct PrivacyInfoSheet: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.xl) {
                Text(L10n.Profile.aboutPrivacyTitle)
                    .font(BaziFont.display(size: 20))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)

                para(L10n.Profile.aboutPrivacy1)

                hairline

                para(L10n.Profile.aboutPrivacy2)

                hairline

                para(L10n.Profile.aboutPrivacy3)

                hairline

                para(L10n.Profile.aboutPrivacy4)
            }
            .padding(BaziTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BaziTheme.cardSurface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            AppLogger.app.info("PrivacyInfoSheet.shown")
        }
    }

    // MARK: - 子组件

    /// 分节 hairline(卡片让位 hairline 的页级纪律,同 ChartBasisSheet)。
    private var hairline: some View {
        Rectangle()
            .fill(BaziTheme.hairline)
            .frame(height: 0.5)
    }

    /// 段落正文(caption 13 inkMuted,同 ChartBasisSheet section 正文档)。
    private func para(_ text: String) -> some View {
        Text(text)
            .font(BaziFont.caption(size: 13))
            .foregroundStyle(BaziTheme.inkMuted)
    }
}
