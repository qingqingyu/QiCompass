import SwiftUI

/// Tab 2:合盘(占位)。
/// 四态:loading / empty / error / success。
/// 脚手架阶段:CTA "选择命盘" 演示 stub 端点错误传播(后端未实现)。
struct CompatibilityView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var state: LoadingState<String> = .empty

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.backgroundGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("合盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            EmptyStateView(
                title: "双人合盘",
                subtitle: "选择两个命盘,分析五行生克与流年同步性",
                ctaTitle: "选择命盘",
                action: triggerStub
            )
        case .loading:
            LoadingStateView(title: "正在合盘…")
        case .error(let error):
            ErrorStateView(error: error, retry: triggerStub)
        case .success(let msg):
            SuccessCardView(
                title: "合盘完成",
                bodyText: msg,
                ctaTitle: nil,
                action: nil
            )
        }
    }

    private func triggerStub() {
        state = .loading
        Task {
            do {
                // stub:后端未实现 /api/bazi/compatibility,预期 throw
                let req = CompatibilityRequest(
                    personAHash: "stub_a",
                    personB: PersonBInput(
                        birthDatetime: Date(),
                        gender: "male",
                        city: "北京",
                        ziHourRule: "zi_next_day"
                    ),
                    context: "general"
                )
                let resp = try await env.apiClient.compatibility(request: req)
                state = .success("compatibility_hash=\(resp.compatibilityHash)")
            } catch {
                state = .error(error)
            }
        }
    }
}
