import SwiftUI

/// 合盘配置态:选 A 盘 + B 模式切换 + context picker + 底部「开始合盘」CTA。
///
/// 决策 D1:配置态与结果态共享同一个 ViewModel,结果态顶部「返回修改」切回此视图。
/// 决策 D4:`zi_hour_rule` 不暴露给用户,MVP 固定 `zi_next_day`,显示只读提示。
struct CompatibilityConfigView: View {
    @Bindable var vm: CompatibilityViewModel
    let onStart: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // A 盘选择
                ChartArchivePickerView(
                    title: "A 盘(你)",
                    charts: vm.archivedCharts,
                    selectedIndex: $vm.selectedChartAIndex
                )

                // B 模式切换
                section(title: "B 盘(对方)") {
                    Picker("B 盘模式", selection: $vm.bMode) {
                        ForEach(BModeSelection.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch vm.bMode {
                    case .archived:
                        ChartArchivePickerView(
                            title: "从存档选择 B 盘",
                            charts: vm.archivedCharts,
                            selectedIndex: $vm.selectedChartBIndex
                        )
                    case .tempInput:
                        tempInputForm
                    }
                }

                // context picker
                section(title: "合盘维度") {
                    Picker("合盘维度", selection: $vm.context) {
                        Text("通用").tag("general")
                        Text("婚姻").tag("marriage")
                        Text("事业").tag("business")
                    }
                    .pickerStyle(.segmented)

                    Text(contextDescription)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.textDim)
                }

                // 子时规则只读提示
                section(title: "子时规则") {
                    HStack {
                        Text("23:00 换日(早子时归当日)")
                            .foregroundStyle(BaziTheme.textDim)
                        Spacer()
                    }
                    Text("MVP 固定规则,后端 setSect(1)。")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.textDim)
                }

                if case .failed(let userError) = vm.state {
                    Text(userError.errorDescription ?? "未知错误")
                        .font(.caption)
                        .foregroundStyle(Color.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)  // 给底部 CTA 留位
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onStart) {
                HStack {
                    Image(systemName: "person.2.wave.2")
                    Text("开始合盘")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(BaziTheme.bgTop)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(BaziTheme.gold, in: Capsule())
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(BaziTheme.bgMid.opacity(0.95))
            }
        }
    }

    // MARK: - 临时输入表单(模式 B)

    private var tempInputForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            DatePicker(
                "出生时间",
                selection: $vm.tempBirthDate,
                in: ...Date(),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)
            .foregroundStyle(BaziTheme.text)

            Picker("性别", selection: $vm.tempGender) {
                Text("男").tag("male")
                Text("女").tag("female")
            }
            .pickerStyle(.segmented)

            Toggle("手动输入经度", isOn: $vm.tempUseManualLongitude)
                .foregroundStyle(BaziTheme.text)

            if vm.tempUseManualLongitude {
                HStack {
                    Text("经度").foregroundStyle(BaziTheme.textDim)
                    TextField("东正西负", value: $vm.tempManualLongitude, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .foregroundStyle(BaziTheme.text)
                        .padding(8)
                        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                Picker("城市", selection: $vm.tempSelectedCity) {
                    ForEach(CityList.cities, id: \.self) { city in
                        Text(city).tag(city)
                    }
                }
                .foregroundStyle(BaziTheme.text)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - context 说明

    private var contextDescription: String {
        switch vm.context {
        case "general":  return "整体缘分概览"
        case "marriage": return "侧重感情质量与家庭节奏"
        case "business": return "侧重合作契合与利益节奏"
        default:         return ""
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
        }
    }
}
