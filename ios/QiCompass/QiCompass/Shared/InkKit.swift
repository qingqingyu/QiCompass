import SwiftUI

// MARK: - InkKit · 水墨孤本组件全家桶
//
// 视觉事实源:DESIGN.md §水墨孤本(Signature elements)+ docs/design-ref/shuimo/ 参考屏。
// 六件套:VText 竖排 / EnsoView 墨圆 / SealStamp 朱印 / PaperGrain 纸纹 /
//         NumeralBadge 大写数字徽 / PaidTag 付费标。
// 全部纯 SwiftUI,零图片资产、零第三方依赖;动效三式(ink-in / stamp / breathe)
// 均尊重 reduce-motion。

// MARK: 竖排文字

/// 竖排文字(VStack 逐字堆叠,泛化 Onboarding SutraView 模式)。
///
/// 适用 ≤20 字的标题 / 经文 / 批语 / 加载文案。标点不做字角位修正(v1 取舍:
/// 短句中标点少,竖排逐字已足够古籍感)。长文横排走常规 Text。
///
/// **英文回退(2026-08-26,DESIGN.md Decisions Log)**:拉丁字母逐字竖排不可读,
/// 短语不含 CJK 字符时自动横排 italic(沿用 SutraView 非中文分支的文学感处理)。
/// 品牌字(玄机问道/干支)始终中文,不受影响。
struct VText: View {
    let phrase: String
    var size: CGFloat
    /// 字间距(pt,竖排即行进方向间距;横排回退时用作 kerning 近似)。
    var tracking: CGFloat = 6
    var color: Color = BaziTheme.ink

    var body: some View {
        if Self.containsCJK(phrase) {
            VStack(spacing: tracking) {
                ForEach(Array(phrase.enumerated()), id: \.offset) { _, char in
                    Text(String(char))
                        .font(BaziFont.display(size: size, weight: .medium))
                        .foregroundStyle(color)
                }
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(phrase)
        } else {
            Text(phrase)
                .font(BaziFont.display(size: size, weight: .medium))
                .tracking(min(tracking, size * 0.18))
                .italic()
                .foregroundStyle(color)
                .multilineTextAlignment(.center)
        }
    }

    /// 是否含 CJK 表意字符(汉/扩展 A/兼容表意)。纯拉丁/数字/标点 → false 走横排。
    private static func containsCJK(_ phrase: String) -> Bool {
        phrase.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }
    }
}

// MARK: 墨圆

/// 墨圆(enso):开放笔触的圆,水墨孤本的品牌指纹。
///
/// 双弧笔触(主弧 + 飞白弧)+ 确定性枯笔墨点,纯 SwiftUI 无图片:
/// - 入场:ink-in(trim 0→1 + blur 7→0,1.2s easeOut)
/// - 常驻:可选 breathe(opacity 1↔0.92,7s 循环,极缓呼吸)
/// - reduce-motion:跳过入场动画与呼吸,静态呈现
struct EnsoView: View {
    var size: CGFloat
    /// 主弧笔宽,默认 size × 0.063(参考屏 19/300 比例)。
    var strokeWidth: CGFloat?
    var breathing = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var breathingOn = false

    private var stroke: CGFloat { strokeWidth ?? size * 0.063 }

