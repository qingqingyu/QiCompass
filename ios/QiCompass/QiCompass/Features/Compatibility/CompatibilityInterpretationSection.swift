import SwiftUI

/// 合盘 AI 解读段(D9;2026-10-01 Match 重构:章节目录形态 + 自动生成)。
///
/// **独立 error 态 + 禁词拦截提示**:定性评估 + 流年同步表已就绪即视为合盘成功;
/// AI 子状态独立 error,可单独重试,不污染整体 ready。
///
/// 2026-10-01 改版(BP Match 设计板 #7/#11/#13,用户拍板):
/// - 章节目录形态对齐深度解析命书目录:NumeralBadge 实线圆 = 已开章、虚线圆 =
///   付费章 + PaidTag 朱红小标,免费章正文随行展开(与 lock.fill 行列表旧形态
///   互斥,PaidChaptersLockView 退役)
/// - 去元信息:剩余次数 / 24h 缓存徽章不上屏(对齐今日页 V4 先例;次数用尽态
///   DailyLimitReachedView 保留——它解释失败,不是元信息)
/// - 手动「生成合盘解读」CTA 拔除:idle 且次数未耗尽由 VM 自动起链(#13,
///   `openDetail` 缓存查询收尾触发),UI 的 idle/fetching 同呈推演态
struct CompatibilityInterpretationSection: View {
    let state: InterpretState
    let remainingReads: Int
    let nextReset: Date
    let onRetry: () -> Void
    let onShowPaywall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch state {
            case .idle:
                // 次数耗尽保持 .idle(VM 不自动起链);否则 idle 是自动起链的
                // 瞬态,与 .fetching 同呈推演态
                if remainingReads <= 0 {
                    DailyLimitReachedView(nextReset: nextReset)
                } else {
                    GeneratingDots()
                }
            case .fetching:
                GeneratingDots()
            case .okFree(let text, _):
                chapterList(freeText: text)
            case .okPaid(let text, _):
                CompatibilityChapterText(text: text)
                // 2026-08-01 grill-me 决策 #15:不做"再生成"按钮(任何模块)。
            case .lockedPaid:
                // M4 后 .lockedPaid case 不再使用,保留 case 兼容性
                EmptyView()
            case .offlineLegacy(let text, _):
                // 不可达(offlineLegacy 仅每日运势离线兜底产生,合盘 VM 不构造);
                // 为 InterpretState exhaustive switch 完整性保留,渲染正文。
                CompatibilityChapterText(text: text)
            case .failed(let message):
                failedBlock(message)
            case .dailyLimitReached(let nextReset):
                DailyLimitReachedView(nextReset: nextReset)
            }
        }
    }

    // MARK: - 头部(标题 + 免费口径;去剩余次数元信息)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("合盘解读")
                .zcoolCardTitle()
            Spacer(minLength: 12)
            if case .okFree(let text, _) = state {
                Text(Self.freeScopeText(freeText: text))
                    .font(BaziFont.caption(size: 10))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
    }

    /// 免费文实际章数(标题行解析产物;老缓存无标题行按产品契约取 2,
    /// clamp 1...6 防 LLM 超发/欠发)。freeScopeText 与 chapterList 锁定编号
    /// 共用同一值,单一事实源。
    static func freeChapterCount(of freeText: String) -> Int {
        min(max(CompatibilityChapterText.parse(freeText)?.chapters.count ?? 2, 1), 6)
    }

    /// 「共 N 章 · 前 M 章免费」:M = 免费文实际解析出的章数,N = M + 付费 4 章。
    static func freeScopeText(freeText: String) -> String {
        let freeCount = Self.freeChapterCount(of: freeText)
        return String(
            format: String(localized: "共 %lld 章 · 前 %lld 章免费"),
            freeCount + Self.paidChapterTitles.count, freeCount
        )
    }

    /// 付费章名(M4 五行共振改造起的第一章「爱情深度」→「五行共振」,
    /// 与后端 compatibility_paid 模板章名对齐)。
    static let paidChapterTitles = ["五行共振", "合作事业", "财运合拍", "流年同步"]
        .map { String(localized: String.LocalizationValue(stringLiteral: $0)) }

    // MARK: - okFree:免费章展开 + 付费章锁行 + CTA

    private func chapterList(freeText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CompatibilityChapterText(text: freeText)

            let paidStart = Self.freeChapterCount(of: freeText) + 1
            ForEach(Array(Self.paidChapterTitles.enumerated()), id: \.offset) { idx, title in
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(height: 0.5)
                lockedRow(index: paidStart + idx, title: title)
            }

            PrimaryCTAButton(
                title: String(localized: "解锁合盘解读"),
                loadingTitle: String(localized: "处理中…"),
                isLoading: false,
                action: onShowPaywall
            )
            .padding(.top, 18)
        }
    }

    /// 付费章行:虚线圆徽 + 弱墨章名 + 朱红付费标(对齐深度解析目录行语言)。
    private func lockedRow(index: Int, title: String) -> some View {
        HStack(spacing: 14) {
            NumeralBadge(index: index, locked: true, size: 38)
            Text(title)
                .font(BaziFont.display(size: 16.5))
                .tracking(1.5)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer(minLength: 8)
            PaidTag()
        }
        .padding(.vertical, 14)
    }

    // MARK: - 失败态(独立 error,单独重试)

    private func failedBlock(_ message: String) -> some View {
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
    }
}

