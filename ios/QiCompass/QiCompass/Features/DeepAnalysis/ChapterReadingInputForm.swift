import SwiftUI

/// M4/M5 页内两问表单(盘面小景定稿 ⑧,替代 Stage 8 的 HealthInputForm /
/// WealthInputForm sheet):阅读页 needsInput 态原地作答,不弹 sheet、不离开章节语境。
///
/// 视觉:亮纸框(cardSurface + hairline + radius 4,与今日运势亮纸框同语言)内
/// 两问;chip 选中 = cinnabarSoft 底 + 朱字(DESIGN.md 选中态底色授权,极少量);
/// 提交 = 「以此推演」浓墨 CTA。控件逻辑(stepper / FlowLayout chips / 字段语义)
/// 从旧 sheet 表单迁移,value 与提交 payload 契约不变(backend m4/m5 校验同款)。
///
/// 文案复用 L10n.HealthForm / L10n.WealthForm(sheet 时代的 key 原样继承)。
struct ChapterReadingInputForm: View {
    let module: ModuleID
    /// M4 提交:(age, concern) → VM.submitM4Input
    let onSubmitM4: (Int, String) -> Void
    /// M5 提交:(assets, preference) → VM.submitM5Input
    let onSubmitM5: (String, String) -> Void

    // M4 状态(进入时 preload VM 已有值或默认)
    @State private var age: Int
    @State private var concern: String
    // M5 状态
    @State private var assets: String
    @State private var preference: String
    /// Q1 键盘聚焦(M5 下划线聚焦转朱红,O2 同规格)
    @FocusState private var assetsFocused: Bool

    init(
        module: ModuleID,
        initialM4: (age: Int, concern: String)? = nil,
        initialM5: (assets: String, preference: String)? = nil,
        onSubmitM4: @escaping (Int, String) -> Void,
        onSubmitM5: @escaping (String, String) -> Void
    ) {
        self.module = module
        self._age = State(initialValue: initialM4?.age ?? 30)
        self._concern = State(initialValue: initialM4?.concern ?? "睡眠")
        self._assets = State(initialValue: initialM5?.assets ?? "")
        self._preference = State(initialValue: initialM5?.preference ?? "平衡")
        self.onSubmitM4 = onSubmitM4
        self.onSubmitM5 = onSubmitM5

    }

    private let concernOptions: [(label: String, value: String)] = [
        (L10n.HealthForm.concernSleep, "睡眠"),
        (L10n.HealthForm.concernFatigue, "疲劳"),
        (L10n.HealthForm.concernWeight, "体重"),
        (L10n.HealthForm.concernMood, "情绪"),
        (L10n.HealthForm.concernOther, "其他"),
    ]

