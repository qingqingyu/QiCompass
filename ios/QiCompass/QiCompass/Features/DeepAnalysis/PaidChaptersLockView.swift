import SwiftUI

/// 付费章节锁标组件(M3c,M4 参数化 title/ctaTitle 复用到合盘)。
///
/// 显示在 InterpretationSection 的 `.okFree` case 下(未购买时):
/// 显示章节标题列表 + lock.fill 图标 + 整块淡蒙层 + "解锁"CTA。
///
/// 视觉决策(用户拍板 + DESIGN.md 反 AI slop):
/// - ❌ 不要金色锁(违反反 AI slop)
/// - ❌ 不要磨砂玻璃遮罩(违反反 AI slop)
/// - ✅ lock.fill + inkMuted + opacity 0.5
/// - ✅ 朱砂红 CTA(PrimaryCTAButton)
struct PaidChaptersLockView: View {
    let previewChapters: [String]  // 深度解析 5 章 / 合盘 4 章
    let title: String  // "深度命书·付费章节" / "合盘解读·付费章节"
    let ctaTitle: String  // "解锁深度命书" / "解锁合盘解读"
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
                .padding(.bottom, 2)

            ForEach(previewChapters, id: \.self) { chapter in
                HStack(spacing: BaziTheme.Spacing.sm) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(BaziTheme.inkMuted)
                    Text(chapter)
                        .font(.body)
                        .foregroundStyle(BaziTheme.ink)
                    Spacer()
                }
            }
        }
        .opacity(0.5)  // 整体淡蒙层(DESIGN.md 反对全黑遮罩,用 opacity)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BaziTheme.Spacing.md)
        .background(
            BaziTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )

        // 解锁 CTA(不受 opacity 影响,朱砂红强引导)
        PrimaryCTAButton(
            title: ctaTitle,
            loadingTitle: "处理中…",
            isLoading: false,
            action: onUnlock
        )
    }
}
