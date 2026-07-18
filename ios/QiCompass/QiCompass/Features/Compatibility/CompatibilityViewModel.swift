import Foundation
import SwiftUI
import SwiftData

// MARK: - 状态机

/// 合盘主状态机(决策 D2)。
///
/// 五态:
/// - loading:命盘列表加载中
/// - empty:0 存档,引导去深度解析
/// - configuring:配置态(A/B/context)
/// - computing:调 /api/bazi/compatibility 中
/// - resultReady(response, interpretState):结果 + AI 子状态
/// - failed(message):显式错误
///
/// `.configuring` 是主动配置态(合盘不像 daily 进入即触发)。
enum CompatibilityViewState: Equatable {
    case loading
    case empty
    case configuring
    case computing
    case resultReady(CompatibilityResponse, InterpretState)
    case failed(UserFacingError)

    static func == (lhs: CompatibilityViewState, rhs: CompatibilityViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): return true
        case (.empty, .empty): return true
        case (.configuring, .configuring): return true
        case (.computing, .computing): return true
        case (.failed(let a), .failed(let b)): return a == b
        case (.resultReady(let a1, let a2), .resultReady(let b1, let b2)):
            // response 用 compatibilityHash 作相等性代理(完整比较太重)
            return a1.compatibilityHash == b1.compatibilityHash && a2 == b2
        default: return false
        }
    }
}

// MARK: - ViewModel

/// 合盘 ViewModel:@Observable + 五态状态机驱动。
///
/// 持有配置字段(A 盘 / B 模式 / 临时输入 / context)+ 主状态,
/// 调用 CompatibilityOrchestrator 编排两阶段。错误显式传播,不吞不静默。
@Observable
@MainActor
final class CompatibilityViewModel {

    // MARK: 配置字段

    /// 已存档命盘列表(从 UserSnapshotLink + ChartSnapshot 取)
    var archivedCharts: [ArchivedChart] = []
    var selectedChartAIndex: Int = 0

    /// B 模式:模式 A(B 已存档)/ 模式 B(B 临时输入)
    var bMode: BModeSelection = .archived
    var selectedChartBIndex: Int = 0

    /// B 临时输入(模式 B 用)
    var tempBirthDate: Date = Date(timeIntervalSince1970: 638_000_000)
    var tempGender: String = "male"
    var tempSelectedCity: String = "北京"
    var tempUseManualLongitude: Bool = false
    var tempManualLongitude: Double = 116.41

    /// context picker(通用 / 婚姻 / 事业)
    var context: String = "general"

    // MARK: 主状态

    var state: CompatibilityViewState = .loading

    // MARK: 依赖

    private let orchestrator: CompatibilityOrchestrator
    private let chartStore: ChartSnapshotStore
    private let compatibilityStore: CompatibilitySnapshotStore
    private let modelContext: ModelContext

    private var computeTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?

    /// 阶段 1 完成后的元数据(供阶段 2 / UI 使用)
    private var lastCompatibilityHash: String?
    private var lastBChartSnapshot: ChartSnapshot?
    private var lastIsSnapshotNew: Bool = false

    init(
        orchestrator: CompatibilityOrchestrator,
        chartStore: ChartSnapshotStore,
        compatibilityStore: CompatibilitySnapshotStore,
        modelContext: ModelContext
    ) {
        self.orchestrator = orchestrator
        self.chartStore = chartStore
        self.compatibilityStore = compatibilityStore
        self.modelContext = modelContext
    }

    // MARK: - 已存档命盘加载

    /// 从 UserSnapshotLink 取所有已存档命盘(按 createdAt DESC),并默认选最新一条为 A。
    /// 0 条 → .empty;>0 条 → .configuring。
    func loadArchivedCharts() {
        do {
            let links = try modelContext.fetch(FetchDescriptor<UserSnapshotLink>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            var charts: [ArchivedChart] = []
            for link in links {
                let hash = link.snapshotHash
                let pred = #Predicate<ChartSnapshot> { $0.contentHash == hash }
                let snapshots = try modelContext.fetch(FetchDescriptor<ChartSnapshot>(predicate: pred))
                guard let snapshot = snapshots.first else {
                    AppLogger.persistence.error(
                        "op=compatibility.loadArchivedCharts missing_snapshot hash=\(hash, privacy: .public)"
                    )
                    throw CompatibilityViewModelError.archivedSnapshotMissing(hash: hash)
                }
                let bazi = try chartStore.decodeResponse(from: snapshot)
                let dayMaster = bazi.pillars.day.gan
                charts.append(ArchivedChart(
                    snapshotHash: hash,
                    alias: link.alias,
                    birthDate: snapshot.birthSolarTime,
                    gender: snapshot.gender,
                    dayMaster: dayMaster,
                    snapshot: snapshot
                ))
            }
            archivedCharts = charts
            if charts.isEmpty {
                state = .empty
            } else {
                selectedChartAIndex = 0
                if case .loading = state {
                    state = .configuring
                } else if case .failed = state {
                    state = .configuring
                }
            }
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.loadArchivedCharts failed error=\(String(describing: error), privacy: .public)"
            )
            // 不静默吞:错误显式传到 UI
            state = .failed(.generic(message: "读取命盘存档失败:\(error.localizedDescription)"))
        }
    }