// MARK: - 推演态(三墨点 breathe;reduce-motion 静态)

private struct GeneratingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private static let dotsBreathing: [Double] = [0.35, 0.65, 1.0]
    private static let dotsStatic: [Double] = [1.0, 0.5, 0.22]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { idx in
                    Circle()
                        .fill(BaziTheme.inkDeep)
                        .frame(width: 8, height: 8)
                        .opacity(breathing ? Self.dotsBreathing[idx] : Self.dotsStatic[idx])
                }
            }
            Text("推演中…")
                .font(BaziFont.caption(size: 11))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "推演中…"))
    }
}

// MARK: - 分章渲染(2026-09-27「章节标题与正文挤同段」修复;2026-10-01 目录化)

/// 合盘解读分章排版:后端 v4 prompt 要求每章标题独立成行(「第一章 基础相处
/// 模式」/ "Chapter 1 …"),本视图按行解析出标题并样式化,章行 = NumeralBadge
/// 实线圆 + 楷体章名(对齐深度解析命书目录行语言),正文段缩进对齐章名。
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
            VStack(alignment: .leading, spacing: 0) {
                if let lead, !lead.isEmpty {
                    Text(MarkdownSanitizer.rendered(lead))
                        .bodySerifText()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 14)
                }
                ForEach(Array(chapters.enumerated()), id: \.offset) { idx, chapter in
                    if idx > 0 {
                        Rectangle()
                            .fill(BaziTheme.hairline)
                            .frame(height: 0.5)
                    }
                    chapterBody(chapter, badgeIndex: idx + 1)
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

    /// 单章:NumeralBadge 实线圆 + 楷体章名 + 行尾墨点(已读语义,对齐深度解析
    /// 目录行);正文段缩进对齐章名(52 = 徽 38 + 行距 14)。
    private func chapterBody(_ chapter: Chapter, badgeIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                NumeralBadge(index: badgeIndex, locked: false, size: 38)
                Text(chapter.title)
                    .font(BaziFont.display(size: 16.5))
                    .tracking(1.5)
                    .foregroundStyle(BaziTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Circle()
                    .fill(BaziTheme.ink)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
            }
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, p in
                    Text(MarkdownSanitizer.rendered(p))
                        .bodySerifText()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 52)
            .padding(.trailing, 4)
            .padding(.bottom, 16)
        }
    }
}
