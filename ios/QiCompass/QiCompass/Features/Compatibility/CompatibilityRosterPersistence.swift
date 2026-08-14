import Foundation

/// 合盘名单 + A 盘 + context 跨启动持久化(决策 D5)。
///
/// 持久化 3 个 UserDefaults key:
/// - `compat.lastPersonAHash`:上次 A 盘 contentHash(失效则 VM fallback 最新 link)
/// - `compat.lastContext`:上次 context(默认 "general")
/// - `compat.roster`:JSON `[personBHash]`(临时人用 S04 回填的 resolvedHash,
///   跨启动后恢复为 `.archived` 风格 entry,显示名走兜底名「对方+出生日期」)
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
    }

    /// 默认 context(决策 D8;持久化无 context 时 fallback)。
    static let defaultContext = "general"

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

    // MARK: - Clear(testing / reset)

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Key.personAHash)
        defaults.removeObject(forKey: Key.context)
        defaults.removeObject(forKey: Key.rosterHashes)
    }
}
