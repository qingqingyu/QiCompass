import SwiftUI

// MARK: - 章末「准 / 不准」反馈控件(2026-11-15 拍板:B6 极简 × B9 三拍退场)

/// 定稿动线(HTML 对比稿 tmp/chapter-feedback-compare/ 的 C1/C2,用户拍板):
/// - 静默态:章末落款行左侧只放「准 · 不准」两词(无问句),与「批」印同一行
/// - 点「准」:准字浓墨停一拍(0.4s) → 词组位置换「收到」小字(ink-in 淡入)
///   → 停约一秒整组消失,章末回到批印独处——不留常驻回执
/// - 点「不准」:展开小节 chip(单选、无提示词、无确认按钮);选中一枚先呈
///   选中态停一拍(0.45s) → 收起 chips 并显示「收到」→ 消失
/// - 展开态再点「不准」= 不选小节只记总评,同走「收到」;点「准」= 改选准
/// - 每次有效点击配轻触觉(HapticEngine.light,内部已守 reduce-motion)
///
/// 反馈一次性:控件只问一次,决定即上报(fire-and-forget)+ 本地标记
/// (ChapterFeedbackStore),此后本章不再显示;选后不可改(不留回执的必然
/// 代价,拍板接受)。仅挂正常成文态——与 chapterSeal 同生命周期(异常 /
/// 失败 / 布算中态不盖章也不挂反馈)。
///
/// 上报的 prompt_version / provider / model 由后端从 interpretation_cache
/// 同 (content_hash, module) 最新行 best-effort 反查(见端点注释),客户端
/// 只报展示层事实。
struct ChapterFeedbackControl: View {
    /// 「不准」展开的小节 key(snake_case;module.feedbackSectionKeys)。
    let sections: [String]
    /// 决定即回调(三拍动画之外):verdict + 选中的小节 key(nil = 总评)。
    let onSubmit: (_ verdict: ChapterFeedbackRequest.Verdict, _ section: String?) -> Void

    private enum Phase: Equatable {
        case idle
        /// 「不准」已选、chips 展开(再点「不准」= 只记总评;点「准」= 改选)。
        case sectionOpen
        /// 「收到」显示中(输入已锁)。
        case received
        /// 整组消失(终态)。
        case gone
    }

