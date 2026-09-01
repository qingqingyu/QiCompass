import SwiftUI

// MARK: - 错误(S10)

/// 补时辰链路错误。errorDescription = 用户可见人话文案(2026-08-16 ErrorCode 清理
/// 口径:技术细节不进 UI);hash 等细节留 associated value,由调用点 AppLogger 记录。
enum AddHourError: Error, LocalizedError {
    /// 触点目标命盘存档缺失(触点状态错乱;上层不应打开 sheet)
    case targetSnapshotMissing(contentHash: String)
    /// 老快照 cityTimezone nil / 非法(S03 之前)——时辰未知盘不可能早于 S03,
    /// 出现即数据损坏,不用设备时区静默兜底
    case timezoneMissing(contentHash: String)
    /// 出生日期 + 新时辰按出生地钟面合成失败(防御性,理论不可达)
    case combineFailed(contentHash: String)
    /// 重算响应 hash 与老盘相同(补时辰未生效 / 后端归一异常)——显式报错,
    /// 不静默接受「假闭环」(付费墙/判据都不会翻转)
    case hashNotChanged(contentHash: String)

    var errorDescription: String? {
        switch self {
        case .targetSnapshotMissing, .timezoneMissing:
            return L10n.AddHour.errorRebuild
        case .combineFailed, .hashNotChanged:
            return L10n.AddHour.errorSubmit
        }
    }
}

// MARK: - ViewModel

/// 补时辰 sheet 的 VM(S10,D7 补时辰升级闭环的单一入口组件)。
///
/// **编辑场景隔离**(生肖决策 Q20:本入口只管补时辰):不重填姓名/性别/地点/日期,
/// 全部从老盘存档原样带过;补的是**确定时辰** → `late_night` 作废清空(D3 二值问题
/// 只为日柱歧义判断,时辰确定后无意义)。提交 = 「原出生日期 + 新时辰 + 原
/// gender/place」重算 → **新 content_hash 新命盘,老三柱盘归档保留**(内容寻址,
/// ChartSnapshot 不删即归档;缓存按新 hash 自然重建 → 付费墙/每日运势判据随
/// payload `hour_known=true` 自然翻转,S07/S11 零额外改动)。
///
/// **link 语义**:老盘有 UserSnapshotLink(命主 / Profile 新建的他人盘)→ 新盘按
/// **原 alias** 补写 link(名字不丢,「妈妈」还是「妈妈」);老盘无 link(合盘临时人
/// 隐式落地的盘)→ 新盘同样不建(D6 红线「临时人不建 link」)。
///
/// **他人盘**:同一入口同样适用于合盘 roster 里的他人命盘;重算后
/// `CompatibilityRosterPersistence.remapHash` 把名单 hash 换新,对级关系自然重算。
@Observable
@MainActor
final class AddHourViewModel {

    enum Phase: Equatable {
        case idle
        case submitting
        case failed(String)
    }

    // MARK: 依赖与目标

    let snapshot: ChartSnapshot
    private let orchestrator: DeepAnalysisOrchestrator
    private let chartStore: ChartSnapshotStore
    private let linkStore: UserSnapshotLinkStore

    /// 出生城市时区(老盘存档;make 时已校验非 nil)。wheel/快捷选表盘 = 出生城市
    /// 钟面(WYSIWYG,与 BirthFormView 同语义),换算责任在后端 zoneinfo。
    let placeTimeZone: TimeZone

    // MARK: 状态

    private(set) var phase: Phase = .idle

    /// 时刻绑定(wheel + 时辰快捷选共用;只取钟面时分,与 BirthFormView.birthTime 同语义)。
    var birthTime: Date = DeepAnalysisViewModel.defaultBirthTimeAnchor

    /// 「我确实不知道」静默态(D7 永久无时辰用户):初始自老盘 payload;toggle 即
    /// **写穿存档**(开启 → 三触点降静默;关闭 → 提示恢复)。静默是尊重不是惩罚。
    private(set) var hourUnknownAccepted: Bool

