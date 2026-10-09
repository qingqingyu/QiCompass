import SwiftUI

// MARK: - 章节结构化正文排版(2026-09-02;2026-10-09 按用户 HTML 目标稿改版)
//
// ChapterContent 节点树的视觉层,版面语言对齐 DESIGN.md(水墨孤本):
// - 引言/正文 = 楷体 16 · 行距 ~1.65× · 首行缩进 2em(2026-10-09 目标稿:
//   收 09-01 的 2.15× 疏朗口径,EN/zh 统一密度,不再分档)
// - 小节题   = 前置短墨横(16×1.5)+ 楷体 20pt tracking 1;嵌套小节 15.5pt 墨青降级
// - 键值行   = 标签 caption 11.5 墨灰 + 值楷体 16;「据/注」小字注 12.5pt
// - 条目列   = 「·」条目楷体 15
// - 条目卡   = 题楷体 16 + 字段,卡间 hairline 分隔(卡片让位 hairline)
// 无卡片底 / 无渐变 / 朱红不进。纯展示,数据源单一(ChapterContent)。

struct ChapterContentView: View {
    let content: ChapterContent

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(Array(content.nodes.enumerated()), id: \.offset) { _, node in
                NodeView(node: node, depth: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 节点排版(递归;depth 控制嵌套小节的降级样式)。
private struct NodeView: View {
    let node: ChapterNode
    let depth: CGFloat

    var body: some View {
        switch node {
        case .lead(let text):
            leadParagraph(text)
        case .note(let label, let text):
            Text("\(label) · \(text)")
                .font(BaziFont.caption(size: 12.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        case .section(let title, let children):
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(title)
                // S4 M1 三层引导句(R12:天赋/训练/防御三层内容已具备,差一句
                // 「这一节是什么」;静态映射,只挂天赋章三节,其余章节不受影响)
                if let guide = Self.sectionGuide(forSectionTitle: title) {
                    Text(guide)
                        .font(BaziFont.caption(size: 12.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    NodeView(node: child, depth: depth + 1)
                }
            }
        case .fields(let fields):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    fieldRow(field)
                }
            }
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("· \(item)")
                        .font(BaziFont.body(size: 15))
                        .foregroundStyle(BaziTheme.ink)
                        .lineSpacing(valueLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .items(let items):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    itemView(item)
                    if index < items.count - 1 {
                        Rectangle()
                            .fill(BaziTheme.hairline)
                            .frame(height: 0.5)
                    }
                }
            }
        }
    }

    // MARK: - 原子

    /// M1 三节引导句(schema key → 一句人话)。第二人称、不带吉凶,对齐
    /// §AI Voice 语言层级。
    ///
    /// 查找在 body 侧经 `sectionGuideTitle` 完成:key 必须用与节题渲染**完全
    /// 相同的本地化查找**生成——节题经 `ChapterContent.label(_:)`(即
    /// `deepanalysis.chapter.<key>` 的 xcstrings 查询)本地化,EN 下是
    /// "Innate"/"Trained"/"Defensive",静态 zh 硬编码 key 会永不命中
    /// (引导句在 EN 整体静默缺失)。两侧同源后,改译文/加语言都不会漂移。
    private static let sectionGuides: [String: String] = [
        "innate": String(localized: "用起来不累,反而回血的能力。"),
        "trained": String(localized: "环境逼出来的本事,好用但有代价。"),
        "defensive": String(localized: "看着像优点,其实在消耗你。"),
    ]

    /// 引导句 key → 节题本地化值(委托 `ChapterContent.localizedLabel`,
    /// 与节题渲染同一实现——两侧永不漂移)。
    private static func sectionGuideTitle(_ key: String) -> String {
        ChapterContent.localizedLabel(key)
    }

    /// 节题(已本地化)→ 引导句。节题必须经 `sectionGuideTitle` 反查而非
    /// 硬编码 zh 字面量(见 `sectionGuides` 注释)。
    private static func sectionGuide(forSectionTitle title: String) -> String? {
        for key in sectionGuides.keys where sectionGuideTitle(key) == title {
            return sectionGuides[key]
        }
        return nil
    }

    /// 正文行距(2026-10-09 目标稿):统一 ~1.65× 密度,EN/zh 不再分档。
    private var proseLineSpacing: CGFloat { 7 }
    /// 键值/条目行距同款。
    private var valueLineSpacing: CGFloat { 4 }

    /// 引言段:与阅读页散文态同规格(16pt · 行距 ~1.65× · 缩进 2em)。
    private func leadParagraph(_ text: String) -> some View {
        Text("　　" + text)
            .bodySerifText(size: 16)
            .lineSpacing(proseLineSpacing)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 小节题:顶层短墨横(16×1.5)+ 楷体 20;嵌套小节去横、字级降 15.5、墨灰。
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if depth == 0 {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(BaziTheme.ink)
                    .frame(width: 16, height: 1.5)
                Text(title)
                    .font(BaziFont.display(size: 20))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
            }
        } else {
            Text(title)
                .font(BaziFont.display(size: 15.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    /// 键值行:标签小字 + 值楷体 16;「据/注」类压成一行小字注。
    @ViewBuilder
    private func fieldRow(_ field: ChapterField) -> some View {
        if field.isNote {
            Text("\(field.label) · \(field.value)")
                .font(BaziFont.caption(size: 12.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                    .font(BaziFont.caption(size: 11.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                Text(field.value)
                    .bodySerifText(size: 16)
                    .lineSpacing(valueLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 条目卡:题(可空)+ 键值组 + 条目列,上下 12pt 呼吸。
    private func itemView(_ item: ChapterItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = item.title {
                Text(title)
                    .font(BaziFont.display(size: 16))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.fields.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                        fieldRow(field)
                    }
                }
            }
            if !item.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.bullets.enumerated()), id: \.offset) { _, bullet in
                        Text("· \(bullet)")
                            .font(BaziFont.body(size: 15))
                            .foregroundStyle(BaziTheme.ink)
                            .lineSpacing(valueLineSpacing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 12)
    }
}
