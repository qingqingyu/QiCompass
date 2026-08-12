import SwiftUI

/// M5 财富结构模块的用户输入 sheet(Stage 8)。
///
/// 用户进入 M5 `.needsInput` 状态时,ModuleCardView 触发 onProvideInput,
/// DeepAnalysisResultView 装配本 sheet。提交后写入 VM.m5UserInput,
/// 用户重试 M5 时 orchestrator.runV1Module 用此输入。
///
/// 字段(对齐 backend m5_wealth_requires_user_inputs):
/// - assets_summary:粗略资产/收入概况(TextField,backend max_length=500)
/// - preference:保守 / 平衡 / 进攻(Picker 三选一)
///
/// 视觉:复用 BaziTheme,对齐 DESIGN.md 现代东方极简(toolbar 内 Button,非 PrimaryCTAButton)。
struct WealthInputForm: View {
    /// 资产概况(进入 sheet 时 preload VM 已有值或默认空)
    @State var assetsSummary: String
    /// 偏好(进入 sheet 时 preload VM 已有值或默认"平衡")
    @State var preference: String
    /// 提交回调
    let onSubmit: (String, String) -> Void
    /// 取消回调
    let onCancel: () -> Void

    /// 偏好三选项(对齐 v1.md M5 任务描述 + backend spike 默认值)
    private let preferenceOptions: [(label: String, value: String, hint: String)] = [
        ("保守", "保守", "保本为先,不愿承担亏损"),
        ("平衡", "平衡", "中等风险,稳健增长"),
        ("进攻", "进攻", "高波动换高回报可能"),
    ]

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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(title: "M5 · 财富结构", level: .primary) {
                        Text("收入形态匹配度与漏财止损规则。请先提供当前状态,LLM 才能给针对性建议(不构成投资建议,自我认知用)。")
                            .font(.caption)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }

                    section(title: "资产 / 收入概况", level: .primary) {
                        TextField("如:中等收入,有积蓄,无房产", text: $assetsSummary, axis: .vertical)
                            .lineLimit(2...5)
                            .foregroundStyle(BaziTheme.ink)
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
                            .padding(BaziTheme.Spacing.sm)
                            .background(BaziTheme.paper, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
                            )
                        HStack(spacing: BaziTheme.Spacing.xs) {
                            Text("可粗略,不需精确数字")
                                .font(.caption2)
                                .foregroundStyle(BaziTheme.inkMuted)
                            Spacer()
                            Text("\(assetsSummary.count) / 500")
                                .font(.caption2)
                                .foregroundStyle(assetsSummary.count >= 500 ? BaziTheme.destructive : BaziTheme.inkMuted)
                                .monospacedDigit()
                        }
                    }

                    section(title: "风险偏好") {
                        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
                            ForEach(preferenceOptions, id: \.value) { option in
                                preferenceRow(option)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(BaziTheme.paper)
            .navigationTitle("M5 财富输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提交") {
                        HapticEngine.medium()
                        onSubmit(assetsSummary, preference)
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BaziTheme.cinnabar)
                    .disabled(!isValid)
                }
            }
        }
    }

    private var isValid: Bool {
        !assetsSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !preference.isEmpty
        // 注:assetsSummary 长度由 onChange 硬截断到 500,isValid 无需再检查上限
    }

    @ViewBuilder
    private func preferenceRow(_ option: (label: String, value: String, hint: String)) -> some View {
        Button {
            HapticEngine.light()
            preference = option.value
        } label: {
            HStack(spacing: BaziTheme.Spacing.sm) {
                Image(systemName: preference == option.value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(preference == option.value ? BaziTheme.cinnabar : BaziTheme.inkMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.body)
                        .foregroundStyle(BaziTheme.ink)
                    Text(option.hint)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Spacer()
            }
            .padding(BaziTheme.Spacing.sm)
            .background(
                preference == option.value
                    ? BaziTheme.cinnabarSoft
                    : BaziTheme.cardSurface,
                in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section wrapper(复用 BirthFormView 风格)

    private func section<Content: View>(
        title: String,
        level: SectionLevel = .standard,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(level == .primary ? .headline : .subheadline)
                .foregroundStyle(BaziTheme.ink)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BaziTheme.Spacing.md)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(BaziTheme.hairline, lineWidth: level == .primary ? 0.8 : 0.5)
        )
    }

    private enum SectionLevel {
        case primary
        case standard
    }
}
