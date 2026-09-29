import SwiftUI

// MARK: - 添加/修改对方表单主体(S2 抽取,2026-09-29)

/// 添加/修改对方表单主体(从 CompatibilityConfigView.AddPersonSheet 抽出,P2/S2)。
///
/// **行为一律不变**:字段(称呼 / 出生日期行 / 出生时刻行 / 性别 / 出生地
/// CityPickerField)、默认值(日期 nil、性别 nil、出生地必选——2026-09-19 去
/// 默认值口径)、校验(validateTempForm)、wheel sheet 行为(live 拨动即写回 +
/// 确定收起)。唯一变化:字符串收编 L10n 键(字段标签复用 L10n.BirthForm)。
///
/// 宿主形态:换人 sheet 内 NavigationStack push 页(PartnerPickerSheet;唯一形态,
/// 2026-09-29 S5 配置页半屏 sheet 宿主随配置页退役)。
///
/// 成功路径经 `onAdded` / `onUpdated` 上抛宿主决定后续——P4 语义(添加即选中
/// 并合盘)在换人 sheet 宿主实现;表单自身只负责校验、入册/替换、草稿重置与
/// 错误显式留在表单内(不关不吞)。
struct PartnerBirthForm: View {
    @Bindable var vm: CompatibilityViewModel
    /// 修改目标(nil = 添加模式;var + 默认值供 memberwise init 注入)。
    var editing: RosterEntry? = nil
    /// 添加成功(参数 = 新入册 entry;表单已重置草稿,宿主负责关闭 + P4 选中)。
    var onAdded: ((RosterEntry) -> Void)? = nil
    /// 修改成功(参数 = 旧 entry、新 entry;输入未变时两者 id 相同——宿主据此
    /// 判断是否需要 force 重算)。
    var onUpdated: ((RosterEntry, RosterEntry) -> Void)? = nil
    /// 表单脚注(宿主按上下文给文案:sheet 型与 push 型语义不同)。
    var footnote: String = ""
    /// 「称呼」字段外部聚焦绑定(S3 P5:点头部占位 = 聚焦内联表单称呼字段;
    /// nil = 无宿主聚焦,半屏 sheet / push 页不传)。
    var aliasFocus: FocusState<Bool>.Binding? = nil

    private var isEditing: Bool { editing != nil }

    /// 表单内错误(校验/重复错误留在表单内,不关不吞;改任一字段即清除)。
    @State private var formError: String?

    /// 日期/时刻 wheel sheet 开关(2026-09-07 双行改造)。
    @State private var showDatePicker = false
    @State private var showTimePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 可选「称呼」字段(留空走兜底名「对方+出生日期」)
            HStack {
                Text(L10n.CompatibilityPartner.formAliasLabel)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .font(BaziFont.caption(size: 12))
                aliasTextField
            }

            // 日期/时刻双行(2026-09-07:row + wheel sheet + 确定;2026-09-19 起镜像
            // 深度表单 S03 拆双字段:tempBirthDate 未选必选(nil 起步)+ tempBirthTime
            // 独立绑定,提交时 VM.combinedTempBirthDate() 合成)
            birthDateRow
            birthTimeRow

            // 性别(2026-09-19 去默认值:两 chip 均未选是合法初始态,提交被拦「请选择性别」)
            HStack(spacing: 12) {
                Text(L10n.BirthForm.genderLabel)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .font(BaziFont.caption(size: 12))
                GenderChipRow(selection: $vm.tempGender)
            }

            // S05:全球城市搜索 + sheet 内自定义地点(与深度解析同一组件)
            CityPickerField(selection: $vm.tempPlace)

            if let formError {
                Text(formError)
                    .font(BaziFont.caption(size: 11))
                    .foregroundStyle(BaziTheme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                if isEditing {
                    saveEdit()
                } else {
                    addTemp()
                }
            } label: {
                HStack {
                    if !isEditing {
                        Image(systemName: "plus.circle.fill")
                    }
                    Text(isEditing
                         ? L10n.CompatibilityPartner.formCtaEdit
                         : L10n.CompatibilityPartner.formCtaAdd)
                }
                .font(BaziFont.button(size: 15))
                .foregroundStyle(formError == nil ? BaziTheme.onInkDeep : BaziTheme.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    // 错误态 CTA 置灰(改任一字段即重新可用,错误同时清除)
                    formError == nil ? BaziTheme.inkDeep : BaziTheme.inkDeep.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 5)
                )
            }
            // 满员只拦「加」不拦「改」(修改原位替换,不占新名额;与满员提示口径一致)
            .disabled((!isEditing && vm.roster.count >= CompatibilityViewModel.rosterMax)
                      || formError != nil)

