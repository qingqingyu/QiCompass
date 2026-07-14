import SwiftUI
import SwiftData

/// Debug 面板:SwiftData CRUD 验证(DESIGN.md §Color)。
///
/// - App 启动后**不自动污染数据**,由 Debug 按钮显式触发
/// - 四态:loading / success / error(失败时保留错误详情)
/// - #if DEBUG 仅 Debug 构建可用
#if DEBUG
struct SwiftDataCRUDView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var state: LoadingState<CRUDVerifyResult> = .empty

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("存储验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            VStack(spacing: 20) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 48))
                    .foregroundStyle(BaziTheme.ink.opacity(0.4))
                Text("本地存储验证")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(BaziTheme.ink)
                Text("覆盖 5 个 SwiftData 模型的 Create / Read / Update / Delete + Assert,验证后自动清理测试数据。")
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .multilineTextAlignment(.center)
                Button("运行本地存储验证", action: runVerify)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BaziTheme.paper)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loading:
            LoadingStateView(title: "正在验证 5 个模型 CRUD…")

        case .error(let error):
            ErrorStateView(error: error, retry: runVerify)

        case .success(let result):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(BaziTheme.jade)
                        Text(result.summary)
                            .font(.headline)
                            .foregroundStyle(BaziTheme.ink)
                    }
                    Divider().background(BaziTheme.separator)
                    ForEach(result.details, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(BaziTheme.ink)
                    }
                    Button("重新验证", action: runVerify)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.cinnabar)
                        .padding(.top, 16)
                }
                .padding()
            }
        }
    }

    private func runVerify() {
        state = .loading
        Task {
            do {
                let verifier = SwiftDataCRUDVerifier(context: env.modelContainer.mainContext)
                let result = try await verifier.verify()
                state = .success(result)
            } catch {
                state = .error(error)
            }
        }
    }
}
#endif