    private let preferenceOptions: [(label: String, value: String)] = [
        (L10n.WealthForm.riskConservative, "保守"),
        (L10n.WealthForm.riskBalanced, "平衡"),
        (L10n.WealthForm.riskAggressive, "进攻"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 亮纸框(定稿 ⑧):两问入框
            VStack(alignment: .leading, spacing: 16) {
                switch module {
                case .m4:
                    ageQuestion
                    divider
                    concernQuestion
                case .m5:
                    assetsQuestion
                    divider
                    preferenceQuestion
                default:
                    // 构造侧保证只传 m4/m5;到这说明调用方错乱,显式报错不静默
                    let _ = AppLogger.app.error("chapterInputForm unexpected module=\(module.rawValue, privacy: .public)")
                    EmptyView()
                }
            }
            .padding(16)
            .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
            )

            PrimaryCTAButton(
                title: L10n.HealthForm.ctaGenerate,
                loadingTitle: L10n.HealthForm.ctaLoading,
                isLoading: false,
                isEnabled: isValid,
                action: submit
            )
            Text(noteText)
                .font(BaziFont.caption(size: 10.5))
                .tracking(1)
                .lineSpacing(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
    }

    // MARK: - 提交

    private func submit() {
        switch module {
        case .m4:
            onSubmitM4(age, concern)
        case .m5:
            onSubmitM5(assets, preference)
        default:
            break // 上面 default 已显式报错;此处不可达,不给假提交
        }
    }

    /// M4:age 0-150(stepper 已 clamp)+ concern 非空(UI 单选恒非空);
    /// M5:assets 非空 + preference 三选一。与旧 sheet 同判据。
    private var isValid: Bool {
        switch module {
        case .m4:
            return (0...150).contains(age) && !concern.isEmpty
        case .m5:
            return !assets.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !preference.isEmpty
        default:
            return false
        }
    }

    private var noteText: String {
        switch module {
        case .m4:
            return "提交后本章按你的情况生成 · 信息仅用于本命主的健康章,不进入其它章节"
        case .m5:
            return "提交后本章按你的情况生成 · 信息仅用于本命主的财富章,不进入其它章节"
        default:
            return ""
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(BaziTheme.hairline)
            .frame(height: 0.5)
    }

    // MARK: - 两问标签(「· 必答」朱红小字,印章级点缀)

    private func questionLabel(_ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(BaziFont.caption(size: 12.5))
                .tracking(2.5)
                .foregroundStyle(BaziTheme.ink)
            Text("· \(L10n.HealthForm.required)")
                .font(BaziFont.caption(size: 12.5))
                .tracking(2.5)
                .foregroundStyle(BaziTheme.cinnabar)
        }
    }

    // MARK: - M4 Q1 年龄(紧凑 stepper,行内右置)

    private var ageQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            questionLabel(L10n.HealthForm.ageQuestion)
            HStack {
                Spacer()
                HStack(spacing: 0) {
                    stepButton("−", label: L10n.HealthForm.ageDecrease) {
                        if age > 0 { age -= 1 }
                    }
                    stepDivider
                    Text(L10n.HealthForm.ageValue(age))
                        .font(BaziFont.body(size: 14))
                        .foregroundStyle(BaziTheme.ink)
                        .frame(width: 64)
                        .lineLimit(1)
                    stepDivider
                    stepButton("＋", label: L10n.HealthForm.ageIncrease) {
                        if age < 150 { age += 1 }
                    }
                }
                .frame(width: 160, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(BaziTheme.ink.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(BaziTheme.ink.opacity(0.2))
            .frame(width: 1, height: 16)
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticEngine.light()
            action()
        } label: {
            Text(symbol)
                .font(BaziFont.body(size: 16))
                .foregroundStyle(BaziTheme.inkMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: - M4 Q2 困扰(chip 单选,cinnabarSoft 选中态)

    private var concernQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            questionLabel(L10n.HealthForm.concernQuestion)
            FlowLayout(spacing: 8) {
                ForEach(concernOptions, id: \.value) { option in
                    chip(option.label, value: option.value, selection: $concern)
                }
            }
        }
    }

    // MARK: - M5 Q1 资产概况(无框下划线,聚焦转朱红)

    private var assetsQuestion: some View {
        VStack(alignment: .leading, spacing: 8) {
            questionLabel(L10n.WealthForm.assetsQuestion)
            TextField(L10n.WealthForm.assetsPlaceholder, text: $assets, axis: .vertical)
                .font(BaziFont.body(size: 14))
                .lineLimit(1...3)
                .focused($assetsFocused)
                .onChange(of: assets) { _, newValue in
                    // backend max_length=500,iOS 硬截断
                    if newValue.count > 500 {
                        assets = String(newValue.prefix(500))
                    }
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(assetsFocused ? BaziTheme.cinnabar : BaziTheme.hairline)
                        .frame(height: assetsFocused ? 2 : 1)
                }
        }
    }

    // MARK: - M5 Q2 风险偏好(chip 单选)

    private var preferenceQuestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            questionLabel(L10n.WealthForm.riskQuestion)
            FlowLayout(spacing: 8) {
                ForEach(preferenceOptions, id: \.value) { option in
                    chip(option.label, value: option.value, selection: $preference)
                }
            }
        }
    }

    /// chip:未选 hairline 空底弱墨字;选中 cinnabarSoft 底 + 朱字 + 朱描边
    /// (定稿 ⑧ 选中态授权,DESIGN.md cinnabarSoft「选中态底色(极少量)」)。
    private func chip(_ label: String, value: String, selection: Binding<String>) -> some View {
        let isSelected = selection.wrappedValue == value
        return Button {
            HapticEngine.light()
            selection.wrappedValue = value
        } label: {
            Text(label)
                .font(BaziFont.body(size: 13))
                .tracking(1.3)
                .foregroundStyle(isSelected ? BaziTheme.cinnabar : BaziTheme.inkMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isSelected ? BaziTheme.cinnabarSoft : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(
                            isSelected ? BaziTheme.cinnabar.opacity(0.4) : BaziTheme.ink.opacity(0.32),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