    var body: some View {
        ZStack {
            // 主弧:约 84% 圆周,起收笔留缺口
            Circle()
                .trim(from: 0.05, to: 0.05 + 0.84 * progress)
                .stroke(BaziTheme.inkDeep,
                        style: StrokeStyle(lineWidth: stroke, lineCap: .round))
            // 飞白弧:收笔方向的细弧,半透明
            Circle()
                .trim(from: 0.90, to: 0.90 + 0.085 * progress)
                .stroke(BaziTheme.inkDeep.opacity(0.55),
                        style: StrokeStyle(lineWidth: stroke * 0.32, lineCap: .round))
            // 枯笔墨点:确定性位置,入场尾段浮现
            dryBrushSpecks
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(-8))
        .blur(radius: (1 - progress) * 7)
        .opacity(breathingOn ? 0.92 : 1)
        .onAppear {
            if reduceMotion {
                progress = 1
            } else {
                withAnimation(.easeOut(duration: 1.2).delay(0.1)) {
                    progress = 1
                }
                if breathing {
                    withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true).delay(1.5)) {
                        breathingOn = true
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// 三粒枯笔墨点(固定相对坐标,不随布局随机)。
    @ViewBuilder
    private var dryBrushSpecks: some View {
        let reveal = max(0, Double(progress - 0.85)) / 0.15
        if reveal > 0 {
            Group {
                ellipseSpeck(relative: CGPoint(x: 0.28, y: 0.70), w: 0.023, h: 0.008, angle: -32)
                ellipseSpeck(relative: CGPoint(x: 0.80, y: 0.65), w: 0.017, h: 0.006, angle: 52)
                ellipseSpeck(relative: CGPoint(x: 0.40, y: 0.25), w: 0.014, h: 0.005, angle: 24)
            }
            .opacity(0.3 * reveal)
        }
    }

    private func ellipseSpeck(relative: CGPoint, w: CGFloat, h: CGFloat, angle: Double) -> some View {
        Ellipse()
            .fill(BaziTheme.inkDeep)
            .frame(width: size * w, height: size * h)
            .rotationEffect(.degrees(angle))
            .position(x: size * relative.x, y: size * relative.y)
    }
}

// MARK: 朱印

/// 朱印:朱底方印白字(水墨孤本版,2026-08-26)+ 朱文空心印变体(outlined)。
///
/// 朱红纪律(DESIGN.md §Color):本组件是 cinnabar 实底的**授权场景之一**
/// (SealStamp / PaidTag / 聚焦线 / 当前时辰点 / 在读态),其余场景禁朱底。
/// 入场:stamp(scale 1.9→1 spring 回弹);reduce-motion 直出静态。
///
/// 两种印面:`outlined = false` 实印(朱底白字);`outlined = true` 朱文空心印
/// (朱描边 + 朱字,纸底透出,hepan-h3-detail.html `.vs` 形态),合盘双柱中轴用。
///
/// 注意:OnboardingView.swift 内旧版同名 private 印章(淡底圆)在其文件内遮蔽本组件,
/// Phase 2 重写 Welcome 页时删除旧版改用本组件。
struct SealStamp: View {
    let character: String
    var size: CGFloat = 28
    /// 轻微旋转,印不会盖得太正。
    var rotation: Double = 3
    /// 落印动画延迟(秒)。nil = 不播动画静态呈现。
    var stampDelay: Double? = 0
    /// 印面与字之间是否留白边距(小印留 1pt,大印按比例)。仅实印生效。
    var insetBorder = true
    /// 朱文空心印变体:朱描边(50%)+ 朱字,无底色(纸底透出)。
    var outlined = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stamped = false

    var body: some View {
        Text(character)
            .font(BaziFont.display(size: size * 0.52, weight: .medium))
            .foregroundStyle(outlined ? BaziTheme.cinnabar : BaziTheme.paper)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.07)
                    .fill(outlined ? Color.clear : BaziTheme.cinnabar)
            )
            .overlay(
                // 实印:纸色内衬细框(留白边);空心印:朱描边(50%)即印面本体,1pt 贴框。
                RoundedRectangle(cornerRadius: size * 0.07)
                    .strokeBorder(
                        outlined ? BaziTheme.cinnabar.opacity(0.5) : BaziTheme.paper.opacity(0.35),
                        lineWidth: outlined ? 1 : max(1, size * 0.045)
                    )
                    .padding(outlined ? 0 : max(1, size * 0.06))
                    .opacity(outlined || insetBorder ? 1 : 0)
            )
            .rotationEffect(.degrees(rotation))
            .scaleEffect(stamped ? 1 : 1.9)
            .opacity(stamped ? 0.94 : 0)
            .onAppear {
                guard let delay = stampDelay, stamped == false else {
                    stamped = true
                    return
                }
                if reduceMotion {
                    stamped = true
                } else {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.62).delay(delay)) {
                        stamped = true
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("印章\(character)")
    }
}

// MARK: 纸纹

/// 纸纹:确定性噪点 Canvas,冷宣纸的颗粒底。
///
/// 全 App 只在 RootTabView 背景级挂一次(overlay + allowsHitTesting(false)),
/// 不逐屏叠加。seed 固定 → 无逐帧闪烁;drawingGroup 离屏缓存,开销一次性。
/// multiply 混合让噪点"长在纸上"而不是"浮在内容上";暗色下噪点自然衰减。
struct PaperGrain: View {
    var opacity: Double = 0.05

    /// SplitMix64 — 稳定 PRNG,同一 seed 全设备同噪点。
    private struct SeededRandom {
        var state: UInt64
        mutating func next() -> CGFloat {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return CGFloat(z &* 2685821657736338717 >> 11) / CGFloat(9007199254740992)
        }
    }

    var body: some View {
        Canvas { context, size in
            var rng = SeededRandom(state: 2_026_082_6)
            let count = max(240, Int(size.width * size.height / 1_100))
            for _ in 0..<count {
                let x = rng.next() * size.width
                let y = rng.next() * size.height
                let r = 0.4 + rng.next() * 0.9
                let gray = 0.08 + rng.next() * 0.26
                context.fill(
                    Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                    with: .color(Color(red: gray, green: gray, blue: gray, opacity: opacity))
                )
            }
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
        .drawingGroup()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: 大写数字徽

/// 章节大写数字圆徽(捌章卷轴编号):实线圆 = 可读,虚线圆 = 锁定。
struct NumeralBadge: View {
    let index: Int
    var locked = false
    var size: CGFloat = 40

    /// 大写数字查表(零-拾);越界回退阿拉伯数字,不静默错位。
    static func numeral(_ i: Int) -> String {
        let table = ["零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖", "拾"]
        guard table.indices.contains(i) else { return String(i) }
        return table[i]
    }

    var body: some View {
        Circle()
            .stroke(
                locked ? BaziTheme.hairlineDashed : BaziTheme.ink.opacity(0.4),
                style: StrokeStyle(
                    lineWidth: 1,
                    dash: locked ? [4, 3] : []
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(Self.numeral(index))
                    .font(BaziFont.display(size: size * 0.4, weight: .medium))
                    .foregroundStyle(locked ? BaziTheme.inkMutedSecondary : BaziTheme.ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("第\(Self.numeral(index))章\(locked ? ",未解锁" : "")")
    }
}

// MARK: 流式换行布局

/// 流式换行布局(chip 按内容宽逐个排,放不下换行;水墨两问输入的 chip 组用)。
///
/// SwiftUI 原生 `Layout` 协议(iOS 16+),零依赖。参考屏
/// deep-p4-input.html `.chips` 的 flex-wrap 行为:行内/行间同一 spacing,
/// 不做行末对齐拉伸(chip 保持内容宽,留白驱动)。
struct FlowLayout: Layout {
    /// 行内与行间间距(同一值,对齐原型 gap: 10px)。
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(
            width: proposal.width ?? max(0, x - spacing),
            height: subviews.isEmpty ? 0 : y + rowHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: 付费标

/// 「付费」白字朱底小方标,旋转 -6°(全 App 唯一朱底块场景之二,另一是 SealStamp)。
struct PaidTag: View {
    var text = "付费"

    var body: some View {
        Text(text)
            .font(BaziFont.caption(size: 9))
            .foregroundStyle(BaziTheme.paper)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(BaziTheme.cinnabar)
            )
            .rotationEffect(.degrees(-6))
            .accessibilityLabel("\(text)内容")
    }
}
