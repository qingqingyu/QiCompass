import SwiftUI

/// 出生信息表单(水墨孤本 O2 无框下划线语言,2026-08-29 重排)。
///
/// 参考 `docs/design-ref/shuimo/onboarding-o2-birthform.html`:
/// - 输入项去卡片化:Micro 标签(大字距)+ 无框输入 + 底部 hairline 下划线
/// - 聚焦态下划线转朱红加粗(DESIGN.md §Color:cinnabar 授权场景「聚焦线」,禁止 CTA/大面积)
/// - 性别双 chip:未选(含初始态,2026-09-19 去默认 male)hairline 描边空底,
///   选中浓墨实底(对齐原型 .gchip;组件在 InkKit.GenderChipRow 共享,合盘同款)
/// - 日期行 + 时刻行 = 两个数值行(S03 拆双 picker;2026-09-23 时刻去默认值:
///   两者未选均显灰占位、validateForm 拦截,锚点只是表盘位置非值)
/// - **时刻三入口合并(2026-09-23,原 S04 toggle + 时辰快选 DisclosureGroup 退役)**:
///   表单常驻单一时刻行,三态显示(已选/未选/未知);点开 sheet 内三枚模式 chip
///   选「精确时间 wheel / 只知道时辰圆格 / 不知道」。「不知道」= D1 时辰未知降级
///   路径(点选即收起 sheet,半夜三态问 D3 在表单展开);D1「单一入口系统分流」
///   精神不变——入口比原 toggle 方案更单一,且不引入「猜/接受不准」元选择
/// - 出生地 = CityPickerField 下划线变体(城市搜索引擎与排序不动)
/// - CTA 换 PrimaryCTAButton(inkDeep 底 + onInkDeep 字 + 朱色菱形印点,radius 5)
///
/// 语义不变(重排不是重构):字段绑定 / 校验逻辑 / 时辰快捷选(取时辰中点)/
/// setSect(1) 子时归子规则全部保留。
/// 共享组件:onboarding O2(OnboardingView formPage)/ 深度解析无存档兜底(DeepAnalysisView)
/// 两处复用;M4/M5 专属定制不在本视图做(独立任务)。
struct BirthFormView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let onSubmit: () -> Void

    /// 键盘聚焦域(仅别名是真键盘输入框;聚焦下划线转朱红)。
    private enum Field: Hashable {
        case alias
    }

    /// 时刻 sheet 模式(2026-09-23 三入口合并)。
    private enum TimeMode {
        case exact
        case shichen
        case unknown
    }

    @FocusState private var focusedField: Field?
    @State private var showDatePicker = false
    @State private var showTimePicker = false
    @State private var timeMode: TimeMode = .exact

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
                aliasSection
                    .riseIn(delay: 0.10)
                dateSection
                    .riseIn(delay: 0.18)
                genderSection
                    .riseIn(delay: 0.34)
                placeSection
                    .riseIn(delay: 0.42)

                formErrorBlock

                PrimaryCTAButton(
                    title: L10n.BirthForm.ctaStart,
                    loadingTitle: L10n.BirthForm.ctaLoading,
                    // 排盘中置灰防双发(2026-09-08 收起态:排盘后台继续,CTA 不可再点;
                    // 未收起时表单不显示,该值恒 false 无行为变化)
                    isLoading: vm.isCalculating,
                    action: onSubmit
                )
                .padding(.top, BaziTheme.Spacing.md)
                .riseIn(delay: 0.5)
            }
            // 排盘中冻结编辑(2026-09-08 收起态数据一致性):收起回表单时排盘仍按
            // 提交快照在飞,若放行编辑,落定后自动流转的盘(.ready/生肖 reveal)与
            // 表单当前输入不一致,且 onboarding 无重排入口。冻结后「改输入」的唯一
            // 路径是横幅「×」取消——与「取消保留输入、改完再发」流程自洽。未收起
            // 时表单不显示,该值恒 false 无行为变化。
            // 挂点在内层 VStack 而非 ScrollView:disabled 禁的是表单控件的 interaction,
            // 滚动手势必须保留——收起态顶部多一条横幅,小屏表单超屏依赖滚动可达底部。
            .disabled(vm.isCalculating)
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

    // MARK: - 出生日期与时刻(S03 拆双 picker + 2026-09-23 三入口合并)

    /// 日期区 = 日期行(date-only wheel sheet)+ 常驻时刻行(点开 sheet 选模式:
    /// 精确 wheel / 时辰圆格 / 不知道)+ 半夜三态问题(「不知道」后展开,D3)
    /// + 教育微文案(D8)。
    /// 收起/展开动画:easeOut 0.25s 纯淡入(DESIGN.md 动效约束,无弹簧无位移)。
    private var dateSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            dateRow
            timeRow
            if !vm.hourKnown {
                lateNightSection
                    .transition(.opacity)
            }
            // D8 把矛盾变成教育:日期为什么必填、时刻为什么可跳过。
            // 字距语言分支(2026-09-23 review #8):拉丁长句正常字距,CJK 保留微字距。
            Text(L10n.BirthForm.dateEducationHint)
                .font(BaziFont.caption(size: 10))
                .tracking(AppLanguage.current.isChinese ? 1 : 0)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .animation(.easeOut(duration: 0.25), value: vm.hourKnown)
    }

    /// 二值半夜问题(D3):「你是否在半夜(约 11 点之后)出生?」三态 是/否/不确定。
    /// 默认未选,**必须选一个才可提交**(不把「不确定」设默认——避免又一层默认假答案)。
    /// chip 形态对齐性别 chip(未选 hairline 描边,选中浓墨实底)。
    private var lateNightSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            fieldLabel(L10n.BirthForm.lateNightQuestion)
            HStack(spacing: 10) {
                lateNightChip(L10n.BirthForm.lateNightYes, choice: .yes)
                lateNightChip(L10n.BirthForm.lateNightNo, choice: .no)
                lateNightChip(L10n.BirthForm.lateNightUnsure, choice: .unsure)
            }
            // D3「用途对用户可见」:这一问只为确认日柱(换日边界),不做别的
            Text(L10n.BirthForm.lateNightHint)
                .font(BaziFont.caption(size: 10))
                .tracking(AppLanguage.current.isChinese ? 1 : 0)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
    }

    /// 半夜三态 chip(选中态语义与性别 chip 同构;选中值走 LateNightChoice,提交时映射 Bool?)。
    private func lateNightChip(_ title: String, choice: LateNightChoice) -> some View {
        let isSelected = vm.lateNightChoice == choice
        return Button {
            HapticEngine.light()
            vm.lateNightChoice = choice
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

    /// 时刻行(2026-09-23 三入口合并后常驻),三态:
    /// 已选(黑字 HH:mm + 时辰 tag)/ 未选(灰占位,镜像日期行)/ 未知(「不知道时刻」,
    /// 下方展开半夜问)。trailing 一律显式 String 拼接——不用 `Text("\(x)时 ›")`
    /// 的 LocalizedStringKey 插值(EN 会漏中文「时」,xcstrings 无该格式 key 翻译)。
    private var timeRow: some View {
        fieldSection(title: L10n.BirthForm.birthTimeLabel) {
            Button {
                HapticEngine.light()
                // 打开 sheet 落在当前态对应的模式(未知态重开 → unknown 模式 + 提示行)
                timeMode = vm.hourKnown ? .exact : .unknown
                showTimePicker = true
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text(timeRowValue)
                        .font(BaziFont.numeric(size: 15))
                        .foregroundStyle(isTimeRowPlaceholder ? BaziTheme.inkMutedSecondary : BaziTheme.ink)
                    Spacer(minLength: BaziTheme.Spacing.sm)
                    Text(timeTrailingTag)
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.BirthForm.datePickerTitleTime)
            .accessibilityValue(timeRowAccessibilityValue)
        }
        .sheet(isPresented: $showTimePicker) {
            timePickerSheet
        }
    }

    /// 时刻行值:未知 →「不知道时刻」;已知未选 → 灰占位;已知已选 → HH:mm。
    private var timeRowValue: String {
        if !vm.hourKnown { return L10n.BirthForm.timeRowUnknown }
        return vm.birthTimePicked ? vm.wallBirthTimeString : L10n.BirthForm.birthTimePlaceholder
    }

    /// 未知与未选态是「非值」表达,走弱墨占位色(对齐日期行未选处理)。
    private var isTimeRowPlaceholder: Bool {
        vm.hourKnown && !vm.birthTimePicked
    }

    /// 时刻行右侧 tag:已选才显时辰名(zh「未时」/ en "Wei (1–3 PM)",ShichenDisplay
    /// 单一事实源);未选/未知只显 ›。
    private var timeTrailingTag: String {
        guard vm.hourKnown, vm.birthTimePicked else { return "›" }
        return "\(currentShichenTag) ›"
    }

    private var timeRowAccessibilityValue: String {
        guard vm.hourKnown, vm.birthTimePicked, !currentShichenTag.isEmpty else {
            return timeRowValue
        }
        return "\(timeRowValue) \(currentShichenTag)"
    }

    /// 日期 wheel sheet:date-only,必选(未选择初始态;seed 只作表盘初始位置,未拨动不写回)。
    /// 头部带「确定」收起入口(2026-09-07):live 绑定拨动即写回,确定=收起;
    /// 下滑手势仍可用且同样保留已选值;未拨动确定收起后保持 nil(validateForm 拦截)。
    /// 2026-09-19 去预填感:未选择时头部副题明示(系统 wheel 无法空白表盘,
    /// 种子锚点只是位置非值),拨动写回后副题消失。
    private var datePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            WheelSheetHeader(
                title: L10n.BirthForm.datePickerTitleDate,
                subtitle: vm.birthDate == nil ? L10n.BirthForm.dateUnselectedHint : nil,
                confirm: { showDatePicker = false }
            )
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

    /// 时刻 sheet(2026-09-23 三入口合并):三枚模式 chip + 对应内容。
    /// - 精确时间:hourAndMinute wheel(live 写回 + 置 birthTimePicked)
    /// - 只知道时辰:12 圆格(setShichenHour 中点小时)
    /// - 不知道:点选即走 D1 降级路径(setHourKnown(false))并收起 sheet,
    ///   半夜三态问(D3)在表单展开;重开 sheet 停留 unknown 模式显提示行
    /// 无「不晚于当下」范围——单时刻无从与当下比较,未来校验落在日期+时刻合成值上(VM.validateForm)。
    private var timePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            WheelSheetHeader(
                title: L10n.BirthForm.datePickerTitleTime,
                // 去预填感同日期 sheet:锚点只是表盘位置非值,未拨动明示
                subtitle: (timeMode == .exact && !vm.birthTimePicked)
                    ? L10n.BirthForm.dateUnselectedHint : nil,
                confirm: { showTimePicker = false }
            )
            HStack(spacing: 10) {
                modeChip(L10n.BirthForm.timeModeExact, mode: .exact)
                modeChip(L10n.BirthForm.timeModeShichen, mode: .shichen)
                modeChip(L10n.BirthForm.timeModeUnknown, mode: .unknown)
            }
            switch timeMode {
            case .exact:
                DatePicker(
                    "",
                    selection: timePickerBinding,
                    displayedComponents: [.hourAndMinute]
                )
                .datePickerStyle(.wheel)
                .labelsHidden()
                // WYSIWYG:表盘按出生城市时区显示(S03;换算责任在后端 zoneinfo)
                .environment(\.calendar, vm.placeCalendar)
            case .shichen:
                shichenGrid
            case .unknown:
                Text(L10n.BirthForm.timeModeUnknownHint)
                    .font(BaziFont.caption(size: 11))
                    .tracking(AppLanguage.current.isChinese ? 1 : 0)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, BaziTheme.Spacing.sm)
            }
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
        .padding(.vertical, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaziTheme.paper)
    }

    /// 模式 chip(GenderChipRow 同款 hairline/墨底样式;三枚等宽)。
    private func modeChip(_ title: String, mode: TimeMode) -> some View {
        let isSelected = timeMode == mode
        return Button {
            HapticEngine.light()
            selectTimeMode(mode)
        } label: {
            Text(title)
                .font(BaziFont.body(size: 14))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
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

    /// 模式切换语义(单一职责在 VM 既有 API 上):
    /// - 选「不知道」→ setHourKnown(false)(三态问表单展开)+ 收起 sheet
    /// - 从不知道切回精确/时辰 → setHourKnown(true)(三态答案重置,既有语义)
    /// - sheet 内停留展示对应选择器,「确定」= 收起
    private func selectTimeMode(_ mode: TimeMode) {
        if mode == .unknown {
            if vm.hourKnown {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.setHourKnown(false)
                }
            }
            timeMode = .unknown
            showTimePicker = false
        } else {
            if !vm.hourKnown {
                withAnimation(.easeOut(duration: 0.25)) {
                    vm.setHourKnown(true)
                }
            }
            timeMode = mode
        }
    }

    /// 时刻 wheel 桥:拨动即写回并置 `birthTimePicked`(2026-09-23 时刻去默认值,
    /// 锚点只是表盘位置,用户拨过才算选;系统 wheel 无法空白表盘,故走标记位而非 Date?)。
    private var timePickerBinding: Binding<Date> {
        Binding(
            get: { vm.birthTime },
            set: { newValue in
                vm.birthTime = newValue
                vm.birthTimePicked = true
            }
        )
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

    // MARK: - 时辰圆格(2026-09-23 从表单 DisclosureGroup 移入时刻 sheet)

    /// 12 时辰圆格(sheet「只知道时辰」模式)。zh 单地支字;EN 拼音 + 时段小字
    /// (ShichenDisplay 单一事实源,review #6:EN 不再裸显「子丑寅卯」)。
    private var shichenGrid: some View {
        let selectedHour = currentShichenHour()
        let isChinese = AppLanguage.current.isChinese
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible()), count: 6),
            spacing: 8
        ) {
            ForEach(Self.shichenTable, id: \.hour) { shichen in
                let isSelected = selectedHour == shichen.hour
                Button {
                    HapticEngine.light()
                    vm.setShichenHour(shichen.hour)
                } label: {
                    Group {
                        if isChinese {
                            Text(ShichenDisplay.name(forMidHour: shichen.hour))
                                .font(.body.weight(.medium))
                        } else {
                            VStack(spacing: 1) {
                                Text(ShichenDisplay.name(forMidHour: shichen.hour))
                                    .font(.footnote.weight(.medium))
                                Text(ShichenDisplay.range(forMidHour: shichen.hour))
                                    .font(BaziFont.caption(size: 7))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                    .frame(width: 48, height: 44)
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

    /// 12 时辰表(中点小时 ↔ 表内顺序;选中态与时刻行 tag 共用同一事实源。
    /// 显示名走 ShichenDisplay,表只管 hour 映射)。
    private static let shichenTable: [(name: String, hour: Int)] = [
        ("子", 0), ("丑", 2), ("寅", 4), ("卯", 6),
        ("辰", 8), ("巳", 10), ("午", 12), ("未", 14),
        ("申", 16), ("酉", 18), ("戌", 20), ("亥", 22),
    ]

    /// 时刻行右侧时辰 tag(zh「未时」/ en "Wei (1–3 PM)",ShichenDisplay 单一事实源);
    /// 边界规则与 grid 选中态一致(23 归子时)。
    private var currentShichenTag: String {
        ShichenDisplay.tag(forMidHour: currentShichenHour())
    }

    /// 从 vm.birthTime 的当前 hour 反推用户选了哪个时辰(用于圆圈选中态与时刻行 tag)。
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
            // 2026-09-19:换共享 GenderChipRow(原私有 genderChip 抽取)+ 性别去默认值
            // ——vm.gender 改 String?,nil = 两 chip 均未选的初始态,提交被 validateForm 拦
            GenderChipRow(selection: $vm.gender)
        }
    }

    // MARK: - 出生地

    private var placeSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            fieldLabel(L10n.BirthForm.birthplaceLabel)
            // S05:全球城市搜索 + sheet 内「自定义地点」(经度+时区必填)
            CityPickerField(selection: $vm.selectedPlace, style: .underlined)
            Text(L10n.CitySearch.customEntryHint)
                .font(BaziFont.caption(size: 10))
                .tracking(AppLanguage.current.isChinese ? 1 : 0)
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
