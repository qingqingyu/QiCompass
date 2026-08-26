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
#if DEBUG
    @State private var showDetail = false
#endif

    /// 便利 init:接受任意 Error(SwiftDataCRUDView 等仍可调用,自动转 generic)。
    /// 非 UserFacingError 的原始 error 不进 UI(2026-08-16:代码性错误不进用户面前),
    /// 全量细节记日志后人话兜底。
    init(error: Error, retry: @escaping () -> Void) {
        if let userError = error as? UserFacingError {
            self.userFacingError = userError
        } else {
            AppLogger.app.warning(
                "errorStateView.generic_fallback error=\(String(describing: error), privacy: .public)"
            )
            self.userFacingError = .generic(message: "操作未完成,请重试")
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
            } else if case .persistentFailure = userFacingError {
                // 生肖阶段 3:反复失败硬性故障。不显示 retry,文案已在 subtitle 引导重启 App。
                // 与 dailyLimitReached 同款模式:不暴露重试入口,避免用户陷入死循环。
                EmptyView()
            } else {
                Button(action: { HapticEngine.light(); retry() }) {
                    Text("重试")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.onInkDeep)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
                }
            }

#if DEBUG
            // 详情展开(帮助诊断):仅 DEBUG build 编译。发布 build 用户不可见
            // (2026-08-16 拍板:原始错误文本属代码性信息,绝不进用户 UI;
            // 生产排查走 AppLogger 日志)。
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
                        .padding(BaziTheme.Spacing.md)
                        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
            }
#endif
        }
        .onAppear {
            // 规则 1:错误显示日志。ErrorStateView 出现 = 用户看到错误,
            // 必须可追溯是哪种错误类型 + 描述(便于排查 UI 错误态问题)
            let kind = String(describing: userFacingError)
            let message = userFacingError.errorDescription ?? "nil"
            AppLogger.app.warning("errorStateView.shown kind=\(kind.prefix(80), privacy: .public) message=\(message.prefix(120), privacy: .public)")
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .baziAnimation(value: userFacingError)
    }

#if DEBUG
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
        case .persistentFailure:
            return "连续 3 次排盘失败"
        }
    }
#endif

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
        case .persistentFailure:
            // 八边形硬停标志,区别于单次 chartFailed 的三角警告:传达"硬性故障,不再重试"语义
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.cinnabar.opacity(0.7))
        }
    }
}
