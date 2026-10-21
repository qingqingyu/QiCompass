import SwiftUI

// MARK: - 章节结构化正文排版(2026-09-02;2026-10-09 按用户 HTML 目标稿改版;
// 2026-10-21 按用户四版对比稿选定 A′「结论即标题,段首不缩进」)
//
// ChapterContent 节点树的视觉层,版面语言对齐 DESIGN.md(水墨孤本):
// - 引言/正文 = 宋体 16 · 行距 ~1.65× · 不缩进,段间距 16(2026-10-21 A′
//   修订 10-09 的首行缩进 2em;文内换行经 `leadParagraphs` 拆段)
// - 小节题   = 前置短墨横(16×1.5)+ 宋体 20pt tracking 1;嵌套小节 15.5pt 墨灰降级;
//   章内含结论句(.headline)时本章所有小节题降为小标:12.5pt 墨灰 + 12×1 短横(A′)
// - 结论句   = 宋体 21pt(仅 M0 v9+ 章节出现,层级主角;A′ 由 17pt 升)
// - 键值行   = 标签 caption 11.5 墨灰 + 值宋体 16;「据/注」小字注 12.5pt
// - 条目列   = 「·」条目宋体 15
// - 条目卡   = 题宋体 16 + 字段,卡间 hairline 分隔(卡片让位 hairline)
// 无卡片底 / 无渐变 / 朱红不进。纯展示,数据源单一(ChapterContent)。

struct ChapterContentView: View {
    let content: ChapterContent

