import SwiftUI

/// 常用 IANA 时区表(S05 决策:~40 常用区 + Etc/GMT-X 固定偏移兜底,静态内嵌)。
///
/// 全部是合法 IANA 名,后端 zoneinfo 统一解释(历史夏令时对地区时区自动生效)。
/// 注意 IANA 反符号坑:**Etc/GMT-8 = UTC+8**(X 为正 = 东经),有专测钉死。
enum CommonTimezones {

    struct Item: Identifiable, Equatable {
        let iana: String
        /// 展示文案(如 "GMT+8 · 中国标准时间")
        let label: String
        var id: String { iana }
    }

    /// 常用地区时区(带样例说明;出生在这些区的人大概率能对上)。
    static let regions: [Item] = [
        Item(iana: "Asia/Shanghai", label: "GMT+8 · 中国标准时间"),
        Item(iana: "Asia/Hong_Kong", label: "GMT+8 · 香港时间"),
        Item(iana: "Asia/Taipei", label: "GMT+8 · 台北时间"),
        Item(iana: "Asia/Singapore", label: "GMT+8 · 新加坡时间"),
        Item(iana: "Asia/Tokyo", label: "GMT+9 · 日本时间"),
        Item(iana: "Asia/Seoul", label: "GMT+9 · 韩国时间"),
        Item(iana: "Asia/Bangkok", label: "GMT+7 · 泰国时间"),
        Item(iana: "Asia/Kolkata", label: "GMT+5:30 · 印度时间"),
        Item(iana: "Asia/Dubai", label: "GMT+4 · 海湾时间"),
        Item(iana: "Asia/Tehran", label: "GMT+3:30 · 伊朗时间"),
        Item(iana: "Australia/Sydney", label: "GMT+10/11 · 澳东时间"),
        Item(iana: "Australia/Perth", label: "GMT+8 · 澳西时间"),
        Item(iana: "Pacific/Auckland", label: "GMT+12/13 · 新西兰时间"),
        Item(iana: "Pacific/Honolulu", label: "GMT-10 · 夏威夷时间"),
        Item(iana: "America/Anchorage", label: "GMT-9 · 阿拉斯加时间"),
        Item(iana: "America/Los_Angeles", label: "GMT-8/-7 · 美西时间"),
        Item(iana: "America/Denver", label: "GMT-7/-6 · 美山区时间"),
        Item(iana: "America/Chicago", label: "GMT-6/-5 · 美中部时间"),
        Item(iana: "America/New_York", label: "GMT-5/-4 · 美东时间"),
        Item(iana: "America/Sao_Paulo", label: "GMT-3 · 巴西时间"),
        Item(iana: "America/Argentina/Buenos_Aires", label: "GMT-3 · 阿根廷时间"),
        Item(iana: "Atlantic/Azores", label: "GMT-1/-0 · 亚速尔时间"),
        Item(iana: "Europe/London", label: "GMT+0/+1 · 英国时间"),
        Item(iana: "Europe/Dublin", label: "GMT+0/+1 · 爱尔兰时间"),
        Item(iana: "Europe/Lisbon", label: "GMT+0/+1 · 葡萄牙时间"),
        Item(iana: "Europe/Paris", label: "GMT+1/+2 · 中欧时间"),
        Item(iana: "Europe/Berlin", label: "GMT+1/+2 · 中欧时间"),
        Item(iana: "Europe/Moscow", label: "GMT+3 · 莫斯科时间"),
        Item(iana: "Europe/Istanbul", label: "GMT+3 · 土耳其时间"),
        Item(iana: "Europe/Athens", label: "GMT+2/+3 · 东欧时间"),
        Item(iana: "Europe/Kyiv", label: "GMT+2/+3 · 基辅时间"),
        Item(iana: "Africa/Cairo", label: "GMT+2/+3 · 埃及时间"),
        Item(iana: "Africa/Johannesburg", label: "GMT+2 · 南非时间"),
        Item(iana: "Africa/Lagos", label: "GMT+1 · 西非时间"),
        Item(iana: "America/Toronto", label: "GMT-5/-4 · 加东时间"),
        Item(iana: "America/Vancouver", label: "GMT-8/-7 · 加西时间"),
        Item(iana: "America/Mexico_City", label: "GMT-6 · 墨西哥时间"),
        Item(iana: "America/Bogota", label: "GMT-5 · 哥伦比亚时间"),
        Item(iana: "America/Lima", label: "GMT-5 · 秘鲁时间"),
        Item(iana: "Asia/Jakarta", label: "GMT+7 · 印尼西部时间"),
        Item(iana: "Asia/Manila", label: "GMT+8 · 菲律宾时间"),
    ]

