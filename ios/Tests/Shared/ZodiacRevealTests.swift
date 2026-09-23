import SwiftUI
import UIKit
import XCTest
@testable import QiCompass

/// 生肖反馈屏回归守护(2026-09-23 review 修复)。
///
/// 覆盖三块:
/// 1. **资产编译守护**:12 生肖 imageset 必须进 Assets.car——原 webp 被 actool
///    **静默丢弃**(构建绿、Assets.car 无条目、运行时 Image=nil),「顶部 1/4 屏
///    空白 + chip 图标占位文字偏右」两个视觉 bug 的共同根因。已转透明底 PNG,
///    本组测试防同类回归再次静默发生。
/// 2. **文案纯函数**:`revealSubLabel`(zh 保留命理双轨 / EN "Wood Ox · 1985"
///    去黑话)+ `revealDayMasterDisplay`(日主展示串,日柱歧义 nil 不猜)。
///    language 显式传参——`AppLanguage.current` 读系统语言且无测试注入通道,
///    设备语言会左右断言结果(2026-09-23 测试假红教训)。
/// 3. **整屏渲染走查**:临时 window 挂载真实 ZodiacRevealView(挂载范式同
///    PaywallLayoutTests),等盖章动效落定后快照,断言印章带确实有墨(资产 ×
///    布局联动);快照进 xcresult 供人工走查(chip 等宽一行/居中/需磨合扁平)。
@MainActor
final class ZodiacRevealTests: XCTestCase {

    private static let phoneWidth: CGFloat = 393
    private static let phoneHeight: CGFloat = 852
    private static let allZodiacs = [
        "Rat", "Ox", "Tiger", "Rabbit", "Dragon", "Snake",
        "Horse", "Goat", "Monkey", "Rooster", "Dog", "Pig",
    ]

    // MARK: - 1. 资产编译守护

    /// 12 × (light + dark) 全部可从主 bundle 解出,且 dark 是**真变体**。
    /// 两个坑都要绕开:
    /// 1. `UIImage(named:)` 按**宿主当前外观**解析——模拟器 test host 处于
    ///    dark 时它返回的直接是 dark 变体(09-23 实测,与既有「假红」同类
    ///    陷阱),light 参照必须同样走 `imageAsset.image(with:)` 显式 trait 解析。
    /// 2. `UIImageAsset.image(with:)` 对未注册 dark 的 imageset 会回落 base
    ///    (light)图且恒非 nil——notNil 断言对「Contents.json 删掉 dark 条目」
    ///    打不响,需像素级判定:dark 与 light 必须实质不同(本资产对
    ///    light=黑墨 / dark=浅墨,笔画 RGB 大面积不同)。
    /// 同时 dark 四角透明(白方块转换回退在 dark 一侧同样要防,light 一侧由
    /// 下方 Ox 抽查覆盖)。
    func test_allZodiacImages_compileIntoAssetCatalog() throws {
        for name in Self.allZodiacs {
            let anyVariant = try XCTUnwrap(
                UIImage(named: "Zodiac_\(name)"),
                "Zodiac_\(name) 未进 Assets.car——imageset 是否又用了被 actool 静默丢弃的格式(如 webp)?"
            )
            let asset = try XCTUnwrap(
                anyVariant.imageAsset,
                "Zodiac_\(name) 无 imageAsset(应有 light/dark appearance 变体)"
            )
            let light = try XCTUnwrap(
                asset.image(with: UITraitCollection(userInterfaceStyle: .light)),
                "Zodiac_\(name) light 变体缺失"
            )
            let dark = try XCTUnwrap(
                asset.image(with: UITraitCollection(userInterfaceStyle: .dark)),
                "Zodiac_\(name) dark 变体缺失"
            )
            let (lw, lh, lbuf) = try rgbaBuffer(of: light)
            let (dw, dh, dbuf) = try rgbaBuffer(of: dark)
            XCTAssertEqual([lw, lh], [dw, dh], "Zodiac_\(name) light/dark 尺寸不一致")
            // 像素 diff 只看 R/B 通道(premultiplied 下透明区 RGB 归零不误报),
            // 超阈早停防全图扫描拖慢 12 组循环
            var diff = 0
            for i in stride(from: 0, to: min(lbuf.count, dbuf.count), by: 4) {
                if lbuf[i] != dbuf[i] || lbuf[i + 2] != dbuf[i + 2] {
                    diff += 1
                    if diff > 200 { break }
                }
            }
            XCTAssertGreaterThan(
                diff, 200,
                "Zodiac_\(name) dark 与 light 像素相同——dark 变体未注册(UIImageAsset 回落 base 图,notNil 对此无效)"
            )
            let cornerAlpha = { (x: Int, y: Int) in dbuf[(y * dw + x) * 4 + 3] }
            XCTAssertLessThan(cornerAlpha(4, 4), 12, "Zodiac_\(name) dark 左上角不透明——透明底抠图回退")
            XCTAssertLessThan(cornerAlpha(dw - 5, 4), 12, "Zodiac_\(name) dark 右上角不透明——透明底抠图回退")
            XCTAssertLessThan(cornerAlpha(4, dh - 5), 12, "Zodiac_\(name) dark 左下角不透明——透明底抠图回退")
            XCTAssertLessThan(cornerAlpha(dw - 5, dh - 5), 12, "Zodiac_\(name) dark 右下角不透明——透明底抠图回退")
        }
    }

