import SwiftUI

/// M5 财富结构模块的用户输入 sheet(Stage 8;水墨孤本「生成前两问」重排 2026-08-29)。
///
/// 用户进入 M5 `.needsInput` 状态时,ModuleCardView 触发 onProvideInput,
/// DeepAnalysisResultView 装配本 sheet。提交后写入 VM.m5UserInput,
/// 用户重试 M5 时 orchestrator.runV1Module 用此输入。
///
/// 视觉:与 HealthInputForm 同族(「生成前两问」语言,原型 deep-p4-input.html
/// 无 M5 专属参考屏,M5 按同族语言定制,见任务取舍):
/// - 章头:kicker「第 陆 章 · 生成前两问」(M5 在捌章卷轴中的序号,与
///   ModuleCardView.chapterIndex 同源)+ 章题「财富结构 · 因你而异」+ 一句副题
/// - Q1 资产概况 = O2 无框下划线输入(BirthFormView 同规格重写:Micro/两问标签 +
///   无框多行 TextField + 底部 hairline,聚焦转朱红 2pt——cinnabar「聚焦线」授权场景)
/// - Q2 风险偏好 = chip 单选(FlowLayout 换行)+ 选中项 hint Micro 注
/// - 提交 = PrimaryCTAButton「生成本章」+「稍后在章节内补答也可」Micro 注
///
/// 字段(对齐 backend m5_wealth_requires_user_inputs,语义不变,纯视觉重排):
/// - assets_summary:粗略资产/收入概况(TextField,backend max_length=500,iOS 硬截断)
/// - preference:保守 / 平衡 / 进攻 三选一(chip 单选)
struct WealthInputForm: View {
    /// 资产概况(进入 sheet 时 preload VM 已有值或默认空)
    @State var assetsSummary: String
    /// 偏好(进入 sheet 时 preload VM 已有值或默认"平衡")
    @State var preference: String
    /// 提交回调
    let onSubmit: (String, String) -> Void
    /// 取消回调
    let onCancel: () -> Void

    /// 偏好三选项(对齐 v1.md M5 任务描述 + backend spike 默认值;value 不变)
    private let preferenceOptions: [(label: String, value: String, hint: String)] = [
        ("保守", "保守", "保本为先,不愿承担亏损"),
        ("平衡", "平衡", "中等风险,稳健增长"),
        ("进攻", "进攻", "高波动换高回报可能"),
    ]

    /// 键盘聚焦态(Q1 是唯一真键盘输入框;聚焦下划线转朱红,O2 同规格)
    @FocusState private var assetsFocused: Bool

    init(
        initialAssetsSummary: String = "",
        initialPreference: String = "平衡",
        onSubmit: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._assetsSummary = State(initialValue: initialAssetsSummary)
        self._preference = State(initialValue: initialPreference)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headBlock
                    .riseIn(delay: 0.08)
                assetsQuestion
                    .riseIn(delay: 0.16)
                preferenceQuestion
                    .riseIn(delay: 0.24)
                footBlock
                    .riseIn(delay: 0.32)
            }
            // 左右 34pt:原型 sheet 内边距,对齐 DESIGN.md §Spacing 正文区 34-36pt
            .padding(.horizontal, 34)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - 章头(kicker / 章题 / 副题 / 取消)

