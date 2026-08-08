import SwiftUI

/// 出生信息表单(方案 §一 empty 态)。
///
/// - DatePicker dateAndTime(方案 §4.2/4.3:拿精确时间,真太阳时由后端按经度修正)
/// - 时辰快捷选(默认折叠;只知时辰的用户展开后选,填该时辰中点)
/// - 性别 Picker
/// - 城市表(客户端副本 52 条,纯展示不存经度;决策 4.1)+ 手动经度开关
/// - 校验错误内联提示
struct BirthFormView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let onSubmit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section(title: "出生时间", level: .primary) {
                    DatePicker(
                        "日期与时辰",
                        selection: $vm.birthDate,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .foregroundStyle(BaziTheme.ink)
                }

                section(title: "时辰快捷选(可选)") {
                    DisclosureGroup {
                        shichenGrid
                            .padding(.top, 8)
                    } label: {
                        Text("只知时辰不知精确时间?点此选")
                    }
                    .tint(BaziTheme.ink)
                    .foregroundStyle(BaziTheme.ink)
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
                        .foregroundStyle(BaziTheme.ink)
                    if vm.useManualLongitude {
                        HStack {
                            Text("经度").foregroundStyle(BaziTheme.inkMuted)
                            TextField("东正西负", value: $vm.manualLongitude, format: .number)
                                .keyboardType(.numbersAndPunctuation)
                                .foregroundStyle(BaziTheme.ink)
                                .padding(8)
                                .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                        }
                        Text("海外用户或设备时区与出生地不一致时使用。")
                            .font(.caption)
                            .foregroundStyle(BaziTheme.inkMuted)
                    } else {
                        Picker("城市", selection: $vm.selectedCity) {
                            ForEach(CityList.cities, id: \.self) { city in
                                Text(city).tag(city)
                            }
                        }
                        .foregroundStyle(BaziTheme.ink)
                    }
                }

                if case .formInvalid(let errors) = vm.state {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors, id: \.self) { err in
                            Text("• \(err)")
                                .font(.caption)
                                .foregroundStyle(BaziTheme.destructive)
                        }
                    }
                    .padding(12)
                    .background(BaziTheme.destructive.opacity(0.1), in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }

                Button(action: { HapticEngine.medium(); onSubmit() }) {
                    Text("开始排盘")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
            }
            .padding()
        }
    }

    // MARK: - Section wrapper

    /// Section 层级(反馈 2026-07-22):出生时间是核心输入,用 .primary 突出;
    /// 其余 section 用 .standard。形成"primary 间距 28+16=44pt / standard 间距 28pt"的节奏。
    enum SectionLevel {
        case primary   // 标题更大(.headline)+ 上方 16pt 呼吸 + 描边略强(0.8pt)
        case standard  // 当前样式:subheadline + 默认间距 + 描边 0.5pt
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        level: SectionLevel = .standard,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isPrimary = level == .primary
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(isPrimary ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            content()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                        .stroke(BaziTheme.hairline, lineWidth: isPrimary ? 0.8 : 0.5)
                )
        }
        .padding(.top, isPrimary ? BaziTheme.Spacing.md : 0)
    }

    // MARK: - 时辰快捷选

    private var shichenGrid: some View {
        let shichens: [(name: String, hour: Int)] = [
            ("子", 0), ("丑", 2), ("寅", 4), ("卯", 6),
            ("辰", 8), ("巳", 10), ("午", 12), ("未", 14),
            ("申", 16), ("酉", 18), ("戌", 20), ("亥", 22),
        ]
        let selectedHour = currentShichenHour()
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 6),
            spacing: 8
        ) {
            ForEach(shichens, id: \.hour) { shichen in
                let isSelected = selectedHour == shichen.hour
                Button {
                    vm.setShichenHour(shichen.hour)
                } label: {
                    Text(shichen.name)
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .foregroundStyle(isSelected ? BaziTheme.paper : BaziTheme.ink)
                        .background {
                            Circle().fill(isSelected ? BaziTheme.cinnabar : Color.clear)
                        }
                        .overlay(
                            Circle().stroke(BaziTheme.hairline, lineWidth: isSelected ? 0 : 0.5)
                        )
                }
            }
        }
    }

    /// 从 vm.birthDate 的当前 hour 反推用户选了哪个时辰(用于圆圈选中态显示)。
    /// 时辰边界:[23,0,1]→子(0),[2,3]→丑(2),[4,5]→寅(4)... 奇数 hour 向下取偶到中点。
    /// 23 点归子时跨日(对齐后端 setSect(1) 规则)。
    private func currentShichenHour() -> Int {
        let hour = Calendar.current.component(.hour, from: vm.birthDate)
        if hour == 23 { return 0 }
        return (hour / 2) * 2
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