    /// 透明底抽查(牛,light 变体):四角全透明(白底已抠)+ 不透明笔画像素存在。
    /// 原 webp 是不透明白底黑线,转换回退会变成白色方块盖在宣纸上。
    /// 显式 `.light` trait 解析:`UIImage(named:)` 会跟宿主外观走(dark host
    /// 下验的就成 dark 变体,09-23 实测),钉死才有确定性。
    func test_zodiacLightVariant_hasKnockedOutBackground() throws {
        let anyVariant = try XCTUnwrap(UIImage(named: "Zodiac_Ox"))
        let asset = try XCTUnwrap(anyVariant.imageAsset, "Zodiac_Ox 无 imageAsset")
        let image = try XCTUnwrap(
            asset.image(with: UITraitCollection(userInterfaceStyle: .light)),
            "Zodiac_Ox light 变体缺失"
        )
        let (w, h, buf) = try rgbaBuffer(of: image)
        let cornerAlpha = { (x: Int, y: Int) in buf[(y * w + x) * 4 + 3] }
        XCTAssertLessThan(cornerAlpha(4, 4), 12, "左上角不透明——透明底抠图回退")
        XCTAssertLessThan(cornerAlpha(w - 5, 4), 12, "右上角不透明——透明底抠图回退")
        XCTAssertLessThan(cornerAlpha(4, h - 5), 12, "左下角不透明——透明底抠图回退")
        XCTAssertLessThan(cornerAlpha(w - 5, h - 5), 12, "右下角不透明——透明底抠图回退")
        let opaqueCount = buf.indices.filter { $0 % 4 == 3 && buf[$0] > 200 }.count
        XCTAssertGreaterThan(opaqueCount, 1_000, "Zodiac_Ox 笔画像素过少——资产内容异常")
    }

    // MARK: - 2. 文案纯函数

    /// zh / zh-Hant:命理 + 公历双轨(Q13 C+ii,2026-09-23 收拢进 helper 行为零变化)。
    func test_revealSubLabel_chineseKeepsLegacyDualTrack() {
        for language: AppLanguage in [.zh, .zhHant] {
            XCTAssertEqual(
                ZodiacHelper.revealSubLabel(
                    zodiac: "Ox", yearGanZhi: "乙丑", yearGanElement: "wood",
                    gender: "female", birthYear: 1985, language: language
                ),
                "坤造(女) · 乙丑年(1985)"
            )
            XCTAssertEqual(
                ZodiacHelper.revealSubLabel(
                    zodiac: "Dragon", yearGanZhi: "庚辰", yearGanElement: "metal",
                    gender: "male", birthYear: 2000, language: language
                ),
                "乾造(男) · 庚辰年(2000)"
            )
        }
    }

