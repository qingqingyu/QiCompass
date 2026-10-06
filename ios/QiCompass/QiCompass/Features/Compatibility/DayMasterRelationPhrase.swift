import Foundation

/// 日主关系方向短语(S4,2026-09-29 结果页主页化)。
///
/// 纯五行生克查表——**展示层派生,非历法计算**(不违反「客户端不做历法计算」:
/// 干支与五行 key 均来自后端 payload,这里只做生克动词的方向判定)。
/// 与后端 `_assess_day_master`(backend/app/engine/compatibility.py)同源同表:
/// 五行生克是对称关系(类别无方向),方向(谁生谁 / 谁克谁)由客户端查表定,
/// 类别必须与后端一致——**一致性守卫**:不等 → `AppLogger.error` + 只显后端标签
/// (不静默、不猜)。
enum DayMasterRelationPhrase {

    /// 关系三态(与后端 Literal 枚举对齐)。
    enum Category: Equatable {
        case sameQi
        case generates
        case overcomes

        /// 后端标签归一(zh「同气/相生/相克」+ en 服务端翻译,term_translations.py;
        /// 后端按请求 language 已译好再下发,客户端双表归一即可)。
        init?(backendLabel: String) {
            switch backendLabel {
            case "同气", "Same element": self = .sameQi
            case "相生", "Generating cycle": self = .generates
            case "相克", "Controlling cycle": self = .overcomes
            default: return nil
            }
        }
    }

    struct Output: Equatable {
        /// 客户端派生类别(nil = 输入不足以派生,如日柱歧义盘字段缺失)。
        let derived: Category?
        /// 中轴展示文字(nil = 派生失败 / 后端标签不可归一 / 与后端不一致
        /// → 调用方只显后端标签,回退不静默)。
        let text: String?
        /// 一致性守卫结果(false = 已 AppLogger.error,走后端标签回退)。
        let matchesBackend: Bool
    }

    /// 五行相生环:木生火、火生土、土生金、金生水、水生木。
    /// (2026-10-01 曾 internal 供 CompatibilityRelationDetailBuilder 复用;其
    /// 日主卡点名随 2026-10-07 去重退役,现仅本文件派生中轴短语用。)
    static let sheng: [String: String] = [
        "wood": "fire", "fire": "earth", "earth": "metal",
        "metal": "water", "water": "wood",
    ]
    /// 五行相克环:木克土、土克水、水克火、火克金、金克木。
    static let ke: [String: String] = [
        "wood": "earth", "earth": "water", "water": "fire",
        "fire": "metal", "metal": "wood",
    ]

    /// 派生日主关系短语(方向:生成/克方在前)。
    /// - Parameters:
    ///   - ganA/elementA:A 侧日干与五行英文 key(DualPillarSource 日柱 gan/ganElement)
    ///   - ganB/elementB:B 侧
    ///   - backendRelation:后端 qualitativeAssessment.dayMasterRelation 原值
    static func make(
        ganA: String?, elementA: String?,
        ganB: String?, elementB: String?,
        backendRelation: String
    ) -> Output {
        // 输入齐全才派生(日柱歧义盘 / 老盘字段缺失 → 字段可能为 nil)
        guard let ganA, !ganA.isEmpty,
              let ganB, !ganB.isEmpty,
              let elementA, Self.sheng[elementA] != nil,
              let elementB, Self.sheng[elementB] != nil else {
            // 派生不了 → 无法与后端互证,显式记录 + 后端标签回退(不猜方向)
            AppLogger.app.error(
                "op=compatibility.dayMasterPhrase insufficient_input backend=\(backendRelation, privacy: .public) ganA=\(ganA ?? "nil") ganB=\(ganB ?? "nil")"
            )
            return Output(derived: nil, text: nil, matchesBackend: false)
        }

        let derived: Category?
        if elementA == elementB {
            derived = .sameQi
        } else if Self.sheng[elementA] == elementB || Self.sheng[elementB] == elementA {
            derived = .generates
        } else if Self.ke[elementA] == elementB || Self.ke[elementB] == elementA {
            derived = .overcomes
        } else {
            derived = nil  // 理论不可达(五行表全覆盖无向对);防御性走守卫
        }

        // 一致性守卫:类别不等 / 后端标签不可归一 → 只显后端标签
        guard let backendCategory = Category(backendLabel: backendRelation) else {
            AppLogger.app.error(
                "op=compatibility.dayMasterPhrase unknown_backend_label backend=\(backendRelation, privacy: .public)"
            )
            return Output(derived: derived, text: nil, matchesBackend: false)
        }
        guard derived == backendCategory else {
            AppLogger.app.error(
                "op=compatibility.dayMasterPhrase mismatch derived=\(String(describing: derived), privacy: .public) backend=\(backendRelation, privacy: .public) ganA=\(ganA, privacy: .public) ganB=\(ganB, privacy: .public)"
            )
            return Output(derived: derived, text: nil, matchesBackend: false)
        }
        guard let derived else {
            return Output(derived: nil, text: nil, matchesBackend: false)
        }

        // 方向短语(五行标签随 UI 语言:zh 单字 / en 词)
        let isChinese = AppLanguage.current.isChinese
        func elemLabel(_ key: String) -> String {
            ElementColors.from(key)
                .map { isChinese ? $0.label : $0.englishLabel } ?? key
        }

        switch derived {
        case .sameQi:
            return Output(
                derived: derived,
                text: L10n.Compatibility.dualAxisSameQi(ganA, elemLabel(elementA), ganB, elemLabel(elementB)),
                matchesBackend: true
            )
        case .generates:
            // 生成方在前(A 生 B 或 B 生 A,方向客户端查表定)。
            // 2026-10-07 去掉「· 关系标签」后缀:方向短语已含类别,类别词归评估卡
            // 承载,一屏不说两遍(EN 界面也不再拼进后端标签原值)
            if Self.sheng[elementA] == elementB {
                return Output(
                    derived: derived,
                    text: L10n.Compatibility.dualAxisGenerate(
                        ganA, elemLabel(elementA), ganB, elemLabel(elementB)
                    ),
                    matchesBackend: true
                )
            }
            return Output(
                derived: derived,
                text: L10n.Compatibility.dualAxisGenerate(
                    ganB, elemLabel(elementB), ganA, elemLabel(elementA)
                ),
                matchesBackend: true
            )
        case .overcomes:
            // 克方在前(同上去后缀)
            if Self.ke[elementA] == elementB {
                return Output(
                    derived: derived,
                    text: L10n.Compatibility.dualAxisOvercome(
                        ganA, elemLabel(elementA), ganB, elemLabel(elementB)
                    ),
                    matchesBackend: true
                )
            }
            return Output(
                derived: derived,
                text: L10n.Compatibility.dualAxisOvercome(
                    ganB, elemLabel(elementB), ganA, elemLabel(elementA)
                ),
                matchesBackend: true
            )
        }
    }
}
