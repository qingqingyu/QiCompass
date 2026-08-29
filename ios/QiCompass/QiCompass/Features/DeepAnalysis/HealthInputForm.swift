import SwiftUI

/// M4 健康续航模块的用户输入 sheet(Stage 8;水墨孤本「生成前两问」重排 2026-08-29)。
///
/// 用户进入 M4 `.needsInput` 状态时,ModuleCardView 触发 onProvideInput,
/// DeepAnalysisResultView 装配本 sheet。提交后写入 VM.m4UserInput,
/// 用户重试 M4 时 orchestrator.runV1Module 用此输入。
///
/// 视觉事实源:`docs/design-ref/shuimo/deep-p4-input.html`:
/// - 章头:kicker「第 伍 章 · 生成前两问」(M4 在捌章卷轴中的序号,与
///   ModuleCardView.chapterIndex 同源)+ 章题「健康续航 · 因你而异」+ 一句副题
/// - 两问形态:Q1 年龄 = 定制 stepper(− / 值 / ＋ 细描边,190pt 左对齐);
///   Q2 身体状况 = chip 单选(FlowLayout 换行)+ 选中项 detail Micro 注
/// - 「· 必答」为印章级朱红小字点缀(原型 .req;DESIGN.md 朱红纪律内的
///   文字级小元素,同聚焦线量级,非 CTA 非大面积)
/// - 提交 = PrimaryCTAButton「生成本章」(浓墨 CTA)+「稍后在章节内补答也可」
///   Micro 注(模块保持 .needsInput,可随时重开本 sheet,文案属实)
/// - 取消 = 章头行右端「取消」小字(保留显式取消可达性,VoiceOver 无法下滑关闭)
///
/// 字段(对齐 backend m4_health_requires_user_inputs,语义不变,纯视觉重排):
/// - age:Int(0-150,backend ge=0 le=150;stepper 按钮边界 clamp)
/// - current_concern:睡眠 / 疲劳 / 体重 / 情绪 / 其他(单选,
///   backend 接受任意字符串,iOS 保持单选;原型 chips 为多选形态,但绑定
///   语义不许动——选项 value 与提交 payload 与重排前完全一致)
struct HealthInputForm: View {
    /// 用户当前填的年龄(进入 sheet 时 preload VM 已有值或默认 30)
    @State var age: Int
    /// 用户当前困扰(进入 sheet 时 preload VM 已有值或默认"睡眠")
    @State var currentConcern: String
    /// 提交回调:把 (age, concern) 写入 VM.m4UserInput
    let onSubmit: (Int, String) -> Void
    /// 取消回调(用户点"取消"或下滑)
    let onCancel: () -> Void

    /// 选项(chip 短标 + detail 选中后下方 Micro 注;value 对齐 backend 契约不变)
    private let concernOptions: [(label: String, value: String, detail: String)] = [
        ("睡眠", "睡眠", "入睡难 / 醒得早 / 不解乏"),
        ("疲劳", "疲劳", "工作日长期精力不济"),
        ("体重", "体重", "代谢 / 食欲 / 体型"),
        ("情绪", "情绪", "焦虑 / 低落 / 易怒"),
        ("其他", "其他", "暂无法填细节,仅告知大类"),
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headBlock
                    .riseIn(delay: 0.08)
                ageQuestion
                    .riseIn(delay: 0.16)
                concernQuestion
                    .riseIn(delay: 0.24)
                footBlock
                    .riseIn(delay: 0.32)
            }
            // 左右 34pt:原型 sheet 内边距,对齐 DESIGN.md §Spacing 正文区 34-36pt
            .padding(.horizontal, 34)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
    }

    // MARK: - 章头(kicker / 章题 / 副题 / 取消)

    private var headBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("第 伍 章 · 生成前两问")
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
            Text("健康续航 · 因你而异")
                .font(BaziFont.display(size: 20))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
            Text("这一章结合你的年龄与近况推演,答案只影响本章内容。仅供参考,不替代医生。")
                .font(BaziFont.caption(size: 11))
                .tracking(1.3)
                .lineSpacing(5)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - Q1 年龄(定制 stepper)

    private var ageQuestion: some View {
        VStack(alignment: .leading, spacing: 12) {
            questionLabel("你的年龄", requirement: "必答")
            ageStepper
        }
    }

    /// 定制 stepper(原型 .stepper):190pt 细描边框,− / 值(84pt)/ ＋ 三段,
    /// 内侧竖 hairline 分隔;按钮边界 clamp 0-150(backend ge=0 le=150)。
    private var ageStepper: some View {
        HStack(spacing: 0) {
            stepButton("−", accessibilityLabel: "减小年龄") {
                if age > 0 { age -= 1 }
            }
            stepDivider
            Text("\(age) 岁")
                .font(BaziFont.body(size: 15))
                .foregroundStyle(BaziTheme.ink)
                .frame(width: 84)
                .lineLimit(1)
            stepDivider
            stepButton("＋", accessibilityLabel: "增大年龄") {
                if age < 150 { age += 1 }
            }
        }
        .frame(width: 190, height: 40)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(BaziTheme.ink.opacity(0.3), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(BaziTheme.ink.opacity(0.2))
            .frame(width: 1, height: 18)
    }

    private func stepButton(_ symbol: String, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button {
            HapticEngine.light()
            action()
        } label: {
            Text(symbol)
                .font(BaziFont.body(size: 18))
                .foregroundStyle(BaziTheme.inkMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Q2 身体状况(chip 单选 + detail 注)

    private var concernQuestion: some View {
        VStack(alignment: .leading, spacing: 12) {
            questionLabel("近来的身体状况", requirement: "必答")
            FlowLayout(spacing: 10) {
                ForEach(concernOptions, id: \.value) { option in
                    chip(option)
                }
            }
            if let detail = concernOptions.first(where: { $0.value == currentConcern })?.detail {
                Text(detail)
                    .font(BaziFont.caption(size: 11))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
    }

    /// chip(原型 .chip):未选 hairline 描边空底 + 弱墨字;选中浓墨实底 + 纸色字。
    /// 单选(绑定语义不变);提交 payload 仍是 option.value。
    private func chip(_ option: (label: String, value: String, detail: String)) -> some View {
        let isSelected = currentConcern == option.value
        return Button {
            HapticEngine.light()
            currentConcern = option.value
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
                action: { onSubmit(age, currentConcern) }
            )
            Text("稍后在章节内补答也可")
                .font(BaziFont.caption(size: 10.5))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .padding(.top, 12)
    }

    /// 两问标签(原型 .ql):12.5pt 大字距问题名 + 朱红「· 必答」小字。
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

    // 注:stepper 按钮已 clamp age 到 0-150,currentConcern init 默认"睡眠"且 UI 只允许选
    // concernOptions 内的值(全非空),所以 isValid 实际恒为 true。
    // 保留 isEnabled 驱动的禁用态作为防御性 UI(未来若加自定义 TextField 输入,此处自然激活)
    private var isValid: Bool {
        (0...150).contains(age) && !currentConcern.isEmpty
    }
}
