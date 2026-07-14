import SwiftUI
import SwiftData

/// Tab 1:深度解析(状态机根,方案 §一 + DESIGN.md §Color)。
///
/// 主状态机:
/// - .empty / .formInvalid → BirthFormView
/// - .calculating(stage) → 分阶段加载文案
/// - .chartReady(response, _) → DeepAnalysisResultView(AI 子状态独立)
/// - .chartFailed(message) → 原始错误 + 重试
///
/// VM 首次 appear 时用 env.deepAnalysisOrchestrator 创建(@State + .task)。
struct DeepAnalysisView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var vm: DeepAnalysisViewModel?

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("深度解析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            #if DEBUG
            .toolbar {
                NavigationLink {
                    SwiftDataCRUDView()
                } label: {
                    Image(systemName: "ladybug")
                        .foregroundStyle(BaziTheme.cinnabar)
                }
            }
            #endif
        }
        .task {
            if vm == nil {
                vm = DeepAnalysisViewModel(orchestrator: env.deepAnalysisOrchestrator)
            }
        }
    }

    @ViewBuilder
    @MainActor
    private var content: some View {
        if let vm {
            switch vm.state {
            case .empty, .formInvalid:
                BirthFormView(vm: vm, onSubmit: vm.calculate)
            case .calculating(let stage):
                calculatingView(stage: stage)
            case .chartReady(let response, _):
                if let request = vm.lastRequest {
                    DeepAnalysisResultView(vm: vm, response: response, request: request)
                } else {
                    VStack {
                        Text("数据异常:无请求记录")
                            .foregroundStyle(.red)
                        Button("返回表单") { vm.reset() }
                            .foregroundStyle(BaziTheme.cinnabar)
                    }
                }
            case .chartFailed(let userError):
                errorView(error: userError, retry: vm.retryCalculation, onBack: vm.reset)
            }
        } else {
            ProgressView()
                .tint(BaziTheme.cinnabar)
        }
    }

    private func calculatingView(stage: LoadingStage) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(BaziTheme.cinnabar)
            Text(stage.text)
                .font(.body)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(
        error: UserFacingError,
        retry: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            ErrorStateView(error: error, retry: retry)
            Button("返回表单", action: onBack)
                .font(.caption)
                .foregroundStyle(BaziTheme.cinnabar)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared State Views(四态共用,被 Compatibility/DailyFortune/CRUDView 复用)

/// 四态共用:加载中
struct LoadingStateView: View {
    let title: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(BaziTheme.cinnabar)
            Text(title)
                .font(.body)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 四态共用:空态
struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let ctaTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wind")
                .font(.system(size: 48))
                .foregroundStyle(BaziTheme.ink.opacity(0.4))
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(ctaTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BaziTheme.paper)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 四态共用:成功态卡片
struct SuccessCardView: View {
    let title: String
    let bodyText: String
    let ctaTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.jade)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.ink)
                .multilineTextAlignment(.center)
            if let ctaTitle, let action {
                Button(action: action) {
                    Text(ctaTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.paper)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