    @State private var phase: Phase = .idle
    /// 选中标志:哪个词浓墨(另一个退淡)。
    @State private var pickedWord: ChapterFeedbackRequest.Verdict?
    /// chip 选中标志(单选;只作停拍展示,上报后随整组消失)。
    @State private var pickedSection: String?
    /// 已提交锁(review 三查:disabled 只挡 .received,而状态要到停拍结束
    /// 才切——双击窗口内二次 onSubmit 会重复上报/标记。决定一次性,此锁
    /// 先于动画生效)。
    @State private var submitted = false
    /// 「收到」淡入驱动(ink-in:opacity + blur 7→0)。
    @State private var receivedShown = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch phase {
            case .gone:
                EmptyView()
            default:
                VStack(alignment: .leading, spacing: 14) {
                    if phase == .received {
                        receivedText
                    } else {
                        wordsRow
                        if phase == .sectionOpen {
                            chipsRow
                        }
                    }
                }
            }
        }
    }

    // MARK: - 词组行「准 · 不准」

    private var wordsRow: some View {
        HStack(spacing: 12) {
            wordButton(L10n.ChapterFeedback.accurate, verdict: .accurate)
            Text("·")
                .font(BaziFont.caption(size: 11.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            wordButton(L10n.ChapterFeedback.inaccurate, verdict: .inaccurate)
        }
    }

    private func wordButton(_ title: String, verdict: ChapterFeedbackRequest.Verdict) -> some View {
        Button {
            tapWord(verdict)
        } label: {
            Text(title)
                .font(BaziFont.caption(size: 11.5))
                .tracking(1)
                // 选中=浓墨,另一个=淡墨;未选=墨灰(拍板:不用朱红,朱红只留印章级)
                .foregroundStyle(wordColor(verdict))
        }
        .buttonStyle(.plain)
        .disabled(phase == .received)
    }

    private func wordColor(_ verdict: ChapterFeedbackRequest.Verdict) -> Color {
        guard let picked = pickedWord else { return BaziTheme.inkMuted }
        return picked == verdict ? BaziTheme.ink : BaziTheme.inkMutedSecondary
    }

    // MARK: - 小节 chip(单选,无提示词)

    private var chipsRow: some View {
        FlowLayout(spacing: 8) {
            ForEach(sections, id: \.self) { key in
                chipButton(key)
            }
        }
    }

    private func chipButton(_ key: String) -> some View {
        let isOn = pickedSection == key
        return Button {
            tapSection(key)
        } label: {
            Text(ChapterContent.localizedLabel(key))
                .font(BaziFont.caption(size: 11.5))
                .tracking(1)
                .foregroundStyle(isOn ? BaziTheme.onInkDeep : BaziTheme.inkMuted)
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(isOn ? BaziTheme.ink : Color.clear)
                )
                .overlay(
                    Capsule().stroke(
                        isOn ? Color.clear : BaziTheme.hairline,
                        lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 「收到」(ink-in 淡入,停约一秒后整组消失)

    private var receivedText: some View {
        Text(L10n.ChapterFeedback.received)
            .font(BaziFont.caption(size: 11.5))
            .tracking(1)
            .foregroundStyle(BaziTheme.inkMuted)
            .opacity(receivedShown ? 1 : 0)
            .blur(radius: receivedShown ? 0 : 7)
            .onAppear {
                guard !reduceMotion else {
                    receivedShown = true
                    return
                }
                withAnimation(.easeInOut(duration: 0.3)) {
                    receivedShown = true
                }
            }
    }

    // MARK: - 状态机(三拍时序;拍间锁输入防重入)

    /// 点词:「准」直接走「收到」;「不准」第一次展开 chips,再点(展开态)
    /// 只记总评也走「收到」。决定即上报 + 本地标记。
    private func tapWord(_ verdict: ChapterFeedbackRequest.Verdict) {
        guard !submitted else { return }
        HapticEngine.light()
        withMotion {
            pickedWord = verdict
        }
        switch verdict {
        case .accurate:
            submit(.accurate, nil)
            scheduleReceived(after: 0.4)
        case .inaccurate:
            if phase == .sectionOpen {
                submit(.inaccurate, nil)
                scheduleReceived(after: 0.35)
            } else {
                withMotion { phase = .sectionOpen }
            }
        }
    }

    /// 点 chip:选中标志停一拍 → 收起并显示「收到」(上报带小节 key)。
    private func tapSection(_ key: String) {
        guard !submitted else { return }
        HapticEngine.light()
        withMotion { pickedSection = key }
        submit(.inaccurate, key)
        scheduleReceived(after: 0.45)
    }

    /// 决定即上报(不等三拍动画:回执动画只是确认,决定此刻已生效——
    /// 调用方同步落本地标记 + fire-and-forget 上报);同时落 submitted 锁。
    private func submit(
        _ verdict: ChapterFeedbackRequest.Verdict, _ section: String?
    ) {
        submitted = true
        onSubmit(verdict, section)
    }

    /// 停拍后:收起词组与 chips → 「收到」→ 约 0.9s 后整组消失(终态)。
    /// Task.sleep 只因取消抛 CancellationError(视图销毁/新 Task)——此处
    /// 显式接住即终断后续拍(退出页面后无需再切态),其余错误面不存在。
    private func scheduleReceived(after delay: TimeInterval) {
        Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            withMotion { phase = .received }
            do { try await Task.sleep(for: .seconds(0.9)) } catch { return }
            withMotion { phase = .gone }
        }
    }

    /// reduce-motion 全降级(DESIGN.md 动效三式纪律):动画跳过,状态照切,
    /// 三拍时序保留(回执语义不随动画降级丢失)。
    private func withMotion(_ body: () -> Void) {
        if reduceMotion {
            body()
        } else {
            withAnimation(.easeInOut(duration: 0.25), body)
        }
    }
}

// MARK: - 反馈小节清单(按章)

extension ModuleID {
    /// 章末反馈「不准」展开的小节 key(2026-11-15)。
    ///
    /// 来源 = 各章模板 JSON 契约的顶层小节对象(backend
    /// app/ai/prompts/{zh,zh-hant,en}/m*_*.md 的「输出 JSON」段);note 类
    /// 键(evidence / medical_note / disclaimer)不进——它们是小字注不是
    /// 小节。展示词走 `ChapterContent.localizedLabel`(labels 短名词,与
    /// 「据 · 」折叠区同词;**漂移守护**:模板 bump 增删顶层小节时此处须
    /// 同步,labels 缺 key 时 localizedLabel 原样透出 key 兜底可见)。
    var feedbackSectionKeys: [String] {
        switch self {
        case .m0:
            return ["main_axis", "core_loop", "structure_type", "capability_source"]
        case .m1:
            return ["innate", "trained", "defensive", "one_leverage"]
        case .m2:
            return ["high_config", "low_config", "threshold", "early_warnings",
                    "switch_actions"]
        case .m3:
            return ["operating_mode", "failure_environments", "ideal_life_structure",
                    "stability_vs_volatility", "environment_checklist"]
        case .m4:
            return ["battery_type", "imbalance_risks", "recovery_levers",
                    "weekly_maintenance"]
        case .m5:
            return ["income_forms", "leaks", "strategies", "asset_ideas"]
        case .m6:
            return ["energy_path", "leverage", "vulnerability", "upgrade_path"]
        case .m7:
            // 2026-11-24 捌章拍板:推翻信号节整节隐藏,反馈 chip 随摘
            return ["true_leverage", "use_cases"]
        }
    }
}

// MARK: - 本地已反馈标记(反馈一次性)

/// 同章只问一次的本地标记(UserDefaults;上报是尽力而为,标记不等上报
/// 成败——决定已做出,失败重试只会让「不可改」语义变含糊)。
///
/// 容量防护:条目 = "{contentHash}#{module}",超 2000 整清一次(反馈分析
/// 价值集中在近期版本,老标记清掉只是可能多问一次,无资损)。
enum ChapterFeedbackStore {
    private static let key = "deepanalysis.chapterFeedback.done.v1"
    private static let cap = 2000

    static func hasFeedback(
        contentHash: String, module: ModuleID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var entries = defaults.stringArray(forKey: key) ?? []
        prune(&entries)
        return entries.contains(entry(contentHash: contentHash, module: module))
    }

    static func markDone(
        contentHash: String, module: ModuleID,
        defaults: UserDefaults = .standard
    ) {
        var entries = defaults.stringArray(forKey: key) ?? []
        prune(&entries)
        entries.append(entry(contentHash: contentHash, module: module))
        defaults.set(entries, forKey: key)
    }

    private static func entry(contentHash: String, module: ModuleID) -> String {
        "\(contentHash)#\(module.rawValue)"
    }

    private static func prune(_ entries: inout [String]) {
        if entries.count > cap {
            entries.removeAll()
        }
    }
}
