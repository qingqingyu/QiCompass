import SwiftUI

// MARK: - 冷启动品牌转场(水墨孤本开机页)
//
// 视觉事实源:DESIGN.md §Motion + docs/design-ref/shuimo/variant-c-shuimo.html。
// Launch Screen 本身是静态的(Info.plist UIColorName = 冷宣纸),本视图承担
// 启动后的品牌瞬间:墨圆 ink-in → 竖题「玄机问道」→ 玄印 stamp → 整体淡出。
//
// 时序(正常):enso ink-in 1.2s 起 0.1s;竖题 0.7s 起;玄印 0.9s 落;
// 1.4s 开始 0.25s 淡出,1.65s onFinished 收场。全程 allowsHitTesting(false),
// 不阻塞任何交互。reduce-motion:静态呈现 0.35s 直接收场。
struct SplashTransitionView: View {
    var onFinished: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fadeOut = false
    @State private var titleShown = false
    @State private var footerShown = false

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()
            PaperGrain()

            VStack(spacing: 0) {
                Spacer(minLength: 60)

                // 主体:墨圆 + 竖题(参考 variant-c-shuimo:圆左题右)
                HStack(alignment: .center, spacing: 34) {
                    EnsoView(size: 196, breathing: true)
                        .overlay {
                            SealStamp(character: "玄", size: 36, rotation: 3, stampDelay: 0.9)
                        }

                    VStack(spacing: 18) {
                        VText(phrase: "玄机问道", size: 25, tracking: 11)
                        VText(phrase: "问道于心 · 观命如水", size: 11, tracking: 6,
                              color: BaziTheme.inkMuted)
                            .padding(.leading, 34) // 右列再让一档,呼应非对称构图
                    }
                    .opacity(titleShown ? 1 : 0)
                    .offset(y: titleShown ? 0 : 10)
                }

                Spacer()

                // 页脚:hairline + QICOMPASS 字距标
                VStack(spacing: 12) {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(width: 54, height: 0.5)
                    Text("QICOMPASS")
                        .font(BaziFont.latinCaps(size: 9))
                        .tracking(5.5)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .opacity(footerShown ? 1 : 0)
                .padding(.bottom, 64)
            }
        }
        .opacity(fadeOut ? 0 : 1)
        .allowsHitTesting(false)
        .onAppear {
            scheduleSequence()
        }
    }

    /// 动效时序(reduce-motion 全部降级为静态短留)。
    private func scheduleSequence() {
        if reduceMotion {
            titleShown = true
            footerShown = true
            Task { [onFinished] in
                try? await Task.sleep(for: .milliseconds(350))
                onFinished()
            }
            return
        }
        withAnimation(.easeOut(duration: 0.7).delay(0.7)) { titleShown = true }
        withAnimation(.easeOut(duration: 0.6).delay(1.1)) { footerShown = true }
        Task { [onFinished] in
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeIn(duration: 0.25)) { fadeOut = true }
            try? await Task.sleep(for: .milliseconds(280))
            onFinished()
        }
    }
}
