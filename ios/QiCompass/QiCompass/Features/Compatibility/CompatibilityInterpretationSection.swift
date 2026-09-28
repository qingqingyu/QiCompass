import SwiftUI

/// 合盘 AI 解读段(D9 + DESIGN.md §Color)。
///
/// **独立 error 态 + 禁词拦截提示**:定性评估 + 流年同步表已就绪即视为合盘成功;
/// AI 子状态独立 error,可单独重试,不污染整体 ready。
///
/// 不复用 DailyInterpretationSection:字数(2026-08-01 grill-me V2 后 1200-1800 字,
/// 6 章 × 200-300 字 Medium voice)/ 标题 / 模块不同。
struct CompatibilityInterpretationSection: View {
    let state: InterpretState
    let remainingReads: Int
    let nextReset: Date
    let onGenerate: () -> Void
    let onRetry: () -> Void
    let onShowPaywall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("合盘解读")
                    .zcoolCardTitle()
                Spacer()
                Text("剩余 \(remainingReads) 次")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            switch state {
            case .idle:
                if remainingReads <= 0 {
                    DailyLimitReachedView(nextReset: nextReset)
                } else {
                    interpretationCTABlock(isLoading: false)
                }
            case .fetching:
                interpretationCTABlock(isLoading: true)
            case .okFree(let text, let cached):
                CompatibilityChapterText(text: text)
                if cached {
                    HStack {
                        Image(systemName: "checkmark.seal")
                        Text("24h 内已缓存,不消耗次数")
                    }
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                }
                Divider()
                    .background(BaziTheme.hairline)
                // M4:未购买 → 显示付费 4 章锁标 + "解锁合盘解读" CTA
                // 五行共振改造(S1):第一章「爱情深度」→「五行共振」,title 对齐产品新定位
                PaidChaptersLockView(
                    previewChapters: ["五行共振", "合作事业", "财运合拍", "流年同步"]
                    .map { String(localized: String.LocalizationValue(stringLiteral: $0)) },
                    title: String(localized: "五行共振·付费章节"),
                    ctaTitle: String(localized: "解锁合盘解读"),
                    onUnlock: onShowPaywall
                )
            case .okPaid(let text, let cached):
                CompatibilityChapterText(text: text)
                if cached {
                    HStack {
                        Image(systemName: "checkmark.seal")
                        Text("24h 内已缓存,不消耗次数")
                    }
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                }
                // 2026-08-01 grill-me 决策 #15:不做"再生成"按钮(任何模块)。
            case .lockedPaid:
                // M4 后 .lockedPaid case 不再使用(改用 .okFree 内嵌锁标),保留 case 兼容性
                EmptyView()
            case .offlineLegacy(let text):
                // 不可达(offlineLegacy 仅每日运势离线兜底产生,合盘 VM 不构造);
                // 为 InterpretState exhaustive switch 完整性保留,渲染正文。
                CompatibilityChapterText(text: text)
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                    Button("重试", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaziTheme.cinnabar)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            case .dailyLimitReached(let nextReset):
                DailyLimitReachedView(nextReset: nextReset)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
            }
        }
        .padding(BaziTheme.Spacing.md)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
    }

    /// idle/fetching 共享 CTA 区(说明文字 + PrimaryCTAButton,loading 时也保留说明)。
    @ViewBuilder
    private func interpretationCTABlock(isLoading: Bool) -> some View {
        VStack(spacing: 12) {
            Text("6 章解读:基础相处 / 互补冲突 / 五行共振 / 合作事业 / 财运合拍 / 流年同步")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            PrimaryCTAButton(
                title: String(localized: "生成合盘解读"),
                loadingTitle: String(localized: "推演中…"),
                isLoading: isLoading,
                action: isLoading ? {} : onGenerate
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// MARK: - 分章渲染(2026-09-27「章节标题与正文挤同段」修复)

/// 合盘解读分章排版:后端 v4 prompt 要求每章标题独立成行(「第一章 基础相处
/// 模式」/ "Chapter 1 …"),本视图按行解析出标题并样式化(大写数字编号 +
/// 楷体章名,对齐深度解析阅读页章题语言),正文段落照排。
///
/// 容错:标题行带全/半角冒号或 `**` 包裹(v3 时代输出习惯)同样解析;
/// 解析不到任何标题行(老缓存散文本)→ `parse` 返回 nil,退回整段渲染,不丢内容。
/// internal 供 Tests 直测 parse(视图本身仅本文件渲染用)。
struct CompatibilityChapterText: View {
    let text: String

    /// 章节:大写数字编号 + 章名 + 正文段落(空行分段)。
    struct Chapter: Equatable {
        let numeral: String
        let title: String
        let paragraphs: [String]
    }

    /// 标题行解析产物;nil = 全文无标题行(调用方退整段)。
    /// lead = 首个标题行之前的正文(引言,v4 契约下通常为空,防御保留)。
    static func parse(_ text: String) -> (lead: String?, chapters: [Chapter])? {
        var leadLines: [String] = []
        var chapters: [Chapter] = []
        var numeral = ""
        var title = ""
        var paragraph: [String] = []
        var paragraphs: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                // 段内保留原始换行(en 单词间距/中文完整性都保真,不拼接),
                // 空行才是段落边界
                paragraphs.append(paragraph.joined(separator: "\n"))
                paragraph = []
            }
        }

        func flushChapter() {
            flushParagraph()
            if !title.isEmpty {
                chapters.append(Chapter(numeral: numeral, title: title, paragraphs: paragraphs))
                numeral = ""
                title = ""
                paragraphs = []
            }
        }

        for line in text.components(separatedBy: .newlines) {
            if let hit = Self.parseTitleLine(line) {
                flushChapter()
                numeral = hit.numeral
                title = hit.title
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if title.isEmpty && chapters.isEmpty {
                    // 引言区空行:跳过(lead 单段呈现,不保留空行)
                } else {
                    flushParagraph()
                }
            } else {
                if title.isEmpty && chapters.isEmpty {
                    leadLines.append(line)
                } else {
                    paragraph.append(line)
                }
            }
        }
        flushChapter()

        guard !chapters.isEmpty else { return nil }
        let lead = leadLines.filter { !$0.isEmpty }.isEmpty
            ? nil
            : leadLines.joined(separator: "\n")
        return (lead, chapters)
    }

    /// 单行标题解析:zh「第X章 章名」(容错 :/:/无分隔)/ en "Chapter N Title"。
    /// 容忍 LLM 违约的 `**` 包裹与行首缩进。
    private static func parseTitleLine(_ line: String) -> (numeral: String, title: String)? {
        let zhNumeral: [Character: String] = [
            "一": "壹", "二": "贰", "三": "叁", "四": "肆",
            "五": "伍", "六": "陆", "七": "柒", "八": "捌",
        ]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // 去 ** 包裹(v3 时代模型习惯,防御)
        var body = trimmed
        if body.hasPrefix("**") { body = String(body.dropFirst(2)) }
        if body.hasSuffix("**") { body = String(body.dropLast(2)) }
        body = body.trimmingCharacters(in: .whitespaces)

        // zh:第X章[ ::]?章名
        if body.hasPrefix("第"), body.count >= 4 {
            let indexAfter = body.index(body.startIndex, offsetBy: 1)
            let zhangIndex = body.index(indexAfter, offsetBy: 1)
            if let numeral = zhNumeral[body[indexAfter]],
               body[zhangIndex] == "章" {
                let rest = String(body[body.index(after: zhangIndex)...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \t：:"))
                if !rest.isEmpty {
                    return (numeral, rest)
                }
            }
        }

        // en:Chapter N[.::]? Title
        // 2026-09-28 修复:序号后粘着分隔符("Chapter 1: Title" 的 "1:"、"Chapter 1. Title"
        // 的 "1.")原实现 Int(parts[1]) 恒 nil → 整篇退化成无分章单块;trim 作用于
        // 序号而非标题(zh 分支同款字符集)。
        let parts = body.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if parts.count == 3, parts[0] == "Chapter",
           let n = Int(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".：:"))),
           (1...8).contains(n) {
            let numeralEn = ["壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌"][n - 1]
            let rest = parts[2].trimmingCharacters(in: CharacterSet(charactersIn: ".：:"))
            if !rest.isEmpty {
                return (numeralEn, rest)
            }
        }
        return nil
    }

    var body: some View {
        if let (lead, chapters) = Self.parse(text) {
            VStack(alignment: .leading, spacing: 18) {
                if let lead, !lead.isEmpty {
                    Text(MarkdownSanitizer.rendered(lead))
                        .bodySerifText()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                    chapterBody(chapter)
                }
            }
            .fadeIn()
        } else {
            // 老缓存/违约输出无标题行:整段渲染(现状排版,不丢内容)
            Text(MarkdownSanitizer.rendered(text))
                .bodySerifText()
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .fadeIn()
        }
    }

    /// 单章:大写数字编号 + 楷体章名(章题语言对齐深度解析阅读页)+ 正文段。
    private func chapterBody(_ chapter: Chapter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(chapter.numeral)
                    .font(BaziFont.display(size: 18))
                    .foregroundStyle(BaziTheme.ink)
                Text(chapter.title)
                    .font(BaziFont.display(size: 15))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(2)
            }
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
                .padding(.trailing, 60)
            ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, p in
                Text(MarkdownSanitizer.rendered(p))
                    .bodySerifText()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