    /// 老盘 link 的展示别名(sheet 标题「为「妈妈」补充出生时辰」);nil = 老盘无
    /// link(临时人)→ 标题退普通版,且提交后不建 link。
    let displayAlias: String?

    private init(
        snapshot: ChartSnapshot,
        placeTimeZone: TimeZone,
        displayAlias: String?,
        hourUnknownAccepted: Bool,
        orchestrator: DeepAnalysisOrchestrator,
        chartStore: ChartSnapshotStore,
        linkStore: UserSnapshotLinkStore
    ) {
        self.snapshot = snapshot
        self.placeTimeZone = placeTimeZone
        self.displayAlias = displayAlias
        self.hourUnknownAccepted = hourUnknownAccepted
        self.orchestrator = orchestrator
        self.chartStore = chartStore
        self.linkStore = linkStore
    }

    /// 四触点共用工厂:按老盘 hash 装配(存档缺失 / payload 损坏 / 时区缺失 →
    /// 显式 throw,宿主 catch 后人话报错,不静默不打开空 sheet)。
    static func make(
        snapshotHash: String,
        orchestrator: DeepAnalysisOrchestrator,
        chartStore: ChartSnapshotStore,
        linkStore: UserSnapshotLinkStore
    ) throws -> AddHourViewModel {
        guard let snapshot = try chartStore.get(contentHash: snapshotHash) else {
            throw AddHourError.targetSnapshotMissing(contentHash: snapshotHash)
        }
        let payload = try chartStore.decodeResponse(from: snapshot)
        guard let tzName = snapshot.cityTimezone, let tz = TimeZone(identifier: tzName) else {
            throw AddHourError.timezoneMissing(contentHash: snapshotHash)
        }
        let alias = try linkStore.findAlias(snapshotHash: snapshotHash)
        return AddHourViewModel(
            snapshot: snapshot,
            placeTimeZone: tz,
            displayAlias: alias,
            hourUnknownAccepted: payload.isHourSilenced,
            orchestrator: orchestrator,
            chartStore: chartStore,
            linkStore: linkStore
        )
    }

