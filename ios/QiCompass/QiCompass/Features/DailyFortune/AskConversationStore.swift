import Foundation
import SwiftData
import SwiftUI

/// 会话落盘材料(DailyAskModel 首问时创建记录;宿主组装,模型只消费)。
/// `record` 非 nil = 打开既有会话(消息从记录种入);nil = 临时会话,
/// 首条用户消息发出时才建记录——空会话(仅开场白)不落盘,pristine 会话
/// 随解读态刷新重建,落盘会留空壳。
struct AskPersistence {
    let record: AskConversation?
    let context: ModelContext
    /// 归属命盘(ChartSnapshot.contentHash;nil 盘 = 离线兜底,不落盘)。
    let chartHash: String
    /// 归属日(yyyy-MM-dd,宿主按 businessDate 算——页面之日即会话之日)。
    let dateKey: String
    /// 首问落盘后回告(登记选择 + 刷新列表;弱引 store,不延长生命周期)。
    var onFirstTurn: ((AskConversation) -> Void)?
    /// 每条落盘后回告(刷新列表的 updatedAt/末轮预览)。
    var onTurn: (() -> Void)?

    /// 落盘保存(失败显式记日志,不静默吞——持久化失败不阻断会话本身,
    /// 但必须留痕;对齐全仓错误显式传播纪律)。
    static func save(_ context: ModelContext, what: String) {
        do {
            try context.save()
        } catch {
            AppLogger.app.error(
                "op=askConversation.save failed what=\(what, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}

/// 抽屉行摘要(值类型——@Model 对象不进 @Observable 观察面,避免记录
/// 内部变化逐条打穿视图;列表刷新统一走 reload())。
struct AskConversationSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let dateKey: String
    /// 行尾时间签(今天 HH:mm / 昨天 / 往日 M月d日)。
    let timeLabel: String
    /// 末轮预览(单行截断;空会话不会出现在列表——首问才落盘)。
    let preview: String
}

/// 问事多会话协调器(宿主 DailyFortuneMainView 持有 @State;2026-11-04 定稿):
/// - 当前选中(selection:.auto/.record/.newThread 三态)+ 抽屉列表(今天/
///   往日,当前命盘范围);
/// - 「今日可聊 / 往日只读」判定源 = todayKey(墙钟,只前进):syncDay 首行
///   与聊天页 scenePhase 回前台都推动 refreshTodayKey——页面之日滚动后
///   todayKey 绝不能滞留旧日(否则跨午夜后:旧线仍可聊 + 新线 born-readonly
///   双重锁死,2026-11-05 对抗审查 F3);
/// - 只管簿记,不碰作答上下文——answerer/开场白/候选仍由宿主 makeAskModel
///   组装(同日同盘的所有会话共享同一作答上下文,后端本就按今天的盘签凭证)。
@Observable
@MainActor
final class AskConversationStore {
    /// 选择三态:.auto = 默认(最近一条今日会话,没有则新线——strip 打开
    /// 语义);.record = 显式选中(含往日只读回看);.newThread = 新开一问。
    /// select/startNew/resetSelection 驱动,宿主 onChange(of: selection)
    /// 重建 askModel;**register 特意不动 selection**(见其注释)。
    enum Selection: Equatable {
        case auto
        case record(UUID)
        case newThread
    }

    /// 今天会话(updatedAt 降序;含当前选中)。
    private(set) var todaySummaries: [AskConversationSummary] = []
    /// 往日会话(updatedAt 降序,只读)。
    private(set) var pastSummaries: [AskConversationSummary] = []
    private(set) var selection: Selection = .auto
    /// 今日键(墙钟 yyyy-MM-dd,**只前进**;旧线转只读的唯一判定源)。
    private(set) var todayKey: String

    private let context: ModelContext
    private var chartHash: String = ""
    /// 上一轮 syncDay 的键(chartHash-dateKey)——换盘/换日重置活跃选择的
    /// 判定键。独立于 todayKey:todayKey 只前进,而离线缓存页 dateKey 可以
    /// 是过去日,拿 dateKey != todayKey 当判定会在离线场景每轮误判「换日」。
    private var lastSyncedKey: String = ""
    private let now: () -> Date

    /// 时间签格式化(主线程用;抽屉行渲染)。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    init(context: ModelContext, now: @escaping () -> Date = Date.init) {
        self.context = context
        self.now = now
        self.todayKey = AskDayKey.of(now())
    }

    // MARK: 宿主同步

    /// syncAskModel 每轮同步:首行先推墙钟今日键(页面之日滚动后 todayKey
    /// 不许滞留——对抗审查 F3:否则跨午夜前台后旧线仍可聊、新线 born-readonly);
    /// 换盘/换日(按 lastSyncedKey 判,独立于 todayKey)重置活跃选择。
    func syncDay(chartHash: String, dateKey: String) {
        refreshTodayKey()
        let key = "\(chartHash)-\(dateKey)"
        if key != lastSyncedKey {
            selection = .auto
        }
        self.chartHash = chartHash
        lastSyncedKey = key
        reload()
    }

    /// 跨午夜刷新:今日键前移 → 旧线转只读、列表重新分组、活跃选择作废
    /// (换日 = 新盘,昨天的活跃线不能默默变成今天的)。**只前进**:子时规则
    /// 23:00 滚日时页面日已前移、墙钟还是「今天」,回退会把已解锁的新盘
    /// 线重新锁死——墙钟键 < 已登键时不动。
    func refreshTodayKey() {
        let key = AskDayKey.of(now())
        if key > todayKey {
            todayKey = key
            selection = .auto
            reload()
        }
    }

    /// 当前应打开的会话记录:.record 选中优先(含往日只读回看);.newThread
    /// 恒新线;.auto = 最近一条今日会话(没有则新线——由调用侧以 nil 落临时)。
    func resolveRecord() -> AskConversation? {
        let all = fetchAll()
        switch selection {
        case .auto:
            return all.first { $0.dateKey == todayKey }
        case .record(let id):
            return all.first { $0.id == id }
                ?? all.first { $0.dateKey == todayKey }
        case .newThread:
            return nil
        }
    }

    // MARK: 抽屉动作

    /// 选中会话(今天可聊 / 往日只读;宿主 onChange 重建模型)。不 reload——
    /// 列表内容与选择无关(当前行高亮走 model.record?.id),抽屉每次打开前
    /// 按钮侧已 reload。
    func select(_ id: UUID) {
        selection = .record(id)
    }

    /// 新开一问(临时会话;首问发出时落盘并回告)。
    func startNew() {
        selection = .newThread
    }

    /// 回到默认(strip 打开语义:最近一条今日会话)——strip 每次打开都调,
    /// 回看完往日线后重开问事不粘在旧线上。
    func resetSelection() {
        selection = .auto
    }

    /// 模型首问落盘回告(DailyAskModel.persistUserTurn → onFirstTurn):
    /// 只刷新列表——**特意不动 selection**(对抗审查 F1/multi-confirmed:register
    /// 若把 selection 翻成 .record(id),宿主 onChange 会把正在作答的模型整个
    /// 换掉,在飞回复落不进用户眼前;抽屉当前行高亮走 model.record?.id,
    /// 不依赖 selection;.auto 本就解析到刚落盘的今日最新线)。
    func register(_ record: AskConversation) {
        _ = record
        reload()
    }

    /// 重载列表(今天/往日分组,updatedAt 降序)。
    func reload() {
        let conversations = fetchAll()
        let yesterdayKey = Calendar.current.date(byAdding: .day, value: -1, to: now())
            .map { AskDayKey.of($0) }

        func summary(_ conversation: AskConversation) -> AskConversationSummary {
            let timeLabel: String
            if conversation.dateKey == todayKey {
                timeLabel = Self.timeFormatter.string(from: conversation.updatedAt)
            } else if conversation.dateKey == yesterdayKey {
                timeLabel = L10n.DailyFortune.askTimeYesterday
            } else {
                timeLabel = Self.dayFormatter.string(from: conversation.updatedAt)
            }
            return AskConversationSummary(
                id: conversation.id,
                title: conversation.title,
                dateKey: conversation.dateKey,
                timeLabel: timeLabel,
                preview: conversation.turns.last?.text ?? ""
            )
        }

        todaySummaries = conversations
            .filter { $0.dateKey == todayKey }
            .map(summary)
        pastSummaries = conversations
            .filter { $0.dateKey != todayKey }
            .map(summary)
    }

    /// 当前命盘的全量会话(updatedAt 降序;chartHash 未登记 = 空)。
    private func fetchAll() -> [AskConversation] {
        guard !chartHash.isEmpty else { return [] }
        let chartHash = self.chartHash
        let descriptor = FetchDescriptor<AskConversation>(
            predicate: #Predicate { $0.chartHash == chartHash },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        do {
            return try context.fetch(descriptor)
        } catch {
            // 显式留痕不静默:列表空呈现 = 可见的降级,原因进日志
            AppLogger.app.error(
                "op=askStore.fetch failed error=\(String(describing: error), privacy: .public)"
            )
            return []
        }
    }
}
