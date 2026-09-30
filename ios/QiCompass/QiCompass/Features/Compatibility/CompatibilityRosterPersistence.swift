import Foundation

/// 合盘名单 + A 盘 + context + 临时表单草稿 跨启动持久化(决策 D5;R1-R5 修订 2026-09-30)。
///
/// 持久化 4 类 UserDefaults key:
/// - `compat.lastPersonAHash`:上次 A 盘 contentHash(失效则 VM fallback 最新 link)
/// - `compat.lastContext`:上次 context(默认 "general";VM 侧已固定不恢复,仅续写)
/// - `compat.rosterV2`:JSON `PersistedRoster`——**名单完整持久化**(R1):每个成员
///   含临时对方的完整出生信息(PersonBInput)/ 称呼 / 出生地 / 已算出的 resolvedHash,
///   以及「当前选中是谁」(R3)。名单或选中一变即写(R2),不依赖 compute() 成功,
///   合盘失败不影响名单。
/// - `compat.tempDraft`:JSON `TempDraftState`(临时表单上次填过的字段,
///   加第二个临时人时默认值用上次的,用户只改称呼/时间)
///
/// 老 key `compat.roster`(`[String]` hash 数组,09-07 单选时代写法):只在
/// `loadLegacyRosterHashesForMigration()` 读一次并转换成 V2 后删除(R5,一次性迁移;
/// `remapHash` 在迁移前发生时也会顺带转换)。
///
/// 红线 D6(2026-09-30 修订后不变的部分):临时对方**不建 UserSnapshotLink**、
/// 零 SwiftData schema 演化、不上云、不进 SyncManager;修订的只是 D6 里
/// 「名单只存 hash、alias 不持久化」的保守选择(见 docs/合盘名单持久化修复-plan.md R4)。
///
/// 错误显式传播:JSON 编解码失败 → AppLogger.persistence.error + 视为空 + 删损坏
/// key(损坏自愈),不静默用默认值掩盖。
struct CompatibilityRosterPersistence {

    private enum Key {
        static let personAHash = "compat.lastPersonAHash"
        static let context = "compat.lastContext"
        static let rosterV2 = "compat.rosterV2"
        /// 老 key(R5 迁移源;迁移后删除,不再写入)。
        static let legacyRosterHashes = "compat.roster"
        static let tempDraft = "compat.tempDraft"
    }

    /// 默认 context(决策 D8;持久化无 context 时 fallback)。
    static let defaultContext = "general"

    /// 临时表单默认草稿(无持久化时 fallback;2026-09-19 去默认值:全 nil——
    /// 不再预填 1990-03-15/male,与深度表单「未选必选」同一原则;
    /// birthTime 缺省回落链在 VM.applyTempDraft:新值 → 旧草稿 birthDate 承接
    /// 时分 → 锚点,不静默编 0 点也不丢用户上次选的时刻)。
    /// S04:出生地无默认城市;S05:自定义地点取代手动经度开关,时区显式。
    static let defaultTempDraft = TempDraftState(
        birthDate: nil,
        birthTime: nil,
        gender: nil,
        place: nil
    )

    // MARK: - V2 数据格式(R1,2026-09-30)

    /// 名单持久化根结构(`compat.rosterV2`)。
    /// 不让 `RosterEntry` 本身 Codable——它的 `==` 按 id 比较,与 Codable 混用
    /// 容易埋坑;互转走 `RosterEntry.init(persisted:)` / `RosterEntry.persisted`。
    struct PersistedRoster: Codable, Equatable {
        var entries: [PersistedRosterEntry]
        /// 当前选中的 entry id;nil = 无选中(结果壳 P6)。
        var selectedEntryID: String?
    }

    /// 名单成员的持久化形态(`RosterEntry` 的镜像;PersonBInput / PlaceSelection
    /// 已是 Codable,直接承载)。
    enum PersistedRosterEntry: Codable, Equatable {
        /// 存档命盘(hash 软引用 ChartSnapshot.contentHash)。
        case archived(snapshotHash: String)
        /// 临时对方:完整输入 + 称呼 + 已算出的 B 盘 hash(nil = 还没算过)+ 原始出生地。
        case temp(input: PersonBInput, alias: String?, resolvedHash: String?, place: PlaceSelection)
    }

    // MARK: - Save / Load(V2)

