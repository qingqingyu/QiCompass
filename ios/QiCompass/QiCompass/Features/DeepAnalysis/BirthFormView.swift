import SwiftUI

/// 出生信息表单(方案 §一 empty 态)。
///
/// - DatePicker dateAndTime(方案 §4.2/4.3:拿精确时间,真太阳时由后端按经度修正)
/// - 时辰快捷选(默认折叠;只知时辰的用户展开后选,填该时辰中点)
/// - 性别 Picker
/// - 出生地:全球城市搜索(S03,cities.sqlite;无默认必选)+ 自定义经度开关(S05 升级为自定义地点)
/// - 校验错误内联提示
struct BirthFormView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let onSubmit: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section(title: "命盘别名", level: .primary) {
                    TextField("我自己 / 妈妈 / 男友", text: $vm.alias)
                        .foregroundStyle(BaziTheme.ink)
                        .submitLabel(.next)
                }

                section(title: "出生时间", level: .primary) {
                    DatePicker(
                        "日期与时辰",
                        selection: $vm.birthDate,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.compact)
                    .foregroundStyle(BaziTheme.ink)
                    // WYSIWYG:表盘按出生城市时区显示(S03;换算责任在后端 zoneinfo)
                    .environment(\.calendar, vm.placeCalendar)
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
                    // S05:全球城市搜索 + sheet 内「自定义地点」(经度+时区必填)
                    CityPickerField(selection: $vm.selectedPlace)
                    Text(L10n.CitySearch.customEntryHint)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }

                if case .formInvalid(let errors) = vm.state {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors, id: \.self) { err in
                            Text("• \(err)")
                                .font(.caption)
                                .foregroundStyle(BaziTheme.destructive)
                        }
                    }
                    .padding(BaziTheme.Spacing.md)
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
                .padding(BaziTheme.Spacing.md)
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
    /// hour 按出生城市时区取(S03 WYSIWYG,不随设备时区漂移)。
    private func currentShichenHour() -> Int {
        let hour = vm.placeCalendar.component(.hour, from: vm.birthDate)
        if hour == 23 { return 0 }
        return (hour / 2) * 2
    }
}