    private var headBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("第 陆 章 · 生成前两问")
                    .font(BaziFont.caption(size: 10))
                    .tracking(4)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Spacer(minLength: 12)
                Button(action: onCancel) {
                    Text("取消")
                        .font(BaziFont.caption(size: 11))
                        .foregroundStyle(BaziTheme.inkMuted)
                        .padding(.vertical, 2)
                }
            }
            Text("财富结构 · 因你而异")
                .font(BaziFont.display(size: 20))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
            Text("这一章结合你的资产概况与风险偏好推演,答案只影响本章内容。自我认知参考,不构成投资建议。")
                .font(BaziFont.caption(size: 11))
                .tracking(1.3)
                .lineSpacing(5)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - Q1 资产 / 收入概况(O2 无框下划线)

    private var assetsQuestion: some View {
        VStack(alignment: .leading, spacing: 12) {
            questionLabel("资产 / 收入概况", requirement: "必答")
            TextField(
                "资产 / 收入概况",
                text: $assetsSummary,
                prompt: Text("如:中等收入,有积蓄,无房产")
                    .font(BaziFont.body(size: 15))
                    .foregroundStyle(BaziTheme.inkMutedSecondary),
                axis: .vertical
            )
            .lineLimit(2...5)
            .font(BaziFont.body(size: 15))
            .foregroundStyle(BaziTheme.ink)
            .focused($assetsFocused)
            .submitLabel(.next)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                // O2 同规格:底部 hairline 下划线,聚焦转朱红 2pt(cinnabar 聚焦线授权场景)
                Rectangle()
                    .fill(assetsFocused ? BaziTheme.cinnabar : BaziTheme.hairline)
                    .frame(height: assetsFocused ? 2 : 1)
            }
            .animation(.easeOut(duration: 0.25), value: assetsFocused)
            .onChange(of: assetsSummary) { _, newValue in
                // 硬截断超长输入(按 Character 数,对齐后端 Pydantic max_length=500)
                // Swift String.count 统计的是 Unicode grapheme cluster 数,
                // Python len(str) 统计 Unicode code point 数。两者在 emoji
                // 组合字符上有微小差异(如 👨‍👩‍👧 Swift=1, Python=5),
                // 但普通中文 / 英文混排场景两者一致,足够用。
                if newValue.count > 500 {
                    assetsSummary = String(newValue.prefix(500))
                    HapticEngine.medium()
                }
            }
            HStack(spacing: BaziTheme.Spacing.xs) {
                Text("可粗略,不需精确数字")
                    .font(BaziFont.caption(size: 11))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Spacer()
                Text("\(assetsSummary.count) / 500")
                    .font(BaziFont.numeric(size: 10))
                    .foregroundStyle(assetsSummary.count >= 500 ? BaziTheme.destructive : BaziTheme.inkMutedSecondary)
            }
        }
    }

    // MARK: - Q2 风险偏好(chip 单选 + hint 注)

    private var preferenceQuestion: some View {
        VStack(alignment: .leading, spacing: 12) {
            questionLabel("风险偏好", requirement: "必答")
            FlowLayout(spacing: 10) {
                ForEach(preferenceOptions, id: \.value) { option in
                    chip(option)
                }
            }
            if let hint = preferenceOptions.first(where: { $0.value == preference })?.hint {
                Text(hint)
                    .font(BaziFont.caption(size: 11))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
    }

    /// chip(与 HealthInputForm 同族):未选 hairline 描边空底;选中浓墨实底 + 纸色字。
    private func chip(_ option: (label: String, value: String, hint: String)) -> some View {
        let isSelected = preference == option.value
        return Button {
            HapticEngine.light()
            preference = option.value
        } label: {
            Text(option.label)
                .font(BaziFont.body(size: 13))
                .tracking(1.3)
                .foregroundStyle(isSelected ? BaziTheme.paper : BaziTheme.inkMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? BaziTheme.ink : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(isSelected ? BaziTheme.ink : BaziTheme.ink.opacity(0.32), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 提交(CTA + 稍后注)

    private var footBlock: some View {
        VStack(spacing: 12) {
            PrimaryCTAButton(
                title: "生成本章",
                loadingTitle: "生成中…",
                isLoading: false,
                isEnabled: isValid,
                action: { onSubmit(assetsSummary, preference) }
            )
            Text("稍后在章节内补答也可")
                .font(BaziFont.caption(size: 10.5))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .padding(.top, 12)
    }

    /// 两问标签(与 HealthInputForm 同族,原型 .ql):12.5pt 大字距 + 朱红「· 必答」小字。
    private func questionLabel(_ title: String, requirement: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(BaziFont.caption(size: 12.5))
                .tracking(2.5)
                .foregroundStyle(BaziTheme.ink)
            Text("· \(requirement)")
                .font(BaziFont.caption(size: 12.5))
                .tracking(2.5)
                .foregroundStyle(BaziTheme.cinnabar)
        }
    }

    private var isValid: Bool {
        !assetsSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !preference.isEmpty
        // 注:assetsSummary 长度由 onChange 硬截断到 500,isValid 无需再检查上限
    }
}
