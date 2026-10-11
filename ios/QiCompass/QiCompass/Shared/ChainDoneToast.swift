import SwiftUI

/// 命书整链完成 in-app toast(方案二前台渠道,2026-10-11):
/// `ChainCompletionNotifier` 发出完成广播 → 顶部浮现水墨 toast
/// (「成」印 stamp + 标题/章数),~4.5s 自动收起;点按跳深度解析 tab。
///
/// 视觉:cardSurface 底 + hairline 描边 + radius 5(DESIGN.md:卡片让位
/// hairline、无渐变、朱红仅印章级小元素)。后台完成走系统通知,与本视图无关。
struct ChainDoneToast: View {
    @State private var isShown = false
    @State private var chapterCount = 0
    @State private var isOwned = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if isShown {
                toastCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ChainCompletionNotifier.completionNotificationName
        )) { note in
            // 缺键不该发生(唯一 post 方恒带两键),不静默:留 error 级痕迹,
            // 缺哪个字段就保哪个字段的上一条值(标题仍准确,仅正文计数停旧)
            if let count = note.userInfo?["chapterCount"] as? Int {
                chapterCount = count
            } else {
                AppLogger.app.error("chainDoneToast missing chapterCount in userInfo keys=\(String(describing: note.userInfo?.keys), privacy: .public)")
            }
            if let owned = note.userInfo?["isOwned"] as? Bool {
                isOwned = owned
            } else {
                AppLogger.app.error("chainDoneToast missing isOwned in userInfo keys=\(String(describing: note.userInfo?.keys), privacy: .public)")
            }
            // 连续完成(重开卷后再次成书)不叠队列:撤旧计时重起
            dismissTask?.cancel()
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                isShown = true
            }
            dismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.4)) {
                    isShown = false
                }
            }
        }
    }

    private var toastCard: some View {
        Button {
            HapticEngine.light()
            dismissTask?.cancel()
            withAnimation(.easeOut(duration: 0.25)) { isShown = false }
            NotificationCenter.default.post(
                name: .switchTab,
                object: nil,
                userInfo: ["tab": RootTabView.Tab.deepAnalysis.switchKey]
            )
        } label: {
            HStack(spacing: 10) {
                SealStamp(character: "成", size: 26, rotation: -3, stampDelay: 0.12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.DeepChain.notifyTitle(isOwned: isOwned))
                        .font(BaziFont.display(size: 13))
                        .tracking(1.5)
                        .foregroundStyle(BaziTheme.ink)
                    Text(L10n.DeepChain.notifyBody(chapterCount: chapterCount, isOwned: isOwned))
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("›")
                    .font(BaziFont.caption(size: 13))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(BaziTheme.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
            )
            // 浮层与内容的最低限度分离(极轻投影,不做深阴影)
            .shadow(color: BaziTheme.ink.opacity(0.10), radius: 8, y: 2)
            .padding(.horizontal, 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.DeepChain.notifyTitle(isOwned: isOwned))
    }
}
