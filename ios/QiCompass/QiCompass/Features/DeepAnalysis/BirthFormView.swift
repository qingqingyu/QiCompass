import SwiftUI

/// 出生信息表单(水墨孤本 O2 无框下划线语言,2026-08-29 重排)。
///
/// 参考 `docs/design-ref/shuimo/onboarding-o2-birthform.html`:
/// - 输入项去卡片化:Micro 标签(大字距)+ 无框输入 + 底部 hairline 下划线
/// - 聚焦态下划线转朱红加粗(DESIGN.md §Color:cinnabar 授权场景「聚焦线」,禁止 CTA/大面积)
/// - 性别双 chip:未选 hairline 描边空底,选中浓墨实底(对齐原型 .gchip)
/// - 日期行 + 时刻行 = 两个数值行(S03 拆双 picker:date-only / hourAndMinute 两个 wheel sheet、
///   两个绑定;日期必选 birthDate 为 nil 未选择初始态,时刻独立绑定 birthTime 保留默认值语义)
/// - 出生地 = CityPickerField 下划线变体(城市搜索引擎与排序不动)
/// - CTA 换 PrimaryCTAButton(inkDeep 底 + onInkDeep 字 + 朱色菱形印点,radius 5)
///
/// 语义不变(重排不是重构):字段绑定 / 校验逻辑 / 时辰快捷选(取时辰中点)/
/// setSect(1) 子时归子规则全部保留。
/// 共享组件:onboarding O2(OnboardingView formPage)/ 深度解析无存档兜底(DeepAnalysisView)/
/// Profile 新建命盘 sheet 三处复用;M4/M5 专属定制不在本视图做(独立任务)。
struct BirthFormView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let onSubmit: () -> Void

    /// 键盘聚焦域(仅别名是真键盘输入框;聚焦下划线转朱红)。
    private enum Field: Hashable {
        case alias
    }

    @FocusState private var focusedField: Field?
    @State private var showDatePicker = false
    @State private var showTimePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
                aliasSection
                    .riseIn(delay: 0.10)
                dateSection
                    .riseIn(delay: 0.18)
                shichenSection
                    .riseIn(delay: 0.26)
                genderSection
                    .riseIn(delay: 0.34)
                placeSection
                    .riseIn(delay: 0.42)

                formErrorBlock

                PrimaryCTAButton(
                    title: L10n.BirthForm.ctaStart,
                    loadingTitle: L10n.BirthForm.ctaLoading,
                    isLoading: false,
                    action: onSubmit
                )
                .padding(.top, BaziTheme.Spacing.md)
                .riseIn(delay: 0.5)
            }
            .padding(.horizontal, BaziTheme.Spacing.xxl)
            .padding(.vertical, BaziTheme.Spacing.lg)
        }
    }

    // MARK: - 命盘别名

    private var aliasSection: some View {
        fieldSection(title: L10n.BirthForm.aliasLabel, focused: focusedField == .alias) {
            TextField(
                L10n.BirthForm.aliasLabel,
                text: $vm.alias,
                prompt: Text(L10n.BirthForm.aliasPlaceholder)
                    .font(BaziFont.body(size: 16))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            )
            .font(BaziFont.body(size: 16))
            .foregroundStyle(BaziTheme.ink)
            .focused($focusedField, equals: .alias)
            .submitLabel(.next)
        }
    }

    // MARK: - 出生日期与时刻(S03 拆双 picker:日期必选 + 时刻独立绑定)

    /// 日期区 = 日期行(date-only wheel sheet)+ 时刻行(hourAndMinute wheel sheet)+ 教育微文案(D8)。
    private var dateSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            dateRow
            timeRow
            // D8 把矛盾变成教育:日期为什么必填(S04 引入「不知道出生时刻」后此处再补「时刻可跳过」半句)
            Text(L10n.BirthForm.dateEducationHint)
                .font(BaziFont.caption(size: 10))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
    }

    private var dateRow: some View {
        fieldSection(title: L10n.BirthForm.birthDateLabel) {
            Button {
                HapticEngine.light()
                showDatePicker = true
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(birthDateText)
                        .font(BaziFont.numeric(size: 15))
                        .foregroundStyle(vm.birthDate == nil ? BaziTheme.inkMutedSecondary : BaziTheme.ink)
                    Spacer(minLength: BaziTheme.Spacing.sm)
                    Text("›")
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.BirthForm.datePickerTitleDate)
            .accessibilityValue(birthDateText)
        }
        .sheet(isPresented: $showDatePicker) {
            datePickerSheet
        }
    }

    private var timeRow: some View {
        fieldSection(title: L10n.BirthForm.birthTimeLabel) {
            Button {
                HapticEngine.light()
                showTimePicker = true
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(vm.wallBirthTimeString)
                        .font(BaziFont.numeric(size: 15))
                        .foregroundStyle(BaziTheme.ink)
                    Spacer(minLength: BaziTheme.Spacing.sm)
                    Text("\(currentShichenName)时 ›")
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.BirthForm.datePickerTitleTime)
            .accessibilityValue("\(vm.wallBirthTimeString) \(currentShichenName)时")
        }
        .sheet(isPresented: $showTimePicker) {
            timePickerSheet
        }
    }

    /// 日期 wheel sheet:date-only,必选(未选择初始态;seed 只作表盘初始位置,未拨动不写回)。
    private var datePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            Text(L10n.BirthForm.datePickerTitleDate)
                .font(BaziFont.body(size: 15))
                .foregroundStyle(BaziTheme.ink)
            DatePicker(
                "",
                selection: datePickerBinding,
                in: ...Date(),
                displayedComponents: [.date]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            // WYSIWYG:表盘按出生城市时区显示(S03;换算责任在后端 zoneinfo)
            .environment(\.calendar, vm.placeCalendar)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
        .padding(.vertical, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaziTheme.paper)
    }

    /// 时刻 wheel sheet:hourAndMinute,独立绑定 birthTime。
    /// 无「不晚于当下」范围——单时刻无从与当下比较,未来校验落在日期+时刻合成值上(VM.validateForm)。
    private var timePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            Text(L10n.BirthForm.datePickerTitleTime)
                .font(BaziFont.body(size: 15))
                .foregroundStyle(BaziTheme.ink)
            DatePicker(
                "",
                selection: $vm.birthTime,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            // WYSIWYG:表盘按出生城市时区显示(S03;换算责任在后端 zoneinfo)
            .environment(\.calendar, vm.placeCalendar)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
        .padding(.vertical, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaziTheme.paper)
    }

    /// Optional date 的 DatePicker 桥:未选择时以旧默认 1990-03-15 作表盘初始位置(仅位置,非值);
    /// 用户拨动才触发 set 写回 birthDate,未拨动保持 nil(提交被 validateForm 拦截)。
    private var datePickerBinding: Binding<Date> {
        Binding(
            get: { vm.birthDate ?? Self.unselectedDateSeed },
            set: { vm.birthDate = $0 }
        )
    }

    /// 日期表盘初始位置锚(= 旧默认 1990-03-15 instant;不作为提交值)。
    private static let unselectedDateSeed = Date(timeIntervalSince1970: 638_000_000)

    /// 日期行文案:公历长日期,按出生城市钟面取(S03 WYSIWYG);未选择 → 占位。
    private var birthDateText: String {
        guard let birthDate = vm.birthDate else {
            return L10n.BirthForm.birthDatePlaceholder
        }
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = vm.placeCalendar
        dateFormatter.timeZone = vm.placeCalendar.timeZone
        dateFormatter.locale = .current
        dateFormatter.dateStyle = .long
        return dateFormatter.string(from: birthDate)
    }

    // MARK: - 时辰快捷选

    private var shichenSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            fieldLabel(L10n.BirthForm.hourQuickPickLabel)
            DisclosureGroup {
                shichenGrid
                    .padding(.top, BaziTheme.Spacing.sm)
            } label: {
                Text(L10n.BirthForm.hourQuickPickHint)
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .tint(BaziTheme.ink)
        }
    }

    private var shichenGrid: some View {
        let selectedHour = currentShichenHour()
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 6),
            spacing: 8
        ) {
            ForEach(Self.shichenTable, id: \.hour) { shichen in
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

    /// 12 时辰表(名 ↔ 中点小时;grid 选中态与日期行「X时」小标共用同一事实源)。
    private static let shichenTable: [(name: String, hour: Int)] = [
        ("子", 0), ("丑", 2), ("寅", 4), ("卯", 6),
        ("辰", 8), ("巳", 10), ("午", 12), ("未", 14),
        ("申", 16), ("酉", 18), ("戌", 20), ("亥", 22),
    ]

    /// 日期行右侧「未时 ›」小标的时辰名;边界规则与 grid 选中态一致(23 归子时)。
    private var currentShichenName: String {
        let hour = currentShichenHour()
        return Self.shichenTable.first(where: { $0.hour == hour })?.name ?? ""
    }

    /// 从 vm.birthTime 的当前 hour 反推用户选了哪个时辰(用于圆圈选中态与时刻行「X时」小标)。
    /// 时辰边界:[23,0,1]→子(0),[2,3]→丑(2),[4,5]→寅(4)... 奇数 hour 向下取偶到中点。
    /// 23 点归子时跨日(对齐后端 setSect(1) 规则)。
    /// hour 按出生城市时区取(S03 WYSIWYG,不随设备时区漂移)。
    private func currentShichenHour() -> Int {
        let hour = vm.placeCalendar.component(.hour, from: vm.birthTime)
        if hour == 23 { return 0 }
        return (hour / 2) * 2
    }

    // MARK: - 性别

    private var genderSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            fieldLabel(L10n.BirthForm.genderLabel)
            HStack(spacing: 14) {
                genderChip(L10n.BirthForm.genderMale, value: "male")
                genderChip(L10n.BirthForm.genderFemale, value: "female")
            }
        }
    }

    /// 性别 chip(原型 .gchip):未选 hairline 描边空底 + 弱墨字;选中浓墨实底 + 纸色字。
    /// tag 值沿用 "male"/"female",与后端契约一致(仅换控件形态,不改语义)。
    private func genderChip(_ title: String, value: String) -> some View {
        let isSelected = vm.gender == value
        return Button {
            HapticEngine.light()
            vm.gender = value
        } label: {
            Text(title)
                .font(BaziFont.body(size: 15))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(isSelected ? BaziTheme.paper : BaziTheme.inkMuted)
                .background(
                    RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                        .fill(isSelected ? BaziTheme.ink : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                        .stroke(BaziTheme.ink.opacity(isSelected ? 0 : 0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 出生地

    private var placeSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            fieldLabel(L10n.BirthForm.birthplaceLabel)
            // S05:全球城市搜索 + sheet 内「自定义地点」(经度+时区必填)
            CityPickerField(selection: $vm.selectedPlace, style: .underlined)
            Text(L10n.CitySearch.customEntryHint)
                .font(BaziFont.caption(size: 10))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
    }

    // MARK: - 校验错误(内联,卡片底让位纯文字)

    @ViewBuilder
    private var formErrorBlock: some View {
        if case .formInvalid(let errors) = vm.state {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(errors, id: \.self) { err in
                    Text("• \(err)")
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.destructive)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, BaziTheme.Spacing.xs)
        }
    }

    // MARK: - O2 无框下划线 section

    /// 下划线字段 section(原型 .field):Micro 标签 + 无框输入行 + 底部 hairline;
    /// 聚焦转朱红 2pt(DESIGN.md §Color「聚焦线」授权场景)。
    private func fieldSection<Content: View>(
        title: String,
        focused: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            fieldLabel(title)
            content()
                .padding(.bottom, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(focused ? BaziTheme.cinnabar : BaziTheme.hairline)
                        .frame(height: focused ? 2 : 1)
                }
                .animation(.easeOut(duration: 0.25), value: focused)
        }
    }

    /// 字段 Micro 标签(原型 .label:10.5pt + .3em 字距 + 弱墨)。
    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(BaziFont.caption(size: 10.5))
            .tracking(3)
            .foregroundStyle(BaziTheme.inkMuted)
    }
}
