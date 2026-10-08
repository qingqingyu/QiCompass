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
    @EnvironmentObject private var env: AppEnvironment
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
            self.userFacingError = .generic(message: String(localized: "操作未完成,请重试"))
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

            Text(userFacingError.errorDescription ?? L10n.Common.unknownError)
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

            if case .dailyLimitReached(let nextReset, let serverPool) = userFacingError {
                CountdownResetLabel(nextReset: nextReset)
                // 服务端共享池 429 + 未登录(2026-10-08 拍板):附登录引导行
                // (本地池与登录无关,不引导)
                if serverPool, !env.accountManager.isLoggedIn {
                    Text(L10n.Common.loginQuotaHint)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            } else if case .contextTokenExpired = userFacingError {
                RecalculateChartButton()
            } else if showsRetryButton {
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

    /// 达上限(等重置)与凭证失效(须重新排盘换新 token)都不渲染「重试」——
    /// 重试只会再次 403 死循环(2026-10-07 double review);凭证失效的出口
    /// 是「重新排盘」按钮(2026-10-08,替代只有一句指引的死胡同)。
    private var showsRetryButton: Bool {
        switch userFacingError {
        case .dailyLimitReached, .contextTokenExpired:
            return false
        default:
            return true
        }
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
            return String(localized: "网络异常")
        case .dailyLimitReached:
            return String(localized: "每日 10 次已用完")
        case .contextTokenExpired:
            return L10n.Errors.contextTokenSubtitle
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
        case .contextTokenExpired:
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.cinnabar.opacity(0.7))
        }
    }
}

// MARK: - 凭证失效出口(2026-10-08)

/// 「重新排盘」按钮:contextTokenExpired 态的统一恢复出口。
///
/// 动作 = post `.switchTab("deepAnalysis")` 落到深度解析 tab(排盘表单所在,
/// 与 Onboarding 完成后的落地同款路由):ChartSnapshot 不存 hourKnown/钟面
/// 时间(真太阳时不可逆推),**无法自动重签**——用户重排后新 chart 快照带
/// 新 token,每日(daily 快照 token nil 视同 miss 重签)与深度解析链自动
/// 自愈。用在:ErrorStateView / InterpretState.contextTokenExpired(每日/
/// 合盘解读区)/ ModuleState.contextTokenExpired(深度章节页)。
struct RecalculateChartButton: View {
    var body: some View {
        Button {
            HapticEngine.light()
            NotificationCenter.default.post(
                name: .switchTab, object: nil,
                userInfo: ["tab": "deepAnalysis"])
        } label: {
            Text(L10n.Errors.contextTokenRecalculate)
                .font(.body.weight(.semibold))
                .foregroundStyle(BaziTheme.onInkDeep)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// 凭证失效态共用视图(InterpretState/ModuleState 的 .contextTokenExpired
/// 分支渲染):标题 + 指引副标 + `RecalculateChartButton`。
struct ContextTokenExpiredView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(L10n.Errors.contextTokenTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(BaziTheme.shenshaInauspicious)
            Text(L10n.Errors.contextTokenSubtitle)
                .font(.caption)
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
            RecalculateChartButton()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
