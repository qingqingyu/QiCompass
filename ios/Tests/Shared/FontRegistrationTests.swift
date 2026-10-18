import XCTest
import UIKit

/// 打包字体注册链回归锚(2026-10-18 全宋体批次):
/// Info.plist `UIAppFonts` × pbxproj Resources 登记 × BaziFont 探测 PostScript 名
/// 三者任一断裂都是**静默**视觉降级——探测 miss 后回退系统 Songti SC,衬线观感
/// 极接近,编译绿 + 测试绿 + 人眼都可能漏(pbxproj 漏登记=静默不进 bundle 是
/// 本仓已知陷阱)。此处对 test host(即 App 进程,UIAppFonts 已加载)直接断言
/// 两个打包名可命中,锁死注册链。字体**字符集**覆盖由 `tools/build_songti_fonts.py
/// --verify` 把关(硬性字符 FAIL),不在本测试范围。
final class FontRegistrationTests: XCTestCase {

    func test_bundledSongtiSC_registeredByPostScriptName() {
        XCTAssertNotNil(
            UIFont(name: "QiSongti-Regular", size: 12),
            "QiSongti-Regular 未注册:查 Info.plist UIAppFonts 条目、pbxproj Resources 登记"
                + "(4 处 ID 一致)与构建产物 nameID 6(tools/build_songti_fonts.py --verify)"
        )
    }

    func test_bundledSongtiTC_registeredByPostScriptName() {
        XCTAssertNotNil(
            UIFont(name: "QiSongtiTC-Regular", size: 12),
            "QiSongtiTC-Regular 未注册:查 Info.plist UIAppFonts 条目、pbxproj Resources 登记"
                + "(4 处 ID 一致)与构建产物 nameID 6(tools/build_songti_fonts.py --verify)"
        )
    }
}
