import SwiftUI
import SwiftData

/// Tab 1:深度解析(状态机根,方案 §一)。
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
                BaziTheme.backgroundGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("深度解析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #if DEBUG
            .toolbar {
                NavigationLink {
                    SwiftDataCRUDView()
                } label: {
                    Image(systemName: "ladybug")
                        .foregroundStyle(BaziTheme.gold)
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
                            .foregroundStyle(BaziTheme.gold)
                    }
                }
            case .chartFailed(let message):
                errorView(message: message, retry: vm.retryCalculation, onBack: vm.reset)
            }
        } else {
            ProgressView()
                .tint(BaziTheme.gold)
        }
    }

    private func calculatingView(stage: LoadingStage) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(BaziTheme.gold)
            Text(stage.text)
                .font(.body)
                .foregroundStyle(BaziTheme.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(
        message: String,
        retry: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.gold.opacity(0.8))
            Text("排盘失败")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("重试", action: retry)
                .font(.body.weight(.semibold))
                .foregroundStyle(BaziTheme.bgTop)
                .padding(.horizontal, 32)
                .padding(.vertical, 12)
                .background(BaziTheme.gold, in: Capsule())
            Button("返回表单", action: onBack)
                .font(.caption)
                .foregroundStyle(BaziTheme.gold)
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
                .tint(BaziTheme.gold)
            Text(title)
                .font(.body)
                .foregroundStyle(BaziTheme.textDim)
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
                .foregroundStyle(BaziTheme.gold.opacity(0.6))
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.textDim)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(ctaTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BaziTheme.bgTop)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(BaziTheme.gold, in: Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 四态共用:错误态(显式展示错误,不吞)
struct ErrorStateView: View {
    let error: Error
    let retry: () -> Void
    @State private var showDetail = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.gold.opacity(0.8))
            Text("天意未明")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.textDim)
                .multilineTextAlignment(.center)
                .lineLimit(showDetail ? nil : 2)
            Button(showDetail ? "收起详情" : "展开详情") {
                showDetail.toggle()
            }
            .font(.caption)
            .foregroundStyle(BaziTheme.gold)
            if showDetail {
                Text(String(describing: error))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(BaziTheme.textDim)
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Button("重试", action: retry)
                .font(.body.weight(.semibold))
                .foregroundStyle(BaziTheme.gold)
                .padding(.top, 8)
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
                .foregroundStyle(BaziTheme.gold)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.text)
                .multilineTextAlignment(.center)
            if let ctaTitle, let action {
                Button(action: action) {
                    Text(ctaTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.bgTop)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(BaziTheme.gold, in: Capsule())
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
