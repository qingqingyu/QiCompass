import SwiftUI

/// Tab 3:每日运势(占位)。
/// 四态:loading / empty / error / success。
/// 脚手架阶段:CTA "查看今日运势" 演示 stub 端点错误传播(后端未实现)。
struct DailyFortuneView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var state: LoadingState<String> = .empty

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.backgroundGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("每日运势")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .empty:
            EmptyStateView(
                title: "今日流日运势",
                subtitle: "需先完成深度解析,基于命盘推演流日",
                ctaTitle: "查看今日运势",
                action: triggerStub
            )
        case .loading:
            LoadingStateView(title: "正在推演流日…")
        case .error(let error):
            ErrorStateView(error: error, retry: triggerStub)
        case .success(let msg):
            SuccessCardView(
                title: "运势已显",
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
                // stub:后端未实现 /api/bazi/daily-fortune,预期 throw
                let req = DailyFortuneRequest(
                    chartHash: "stub_chart",
                    targetDate: Date()
                )
                let resp = try await env.apiClient.dailyFortune(request: req)
                state = .success("日柱:\(resp.dayPillar)")
            } catch {
                state = .error(error)
            }
        }
    }
}
