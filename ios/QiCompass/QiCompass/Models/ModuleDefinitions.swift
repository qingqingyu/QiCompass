import Foundation

/// v1 prompt 系统模块标识(Stage 7a 引入)。
///
/// 对齐 backend `app/models/interpret.py:Module` Literal 的 v1 部分
/// (m0_structure ~ m7_manual),以及 `app/config.py:MODULE_TEMPERATURES`。
///
/// 设计决策(2026-08-11 用户拍板):
/// - M0+M1 免费,M2-M7 付费(替代老 bazi_deep_free / _paid 2+5 拆分)
/// - M4/M5 按需模块,需要用户输入(age+concern / assets+preference)
/// - M0 是 fingerprint 产生者,M1-M7 链式注入 parent_fingerprint
///
/// 现有 InterpretState(单文本态)保留给合盘 / 每日运势 / 老 bazi_deep 路径继续用,
/// 本 enum 仅服务 v1 模块化路径(DeepAnalysisViewModel 的 moduleStates 字典)。
enum ModuleID: String, CaseIterable, Codable, Sendable {
    case m0 = "m0_structure"     // 免费:识别主线结构
    case m1 = "m1_talent"        // 免费:天赋能力
    case m2 = "m2_high_low"      // 付费:高配/低配
    case m3 = "m3_system"        // 付费:人生系统模式
    case m4 = "m4_health"        // 付费:健康续航(需 age + current_concern)
    case m5 = "m5_wealth"        // 付费:财富结构(需 assets_summary + preference)
    case m6 = "m6_dynamics"      // 付费:结构动力学(高阶)
    case m7 = "m7_manual"        // 付费:落地手册

    /// 显示名称(中文,对齐 v1.md §3 各模块标题;en 走 xcstrings 同 key)。
    /// 用于 ModuleCardView 的 header,格式 "M{N} · {标题}" 便于用户识别层级。
    var displayName: String {
        switch self {
        case .m0: return String(localized: "M0 · 主线结构")
        case .m1: return String(localized: "M1 · 天赋能力")
        case .m2: return String(localized: "M2 · 高配 vs 低配")
        case .m3: return String(localized: "M3 · 系统模式")
        case .m4: return String(localized: "M4 · 健康续航")
        case .m5: return String(localized: "M5 · 财富结构")
        case .m6: return String(localized: "M6 · 结构动力学")
        case .m7: return String(localized: "M7 · 落地手册")
        }
    }

    /// 章名(displayName 去「M{N} · 」前缀;目录行/付费墙清单/翻章条同口径,
    /// 2026-09-30 S4 收敛为单一实现)。
    var chapterName: String {
        let name = displayName
        guard let separator = name.range(of: "· ") else { return name }
        return String(name[separator.upperBound...])
    }

    /// 一句话副标题(S4 章名人话化,2026-09-30 BP 内容评审 R8/R12/R13:
    /// 系统分析术语 → 按各章实际产出说人话;en 走 xcstrings 同 key)。
    /// 目录行/阅读页章节头/付费墙卖点共同消费,改这里即三处同步。
    var subtitle: String {
        switch self {
        case .m0: return String(localized: "你这张盘的主线:靠什么驱动,在哪里打转")
        case .m1: return String(localized: "天生就会的 · 后天练出的 · 为自保养成、长期在消耗你的")
        case .m2: return String(localized: "同一张盘,在好环境和坏环境里分别会活成什么样")
        case .m3: return String(localized: "你怎样运转最好、什么环境会让你失灵、什么样的生活节奏适合你")
        case .m4: return String(localized: "精力的起落规律,和最有效的恢复方式")
        case .m5: return String(localized: "适合你的赚钱方式,和最容易漏钱的地方")
        case .m6: return String(localized: "你的发力点、薄弱点,以及下一阶段怎么升级")
        case .m7: return String(localized: "最值得押注的一件事,和接下来 90 天的行动")
        }
    }

    /// 免费模块(对齐用户决策:M0+M1 免费)。
    /// 后端 PAID_MODULES 白名单不含 m0_structure / m1_talent,与本属性一致。
    var isFree: Bool {
        self == .m0 || self == .m1
    }

    /// 付费模块(M2-M7)。
    var isPaid: Bool {
        !isFree
    }

    /// 需要用户输入的按需模块(M4 / M5)。
    /// 决定 ModuleCardView 显示 "提供输入" CTA(.needsInput state)。
    var needsUserInput: Bool {
        self == .m4 || self == .m5
    }

    /// 链式调用契约:M1-M7 必填 parent_fingerprint,M0 自身不需要。
    /// 对齐 backend `app/models/interpret.py:V1_CHILDREN_MODULES`。
    var requiresParentFingerprint: Bool {
        self != .m0
    }

    /// v1 §1 temperature 分级(对齐 backend `app/config.py:MODULE_TEMPERATURES`)。
    /// iOS 不直接用(后端 resolve_temperature 决定),保留作 metadata 与文档对齐。
    var temperature: Double {
        switch self {
        case .m0, .m1, .m2: return 0.3
        case .m3, .m4, .m5, .m6, .m7: return 0.6
        }
    }

    /// 链式调用依赖(本模块执行前必须成功的上游模块)。
    /// 对齐 backend/spikes/prompt_validation/run_v1_chain_spike.py 依赖图。
    /// M0 无依赖;M1 needs M0;M2 needs M0+M1;M3 needs M0;
    /// M4 needs M0(+用户输入);M5 needs M0+M1+M3(+用户输入);
    /// M6 needs M0+M1+M2;M7 needs M1+M2+M3+M6(注意不含 M0,M7 模板不读 chart)。
    var dependencies: [ModuleID] {
        switch self {
        case .m0: return []
        case .m1: return [.m0]
        case .m2: return [.m0, .m1]
        case .m3: return [.m0]
        case .m4: return [.m0]
        case .m5: return [.m0, .m1, .m3]
        case .m6: return [.m0, .m1, .m2]
        case .m7: return [.m1, .m2, .m3, .m6]
        }
    }

    /// 本模块渲染 prompt 必带的**链式字段**(backend `REQUIRED_FIELDS` 减去
    /// chart / structure_fingerprint / M4/M5 用户输入——那三类由
    /// DeepAnalysisOrchestrator.runV1Module 直接组装)。
    ///
    /// 字段值 = 上游模块 JSON 输出的序列化字符串,VM 从 v1ChainFields 取出后
    /// 经 `runV1Module(chainFields:)` 注入 context。
    /// 2026-09-25 修复:此前这些字段提取后从未随请求发送,m1/m2/m5/m6/m7
    /// 真机必 422"prompt 渲染缺字段"(免费预览 M1 卡永远死卡)。
    ///
    /// 对齐 backend `app/ai/prompts.py` REQUIRED_FIELDS;tools/check_prompt_sync.py
    /// ③ 对本清单做 backend↔iOS 一致性校验,改任一侧必须两边同步。
    var requiredChainFields: [String] {
        switch self {
        case .m0: return []
        case .m1: return ["main_axis", "core_loop"]
        case .m2: return ["innate", "defensive"]
        case .m3: return []
        case .m4: return []
        case .m5: return ["innate", "ideal_life_structure"]
        case .m6: return ["core_loop", "innate", "defensive", "threshold"]
        case .m7: return ["one_leverage", "switch_actions", "environment_checklist", "leverage"]
        }
    }
}