    /// 出生地时区 Calendar(wheel / 时辰快捷选挂它)。
    var placeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = placeTimeZone
        return calendar
    }

    // MARK: - 时辰快捷选(与 BirthFormView 同语义:写时刻绑定,中点小时)

    func setShichenHour(_ hour: Int) {
        if let newTime = placeCalendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: birthTime
        ) {
            birthTime = newTime
        }
    }

    // MARK: - 静默态(D7「我确实不知道」)

    /// 静默态开关,toggle 即写穿老盘 payload(开/关都立即落档;消费方每次现读
    /// payload,无需通知)。写失败 → phase 显式报错,不吞不留 UI 假状态。
    func setHourUnknownAccepted(_ accepted: Bool) {
        do {
            try chartStore.setHourUnknownAccepted(
                contentHash: snapshot.contentHash,
                accepted: accepted
            )
            hourUnknownAccepted = accepted
        } catch {
            AppLogger.persistence.error(
                "op=addHour.setHourUnknownAccepted failed hash=\(self.snapshot.contentHash, privacy: .public) accepted=\(accepted, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            phase = .failed(L10n.AddHour.errorSilenceSave)
        }
    }

    // MARK: - 提交(hash 重建闭环)

    /// 重建请求 → 重算 → 断言新 hash → link 补写(有则原 alias / 无则不建)→
    /// roster hash remap。返回新响应(nil = 失败,phase 已置 .failed 人话文案)。
    @discardableResult
    func submit() async -> BaziResponse? {
        phase = .submitting
        do {
            let calendar = placeCalendar
            let request = try snapshot.addHourRequest(
                hour: calendar.component(.hour, from: birthTime),
                minute: calendar.component(.minute, from: birthTime)
            )
            let response = try await orchestrator.runAddHourRecalculation(request: request)
            // 闭环断言:补时辰后 content_hash 必须变(2h 时辰桶参与计算,D7)。
            // 同 hash = 补时辰没生效(归一/契约异常),显式报错不假闭环。
            guard response.contentHash != snapshot.contentHash else {
                throw AddHourError.hashNotChanged(contentHash: snapshot.contentHash)
            }
            // link 补写:仅老盘有 link 时(编辑场景隔离——alias 继承;临时人不建,
            // D6)。盘已落库,link 失败不拦 UI(与 runCalculation 同降级策略:
            // 显式 error 日志,下次重排 upsert 命中重试)。
            if let alias = displayAlias {
                do {
                    _ = try linkStore.upsert(
                        userId: UserIdentity.userLocalId,
                        snapshotHash: response.contentHash,
                        alias: alias
                    )
                } catch {
                    AppLogger.persistence.error(
                        "op=addHour.submit userLink.upsert.failed newHash=\(response.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            }
            // 他人盘/自己盘换新 hash → 合盘名单持久化原地 remap(对级关系自然重算)
            CompatibilityRosterPersistence.remapHash(
                from: snapshot.contentHash,
                to: response.contentHash
            )
            AppLogger.app.info(
                "op=addHour.submit ok oldHash=\(self.snapshot.contentHash, privacy: .public) newHash=\(response.contentHash, privacy: .public) hasLink=\(self.displayAlias != nil, privacy: .public)"
            )
            phase = .idle
            return response
        } catch {
            AppLogger.app.error(
                "op=addHour.submit failed oldHash=\(self.snapshot.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            phase = .failed((error as? LocalizedError)?.errorDescription ?? L10n.AddHour.errorSubmit)
            return nil
        }
    }
}

// MARK: - Identifiable(sheet(item:) 装配用;老盘 hash 即身份)

extension AddHourViewModel: Identifiable {
    var id: String { snapshot.contentHash }
}

// MARK: - Sheet 视图

/// 补时辰 sheet(单一入口组件,D7 四触点全部指向这里)。
///
/// 只含时辰输入(wheel + 时辰快捷选,控件形态复用 BirthFormView 的时刻语言)+
/// 「我确实不知道」静默态确认。不重填姓名/性别/地点(编辑场景隔离,Q20)。
/// 顶部展示老盘锚点(别名 + 出生日期 + 出生地)让用户确认补的是哪张盘。
struct AddHourSheet: View {
    @Bindable var vm: AddHourViewModel
    /// 关闭(sheet dismiss;取消按钮与重算成功后都走这里,宿主在 onDismiss 统一刷新)。
    let onCancel: () -> Void
    /// 重算成功(新盘已存档 + link 已补写 + roster 已 remap;新响应透传给宿主,
    /// onboarding 生肖屏翻转完整 reveal 用)。
    let onRecalculated: (BaziResponse) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
                header
                anchorRow
                    .riseIn(delay: 0.10)
                if !vm.hourUnknownAccepted {
                    timeSection
                        .riseIn(delay: 0.18)
                }
                giveUpSection
                    .riseIn(delay: 0.26)

                if case .failed(let message) = vm.phase {
                    Text("• \(message)")
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                PrimaryCTAButton(
                    title: vm.hourUnknownAccepted ? L10n.AddHour.doneCta : L10n.AddHour.cta,
                    loadingTitle: L10n.AddHour.ctaLoading,
                    isLoading: vm.phase == .submitting,
                    action: submitOrDismiss
                )
                .padding(.top, BaziTheme.Spacing.md)
            }
            .padding(.horizontal, BaziTheme.Spacing.xxl)
            .padding(.vertical, BaziTheme.Spacing.lg)
        }
        .background(BaziTheme.cardSurface)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .animation(.easeOut(duration: 0.25), value: vm.hourUnknownAccepted)
    }

    // MARK: - 章头

    private var header: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            Text(vm.displayAlias.map { L10n.AddHour.forAlias($0) } ?? L10n.AddHour.title)
                .font(BaziFont.display(size: 20))
                .tracking(2)
                .foregroundStyle(BaziTheme.ink)
            Text(L10n.AddHour.subtitle)
                .font(BaziFont.caption(size: 11))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    /// 老盘锚点行:出生日期 · 出生地(只读;让用户确认补的是哪张盘,不提供编辑)。
    private var anchorRow: some View {
        HStack(spacing: 10) {
            Text(anchorText)
                .font(BaziFont.numeric(size: 13))
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
        }
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 1)
        }
    }

    /// 锚点串:「1990-02-04 · 北京」(出生城市钟面日期;无城市名 → 只日期)。
    private var anchorText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = vm.placeTimeZone
        let date = formatter.string(from: vm.snapshot.birthSolarTime)
        if let city = vm.snapshot.cityName, !city.isEmpty {
            return "\(date) · \(city)"
        }
        return date
    }

    // MARK: - 时辰输入(wheel + 快捷选,BirthFormView 同款形态)

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            fieldLabel(L10n.BirthForm.birthTimeLabel)
            DatePicker(
                "",
                selection: $vm.birthTime,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            // WYSIWYG:表盘按出生城市时区(换算责任在后端 zoneinfo)
            .environment(\.calendar, vm.placeCalendar)

            fieldLabel(L10n.BirthForm.hourQuickPickLabel)
            shichenGrid
        }
    }

    /// 12 时辰快捷选(圆圈选中态,BirthFormView.shichenGrid 同款;
    /// 选中值取时辰中点小时,23 归子时跨日规则由后端 setSect(1) 契约承接)。
    private var shichenGrid: some View {
        let selectedHour = currentShichenHour()
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

    /// 12 时辰表(名 ↔ 中点小时)。与 BirthFormView 私有表同值(该表 private,
    /// 不为接线扩大其可见性;两表语义由测试钉死一致性)。
    static let shichenTable: [(name: String, hour: Int)] = [
        ("子", 0), ("丑", 2), ("寅", 4), ("卯", 6),
        ("辰", 8), ("巳", 10), ("午", 12), ("未", 14),
        ("申", 16), ("酉", 18), ("戌", 20), ("亥", 22),
    ]

    /// 从 birthTime 反推当前时辰中点小时(奇数 hour 向下取偶;23 归子时)。
    private func currentShichenHour() -> Int {
        let hour = vm.placeCalendar.component(.hour, from: vm.birthTime)
        if hour == 23 { return 0 }
        return (hour / 2) * 2
    }

    // MARK: - 「我确实不知道」静默态(D7)

    /// checkbox 形态与 BirthFormView.hourUnknownToggle 同款(hairline 空圈 → 选中墨点);
    /// toggle 即写穿存档(开 → 三触点降静默;关 → 提示恢复)。
    private var giveUpSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            Button {
                HapticEngine.light()
                vm.setHourUnknownAccepted(!vm.hourUnknownAccepted)
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .stroke(BaziTheme.hairline, lineWidth: 1)
                        if vm.hourUnknownAccepted {
                            Circle()
                                .fill(BaziTheme.ink)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(L10n.AddHour.giveUpToggle)
                        .font(BaziFont.body(size: 14))
                        .foregroundStyle(vm.hourUnknownAccepted ? BaziTheme.ink : BaziTheme.inkMuted)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.AddHour.giveUpToggle)
            .accessibilityAddTraits(vm.hourUnknownAccepted ? [.isSelected] : [])

            Text(L10n.AddHour.giveUpHint)
                .font(BaziFont.caption(size: 10))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
    }

    // MARK: - 提交

    /// 静默态开启时 CTA = 完成(无重算可做);否则 = 保存并重算。
    private func submitOrDismiss() {
        guard !vm.hourUnknownAccepted else {
            onCancel()
            return
        }
        Task { @MainActor in
            if let newResponse = await vm.submit() {
                onRecalculated(newResponse)
                onCancel()
            }
        }
    }

    /// 字段 Micro 标签(BirthFormView.fieldLabel 同款形态)。
    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(BaziFont.caption(size: 10.5))
            .tracking(3)
            .foregroundStyle(BaziTheme.inkMuted)
    }
}
