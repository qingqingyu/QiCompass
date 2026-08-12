import SwiftUI

/// M4 健康续航模块的用户输入 sheet(Stage 8)。
///
/// 用户进入 M4 `.needsInput` 状态时,ModuleCardView 触发 onProvideInput,
/// DeepAnalysisResultView 装配本 sheet。提交后写入 VM.m4UserInput,
/// 用户重试 M4 时 orchestrator.runV1Module 用此输入。
///
/// 字段(对齐 backend m4_health_requires_user_inputs):
/// - age:Int(0-150,backend ge=0 le=150)
/// - current_concern:睡眠 / 疲劳 / 体重 / 情绪 / 其他(单选,
///   backend 接受任意字符串,iOS 简化为 Picker;未来可改多选)
///
/// 视觉:复用 BaziTheme,对齐 DESIGN.md 现代东方极简(toolbar 内 Button,非 PrimaryCTAButton)。
struct HealthInputForm: View {
    /// 用户当前填的年龄(进入 sheet 时 preload VM 已有值或默认 30)
    @State var age: Int
    /// 用户当前困扰(进入 sheet 时 preload VM 已有值或默认"睡眠")
    @State var currentConcern: String
    /// 提交回调:把 (age, concern) 写入 VM.m4UserInput
    let onSubmit: (Int, String) -> Void
    /// 取消回调(用户点"取消"或下滑)
    let onCancel: () -> Void

    /// 预设困扰清单(对齐 v1.md M4 任务描述 + backend spike 默认值)
    /// 单选简化(未来可扩为多选 + 自定义文本;当前"其他"只传固定字符串,
    /// LLM 会收到 "其他" 但无细节 — 若需自定义文本应 Stage 9 加 TextField)
    private let concernOptions: [(label: String, value: String)] = [
        ("睡眠(入睡难 / 醒得早 / 不解乏)", "睡眠"),
        ("疲劳(工作日长期精力不济)", "疲劳"),
        ("体重(代谢 / 食欲 / 体型)", "体重"),
        ("情绪(焦虑 / 低落 / 易怒)", "情绪"),
        ("其他(暂无法填细节,LLM 仅知大类)", "其他"),
    ]

    init(
        initialAge: Int = 30,
        initialConcern: String = "睡眠",
        onSubmit: @escaping (Int, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._age = State(initialValue: initialAge)
        self._currentConcern = State(initialValue: initialConcern)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(title: "M4 · 健康续航", level: .primary) {
                        Text("基于命局的能量规律与恢复杠杆。请先提供当前状态,LLM 才能给针对性建议(不替代医生,仅作自我觉察参考)。")
                            .font(.caption)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }

                    section(title: "年龄", level: .primary) {
                        Stepper(value: $age, in: 0...150) {
                            Text("\(age) 岁")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(BaziTheme.ink)
                        }
                        .tint(BaziTheme.cinnabar)
                    }

                    section(title: "当前最困扰") {
                        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
                            ForEach(concernOptions, id: \.value) { option in
                                concernRow(option)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(BaziTheme.paper)
            .navigationTitle("M4 健康输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: onCancel)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提交") {
                        HapticEngine.medium()
                        onSubmit(age, currentConcern)
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BaziTheme.cinnabar)
                    .disabled(!isValid)
                }
            }
        }
    }

    // 注:Stepper 已 clamp age 到 0-150,currentConcern init 默认"睡眠"且 UI 只允许选
    // concernOptions 内的值(全非空),所以 isValid 实际恒为 true。
    // 保留 disabled(!isValid) 作为防御性 UI(未来若加自定义 TextField 输入,此处自然激活)
    private var isValid: Bool {
        (0...150).contains(age) && !currentConcern.isEmpty
    }

    @ViewBuilder
    private func concernRow(_ option: (label: String, value: String)) -> some View {
        Button {
            HapticEngine.light()
            currentConcern = option.value
        } label: {
            HStack(spacing: BaziTheme.Spacing.sm) {
                Image(systemName: currentConcern == option.value ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(currentConcern == option.value ? BaziTheme.cinnabar : BaziTheme.inkMuted)
                Text(option.label)
                    .font(.body)
                    .foregroundStyle(BaziTheme.ink)
                Spacer()
            }
            .padding(BaziTheme.Spacing.sm)
            .background(
                currentConcern == option.value
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