    /// 固定偏移兜底(IANA 反符号:Etc/GMT-8 = UTC+8)。
    /// 「我知道当年就是 UTC+9」这类怪需求的诚实出路,永远无夏令时。
    static let fixedOffsets: [Item] = (0...12).flatMap { h -> [Item] in
        [
            Item(iana: "Etc/GMT-\(h)", label: "GMT+\(h) · 固定偏移"),
            h == 0 ? nil : Item(iana: "Etc/GMT+\(h)", label: "GMT-\(h) · 固定偏移"),
        ].compactMap { $0 }
    }
}

/// 城市搜索 sheet(Q8:自动聚焦 → 空态「最近 + 热门」→ 键入即搜 200ms 防抖;
/// S05:底部「自定义地点」入口,经度 + IANA 时区必填)。
///
/// - 排序/归一化在 `CitySearchEngine`(决策 Q6)
/// - 数据库不可用 → 显式错误态(错误显式传播,不静默空列表)
/// - 视觉对齐 DESIGN.md;sheet 复用于深度解析/合盘/onboarding 三入口
struct CitySearchSheet: View {
    @Binding var selection: PlaceSelection?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [CityRecord] = []
    @State private var recentRecords: [CityRecord] = []
    @State private var hotRecords: [CityRecord] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    // S05 自定义地点表单态
    @State private var showCustomForm = false
    @State private var customLongitudeText = ""
    @State private var customTimezone: String?
    @State private var customError: String?

    /// 引擎不可用(库缺失/损坏/打开失败)时为 nil → 错误态。initError 保留构造失败的
    /// 原始 `CitySearchError`(含 sqlite code 关联值):日志用 `String(describing:)`
    /// 记技术细节,UI 用其 `errorDescription`(人话;databaseMissing 带专用
    /// 「重装」指引,不与其他失败混同)。
    private let engine: CitySearchEngine?
    private let initError: CitySearchError?

    init(selection: Binding<PlaceSelection?>) {
        self._selection = selection
        do {
            self.engine = try CitySearchEngine()
            self.initError = nil
        } catch let error as CitySearchError {
            self.engine = nil
            self.initError = error
        } catch {
            // init 契约只抛 CitySearchError;其他类型属不变量破坏,
            // 细节进日志(不静默吞),UI 走 queryFailed 兜底文案。
            self.engine = nil
            self.initError = nil
            AppLogger.app.error(
                "citySearch.engine.init.unexpected error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(L10n.CitySearch.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.CitySearch.cancel) { dismiss() }
                            .foregroundStyle(BaziTheme.ink)
                    }
                }
                .background(BaziTheme.paper)
                .task {
                    // sheet 打开后自动聚焦键盘(自定义表单展开时不抢焦点)
                    if !showCustomForm { searchFocused = true }
                    await reloadStaticSections()
                }
                .onDisappear { searchTask?.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            errorView(errorMessage)
        } else if showCustomForm {
            customPlaceForm
        } else {
            searchList
        }
    }

    // MARK: 搜索列表

    private var searchList: some View {
        List {
            Section {
                TextField(L10n.CitySearch.placeholder, text: $query)
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .foregroundStyle(BaziTheme.ink)
                    .onChange(of: query) { _, new in scheduleSearch(new) }
                    .listRowBackground(BaziTheme.cardSurface)
            }

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if !recentRecords.isEmpty {
                    Section(L10n.CitySearch.recents) {
                        ForEach(recentRecords) { row($0) }
                    }
                }
                Section(L10n.CitySearch.hot) {
                    hotGrid
                }
            } else if results.isEmpty {
                Section {
                    Text(L10n.CitySearch.noResults(query))
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            } else {
                Section {
                    ForEach(results) { row($0) }
                }
            }

            // S05:自定义地点入口(冷门出生地逃生舱,三入口共享)
            Section {
                Button {
                    prefillCustomForm()
                    showCustomForm = true
                } label: {
                    Label(L10n.CitySearch.customEntry, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.cinnabar)
                }
                .listRowBackground(BaziTheme.cardSurface)
            }
        }
        // List 自带系统分组底色会盖住 paper,隐藏后透出 sheet 背景(对齐 ProfileView 做法)
        .scrollContentBackground(.hidden)
    }

