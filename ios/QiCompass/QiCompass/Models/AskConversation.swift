import Foundation
import SwiftData

/// 问事多会话(2026-11-04 定稿,事实源 docs/design-ref/today-type/今日问事-多会话.html
/// + DESIGN.md Decisions Log 同日条):每次对话一条。
///
/// 归属 (chartHash, dateKey) 双键——日柱是日期的属性而非命盘的,同日换盘
/// dateKey 相同,缺 chartHash 则旧盘会话残留(对齐宿主 askDayKey 键纪律)。
///
/// 生命周期拍板:**今日线可聊 / 往日线只读 / 不跨天续聊**——盘面每日换,
/// 旧线的回答踩旧盘,续聊「昨天的盘说X、今天的盘说Y」语义打架,且后端
/// 作答端点把上下文钉死今日盘;往日价值在回看不在续问。
///
/// 标题 = 首问截断(确定性,不烧 LLM);**空会话(仅开场白)不落盘**——
/// pristine 会话随解读态刷新重建,落盘会留空壳;首条用户消息发出时才创建
/// 记录(开场白随行入库,回看时语境完整)。
///
/// **留存策略 v1 未定**(red-team 记录,有意接受):行无限累积,唯一清除
/// 路径 = 重置命盘(ProfileView 全量清空含本实体)。v1 量级(每日数条 ×
/// 数十轮 JSON,KB 级)无压力;v2 杠杆 = 按 dateKey 修剪 / 每盘上限 / 抽屉
/// 行滑删,触发条件 = 真机出现可感知延迟或用户提管理诉求。
///
/// **消息不建子实体 @Relationship,走 JSON payload 列**(D1 哲学,同
/// DailyFortuneSnapshot 的 hourPillars/tomorrowPreview 易变结构):会话消息
/// 追加即整体读写、量小(≤ 数十轮),整取整存免了关系排序(seq)/级联删除
/// 的整套簿记;SwiftData to-many 关系集合无序,排序簿记是纯负担。
@Model
final class AskConversation {
    /// 消息流水(JSON 编码 [AskTurnRecord])。
    struct AskTurnRecord: Codable {
        /// 角色字面量单一事实源(wire 值,对齐 DailyAskTurn)——散写裸串
        /// 一处手滑即角色翻转(history/回放/落盘三处映射共用)。
        static let roleUser = "user"
        static let roleAI = "ai"
        let role: String
        let text: String
        let createdAt: Date
    }

    @Attribute(.unique) var id: UUID
    /// 归属命盘(ChartSnapshot.contentHash 软引用,同 DailyFortuneSnapshot)。
    var chartHash: String
    /// 归属日(本地 yyyy-MM-dd;≠ 今日 = 只读)。
    var dateKey: String
    /// 会话标题(首问前 12 字,创建时定版)。
    var title: String
    /// 副题「辛未日 · 比肩」(创建时定版——往日线的日柱/十神属当天,不能现算)。
    var contextLine: String
    var createdAt: Date
    var updatedAt: Date
    /// [AskTurnRecord] 的 JSON 编码(解码失败记日志并按空处理——数据已损,
    /// 空壳会话好过崩溃,错误留痕不静默)。
    var messagesData: Data

    init(
        id: UUID = UUID(),
        chartHash: String,
        dateKey: String,
        title: String,
        contextLine: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messagesData: Data = Data()
    ) {
        self.id = id
        self.chartHash = chartHash
        self.dateKey = dateKey
        self.title = title
        self.contextLine = contextLine
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messagesData = messagesData
    }

    // MARK: 消息流水(JSON 整取整存)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 消息流水(时间原序;追加即整体重编码)。
    var turns: [AskTurnRecord] {
        guard !messagesData.isEmpty else { return [] }
        do {
            return try Self.decoder.decode([AskTurnRecord].self, from: messagesData)
        } catch {
            AppLogger.app.error(
                "op=askConversation.decode failed error=\(String(describing: error), privacy: .public) -> 按空处理(空壳好过崩溃,错误留痕)"
            )
            return []
        }
    }

    /// 追加一条消息(整体重编码;纯 JSON 读写,无关系操作)。**解码失败时
    /// 拒绝追加**(red-team:decode 空 + 追加一条 = 把损毁的残骸整块覆写掉,
    /// 与「留痕不静默」相悖——拒追加保住现场,消息仍在内存会话,重开缺尾
    /// 是可见降级)。
    func append(role: String, text: String, at date: Date = Date()) {
        var all = turns
        guard all.count == messagesTurnCount else {
            AppLogger.app.error(
                "op=askConversation.append refused reason=corruptPayload(解码失败拒覆写,保残骸)"
            )
            return
        }
        all.append(AskTurnRecord(role: role, text: text, createdAt: date))
        do {
            messagesData = try Self.encoder.encode(all)
        } catch {
            AppLogger.app.error(
                "op=askConversation.encode failed error=\(String(describing: error), privacy: .public) -> 本条未入流水(消息仍在内存会话中,重开缺尾)"
            )
            return
        }
        updatedAt = date
    }

    /// 流水条数(append 的防覆写守卫用:与 turns 解码结果一致 = 流水健康;
    /// 空 Data = 0 条属健康,-1 只留给「非空但解码失败」的损毁态)。
    private var messagesTurnCount: Int {
        guard !messagesData.isEmpty else { return 0 }
        return (try? Self.decoder.decode([AskTurnRecord].self, from: messagesData))?.count ?? -1
    }
}

/// dateKey 工具(本地 yyyy-MM-dd;Calendar 可注入,测试不依赖设备时区)。
enum AskDayKey {
    static func of(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 「往日」判定(**只读语义单一事实源**,模型 isReadOnly / store 归组 /
    /// 抽屉往日签三处共用):dateKey **早于** todayKey 才是往日。相等 = 今日;
    /// **晚于** = 23:00 滚日窗口的页面超前日(`zi_next_day`:23:00–00:00
    /// 页面 businessDate 已前移而墙钟未跨日)——该窗口新线的 dateKey 取自
    /// 前移后的页面日,踩的正是已解锁的新盘,必须可聊(墙钟追平后自然落
    /// 回「今日」);若判 `!=`,每晚这一小时所有新线 born-readonly、「新开
    /// 一问」成死控件(2026-11-06 双 review R1)。定宽 yyyy-MM-dd 的字典序
    /// = 时间序,直接字符串比较。
    static func isPastDay(_ dateKey: String, todayKey: String) -> Bool {
        dateKey < todayKey
    }
}
