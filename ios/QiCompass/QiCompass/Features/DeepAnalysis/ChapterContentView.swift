import SwiftUI

// MARK: - 章节结构化正文排版(2026-09-02)
//
// ChapterContent 节点树的视觉层,版面语言对齐 DESIGN.md(水墨孤本):
// - 引言/正文 = 楷体 15.5 · 行距 2.15× · 首行缩进 2em(与散文态同规格,§Body)
// - 小节题   = 前置短墨横(12×1.2)+ 楷体 14pt tracking 3;嵌套小节 12pt 墨青降级
// - 键值行   = 标签 caption 11.5 墨灰 + 值楷体 14.5;「据/注」小字注 11pt
// - 条目列   = 「·」条目楷体 14.5
// - 条目卡   = 题楷体 14.5 + 字段,卡间 hairline 分隔(卡片让位 hairline)
// 无卡片底 / 无渐变 / 朱红不进。纯展示,数据源单一(ChapterContent)。

struct ChapterContentView: View {
    let content: ChapterContent

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .section(let title, let children):
            VStack(alignment: .leading, spacing: 11) {
                sectionHeader(title)
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    NodeView(node: child, depth: depth + 1)
                }
            }
        case .fields(let fields):
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    fieldRow(field)
                }
            }
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("· \(item)")
                        .font(BaziFont.body(size: 14.5))
                        .foregroundStyle(BaziTheme.ink)
                        .lineSpacing(16)
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

    /// 引言段:与阅读页散文态同规格(15.5pt · 行距 2.15× · 缩进 2em)。
    private func leadParagraph(_ text: String) -> some View {
        Text("　　" + text)
            .bodySerifText(size: 15.5)
            .lineSpacing(18)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 小节题:顶层短墨横 + 楷体;嵌套小节去横、字级降 12、墨灰。
    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if depth == 0 {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(BaziTheme.ink)
                    .frame(width: 12, height: 1.2)
                Text(title)
                    .font(BaziFont.display(size: 14))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.ink)
            }
        } else {
            Text(title)
                .font(BaziFont.display(size: 12))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    /// 键值行:标签小字 + 值楷体;「据/注」类压成一行小字注。
    @ViewBuilder
    private func fieldRow(_ field: ChapterField) -> some View {
        if field.isNote {
            Text("\(field.label) · \(field.value)")
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                    .font(BaziFont.caption(size: 11.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                Text(field.value)
                    .bodySerifText(size: 14.5)
                    .lineSpacing(16)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 条目卡:题(可空)+ 键值组 + 条目列,上下 10pt 呼吸。
    private func itemView(_ item: ChapterItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = item.title {
                Text(title)
                    .font(BaziFont.display(size: 14.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.fields.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.fields.enumerated()), id: \.offset) { _, field in
                        fieldRow(field)
                    }
                }
            }
            if !item.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(item.bullets.enumerated()), id: \.offset) { _, bullet in
                        Text("· \(bullet)")
                            .font(BaziFont.body(size: 14.5))
                            .foregroundStyle(BaziTheme.ink)
                            .lineSpacing(16)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }
}
