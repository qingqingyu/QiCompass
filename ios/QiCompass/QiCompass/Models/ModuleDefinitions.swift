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

    /// 显示名称(中文,对齐 v1.md §3 各模块标题)。
    /// 用于 ModuleCardView 的 header,格式 "M{N} · {标题}" 便于用户识别层级。
    var displayName: String {
        switch self {
        case .m0: return "M0 · 主线结构"
        case .m1: return "M1 · 天赋能力"
        case .m2: return "M2 · 高配 vs 低配"
        case .m3: return "M3 · 系统模式"
        case .m4: return "M4 · 健康续航"
        case .m5: return "M5 · 财富结构"
        case .m6: return "M6 · 结构动力学"
        case .m7: return "M7 · 落地手册"
        }
    }

    /// 一句话副标题(对齐 v1.md §3 各模块"目的")。
    /// 卡片 pending 态显示,让用户在点击前知道这个模块分析什么。
    var subtitle: String {
        switch self {
        case .m0: return "识别你命局的主线结构与核心循环"
        case .m1: return "区分天赋能力、训练能力与防御性能力"
        case .m2: return "同一结构在高配/低配环境下的两种跑法"
        case .m3: return "你的运行模式 + 失效环境 + 适配生活结构"
        case .m4: return "基于命局的能量规律与恢复杠杆"
        case .m5: return "收入形态匹配度与漏财止损规则"
        case .m6: return "能量路径、杠杆点、易损点与升级路线"
        case .m7: return "你的真正杠杆 + 90 天放大行动"
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
}