    /// 写入 V2 名单 + A 盘 + context(VM `persistRoster()` 单一出口调;
    /// 名单或选中一变即写,R2——不依赖 compute() 成功)。
    static func saveV2(personAHash: String, context: String, roster: PersistedRoster) {
        let defaults = UserDefaults.standard
        defaults.set(personAHash, forKey: Key.personAHash)
        defaults.set(context, forKey: Key.context)
        do {
            let data = try JSONEncoder().encode(roster)
            defaults.set(data, forKey: Key.rosterV2)
        } catch {
            // 不静默吞:编码失败说明结构异常,记录但不阻塞调用方已完成的内存态
            AppLogger.persistence.error(
                "op=compatibility.rosterPersistence.saveV2_encode_failed error=\(String(describing: error), privacy: .public)"
            )
            return
        }
        AppLogger.app.info(
            "op=compatibility.rosterPersistence.saveV2 a_hash=\(personAHash, privacy: .public) roster_count=\(roster.entries.count, privacy: .public) selected=\(roster.selectedEntryID ?? "nil", privacy: .public)"
        )
    }

    /// 读 V2 名单;key 不存在 → nil(调用方决定是否走 R5 迁移);
    /// JSON 损坏 → error 日志 + 删 key + nil(视为空,损坏自愈)。
    static func loadV2() -> PersistedRoster? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Key.rosterV2) else { return nil }
        do {
            return try JSONDecoder().decode(PersistedRoster.self, from: data)
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.rosterPersistence.loadV2_decode_failed error=\(String(describing: error), privacy: .public)"
            )
            defaults.removeObject(forKey: Key.rosterV2)
            return nil
        }
    }

    /// 本地是否已有名单数据(V2 非空,或未迁移的老 key 仍在)。
    /// VM 防覆盖守卫用:未恢复的 VM 不得覆盖已有名单。V2 损坏会经 `loadV2()`
    /// 显式记日志并删 key,此时视为无。
    static func hasPersistedRoster() -> Bool {
        if UserDefaults.standard.data(forKey: Key.legacyRosterHashes) != nil { return true }
        guard let roster = loadV2() else { return false }
        return !roster.entries.isEmpty
    }

    /// 读上次 A 盘 hash(独立 key,V2 与迁移路径共用)。
    static func loadPersonAHash() -> String? {
        UserDefaults.standard.string(forKey: Key.personAHash)
    }

    // MARK: - R5 老数据迁移(一次性)

    /// 读老 key `compat.roster` 的 hash 数组并**删除老 key**(迁移只跑一次;
    /// 无论 decode 成败都删——损坏的老数据视为无,下次不再尝试)。
    /// 返回 nil = 老 key 不存在 / 已迁移 / 损坏。
    static func loadLegacyRosterHashesForMigration() -> [String]? {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Key.legacyRosterHashes) else { return nil }
        defer { defaults.removeObject(forKey: Key.legacyRosterHashes) }
        do {
            let hashes = try JSONDecoder().decode([String].self, from: data)
            AppLogger.app.info(
                "op=compatibility.rosterPersistence.legacy_migration_read count=\(hashes.count, privacy: .public)"
            )
            return hashes
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.rosterPersistence.legacy_decode_failed error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Hash remap(S10 补时辰换新盘)

    /// 补时辰 hash 重建后,把持久化名单/A 盘里的老 hash 原地换成新 hash。
    ///
    /// 他人盘补时辰 → content_hash 变 → 不 remap 的话名单仍指向老三柱盘
    /// (照旧「不可合盘」标记,人像从名单里消失);remap 后该人带着新盘留在名单。
    ///
    /// V2 三处全换:`.archived` 的 hash、`.temp` 的 resolvedHash、`selectedEntryID`
    /// 里内嵌的 `archived:<hash>`。V2 尚未建立(老 key 还在,用户升级后先补了时辰)
    /// → 老 key 顺带转换成 V2 再 remap(remap 即迁移,老 key 删除)。
    /// personAHash 命中同样换。无命中 → no-op(不写 UserDefaults;**例外**:老 key
    /// 迁移在本 call 顺带发生时,迁移结果必须落盘——老 key 已读后删除,不写即丢)。
    static func remapHash(from oldHash: String, to newHash: String) {
        var rosterV2 = loadV2()
        var legacyHashes: [String]? = nil
        if rosterV2 == nil {
            legacyHashes = loadLegacyRosterHashesForMigration()
            if let legacyHashes {
                rosterV2 = PersistedRoster(
                    entries: legacyHashes.map { .archived(snapshotHash: $0) },
                    selectedEntryID: nil
                )
            }
        }
        guard var roster = rosterV2 else {
            // V2 与老 key 都不存在:只剩 personAHash 可能命中
            if loadPersonAHash() == oldHash {
                saveV2(personAHash: newHash,
                       context: loadContextForRemap(),
                       roster: PersistedRoster(entries: [], selectedEntryID: nil))
                AppLogger.app.info(
                    "op=compatibility.rosterPersistence.remap_hash a_only old=\(oldHash, privacy: .public) new=\(newHash, privacy: .public)"
                )
            }
            return
        }

        var changed = false
        roster.entries = roster.entries.map { entry in
            switch entry {
            case .archived(let hash) where hash == oldHash:
                changed = true
                return .archived(snapshotHash: newHash)
            case .temp(let input, let alias, let resolved, let place) where resolved == oldHash:
                changed = true
                return .temp(input: input, alias: alias, resolvedHash: newHash, place: place)
            default:
                return entry
            }
        }
        if roster.selectedEntryID == RosterEntry.archived(snapshotHash: oldHash).id {
            roster.selectedEntryID = RosterEntry.archived(snapshotHash: newHash).id
            changed = true
        }
        let remappedA: String
        if loadPersonAHash() == oldHash {
            remappedA = newHash
            changed = true
        } else {
            remappedA = loadPersonAHash() ?? ""
        }
        // legacyHashes 非 nil = 本次顺带完成迁移——老 key 已在上面读后删除,
        // 无论 hash 是否命中都必须把迁移结果落盘 V2(否则老数据被消费却未转存,静默丢失)
        guard changed || legacyHashes != nil else { return }
        saveV2(personAHash: remappedA, context: loadContextForRemap(), roster: roster)
        AppLogger.app.info(
            "op=compatibility.rosterPersistence.remap_hash old=\(oldHash, privacy: .public) new=\(newHash, privacy: .public) roster_count=\(roster.entries.count, privacy: .public) migrated_legacy=\(legacyHashes != nil, privacy: .public)"
        )
    }

    /// remap 写回时保留既有 context 值(无则默认)。
    private static func loadContextForRemap() -> String {
        UserDefaults.standard.string(forKey: Key.context) ?? defaultContext
    }

    // MARK: - Clear(testing / reset)

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.personAHash)
        defaults.removeObject(forKey: Key.context)
        defaults.removeObject(forKey: Key.rosterV2)
        defaults.removeObject(forKey: Key.legacyRosterHashes)
        defaults.removeObject(forKey: Key.tempDraft)
    }

    // MARK: - 临时表单草稿(下次添加时默认值用上次填过的)

    /// 临时表单草稿。alias 不持久化(每次默认空,避免连续加多个相同 alias)。
    /// S04:city: String → place;S05:place 升级 PlaceSelection(城市/自定义地点),
    /// 手动经度字段删除(自定义地点时区显式,不再默认设备时区)。
    /// 2026-09-19 去默认值 + 拆双字段(镜像深度表单 S03):birthDate/gender 改
    /// Optional(未选必选,校验在 VM.validateTempForm),新增 birthTime(时刻独立
    /// 绑定;草稿里 Optional 纯为旧 JSON decode 兼容——缺 key 得 nil,VM.applyTempDraft
    /// 回落链承接:旧草稿 birthDate(时分编码在内)→ 锚点)。
    /// 老草稿(单字段 1990/male)decode:字段全 Optional → 旧值照常解出(草稿语义
    /// =「上次填过的」,升级用户保留上次值是正确行为);整体 decode 失败仍有
    /// 删 key + fallback 兜底(pre-launch 零兼容)。
    struct TempDraftState: Codable, Equatable {
        let birthDate: Date?
        let birthTime: Date?
        let gender: String?
        let place: PlaceSelection?
    }

    /// 写入草稿(addTempToRoster 成功后调)。
    static func saveTempDraft(_ state: TempDraftState) {
        let defaults = UserDefaults.standard
        do {
            let data = try JSONEncoder().encode(state)
            defaults.set(data, forKey: Key.tempDraft)
        } catch {
            // 不静默吞:JSON 编码失败说明 TempDraftState 类型异常
            AppLogger.persistence.error(
                "op=compatibility.rosterPersistence.tempDraft.save_failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// 读出草稿;无数据 / JSON 损坏时 fallback defaultTempDraft(显式日志)。
    static func loadTempDraft() -> TempDraftState {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Key.tempDraft) else {
            return defaultTempDraft
        }
        do {
            return try JSONDecoder().decode(TempDraftState.self, from: data)
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.rosterPersistence.tempDraft.load_failed error=\(String(describing: error), privacy: .public)"
            )
            defaults.removeObject(forKey: Key.tempDraft)
            return defaultTempDraft
        }
    }
}