            if !footnote.isEmpty {
                Text(footnote)
                    .font(BaziFont.caption(size: 10))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
        // 配套:任一字段变更即清错误(重复/校验错误不再黏住,CTA 随之恢复)
        .onChange(of: vm.tempAlias) { _, _ in formError = nil }
        .onChange(of: vm.tempBirthDate) { _, _ in formError = nil }
        .onChange(of: vm.tempBirthTime) { _, _ in formError = nil }
        .onChange(of: vm.tempGender) { _, _ in formError = nil }
        .onChange(of: vm.tempPlace) { _, _ in formError = nil }
    }

    // MARK: - 称呼字段(S3:外部聚焦绑定可选)

    /// 「称呼」输入框(有宿主聚焦绑定时挂 .focused——P5 点头部占位直达)。
    @ViewBuilder
    private var aliasTextField: some View {
        if let aliasFocus {
            baseAliasTextField
                .focused(aliasFocus)
        } else {
            baseAliasTextField
        }
    }

    private var baseAliasTextField: some View {
        TextField(L10n.CompatibilityPartner.formAliasPlaceholder, text: $vm.tempAlias)
            .font(BaziFont.body(size: 14))
            .foregroundStyle(BaziTheme.ink)
            .padding(BaziTheme.Spacing.sm)
            .background(BaziTheme.paper, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }

    // MARK: - 出生日期/时刻双行(2026-09-07:compact 弹层无确定 → row + wheel sheet)

    /// 出生日期行(点开 date-only wheel sheet;值按对方出生地钟面取;
    /// 2026-09-19 未选 → 占位弱墨,与 BirthFormView 日期行同式)。
    private var birthDateRow: some View {
        Button {
            HapticEngine.light()
            showDatePicker = true
        } label: {
            pickerRowLabel(
                title: L10n.BirthForm.birthDateLabel,
                value: tempBirthDateString,
                isPlaceholder: vm.tempBirthDate == nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.BirthForm.birthDateLabel)
        .accessibilityValue(tempBirthDateString)
        .sheet(isPresented: $showDatePicker) { tempDatePickerSheet }
    }

    /// 出生时刻行(点开 hourAndMinute wheel sheet)。
    private var birthTimeRow: some View {
        Button {
            HapticEngine.light()
            showTimePicker = true
        } label: {
            pickerRowLabel(title: L10n.BirthForm.birthTimeLabel, value: tempBirthTimeString)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.BirthForm.birthTimeLabel)
        .accessibilityValue(tempBirthTimeString)
        .sheet(isPresented: $showTimePicker) { tempTimePickerSheet }
    }

    /// 双行共用行体(与「称呼」字段同款纸底 hairline 盒:标签居左弱墨,值居右浓墨 + ›)。
    /// isPlaceholder=true 时值降为弱墨次级色(2026-09-19 日期未选占位,对齐 BirthFormView 日期行)。
    private func pickerRowLabel(title: String, value: String, isPlaceholder: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
            Text(value)
                .font(BaziFont.body(size: 14))
                .foregroundStyle(isPlaceholder ? BaziTheme.inkMutedSecondary : BaziTheme.ink)
            Text("›")
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .padding(BaziTheme.Spacing.sm)
        .background(BaziTheme.paper, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }

    /// 出生日期 wheel sheet(date-only,不晚于当下;确定=收起,live 拨动即写回)。
    /// 2026-09-19 去预填感:未选择时头部副题明示(镜像 BirthFormView 日期弹层)。
    private var tempDatePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            WheelSheetHeader(
                title: L10n.BirthForm.datePickerTitleDate,
                subtitle: vm.tempBirthDate == nil ? L10n.BirthForm.dateUnselectedHint : nil
            ) { showDatePicker = false }
            DatePicker(
                "",
                selection: tempDateOnlyBinding,
                in: ...Date(),
                displayedComponents: [.date]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            // WYSIWYG:表盘按对方出生地时区(S05;解释责任在后端 zoneinfo)
            .environment(\.calendar, vm.tempPlaceCalendar)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
        .padding(.vertical, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaziTheme.paper)
    }

    /// 出生时刻 wheel sheet(hourAndMinute;无「不晚于当下」范围——单时刻无从比较,
    /// 未来校验落在日期+时刻合成值上,validateTempForm 提交时拦)。
    /// 2026-09-19 拆双字段:直绑 tempBirthTime(镜像 BirthFormView.timePickerSheet)。
    private var tempTimePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            WheelSheetHeader(title: L10n.BirthForm.datePickerTitleTime) { showTimePicker = false }
            DatePicker(
                "",
                selection: $vm.tempBirthTime,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            // WYSIWYG:表盘按对方出生地时区(S05;解释责任在后端 zoneinfo)
            .environment(\.calendar, vm.tempPlaceCalendar)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
        .padding(.vertical, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaziTheme.paper)
    }

    // MARK: - 日期/时刻绑定与行文案(2026-09-19 拆双字段,镜像 BirthFormView)

    /// 日期分量绑定(镜像 BirthFormView.datePickerBinding):未选时以
    /// `DeepAnalysisViewModel.defaultBirthTimeAnchor` 作表盘初始位置,单一事实源
    /// 不复制魔数;仅位置非值——未拨动不写回,提交 nil 被 validateTempForm 拦。
    /// 拨动写回 tempBirthDate(该日的时分由 tempBirthTime 独立承载,提交时
    /// VM.combinedTempBirthDate() 合成、秒归 0)。
    private var tempDateOnlyBinding: Binding<Date> {
        Binding(
            get: { vm.tempBirthDate ?? DeepAnalysisViewModel.defaultBirthTimeAnchor },
            set: { vm.tempBirthDate = $0 }
        )
    }

    /// 出生日期行文案(公历长日期,对方出生地钟面;与 BirthFormView.birthDateText
    /// 同式;2026-09-19 未选 → 占位「请选择日期」)。
    private var tempBirthDateString: String {
        guard let birthDate = vm.tempBirthDate else {
            return L10n.BirthForm.birthDatePlaceholder
        }
        let formatter = DateFormatter()
        formatter.calendar = vm.tempPlaceCalendar
        formatter.timeZone = vm.tempPlaceCalendar.timeZone
        formatter.locale = .current
        formatter.dateStyle = .long
        return formatter.string(from: birthDate)
    }

    /// 出生时刻行文案(HH:mm,对方出生地钟面;POSIX 模板防系统格式注入;
    /// 时刻独立绑定后恒有锚点值,与深度表单时刻行「保留默认值语义」一致)。
    private var tempBirthTimeString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = vm.tempPlaceCalendar.timeZone
        return formatter.string(from: vm.tempBirthTime)
    }

    // MARK: - 提交(成功上抛宿主;错误留在表单内)

    private func addTemp() {
        do {
            let added = try vm.addTempToRoster()
            // 成功:清草稿(可重开连加);P4 选中/关闭由宿主经 onAdded 决定
            vm.resetTempDraftForm()
            onAdded?(added)
        } catch {
            // 不静默吞(CLAUDE.md):UserFacingError(表单校验/重复)文案原样留在表单;
            // 意外错误(存储层)记日志 + 人话兜底
            if let userError = error as? UserFacingError {
                formError = userError.errorDescription
            } else {
                AppLogger.app.error(
                    "compat.addTemp.unexpected_error error=\(String(describing: error), privacy: .public)"
                )
                formError = L10n.CompatibilityPartner.formErrorAdd
            }
        }
    }

    /// 修改保存:原位替换后上抛宿主(草稿还原由宿主在离开表单时统一处理,
    /// 覆盖保存/取消/返回三条路径)。
    private func saveEdit() {
        guard let entry = editing else { return }
        do {
            let updated = try vm.updateTempEntry(entry)
            onUpdated?(entry, updated)
        } catch {
            // 错误面与添加一致:校验/重复文案留在表单内,不关不吞
            if let userError = error as? UserFacingError {
                formError = userError.errorDescription
            } else {
                AppLogger.app.error(
                    "compat.saveEdit.unexpected_error error=\(String(describing: error), privacy: .public)"
                )
                formError = L10n.CompatibilityPartner.formErrorEdit
            }
        }
    }
}
