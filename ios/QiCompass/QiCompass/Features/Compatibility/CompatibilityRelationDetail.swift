import Foundation

/// 合盘评估卡的确定性「点名干支」派生(BP Match 设计板 #2/#3/#10,2026-10-01)。
///
/// 纯查表派生——**展示层,非历法计算**(干支与五行 key 均来自后端 payload,
/// 与 `DayMasterRelationPhrase` 同一原则)。地支关系表与后端
/// `branch_relations.py` 同源同表(六合/三合/六冲/三刑/相害)。
///
/// 与后端计数的刻意差异:后端 `_assess_branch_harmony` 按先命中先计、每对
/// 只记一类(寅巳记害不记刑),且保留重复柱位(桶计数语义);本层**如实双记**
/// (寅巳 = 刑 + 害)并**按文本去重**——「点名」展示要的是全部关系类型,不是
/// 桶计数。单测用设计稿例盘对盘锁定。
///
/// i18n 债(T2-T6 范围,2026-10-01 记录):关系后缀「合/冲/刑/害」为简体字面
/// (生克动词「生/克」原随日主卡点名在本层,2026-10-07 该点名退役后归
/// `DayMasterRelationPhrase` 中轴短语族);`AppLanguage.zhHant` 止血期不可达
/// (见 AppLanguage.swift T2 说明),接回繁体时本层需随 BaziTerms 的 zhHant
/// 路径补繁体形态。
struct CompatibilityRelationDetail: Equatable {
    /// 五行卡点名(8 字计数差 ≥2 的元素,盘面事实非喜忌判断;nil = 无显著差)。
    let fiveElements: String?
    /// 生肖卡点名(年支动物,zh「鼠 · 蛇」/ en「Rat · Snake」)。
    let zodiac: String?
    /// 地支卡点名(全部合冲刑害对,如「子丑合 · 子午冲 · 寅巳刑害」)。
    let branch: String?
    /// 刑/害对(Note 行用;空 = 不渲染 Note)。
    let frictionPairs: [String]
}

enum CompatibilityRelationDetailBuilder {

    // MARK: 地支关系表(单一事实源同 backend/app/engine/branch_relations.py)

    private static let liuhe: Set<Set<String>> = [
        ["子", "丑"], ["寅", "亥"], ["卯", "戌"], ["辰", "酉"],
        ["巳", "申"], ["午", "未"],
    ]
    private static let sanheGroups: [Set<String>] = [
        ["申", "子", "辰"], ["寅", "午", "戌"], ["巳", "酉", "丑"], ["亥", "卯", "未"],
    ]
    private static let liuchong: Set<Set<String>> = [
        ["子", "午"], ["丑", "未"], ["寅", "申"], ["卯", "酉"],
        ["辰", "戌"], ["巳", "亥"],
    ]
    private static let sanxing: [Set<String>] = [
        ["寅", "巳", "申"], ["丑", "戌", "未"], ["子", "卯"],
    ]
    private static let xianghai: Set<Set<String>> = [
        ["子", "未"], ["丑", "午"], ["寅", "巳"], ["卯", "辰"],
        ["申", "亥"], ["酉", "戌"],
    ]

    /// 单条地支关系(刑害双属性时 text 如「寅巳刑害」)。
    private struct BranchPair {
        let text: String
        /// 关系rank(展示排序:合 → 半合 → 冲 → 刑 → 害)。
        let rank: Int
        /// 扫描序(Swift sort 非稳定,作同 rank 平局裁决:年→时 × A外B内)。
        let scanIndex: Int
        let isFriction: Bool
    }

    // MARK: 入口

    static func make(pillars: [DualPillarSource]) -> CompatibilityRelationDetail {
        // 展示去重(2026-10-01 review):同一关系文本在多柱位重复出现时只列一次
        // (A 两柱有子 × B 一柱有丑 →「子丑合」一条)。后端 4×4 计数**保留**重复
        // 是桶计数语义(多冲少合等枚举的输入);点名是"列关系",重复串是噪音。
        let pairs = branchRelations(pillars)
        var seen: Set<String> = []
        let unique = pairs.filter { seen.insert($0.text).inserted }
        return CompatibilityRelationDetail(
            fiveElements: fiveElementsTerm(pillars),
            zodiac: zodiacTerm(pillars),
            branch: unique.isEmpty ? nil : unique.map(\.text).joined(separator: " · "),
            frictionPairs: unique.filter(\.isFriction).map(\.text)
        )
    }

    // MARK: 五行卡(盘面计数,非喜忌)