    // MARK: - 合盘触发

    /// 触发合盘:校验配置 → 构造请求 → orchestrator.runDeterministic。
    func compute() {
        guard !archivedCharts.isEmpty else {
            state = .empty
            return
        }
        guard selectedChartAIndex < archivedCharts.count else {
            state = .failed(.generic(message: "A 盘选择越界,请重新选择"))
            return
        }

        // 表单校验(模式 B)
        if bMode == .tempInput {
            if tempBirthDate > Date() {
                state = .failed(.generic(message: "B 盘出生时间不能晚于当下"))
                return
            }
            if !tempUseManualLongitude && tempSelectedCity.trimmingCharacters(in: .whitespaces).isEmpty {
                state = .failed(.generic(message: "请选择 B 盘城市,或开启手动经度输入"))
                return
            }
            if tempUseManualLongitude && !(-180.0...180.0).contains(tempManualLongitude) {
                state = .failed(.generic(message: "B 盘经度需在 -180 到 180 之间"))
                return
            }
        }

        computeTask?.cancel()
        state = .computing

        computeTask = Task {
            do {
                let chartA = archivedCharts[selectedChartAIndex]
                let baziA = try chartStore.decodeResponse(from: chartA.snapshot)
                let payloadA = ChartPayloadDTO.from(baziResponse: baziA)

                let request: CompatibilityRequest
                var bSnapshotForUI: ChartSnapshot?

                switch bMode {
                case .archived:
                    guard selectedChartBIndex < archivedCharts.count else {
                        state = .failed(.generic(message: "B 盘选择越界,请重新选择"))
                        return
                    }
                    let chartB = archivedCharts[selectedChartBIndex]
                    let baziB = try chartStore.decodeResponse(from: chartB.snapshot)
                    let payloadB = ChartPayloadDTO.from(baziResponse: baziB)
                    request = CompatibilityRequest(
                        personAHash: chartA.snapshotHash,
                        personBHash: chartB.snapshotHash,
                        chartPayloadA: payloadA,
                        chartPayloadB: payloadB,
                        context: context
                    )
                    bSnapshotForUI = chartB.snapshot

                case .tempInput:
                    let city: String? = tempUseManualLongitude ? nil : tempSelectedCity
                    let longitude: Double? = tempUseManualLongitude ? tempManualLongitude : nil
                    let personB = PersonBInput(
                        birthDatetime: tempBirthDate,
                        gender: tempGender,
                        city: city,
                        longitude: longitude
                    )
                    request = CompatibilityRequest(
                        personAHash: chartA.snapshotHash,
                        personB: personB,
                        chartPayloadA: payloadA,
                        context: context
                    )
                    bSnapshotForUI = nil  // 模式 B:B 盘由 orchestrator 隐式落地后回填
                }

                let result = try await orchestrator.runDeterministic(
                    request: request,
                    personAHash: chartA.snapshotHash
                )

                // 模式 B:B snapshot 是新隐式落地的,从 chartStore 取回
                if bSnapshotForUI == nil {
                    bSnapshotForUI = try chartStore.get(contentHash: result.personBHash)
                    // 不静默吞:刚隐式落地的 B snapshot 取不回说明持久化失败,
                    // 后续阶段 2 无法进行,显式抛错让 UI 进入 error 态。
                    if bSnapshotForUI == nil {
                        state = .failed(.generic(message: "B 盘隐式落地后取回失败,请重试"))
                        return
                    }
                }

                // 缓存元数据
                lastCompatibilityHash = result.response.compatibilityHash
                lastBChartSnapshot = bSnapshotForUI
                lastIsSnapshotNew = result.isSnapshotNew

                // 查本地 24h AI 缓存(orchestrator 内部含禁词扫描,命中即抛 forbiddenWordsHit)
                var interpretState: InterpretState = .idle
                do {
                    if let cached = try await orchestrator.cachedInterpretationIfFresh(
                        compatibilityHash: result.response.compatibilityHash
                    ) {
                        interpretState = .okFree(text: cached.text, cached: true)
                    }
                } catch CompatibilityError.forbiddenWordsHit {
                    interpretState = .failed(message: "解读包含不合规绝对结论,请重试")
                } catch {
                    AppLogger.persistence.error(
                        "compat.cachedInterpretation_read_failed compatibility_hash=\(result.response.compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    interpretState = .failed(message: "读取合盘解读缓存失败:\(error.localizedDescription)")
                }

                if !Task.isCancelled {
                    state = .resultReady(result.response, interpretState)
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    state = .failed(UserFacingError.from(error, stage: .compatibilityDeterministic))
                }
            }
        }
    }

    // MARK: - AI 合盘解读

    /// 触发 AI 解读:用户点「生成合盘解读」。
    func generateInterpretation() {
        guard case .resultReady(let response, _) = state else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明状态机错乱,显式记录
            AppLogger.app.error("op=compatibility.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard let compatHash = lastCompatibilityHash else {
            state = .resultReady(response, .failed(message: "合盘缓存键缺失,请重新合盘"))
            return
        }
        guard let chartASnapshot = archivedCharts[safe: selectedChartAIndex]?.snapshot,
              let bSnapshot = lastBChartSnapshot else {
            state = .resultReady(response, .failed(message: "命盘快照缺失,请重新合盘"))
            return
        }

        interpretTask?.cancel()
        state = .resultReady(response, .fetching)

        interpretTask = Task {
            do {
                let baziA = try chartStore.decodeResponse(from: chartASnapshot)
                let baziB = try chartStore.decodeResponse(from: bSnapshot)
                let chartA = PromptContextBuilder.chartContext(
                    from: baziA,
                    gender: chartASnapshot.gender,
                    cityDisplay: cityDisplay(for: chartASnapshot)
                )
                let chartB = PromptContextBuilder.chartContext(
                    from: baziB,
                    gender: bSnapshot.gender,
                    cityDisplay: cityDisplay(for: bSnapshot)
                )

                let resp = try await orchestrator.runInterpretation(
                    compatibilityHash: compatHash,
                    chartA: chartA,
                    chartB: chartB,
                    assessment: response.qualitativeAssessment,
                    syncedFortune: response.syncedFortune,
                    context: context
                )

                if !Task.isCancelled {
                    state = .resultReady(
                        response,
                        .okFree(text: resp.interpretation, cached: resp.cached)
                    )
                }
            } catch let error as CompatibilityError {
                if !Task.isCancelled {
                    state = .resultReady(response, .failed(message: error.errorDescription ?? "未知错误"))
                }
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled {
                    // dailyLimitReached 独立形态(方案 step 4):禁用生成按钮、不显示重试
                    if case .dailyLimitReached(let reset, _) = error {
                        state = .resultReady(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .resultReady(response, .failed(message: error.errorDescription ?? "未知错误"))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    let userError = UserFacingError.from(error, stage: .interpret)
                    if case .dailyLimitReached(let reset) = userError {
                        state = .resultReady(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .resultReady(response, .failed(message: userError.errorDescription ?? "未知错误"))
                    }
                }
            }
        }
    }

    // MARK: - 重置

    /// 从结果态切回配置态(顶部「返回修改」 toolbar)。
    func backToConfig() {
        computeTask?.cancel()
        interpretTask?.cancel()
        state = .configuring
    }

    // MARK: - 查询

    var remainingReads: Int { orchestrator.remainingReads() }
    var nextDailyReset: Date { orchestrator.nextDailyReset() }
    var bChartSnapshot: ChartSnapshot? { lastBChartSnapshot }
    var isSnapshotNew: Bool { lastIsSnapshotNew }

    /// 供结果页构造双盘对比;View 不直接访问 ChartSnapshotStore。
    func makeDualPillars(
        chartASnapshot: ChartSnapshot,
        chartBSnapshot: ChartSnapshot
    ) throws -> [DualPillarSource] {
        let baziA = try chartStore.decodeResponse(from: chartASnapshot)
        let baziB = try chartStore.decodeResponse(from: chartBSnapshot)
        return DualPillarSource.from(a: baziA, b: baziB)
    }

    // MARK: - Private

    /// ChartSnapshot 城市可读展示(用经度或 cityLongitude 兜底)。
    private func cityDisplay(for snapshot: ChartSnapshot) -> String {
        // ChartSnapshot 不存城市名,只有 cityLongitude。展示经度足够 prompt 使用。
        let lon = snapshot.cityLongitude
        let hemisphere = lon >= 0 ? "东经" : "西经"
        return "\(hemisphere)\(String(format: "%.2f", abs(lon)))"
    }
}

// MARK: - 辅助类型

/// 已存档命盘的展示封装(避免 View 直查 SwiftData)。
struct ArchivedChart: Identifiable, Hashable {
    let snapshotHash: String
    let alias: String
    let birthDate: Date
    let gender: String
    let dayMaster: String
    let snapshot: ChartSnapshot

    var id: String { snapshotHash }
}

enum CompatibilityViewModelError: LocalizedError {
    case archivedSnapshotMissing(hash: String)

    var errorDescription: String? {
        switch self {
        case .archivedSnapshotMissing(let hash):
            return "命盘存档缺少快照:\(hash)"
        }
    }
}

/// B 模式选择。
enum BModeSelection: String, CaseIterable, Identifiable {
    case archived    // 已存档
    case tempInput   // 临时输入

    var id: String { rawValue }

    var label: String {
        switch self {
        case .archived:  return "已存档"
        case .tempInput: return "临时输入"
        }
    }
}

/// App 模块内共享的安全下标。
///
/// 注:Swift 无法把 extension 限定到「仅本文件/仅某些 Array」，
/// 此扩展在 App target 内对所有 Array 生效（internal，不出模块）。
/// 若后续拆 SDK 需收窄，改用 wrapper 类型或 free function。
internal extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
