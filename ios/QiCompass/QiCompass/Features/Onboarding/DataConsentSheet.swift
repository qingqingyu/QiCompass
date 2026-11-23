import SwiftUI

/// 老用户 AI 数据授权补授权 sheet(T12,2026-11-23;D4=B 必勾复选框)。
///
/// 触发:RootTabView 启动时 `hasSeenOnboarding == true` 且
/// `DataConsent.isCurrent == false`(从未同意,或口径版本落后)。
/// **不可下滑关闭**(interactiveDismissDisabled):App 核心功能离不开
/// 服务器排盘,不提供「拒绝但继续用」的出口——这是任务书拍板的行为,
/// 不同意的用户只能退出 App。同意 → `DataConsent.recordConsent()` → 关闭。
/// D4=B 复选框的水墨形态(iOS 无内置 .checkbox):hairline 方框,选中填
/// 焦墨 + 白勾;命中区含标签整行(tap 整行切换)。
struct InkCheckboxToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    Rectangle()
                        .strokeBorder(BaziTheme.hairline, lineWidth: 1)
                        .frame(width: 18, height: 18)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(BaziTheme.paper)
                    }
                }
                .background(
                    configuration.isOn
                        ? BaziTheme.inkDeep
                        : Color.clear,
                    in: Rectangle())
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // a11y:复选框选中语义用 .isSelected trait(VoiceOver 播报「已选择」)。
        // 不用 accessibilityValue("1"/"0")——读屏会念「一/零」非选中态;
        // 也不设 hint:label 即授权全文,自描述,hint 会让长句被读两遍。
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

struct DataConsentSheet: View {
    let onAgree: () -> Void

    @State private var consentChecked = false
    @State private var showPrivacySheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
                Text(L10n.DataConsentCopy.sheetTitle)
                    .font(BaziFont.display(size: 20))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)

                Text(L10n.DataConsentCopy.body)
                    .font(BaziFont.caption(size: 13))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                DataConsentBlock(isOn: $consentChecked) {
                    showPrivacySheet = true
                }

                Button {
                    guard consentChecked else { return }
                    HapticEngine.medium()
                    onAgree()
                } label: {
                    Text(L10n.DataConsentCopy.agree)
                        .font(BaziFont.button())
                        .foregroundStyle(BaziTheme.onInkDeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BaziTheme.Spacing.md)
                        .background(
                            consentChecked ? BaziTheme.inkDeep : BaziTheme.inkDeep.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 5))
                }
                .disabled(!consentChecked)
                .padding(.top, BaziTheme.Spacing.md)
            }
            .padding(BaziTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(BaziTheme.cardSurface)
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .sheet(isPresented: $showPrivacySheet) {
            PrivacyInfoSheet()
        }
        .onAppear {
            AppLogger.app.info("DataConsentSheet.shown version=\(DataConsent.currentVersion, privacy: .public)")
        }
    }
}

/// T12(D4=B)授权块:必勾复选框 +「隐私说明 ›」链接。
/// 确认排盘 sheet(新用户)与老用户补授权 sheet 共用——合规关键 UI 单一
/// 实现,披露文案的字体/颜色/间距改动只落一处,防两处漂移呈现不一致。
/// 隐私 sheet 的呈现由宿主持有(各 sheet 自己挂 .sheet)。
struct DataConsentBlock: View {
    @Binding var isOn: Bool
    let onOpenPrivacy: () -> Void

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.xs) {
            Toggle(isOn: $isOn) {
                Text(L10n.BirthForm.dataConsentText)
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .toggleStyle(InkCheckboxToggleStyle())
            Button(action: onOpenPrivacy) {
                Text(L10n.BirthForm.privacyLink)
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .underline()
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
