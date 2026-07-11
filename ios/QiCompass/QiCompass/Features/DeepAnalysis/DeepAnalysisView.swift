import SwiftUI
import SwiftData

/// Tab 1:深度解析(占位)。
/// 四态:loading / empty / error / success。
/// 脚手架阶段调用 apiClient.health() 验证链路;正式 slice 替换为排盘表单。
struct DeepAnalysisView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var state: LoadingState<HealthResponse> = .empty

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
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            EmptyStateView(
                title: "四柱八字深度解析",
                subtitle: "输入出生信息,排盘解析命局",
                ctaTitle: "开始排盘",
                action: checkHealth
            )
        case .loading:
            LoadingStateView(title: "正在排盘…")
        case .error(let error):
            ErrorStateView(error: error, retry: checkHealth)
        case .success(let resp):
            SuccessCardView(
                title: "命盘已就绪",
                bodyText: "后端连通:\(resp.lunarPythonVersion)\n模型:\(resp.model)",
                ctaTitle: nil,
                action: nil
            )
        }
    }

    private func checkHealth() {
        state = .loading
        Task {
            do {
                let resp = try await env.apiClient.health()
                state = .success(resp)
            } catch {
                state = .error(error)
            }
        }
    }
}

// MARK: - Shared State Views

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
