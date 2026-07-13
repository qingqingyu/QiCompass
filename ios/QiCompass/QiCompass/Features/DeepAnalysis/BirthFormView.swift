import SwiftUI

/// 出生信息表单(方案 §一 empty 态)。
///
/// - DatePicker dateAndTime(方案 §4.2/4.3:拿精确时间,真太阳时由后端按经度修正)
/// - 时辰快捷选(只知时辰的用户,填该时辰中点)
/// - 性别 Picker
/// - 城市表(客户端副本 52 条,纯展示不存经度;决策 4.1)+ 手动经度开关
/// - 子时规则固定 zi_next_day(只读展示)
/// - 校验错误内联提示
struct BirthFormView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let onSubmit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section(title: "出生时间") {
                    DatePicker(
                        "日期与时辰",
                        selection: $vm.birthDate,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .foregroundStyle(BaziTheme.text)
                }

                section(title: "时辰快捷选(可选)") {
                    shichenGrid
                }

                section(title: "性别") {
                    Picker("性别", selection: $vm.gender) {
                        Text("男").tag("male")
                        Text("女").tag("female")
                    }
                    .pickerStyle(.segmented)
                }

                section(title: "出生地") {
                    Toggle("手动输入经度", isOn: $vm.useManualLongitude)
                        .foregroundStyle(BaziTheme.text)
                    if vm.useManualLongitude {
                        HStack {
                            Text("经度").foregroundStyle(BaziTheme.textDim)
                            TextField("东正西负", value: $vm.manualLongitude, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                                .foregroundStyle(BaziTheme.text)
                                .padding(8)
                                .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
                        }
                        Text("海外用户或设备时区与出生地不一致时使用。")
                            .font(.caption)
                            .foregroundStyle(BaziTheme.textDim)
                    } else {
                        Picker("城市", selection: $vm.selectedCity) {
                            ForEach(CityList.cities, id: \.self) { city in
                                Text(city).tag(city)
                            }
                        }
                        .foregroundStyle(BaziTheme.text)
                    }
                }

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

                if case .formInvalid(let errors) = vm.state {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors, id: \.self) { err in
                            Text("• \(err)")
                                .font(.caption)
                                .foregroundStyle(Color.red.opacity(0.9))
                        }
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }

                Button(action: { HapticEngine.medium(); onSubmit() }) {
                    Text("开始排盘")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.bgTop)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(BaziTheme.gold, in: Capsule())
                }
            }
            .padding()
        }
    }

    // MARK: - Section wrapper

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

    // MARK: - 时辰快捷选

    private var shichenGrid: some View {
        let shichens: [(name: String, hour: Int)] = [
            ("子", 0), ("丑", 2), ("寅", 4), ("卯", 6),
            ("辰", 8), ("巳", 10), ("午", 12), ("未", 14),
            ("申", 16), ("酉", 18), ("戌", 20), ("亥", 22),
        ]
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 6),
            spacing: 8
        ) {
            ForEach(shichens, id: \.hour) { shichen in
                Button {
                    vm.setShichenHour(shichen.hour)
                } label: {
                    Text(shichen.name)
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(BaziTheme.gold)
                        .background(BaziTheme.cardBackground, in: Circle())
                        .overlay(Circle().stroke(BaziTheme.cardBorder, lineWidth: 1))
                }
            }
        }
    }
}

// MARK: - CityList

/// 城市表客户端副本(决策 4.1)。
///
/// 纯展示用,不存经度,不参与计算。与后端 `CITY_LONGITUDE`(52 条)同步。
/// 用户选城市 → 客户端只传 `city: String` 给后端,后端查表得经度。
/// 查不到的城市走"手动输入经度"开关。
enum CityList {
    static let cities: [String] = [
        // 一线 / 新一线
        "北京", "上海", "广州", "深圳", "成都", "重庆", "杭州", "武汉",
        "西安", "南京", "天津", "苏州", "长沙", "郑州", "青岛",
        // 省会 / 重要城市
        "沈阳", "哈尔滨", "长春", "大连", "济南", "福州", "厦门", "合肥",
        "南昌", "太原", "石家庄", "呼和浩特", "兰州", "西宁", "银川",
        "乌鲁木齐", "拉萨", "昆明", "贵阳", "南宁", "海口", "三亚",
        "台北", "香港", "澳门",
        // 海外
        "新加坡", "东京", "首尔", "纽约", "旧金山", "洛杉矶", "温哥华",
        "多伦多", "伦敦", "巴黎", "悉尼", "墨尔本",
    ]
}
