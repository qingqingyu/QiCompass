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

    /// 未登录付费墙**暗色**快照(夜宣纸走查,B 章回分段 2026-09-06)。
    func test_deepAnalysisPaywall_mediumDarkSnapshot() throws {
        let host = try installPaywallInWindow(module: .deepAnalysis, interfaceStyle: .dark)
        defer { host.view.removeFromSuperview() }

        let png = try XCTUnwrap(snapshotPng(host.view), "快照渲染失败")
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qicompass_paywall_medium_deep_dark.png"))
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "paywall-medium-deep-dark.png",
                                       payload: png, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 未登录付费墙**全高**快照(走查用:.medium 只露出上半段,登录区/
    /// 法律注在 ScrollView 下方;本快照按内容理想高撑满窗口渲染整页)。
    func test_deepAnalysisPaywall_fullHeightSnapshot() throws {
        let host = try installPaywallInWindow(module: .deepAnalysis)
        defer { host.view.removeFromSuperview() }

        // B 章回分段后未登录内容理想高 ~880pt,固定窗口(挂载默认 .medium 高)
        // 顶锚下会裁掉登录区/法律注——恰是本快照要走查的区域。按 sizeThatFits
        // 无条件把 window 撑到内容理想高再重排(内容更矮时收缩到 ideal 同样无害;
        // 改 frame 不涉 trait 重解析,暗色陷阱只针对 overrideUserInterfaceStyle)。
        // window 用 XCTUnwrap:挂载不变量若被破坏,宁可测试失败也不静默产错误快照。
        let ideal = host.sizeThatFits(in: CGSize(width: Self.phoneWidth, height: .greatestFiniteMagnitude))
        let window = try XCTUnwrap(host.view.window, "mountInWindow 后 host 必有 window")
        window.frame = CGRect(origin: .zero, size: CGSize(width: Self.phoneWidth, height: ideal.height))
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()

        let png = try XCTUnwrap(snapshotPng(host.view), "快照渲染失败")
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qicompass_paywall_full_deep.png"))
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "paywall-full-deep.png",
                                       payload: png, userInfo: nil)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 契约 stepper 四态 + 落价块双形态状态矩阵快照(B 章回分段走查)。
    /// AccountManager 的 state/exchangeState 是 private(set),登录态注入
    /// 不进真实链路,故直接渲染组件状态矩阵(各态视觉一眼可核)。
    func test_contractStepperStateMatrixSnapshot() throws {
        let matrix = VStack(alignment: .leading, spacing: 30) {
            ContractStepper(step: .sealing, isExchanging: false, isPurchased: false)
            ContractStepper(step: .sealing, isExchanging: true, isPurchased: false)
            ContractStepper(step: .dealing, isExchanging: false, isPurchased: false)
            ContractStepper(step: .dealing, isExchanging: false, isPurchased: true)
            PricePlate(upperPrice: ChineseUpperPrice.priceString(from: "¥128.00"), rawPrice: "¥128.00")
            PricePlate(upperPrice: nil, rawPrice: "$17.99")
        }
        .padding(BaziTheme.Spacing.lg)
        .frame(width: Self.phoneWidth - BaziTheme.Spacing.lg * 2, alignment: .leading)

        let host = mountInWindow(rootView: matrix, height: 580)
        defer { host.view.removeFromSuperview() }

        let png = try XCTUnwrap(snapshotPng(host.view), "快照渲染失败")
        try png.write(to: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qicompass_paywall_stepper_matrix.png"))
        let attachment = XCTAttachment(uniformTypeIdentifier: "public.png", name: "paywall-stepper-matrix.png",
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
    /// window 参与,否则 SwiftUI 不跑 layout、层级不落地)。全高走查由
    /// 调用方挂载后按 sizeThatFits 撑高 window(fullHeight 快照)。
    private func installPaywallInWindow(
        module: PaywallModule,
        interfaceStyle: UIUserInterfaceStyle = .unspecified
    ) throws -> UIHostingController<some View> {
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
        return mountInWindow(
            rootView: PaywallView(viewModel: viewModel).environmentObject(env),
            height: Self.mediumContentHeight,
            interfaceStyle: interfaceStyle
        )
    }

    /// 通用挂载:UIHostingController + 临时 UIWindow + 强制布局。
    /// interfaceStyle 必须在 makeKeyAndVisible **之前**设在 window 上:
    /// 挂载后再改,BaziTheme 的动态色(traitCollection 闭包)不会重新解析。
    private func mountInWindow<V: View>(
        rootView: V,
        height: CGFloat,
        interfaceStyle: UIUserInterfaceStyle = .unspecified
    ) -> UIHostingController<V> {
        let host = UIHostingController(rootView: rootView)
        host.overrideUserInterfaceStyle = interfaceStyle
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: Self.phoneWidth, height: height)))
        window.overrideUserInterfaceStyle = interfaceStyle
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