    /// 计数差 ≥2 的元素判「多」(纯盘面事实,不给喜忌结论——那是后端枚举的职责)。
    private static func fiveElementsTerm(_ pillars: [DualPillarSource]) -> String? {
        let countsA = elementCounts(pillars, isA: true)
        let countsB = elementCounts(pillars, isA: false)

        func more(isASide: Bool) -> [ElementColors] {
            let mine = isASide ? countsA : countsB
            let other = isASide ? countsB : countsA
            return ElementColors.allCases.filter { elem in
                (mine[elem] ?? 0) - (other[elem] ?? 0) >= 2
            }
        }
        let bMore = more(isASide: false)
        let aMore = more(isASide: true)
        guard !bMore.isEmpty || !aMore.isEmpty else { return nil }

        var parts: [String] = []
        if !bMore.isEmpty {
            parts.append(String(format: String(localized: "对方多 %@"), joinedLabels(bMore)))
        }
        if !aMore.isEmpty {
            parts.append(String(format: String(localized: "你多 %@"), joinedLabels(aMore)))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 生肖卡

    /// 年支动物(zh 单字 / zh-hant 繁体字 / en 英文名;干支字本体在双盘表可见,
    /// 这里给可读动物名)。走 `ZodiacHelper.displayName` 三语分流(2026-10-02
    /// 修复:此前 `isChinese ? animalChar : name` 把 zh-hant 落进简体表,
    /// 繁体界面显示「龙 · 马」而非「龍 · 馬」,违反 D9)。
    private static func zodiacTerm(_ pillars: [DualPillarSource]) -> String? {
        guard let year = pillars.first(where: { $0.position == L10n.Compatibility.dualYearPillar }),
              let za = year.zhiA, let zb = year.zhiB,
              let nameA = ZodiacHelper.zodiacName(forZhi: za),
              let nameB = ZodiacHelper.zodiacName(forZhi: zb) else {
            return nil
        }
        let a = ZodiacHelper.displayName(forZodiac: nameA)
        let b = ZodiacHelper.displayName(forZodiac: nameB)
        return "\(a) · \(b)"
    }

    // MARK: 地支卡(4×4 全扫描,如实双记)

    private static func branchRelations(_ pillars: [DualPillarSource]) -> [BranchPair] {
        // 「冲」简繁异形(繁体惯例「沖」,对齐 BaziTerms zhHant「六沖」用字);
        // 合/半合/刑/害简繁同形无需分流(2026-10-02 D9 修复)
        let chong = AppLanguage.current == .zhHant ? "沖" : "冲"
        let aZhis = pillars.compactMap { $0.zhiA }
        let bZhis = pillars.compactMap { $0.zhiB }
        var out: [BranchPair] = []
        for a in aZhis {
            for b in bZhis {
                guard a != b else { continue }  // 同支无关系(与后端扫描同判)
                let pair: Set<String> = [a, b]
                var parts: [String] = []
                var rank = 0
                if liuhe.contains(pair) {
                    parts.append("合"); rank = 1
                } else if sanheGroups.contains(where: { $0.isSuperset(of: pair) }) {
                    parts.append("半合"); rank = 2
                }
                if liuchong.contains(pair) {
                    parts.append(chong); rank = max(rank, 3)
                }
                let hasXing = sanxing.contains(where: { $0.isSuperset(of: pair) })
                if hasXing {
                    parts.append("刑"); rank = max(rank, 4)
                }
                let hasHai = xianghai.contains(pair)
                if hasHai {
                    parts.append("害"); rank = max(rank, 5)
                }
                guard !parts.isEmpty else { continue }
                out.append(BranchPair(
                    text: a + b + parts.joined(),
                    rank: rank,
                    scanIndex: out.count,
                    isFriction: hasXing || hasHai
                ))
            }
        }
        // 确定性排序:合 → 半合 → 冲 → 刑 → 害;同 rank 按扫描序(年→时 × A外B内)
        out.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.scanIndex < $1.scanIndex }
        return out
    }

    // MARK: 工具

    private static func joinedLabels(_ elems: [ElementColors]) -> String {
        // zh 单字连排自然(「木火」);en 需分隔符,否则双元素连成 "WoodFire"
        let isZh = AppLanguage.current.isChinese
        return elems.map { isZh ? $0.label : $0.englishLabel }
            .joined(separator: isZh ? "" : ", ")
    }

    /// 单侧五行字数(干 + 支各计 1;元素 key 缺失的字不计,不猜)。
    /// internal(2026-10-01 #4):ElementBalanceSection.Model 复用同一计数。
    static func elementCounts(
        _ pillars: [DualPillarSource], isA: Bool
    ) -> [ElementColors: Int] {
        var counts: [ElementColors: Int] = [:]
        for p in pillars {
            let keys: [String?] = isA
                ? [p.ganElementA, p.zhiElementA]
                : [p.ganElementB, p.zhiElementB]
            for key in keys.compactMap({ $0 }) {
                if let elem = ElementColors.from(key) {
                    counts[elem, default: 0] += 1
                }
            }
        }
        return counts
    }
}
