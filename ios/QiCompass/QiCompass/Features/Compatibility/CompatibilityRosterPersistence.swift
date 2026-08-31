import Foundation

/// 合盘名单 + A 盘 + context + 临时表单草稿 跨启动持久化(决策 D5)。
///
/// 持久化 4 类 UserDefaults key:
/// - `compat.lastPersonAHash`:上次 A 盘 contentHash(失效则 VM fallback 最新 link)
/// - `compat.lastContext`:上次 context(默认 "general")
/// - `compat.roster`:JSON `[personBHash]`(临时人用 S04 回填的 resolvedHash,
///   跨启动后恢复为 `.archived` 风格 entry,显示名走兜底名「对方+出生日期」)
/// - `compat.tempDraft`:JSON `TempDraftState`(临时表单上次填过的字段,
///   加第二个临时人时默认值用上次的,用户只改称呼/时间)
///
/// 红线 D6:名单只存 hash 字符串,**不存完整 RosterEntry**(临时人 alias 不持久化,
/// 会话内场景已过;不转 UserSnapshotLink)。这是深思后的保守选择——
/// 减少持久化状态维度,避免与 SwiftData 快照库不一致。
///
/// 错误显式传播:JSON 损坏 → load() 返回空数组(显式日志记录),不静默吞数据。
struct CompatibilityRosterPersistence {

    private enum Key {
        static let personAHash = "compat.lastPersonAHash"
        static let context = "compat.lastContext"
        static let rosterHashes = "compat.roster"
        static let tempDraft = "compat.tempDraft"
    }

    /// 默认 context(决策 D8;持久化无 context 时 fallback)。
    static let defaultContext = "general"

    /// 临时表单默认草稿(无持久化时 fallback;1990-03-15 占位)。
    /// S04:出生地无默认城市;S05:自定义地点取代手动经度开关,时区显式。
    static let defaultTempDraft = TempDraftState(
        birthDate: Date(timeIntervalSince1970: 638_000_000),
        gender: "male",
        place: nil
    )

    // MARK: - Save

    /// 写入持久化(compute() 成功后调)。
    /// rosterHashes 来自 summaries.personBHash(已含 resolved contentHash)。
    static func save(personAHash: String, context: String, rosterHashes: [String]) {
        let defaults = UserDefaults.standard
        defaults.set(personAHash, forKey: Key.personAHash)
        defaults.set(context, forKey: Key.context)
        do {
            let data = try JSONEncoder().encode(rosterHashes)
            defaults.set(data, forKey: Key.rosterHashes)
        } catch {
            // 不静默吞:JSON 编码失败说明 rosterHashes 类型异常,记录但不阻塞 compute() 已成功的状态
            AppLogger.persistence.error(
                "op=compatibility.rosterPersistence.save_encode_failed error=\(String(describing: error), privacy: .public)"
            )
        }
        AppLogger.app.info(
            "op=compatibility.rosterPersistence.save a_hash=\(personAHash, privacy: .public) context=\(context, privacy: .public) roster_count=\(rosterHashes.count, privacy: .public)"
        )
    }

    // MARK: - Load

    struct PersistedState {
        let personAHash: String?
        let context: String
        let rosterHashes: [String]
    }

    /// 读出持久化值;JSON 损坏时返回空 roster(显式日志)。
    static func load() -> PersistedState {
        let defaults = UserDefaults.standard
        let aHash = defaults.string(forKey: Key.personAHash)
        let context = defaults.string(forKey: Key.context) ?? defaultContext

        var hashes: [String] = []
        if let data = defaults.data(forKey: Key.rosterHashes) {
            do {
                hashes = try JSONDecoder().decode([String].self, from: data)
            } catch {
                AppLogger.persistence.error(
                    "op=compatibility.rosterPersistence.load_decode_failed error=\(String(describing: error), privacy: .public)"
                )
                // 损坏 → 视为空,清理脏数据
                defaults.removeObject(forKey: Key.rosterHashes)
            }
        }
        return PersistedState(personAHash: aHash, context: context, rosterHashes: hashes)
    }

    // MARK: - Cleanup(无效 hash 剔除)

    /// 恢复时若名单 hash 失效(ChartSnapshot 不存在),剔除 + 写回干净名单。
    /// 用有效性验证 closure 决定保留与否。
    static func cleanupInvalidHashes(
        persistedHashes: [String],
        isValid: (String) -> Bool
    ) -> [String] {
        let cleaned = persistedHashes.filter(isValid)
        if cleaned.count != persistedHashes.count {
            AppLogger.app.warning(
                "op=compatibility.rosterPersistence.cleanup_invalid_hashes before=\(persistedHashes.count, privacy: .public) after=\(cleaned.count, privacy: .public)"
            )
            // 写回干净名单:单次 load() 避免重复 UserDefaults 读 + JSON decode
            let state = load()
            if let aHash = state.personAHash {
                save(personAHash: aHash, context: state.context, rosterHashes: cleaned)
            }
        }
        return cleaned
    }

    // MARK: - Hash remap(S10 补时辰换新盘)

    /// 补时辰 hash 重建后,把持久化名单/A 盘里的老 hash 原地换成新 hash。
    ///
    /// 他人盘补时辰 → content_hash 变 → 不 remap 的话名单仍指向老三柱盘
    /// (照旧「不可合盘」标记,人像从名单里消失);remap 后该人带着新盘留在名单,
    /// 「对级关系自然重算」落到用户重新点「开始合盘」即得完整结果(新对走 S05
    /// 增量预查未命中 → 正常发起)。自己盘同理(A hash 失效本可 fallback 最新 link,
    /// remap 让持久化状态与最新 link 直接一致)。
    ///
    /// 无命中(A 盘 + 名单都不含老 hash)→ no-op(不写 UserDefaults,无副作用)。
    static func remapHash(from oldHash: String, to newHash: String) {
        let state = load()
        let remappedRoster = state.rosterHashes.map { $0 == oldHash ? newHash : $0 }
        let remappedA = state.personAHash == oldHash ? newHash : state.personAHash
        guard remappedRoster != state.rosterHashes || remappedA != state.personAHash else {
            return
        }
        // personAHash 为 nil 时沿用既有「无 A」语义(空串,与 persistRosterState 一致)
        save(personAHash: remappedA ?? "", context: state.context, rosterHashes: remappedRoster)
        AppLogger.app.info(
            "op=compatibility.rosterPersistence.remap_hash old=\(oldHash, privacy: .public) new=\(newHash, privacy: .public) roster_count=\(remappedRoster.count, privacy: .public)"
        )
    }

    // MARK: - Clear(testing / reset)

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.personAHash)
        defaults.removeObject(forKey: Key.context)
        defaults.removeObject(forKey: Key.rosterHashes)
        defaults.removeObject(forKey: Key.tempDraft)
    }

    // MARK: - 临时表单草稿(下次添加时默认值用上次填过的)

    /// 临时表单草稿。alias 不持久化(每次默认空,避免连续加多个相同 alias)。
    /// S04:city: String → place;S05:place 升级 PlaceSelection(城市/自定义地点),
    /// 手动经度字段删除(自定义地点时区显式,不再默认设备时区)。
    /// 老草稿解码失败 → loadTempDraft fallback 默认草稿(pre-launch 零兼容)。
    struct TempDraftState: Codable, Equatable {
        let birthDate: Date
        let gender: String
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
