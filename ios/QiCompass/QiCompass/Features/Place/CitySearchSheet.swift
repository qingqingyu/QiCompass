import SwiftUI

/// 城市搜索 sheet(Q8:自动聚焦 → 空态「最近 + 热门」→ 键入即搜 200ms 防抖)。
///
/// - 排序/归一化在 `CitySearchEngine`(决策 Q6)
/// - 数据库不可用 → 显式错误态(错误显式传播,不静默空列表)
/// - 视觉对齐 DESIGN.md;sheet 复用于深度解析/合盘/onboarding 三入口(S03-S04)
struct CitySearchSheet: View {
    @Binding var selection: CityRecord?
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [CityRecord] = []
    @State private var recentRecords: [CityRecord] = []
    @State private var hotRecords: [CityRecord] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @FocusState private var searchFocused: Bool

    /// 引擎不可用(库缺失/损坏/打开失败)时为 nil → 错误态;initError 保留具体原因
    /// (不加区分地显示「缺失」会掩盖真实故障,违背错误显式传播)。
    private let engine: CitySearchEngine?
    private let initError: String?

    init(selection: Binding<CityRecord?>) {
        self._selection = selection
        do {
            self.engine = try CitySearchEngine()
            self.initError = nil
        } catch {
            self.engine = nil
            self.initError = error.localizedDescription
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
                    // sheet 打开后自动聚焦键盘
                    searchFocused = true
                    await reloadStaticSections()
                }
                .onDisappear { searchTask?.cancel() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            errorView(errorMessage)
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
        }
        // List 自带系统分组底色会盖住 paper,隐藏后透出 sheet 背景(对齐 ProfileView 做法)
        .scrollContentBackground(.hidden)
    }

    /// 单条结果行:主名 + 副标题(admin1, 国家)。
    private func row(_ record: CityRecord) -> some View {
        Button {
            select(record)
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
                    select(record)
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

    private func select(_ record: CityRecord) {
        selection = record
        CityRecentStore.record(record.geonameId)
        HapticEngine.light()
        dismiss()
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
                // 查询失败显式进入错误态(不静默空列表)
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    /// 空态数据:最近选择 + 热门网格。任一失败 → 错误态。
    private func reloadStaticSections() async {
        guard let engine else {
            errorMessage = initError ?? CitySearchError.databaseMissing.localizedDescription
            return
        }
        do {
            recentRecords = try engine.records(ids: CityRecentStore.load())
            hotRecords = try engine.records(ids: CitySearchEngine.hotGeonameIds)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