    /// EN:去命理黑话(坤造/干支),"Wood Ox · 1985"。
    func test_revealSubLabel_englishDropsJargon() {
        XCTAssertEqual(
            ZodiacHelper.revealSubLabel(
                zodiac: "Ox", yearGanZhi: "乙丑", yearGanElement: "wood",
                gender: "female", birthYear: 1985, language: .en
            ),
            "Wood Ox · 1985"
        )
    }

    /// EN:五行 key 缺失(理论不可达)→ 诚实退到 "Ox · 1985",不编造。
    func test_revealSubLabel_englishWithoutElementFallsBack() {
        XCTAssertEqual(
            ZodiacHelper.revealSubLabel(
                zodiac: "Ox", yearGanZhi: "乙丑", yearGanElement: nil,
                gender: "female", birthYear: 1985, language: .en
            ),
            "Ox · 1985"
        )
    }

    /// 日主展示串:zh「丁火」/ en "Ding Fire";日柱歧义(任一输入 nil)→ nil 不猜。
    func test_revealDayMasterDisplay() {
        XCTAssertEqual(
            ZodiacHelper.revealDayMasterDisplay(gan: "丁", ganElement: "fire", language: .zh),
            "丁火"
        )
        XCTAssertEqual(
            ZodiacHelper.revealDayMasterDisplay(gan: "丁", ganElement: "fire", language: .zhHant),
            "丁火"
        )
        XCTAssertEqual(
            ZodiacHelper.revealDayMasterDisplay(gan: "丁", ganElement: "fire", language: .en),
            "Ding Fire"
        )
        XCTAssertNil(ZodiacHelper.revealDayMasterDisplay(gan: nil, ganElement: "fire", language: .en),
                     "日柱歧义必须 nil(不猜)")
        XCTAssertNil(ZodiacHelper.revealDayMasterDisplay(gan: "丁", ganElement: nil, language: .zh),
                     "五行字段缺失必须 nil(不猜)")
        XCTAssertNil(ZodiacHelper.revealDayMasterDisplay(gan: "??", ganElement: "fire", language: .zh),
                     "未知天干必须 nil(fail-fast 而非展示错字)")
    }

    // MARK: - 3. 整屏渲染走查

    /// 正常态亮色:盖章动效落定后,印章带(顶部区)必须有墨——资产没进
    /// Assets.car 或 stampComposition 布局塌掉都会让该带空白。
    /// 显式 .light:模拟器系统外观不可控(09-23 实测设备处于 dark,
    /// unspecified 会继承成夜宣纸,断言口径跟着错)。
    func test_fullContent_light_rendersStampInk() async throws {
        try await assertRevealRendersStamp(interfaceStyle: .light, name: "light")
    }

    /// 正常态暗色:dark 变体资产 + 夜宣纸(2026-09-23 dark 快照走查)。
    func test_fullContent_dark_rendersStampInk() async throws {
        try await assertRevealRendersStamp(interfaceStyle: .dark, name: "dark")
    }

    // MARK: - 实现