    var body: some View {
        // 含结论句的章节(M0 v9+)小节间距放大 44,只用留白不加线(A′);
        // 其余章节(含 v7/v8 老缓存)照旧 28。
        VStack(alignment: .leading, spacing: content.containsHeadline ? 44 : 28) {
            ForEach(Array(content.nodes.enumerated()), id: \.offset) { _, node in
                NodeView(node: node, depth: 0, chapterHasHeadline: content.containsHeadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 节点排版(递归;depth 控制嵌套小节的降级样式;chapterHasHeadline 是
/// 整章级结论句标记,与顶层 spacing 同源)。
private struct NodeView: View {
    let node: ChapterNode
    let depth: CGFloat
    let chapterHasHeadline: Bool

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
            // A′(2026-10-21,同日 review 修订):小标按**整章**判定——章内
            // 含任一结论句(containsHeadline)则本章所有小节统一小标,21pt
            // 结论句接管层级主角。不按节判定:模型偶发漏写某节 headline
            // (v10 实测漏过 capability_source.headline),按节判定会让该节
            // 回退 20pt 大标题,同章两种样式混排。判定只看章内节点形态,
            // 不按章节号硬编码(目前仅 M0 v9+ 组装产出 .headline);老缓存
            // 章无结论句,小节照旧 20pt + 墨横。
            let opensWithHeadline = children.first.map { node in
                if case .headline = node { return true }
                return false
            } ?? false
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(title, smallStyle: chapterHasHeadline)
                // S4 M1 三层引导句(R12:天赋/训练/防御三层内容已具备,差一句
                // 「这一节是什么」;静态映射,只挂天赋章三节,其余章节不受影响)
                if let guide = Self.sectionGuide(forSectionTitle: title) {
                    Text(guide)
                        .font(BaziFont.caption(size: 12.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    NodeView(node: child, depth: depth + 1, chapterHasHeadline: chapterHasHeadline)
                        // 结论句与后续正文间距 14pt(A′):容器 spacing 16 上收 2pt
                        // (只对本节真实存在的 headline 生效;漏写 headline 的节
                        // 首个正文段照常 16pt)
                        .padding(.top, index == 1 && opensWithHeadline ? -2 : 0)
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
        case .inlineLabel(let label, let text):
            inlineLabelParagraph(label: label, text: text)
        case .headline(let text):
            headlineParagraph(text)
        case .loopFromTo(let from, let to):
            loopFromToLine(from: from, to: to)
        case .evidenceFold(let notes):
            EvidenceFoldView(notes: notes)
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
    /// 结论句行距(A′ 2026-10-21):21pt 大字,行距 ~1.5×((25.2+6)/21),
    /// 略收于正文;17pt 时代同为 6pt,升字号后自然落在 1.5× 口径上。
    private var headlineLineSpacing: CGFloat { 6 }

    /// 引言段:与阅读页散文态同规格(16pt · 行距 ~1.65× · 不缩进,A′)。
    /// 文内换行经 `ChapterContent.leadParagraphs` 拆段(M0 v11 leak 三段 /
    /// 老内容偶发换行),段间距 16pt——拆分单源于模型层,散文档走同一实现。
    private func leadParagraph(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(
                Array(ChapterContent.leadParagraphs(text).enumerated()),
                id: \.offset
            ) { _, paragraph in
                Text(paragraph)
                    .bodySerifText(size: 16)
                    .lineSpacing(proseLineSpacing)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 小节题:顶层短墨横(16×1.5)+ 宋体 20;嵌套小节去横、字级降 15.5、墨灰。
    /// A′(2026-10-21,同日 review 修订):章内含结论句(containsHeadline)时
    /// 本章**所有**小节题统一降为小标——12.5pt 墨灰 tracking 2 + 前置 12×1
    /// 墨灰短横,不加新颜色/字重/字体(按整章判定防混排,见 .section case)。
    @ViewBuilder
    private func sectionHeader(_ title: String, smallStyle: Bool) -> some View {
        if smallStyle {
            HStack(spacing: 8) {
                Rectangle()
                    .fill(BaziTheme.inkMuted)
                    .frame(width: 12, height: 1)
                Text(title)
                    .font(BaziFont.caption(size: 12.5))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
        } else if depth == 0 {
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

    /// 键值行:标签小字 + 值宋体 16;「据/注」类压成一行小字注。
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

    /// 行内标签段(M0,2026-10-12 S4-A):段首小标签 + 「 · 」+ 正文连排,
    /// 取代 caption 标签行 + 值的上下两行结构——读感像书页段落不像表单。
    /// 换行续行回全文宽(标签只在段首),与「据 · 」小字注同一符号语言。
    /// 拼接只可用 Text 级 modifier(font/foregroundStyle 返回 Text;
    /// bodySerifText 返回 View 不能进拼接,lineSpacing 挂整段)。
    private func inlineLabelParagraph(label: String, text: String) -> some View {
        (Text(label)
            .font(BaziFont.caption(size: 11.5))
            .tracking(1)
            .foregroundStyle(BaziTheme.inkMuted)
        + Text(" · ")
            .font(BaziFont.caption(size: 12.5))
            .foregroundStyle(BaziTheme.inkMutedSecondary)
        + Text(text)
            .font(BaziFont.body(size: 16))
            .foregroundStyle(BaziTheme.ink))
            .lineSpacing(valueLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 结论句(M0 v9 白话结论层,2026-10-14;A′ 2026-10-21 升版):每节
    /// 第一层——白话结论,不缩进、无标签,作小节的视觉主角。宋体 `.custom`
    /// 不吃 weight(BaziFont.songti),「加粗」不可用,靠字号(display 21 >
    /// 正文 16)+ 浓墨 + tracking 0.5 区分;不加新颜色、无朱红(DESIGN.md)。
    /// 与后续正文间距 14pt 由小节容器控制(见 .section case)。
    private func headlineParagraph(_ text: String) -> some View {
        Text(text)
            .font(BaziFont.display(size: 21))
            .tracking(0.5)
            .foregroundStyle(BaziTheme.ink)
            .lineSpacing(headlineLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 循环起止一行小字(M0):from/to 两个孤立标签行合成的弱化信息行。
    /// 标签走既有 dot-key 本地化(起点/终点),值是十神名(输出口径已本地)。
    private func loopFromToLine(from: String, to: String) -> some View {
        (Text(ChapterContent.localizedLabel("from"))
            .foregroundStyle(BaziTheme.inkMuted)
        + Text(" \(from)　")
            .foregroundStyle(BaziTheme.ink)
        + Text(ChapterContent.localizedLabel("to"))
            .foregroundStyle(BaziTheme.inkMuted)
        + Text(" \(to)")
            .foregroundStyle(BaziTheme.ink))
            .font(BaziFont.caption(size: 12.5))
            .tracking(0.5)
            .fixedSize(horizontal: false, vertical: true)
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

/// 章末「据」折叠区(M0,2026-10-12 S4-A):各小节的 evidence 从正文里
/// 抽出收拢,默认收起、轻触展开——依据要可查但不打断阅读。视觉沿用
/// 小字注语言(hairline 分隔 + caption 墨灰),无卡片无渐变(DESIGN.md)。
private struct EvidenceFoldView: View {
    let notes: [ChapterNote]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Text(ChapterContent.localizedLabel("evidence"))
                        .font(BaziFont.caption(size: 11.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(BaziFont.caption(size: 10))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
            }
            .buttonStyle(.plain)
            // VoiceOver:展开/收起状态须可闻(2026-10-13 review 修复——
            // 视觉靠 chevron 方向传达,读屏拿不到;Apple 折叠控件惯例用
            // value 报状态)
            .accessibilityLabel(Text(ChapterContent.localizedLabel("evidence")))
            .accessibilityValue(
                expanded ? String(localized: "已展开") : String(localized: "已收起"))
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Text("\(note.label) · \(note.text)")
                            .font(BaziFont.caption(size: 12.5))
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
