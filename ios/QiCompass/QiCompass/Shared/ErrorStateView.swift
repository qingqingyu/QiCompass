import SwiftUI

/// 四态共用:错误态(三态分类渲染,方案 step 3 + DESIGN.md §Color)。
///
/// 图标映射(方案 §D2):
/// - `InkSplashView` 墨溅:networkUnavailable / generic
/// - `exclamationmark.triangle`:chartFailed(排盘异常)
/// - `book.closed`:interpretFailed(命书生成失败)
/// - `hourglass`:dailyLimitReached(达上限,带倒计时,不显示重试)
///
/// Reduce Motion:错误切换过渡统一走 `MotionPreferences.transition`(开启时退化为 .opacity)。
/// 触感:重试按钮 `.light`(用户主动操作)。
struct ErrorStateView: View {
    let userFacingError: UserFacingError
    let retry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetail = false

    /// 便利 init:接受任意 Error(SwiftDataCRUDView 等仍可调用,自动转 generic)。
    init(error: Error, retry: @escaping () -> Void) {
        if let userError = error as? UserFacingError {
            self.userFacingError = userError
        } else {
            self.userFacingError = .generic(message: error.localizedDescription)
        }
        self.retry = retry
    }

    /// 主 init:直接接受 UserFacingError。
    init(userFacingError: UserFacingError, retry: @escaping () -> Void) {
        self.userFacingError = userFacingError
        self.retry = retry
    }

    var body: some View {
        VStack(spacing: 16) {
            iconView
                .transition(MotionPreferences.transition(
                    .scale.combined(with: .opacity), reduceMotion: reduceMotion
                ))

            Text(userFacingError.errorDescription ?? "未知错误")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)

            // subtitle 与 errorDescription 相同时(.generic)不重复展示
            if userFacingError.subtitle != (userFacingError.errorDescription ?? "") {
                Text(userFacingError.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if case .dailyLimitReached(let nextReset) = userFacingError {
                CountdownResetLabel(nextReset: nextReset)
            } else {
                Button(action: { HapticEngine.light(); retry() }) {
                    Text("重试")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.paper)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
            }

            // 详情展开(帮助诊断):非 networkUnavailable 时显示
            if showsDetailSection {
                Button(showDetail ? "收起详情" : "展开详情") {
                    showDetail.toggle()
                }
                .font(.caption)
                .foregroundStyle(BaziTheme.cinnabar)
                if showDetail {
                    Text(detailText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(BaziTheme.inkMuted)
                        .padding(12)
                        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .baziAnimation(value: userFacingError)
    }

    /// networkUnavailable 时无需展示原始 URLError 细节;其余允许展开。
    private var showsDetailSection: Bool {
        switch userFacingError {
        case .networkUnavailable: return false
        default: return true
        }
    }

    private var detailText: String {
        switch userFacingError {
        case .chartFailed(let s), .interpretFailed(let s), .generic(let s):
            return s
        case .networkUnavailable:
            return "网络异常"
        case .dailyLimitReached:
            return "每日 10 次已用完"
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch userFacingError {
        case .networkUnavailable, .generic:
            InkSplashView(seed: 42)
                .frame(width: 96, height: 96)
        case .chartFailed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.cinnabar.opacity(0.7))
        case .interpretFailed:
            Image(systemName: "book.closed")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.cinnabar.opacity(0.7))
        case .dailyLimitReached:
            Image(systemName: "hourglass")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.cinnabar.opacity(0.7))
        }
    }
}