    @MainActor
    private func assertRevealRendersStamp(
        interfaceStyle: UIUserInterfaceStyle,
        name: String
    ) async throws {
        let host = mountReveal(interfaceStyle: interfaceStyle)
        defer { host.view.removeFromSuperview() }

        // 盖章动效三拍错峰总 ~1.15s(内容 opacity 由 .task 驱动从 0 起步),
        // 等动效落定再快照;Task.sleep 不阻塞 main runloop(动效可推进)。
        try await Task.sleep(for: .milliseconds(1800))

        let data = try XCTUnwrap(snapshotPng(host.view), "快照渲染失败")
        let dark = interfaceStyle == .dark
        let totalInk = Self.inkPixelCount(data, dark: dark)
        XCTAssertGreaterThan(totalInk, 3_000, "整页几乎无墨——内容 opacity 未落定或整屏空白")

        // 印章带(scale1 快照 393×852,窗口无安全区插入):stamp ∈ y[78,218],
        // 标题在其下 ~24pt 起(y≈272);取 y∈[40,240] 避开标题行——资产被丢时
        // 该带只剩顶部留白。
        let stampInk = Self.inkPixelCount(
            data,
            band: CGRect(x: 0, y: 40, width: Int(Self.phoneWidth), height: 200),
            dark: dark
        )
        XCTAssertGreaterThan(stampInk, 150, "印章带无墨——Zodiac_* 资产未渲染(2026-09-23 webp 被 actool 丢弃的同款回归)")

        // 快照落盘 + 进 xcresult,供人工走查 chip 等宽一行 / 居中 / 需磨合扁平
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qicompass_zodiac_reveal_\(name).png")
        try data.write(to: url)
        let attachment = XCTAttachment(
            uniformTypeIdentifier: "public.png",
            name: "zodiac-reveal-\(name).png",
            payload: data,
            userInfo: nil
        )
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 挂载范式同 PaywallLayoutTests.mountInWindow(interfaceStyle 必须在
    /// makeKeyAndVisible 之前设,BaziTheme 动态色才会按 trait 解析)。
    private func mountReveal(interfaceStyle: UIUserInterfaceStyle) -> UIHostingController<ZodiacRevealView> {
        let reveal = ZodiacRevealView(
            zodiac: "Ox",
            mainLabel: "丑 · 牛",
            subLabel: "坤造(女) · 乙丑年(1985)",
            friendZodiacs: ["Rat", "Snake", "Rooster"],
            clashZodiac: "Goat",
            personalTease: "属相只是开篇 · 日主丁火与五行喜忌，都在深度解析里",
            onComplete: {}
        )
        let host = UIHostingController(rootView: reveal)
        host.overrideUserInterfaceStyle = interfaceStyle
        let window = UIWindow(
            frame: CGRect(origin: .zero, size: CGSize(width: Self.phoneWidth, height: Self.phoneHeight))
        )
        window.overrideUserInterfaceStyle = interfaceStyle
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        window.layoutIfNeeded()
        return host
    }

    private func snapshotPng(_ view: UIView) -> Data? {
        // scale 钉 1:快照恒 393×852(屏幕 scale 会出 @3x 1179×2556,
        // band 像素坐标随之错位——09-23 dark 断言 0 墨的假失败根因)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds, format: format)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.pngData()
    }

    /// 与背景纸色的偏离计数(1pt=1px 按 scale1 快照)。
    /// 阈值按「偏离纸色 >25」:scale1 下细线笔画被抗锯齿冲淡(实测印章环
    /// lum≈140-170),按绝对暗/亮阈值会漏计出「0 墨」假失败;纸色本身
    /// light≈225 / dark≈20,25 的余量既不数纸也不丢淡笔画。
    /// band 为 nil 时统计整图。
    private static func inkPixelCount(_ png: Data, band: CGRect? = nil, dark: Bool) -> Int {
        guard let image = UIImage(data: png), let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return 0 }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return 0 }
        let buf = base.bindMemory(to: UInt8.self, capacity: w * h * 4)

        let xRange: Range<Int>, yRange: Range<Int>
        if let band {
            xRange = Int(band.minX)..<min(Int(band.maxX), w)
            yRange = Int(band.minY)..<min(Int(band.maxY), h)
        } else {
            xRange = 0..<w
            yRange = 0..<h
        }
        let paperLum = dark ? 20 : 225
        var count = 0
        for y in yRange {
            for x in xRange {
                let p = (y * w + x) * 4
                let lum = (Int(buf[p]) * 299 + Int(buf[p + 1]) * 587 + Int(buf[p + 2]) * 114) / 1000
                if abs(lum - paperLum) > 25 { count += 1 }
            }
        }
        return count
    }

    /// RGBA 像素 buffer(资产透明度检查用)。
    private func rgbaBuffer(of image: UIImage) throws -> (Int, Int, [UInt8]) {
        let cg = try XCTUnwrap(image.cgImage, "UIImage 无 cgImage")
        let w = cg.width, h = cg.height
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = ctx.data!
        let buf = base.bindMemory(to: UInt8.self, capacity: w * h * 4)
        return (w, h, Array(UnsafeBufferPointer(start: buf, count: w * h * 4)))
    }
}
