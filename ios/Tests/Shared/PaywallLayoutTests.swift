import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import QiCompass

/// 付费墙 sheet 布局守护(2026-08-31 bug:章节清单首章「壹」不可见)。
///
/// 根因:PaywallView 根 View 是不可滚动的固定 VStack,未登录态内容
/// (印章头 + 8 章清单 + 双登录按钮 + 法律注)理想高度远超
/// `.presentationDetents([.medium])` 的内容区高度。超高内容在 sheet
/// 宿主里被垂直居中,上下两端同时裁掉:顶部丢「解」印 + 标题 +
/// 「壹·命盘」行(用户看到清单从「贰」开始),底部丢 Google 按钮 + 法律注。
///
/// 不变量:内容理想高度若超出 .medium 内容区,层级里必须有 UIScrollView
/// 兜底(ScrollView 顶部锚定,永不居中裁切);未来内容变矮到放得下时,
/// 没有 ScrollView 也合法(断言按 if 分支,不锁死实现)。
@MainActor
final class PaywallLayoutTests: XCTestCase {
    /// iPhone 16 Pro(393×852)上 .medium detent 的内容区近似高度
    /// (852 / 2 - 底部安全区 34 ≈ 392)。
    private static let mediumContentHeight: CGFloat = 392
    private static let phoneWidth: CGFloat = 393

    private var container: ModelContainer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDownWithError() throws {
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 不变量(回归守护)

    func test_deepAnalysisPaywall_mediumDetentNeverClips() throws {
        try assertMediumDetentNeverClips(module: .deepAnalysis)
    }

    func test_compatibilityPaywall_mediumDetentNeverClips() throws {
        try assertMediumDetentNeverClips(module: .compatibility)
    }

    // MARK: - 布局诊断快照(视觉证据)

    /// 在 .medium 高度约束下渲染深度解析付费墙,快照落盘 + 附到 xcresult。
    /// 布局回归时肉眼核对「壹·命盘」是否可见、内容是否顶部锚定。
    func test_deepAnalysisPaywall_mediumSnapshotForVisualInspection() throws {
        let host = try installPaywallInWindow(module: .deepAnalysis)
        defer { host.view.removeFromSuperview() }

        let png = try XCTUnwrap(snapshotPng(host.view), "快照渲染失败")
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qicompass_paywall_medium_deep.png"))
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "paywall-medium-deep.png",
                                       payload: png, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - 实现

    private func assertMediumDetentNeverClips(module: PaywallModule) throws {
        let host = try installPaywallInWindow(module: module)
        defer { host.view.removeFromSuperview() }

        let ideal = host.sizeThatFits(in: CGSize(width: Self.phoneWidth, height: .greatestFiniteMagnitude))
        let hasScrollView = Self.containsScrollView(host.view)

        if ideal.height > Self.mediumContentHeight {
            XCTAssertTrue(
                hasScrollView,
                "PaywallView 理想高度 \(Int(ideal.height))pt 超出 .medium 内容区 ~\(Int(Self.mediumContentHeight))pt,"
                    + "但层级中没有 UIScrollView → 超高内容会被 sheet 垂直居中裁掉上下两端"
                    + "(2026-08-31 首章「壹」不可见回归)"
            )
        }
    }

    /// 构造真实 AppEnvironment(Mock 客户端 + 内存容器),把 PaywallView
    /// 装进临时 UIWindow 并按 .medium 内容区尺寸布局(离屏渲染需要
    /// window 参与,否则 SwiftUI 不跑 layout、层级不落地)。
    private func installPaywallInWindow(module: PaywallModule) throws -> UIHostingController<some View> {
        let env = AppEnvironment(
            modelContainer: container,
            apiClient: MockAPIClient(),
            useMockClient: true
        )
        let viewModel = PaywallViewModel(
            module: module,
            contentHash: "layout-test",
            purchaseManager: env.purchaseManager
        )
        let host = UIHostingController(rootView: PaywallView(viewModel: viewModel).environmentObject(env))
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: Self.phoneWidth, height: Self.mediumContentHeight)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        return host
    }

    private static func containsScrollView(_ view: UIView) -> Bool {
        if view is UIScrollView { return true }
        return view.subviews.contains { containsScrollView($0) }
    }

    private func snapshotPng(_ view: UIView) -> Data? {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.pngData()
    }
}