    /// 单条结果行:主名 + 副标题(admin1, 国家)。
    private func row(_ record: CityRecord) -> some View {
        Button {
            select(.city(record))
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(BaziTheme.ink)
                Text(record.subtitle)
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowBackground(BaziTheme.cardSurface)
    }

    /// 热门城市网格(种子 27 城,4 列胶囊片,对齐时辰快捷选的圆片视觉)。
    private var hotGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
            ForEach(hotRecords) { record in
                Button {
                    select(.city(record))
                } label: {
                    Text(record.displayName)
                        .font(.footnote)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(BaziTheme.ink)
                        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                                .stroke(BaziTheme.hairline, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .listRowSeparator(.hidden)
    }

    // MARK: 自定义地点表单(S05:经度 + IANA 时区必填)

    private var customPlaceForm: some View {
        Form {
            Section {
                HStack {
                    Text(L10n.CitySearch.customLongitude)
                        .foregroundStyle(BaziTheme.inkMuted)
                    TextField(L10n.CitySearch.customLongitudeHint, text: $customLongitudeText)
                        .keyboardType(.numbersAndPunctuation)
                        .foregroundStyle(BaziTheme.ink)
                        .autocorrectionDisabled()
                }
                .listRowBackground(BaziTheme.cardSurface)
            } footer: {
                Text(L10n.CitySearch.customLongitudeFooter)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            Section {
                Picker(L10n.CitySearch.customTimezone, selection: Binding(
                    get: { customTimezone ?? "" },
                    set: { customTimezone = $0.isEmpty ? nil : $0 }
                )) {
                    Text(L10n.CitySearch.customTimezonePrompt).tag("")
                    ForEach(CommonTimezones.regions) { item in
                        Text(item.label).tag(item.iana)
                    }
                    ForEach(CommonTimezones.fixedOffsets) { item in
                        Text(item.label).tag(item.iana)
                    }
                }
                .foregroundStyle(BaziTheme.ink)
                .listRowBackground(BaziTheme.cardSurface)
            }

            if let customError {
                Section {
                    Text(customError)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.destructive)
                        .listRowBackground(BaziTheme.cardSurface)
                }
            }

            Section {
                Button {
                    confirmCustom()
                } label: {
                    Text(L10n.CitySearch.customConfirm)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .listRowBackground(BaziTheme.cinnabar)
                .buttonStyle(.plain)

                Button(L10n.CitySearch.customBack) {
                    showCustomForm = false
                }
                .foregroundStyle(BaziTheme.inkMuted)
                .frame(maxWidth: .infinity)
                .listRowBackground(BaziTheme.cardSurface)
            }
        }
        // 与 searchList 同规:系统分组底色会盖住 paper,隐藏后透出 sheet 背景
        .scrollContentBackground(.hidden)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: BaziTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(BaziTheme.destructive)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 行为

    private func select(_ place: PlaceSelection) {
        selection = place
        if case .city(let record) = place {
            CityRecentStore.record(record.geonameId)
        }
        HapticEngine.light()
        dismiss()
    }

    /// 打开自定义表单时,若当前已是自定义地点则预填(编辑语义)。
    private func prefillCustomForm() {
        if case .custom(let longitude, let timezone) = selection {
            customLongitudeText = String(format: "%.4f", longitude)
            customTimezone = timezone
        } else {
            customLongitudeText = ""
            customTimezone = nil
        }
        customError = nil
    }

    /// 自定义地点确认:经度范围 + 时区必选,校验失败显式内联报错(不静默)。
    private func confirmCustom() {
        guard let raw = Double(customLongitudeText.trimmingCharacters(in: .whitespaces)),
              raw.isFinite, (-180.0...180.0).contains(raw) else {
            customError = L10n.CitySearch.customErrorLongitude
            return
        }
        guard let timezone = customTimezone else {
            customError = L10n.CitySearch.customErrorTimezone
            return
        }
        select(.custom(longitude: raw, timezone: timezone))
    }

    /// 200ms 防抖(S03 决策:50 万键 LIKE 在 iPhone 上流畅)。
    private func scheduleSearch(_ raw: String) {
        searchTask?.cancel()
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            do {
                let found = try engine?.search(trimmed) ?? []
                if !Task.isCancelled { results = found }
            } catch {
                // 查询失败显式进入错误态(不静默空列表);人话文案,
                // 原始 error(sqlite code/message)记日志不进 UI
                if !Task.isCancelled {
                    AppLogger.app.error(
                        "citySearch.search.failed query=\(trimmed, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    errorMessage = String(localized: "city.error.queryFailed")
                }
            }
        }
    }

    /// 空态数据:最近选择 + 热门网格。任一失败 → 错误态。
    private func reloadStaticSections() async {
        guard let engine else {
            // initError 是引擎构造失败的原始 CitySearchError(含 sqlite code),
            // 在此记 String(describing:) 日志留痕;UI 用其 errorDescription 人话
            // (databaseMissing → 「数据库不可用,请重新安装」专用指引;
            //  打开失败等其余 → queryFailed 统一文案)。
            if let initError {
                AppLogger.app.error(
                    "citySearch.engine.init error=\(String(describing: initError), privacy: .public)"
                )
                errorMessage = initError.errorDescription ?? String(localized: "city.error.queryFailed")
            } else {
                errorMessage = String(localized: "city.error.queryFailed")
            }
            return
        }
        do {
            recentRecords = try engine.records(ids: CityRecentStore.load())
            hotRecords = try engine.records(ids: CitySearchEngine.hotGeonameIds)
        } catch {
            AppLogger.app.error(
                "citySearch.staticSections.failed error=\(String(describing: error), privacy: .public)"
            )
            errorMessage = String(localized: "city.error.queryFailed")
        }
    }
}
