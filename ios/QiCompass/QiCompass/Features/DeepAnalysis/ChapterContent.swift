import Foundation

// MARK: - 章节正文结构化模型(2026-09-02)
//
// 背景:v1 prompt 系统 M0-M7 的后端契约=输出 JSON(链式注入载体:structure_fingerprint /
// main_axis 等字段要喂给下游模块),字段值本身是丰富中文长文(篇幅约束 150-300 字/字段)。
// 阅读页(盘面小景 ⑤)此前按纯散文直排 `.ok(text)`,JSON 原文裸奔。本模型把模块 JSON
// 规范化为节点树,供 ChapterContentView 排版;解析失败返回 nil,调用方退回散文排版
// 并记日志(错误显式传播:不静默丢章,也不吞解析异常)。
//
// 节点映射规则:
// - 顶层标量字符串          → 引言段(.lead,如 structure_fingerprint / one_leverage)
// - 对象(含非标量值)      → 小节(.section,递归),小节题走中文标签表
// - 对象(值全为标量)      → 键值组(.fields,保持 JSON 书写顺序)
// - 字符串数组              → 条目列(.bullets)
// - 对象数组                → 条目卡(.items,按 titleKeys 优先级取首字段作题)
// - evidence / medical_note / disclaimer → 小字注(「据 · 」/「注 · 」)

/// 章节节点树(纯值类型,Equatable 供单测)。
enum ChapterNode: Equatable {
    /// 顶层标量字符串:章首引言。
    case lead(String)
    /// 小节:题 + 子节点(对象里混有结构值时降级为小节)。
    case section(String, [ChapterNode])
    /// 键值组:对象且值全标量;evidence 类字段标记 isNote 供小字排版。
    case fields([ChapterField])
    /// 条目列:字符串数组。
    case bullets([String])
    /// 条目卡:对象数组(每项 title 可空 + 键值组 + 条目列)。
    case items([ChapterItem])
    /// 顶层小字注(medical_note / disclaimer / 顶层 evidence):标签 + 正文。
    case note(label: String, text: String)
}

/// 键值行(结构体而非元组:元组带标签不合成 Equatable,单测要断言全树)。
struct ChapterField: Equatable {
    let label: String
    let value: String
    let isNote: Bool
}

/// 对象数组里的单个条目卡。
struct ChapterItem: Equatable {
    /// 条目题(按 titleKeys 优先级从对象字段提取;无命中则为 nil)。
    let title: String?
    let fields: [ChapterField]
    let bullets: [String]
}

/// 章节正文(解析产物)。
struct ChapterContent: Equatable {
    var nodes: [ChapterNode]

    /// 解析模块正文。非 JSON / 顶层非对象 / 非法 JSON → nil(调用方退回散文)。
    /// 容错:剥掉 LLM 违约附加的 ```json 围栏(prompt 已禁但防御)。
    static func parse(_ text: String) -> ChapterContent? {
        guard let root = OrderedJSONParser.parse(OrderedJSONParser.stripCodeFences(text)) else { return nil }
        guard case .object(let pairs) = root else { return nil }
        let nodes = pairs.compactMap { node(key: $0.0, value: $0.1) }
        return nodes.isEmpty ? nil : ChapterContent(nodes: nodes)
    }

    // MARK: - 规范化

    private static func node(key: String, value: JSONValue) -> ChapterNode? {
        switch value {
        case .string(let s):
            if Self.noteKeys.contains(key) {
                return .note(label: Self.label(key), text: s)
            }
            return .lead(s)
        case .number, .bool:
            // 顶层裸标量(理论上 schema 不出):按引言排版
            return .lead(Self.scalarText(key: key, value: value))
        case .null:
            return nil
        case .array(let values):
            return arrayNode(key: key, values: values)
        case .object(let pairs):
            // 对象一律成节(小节题是语义信息:主线/核心循环/电池类型…);
            // 值全标量 → 子节点为单个键值组;混结构值 → 子节点递归。
            let children: [ChapterNode]
            if pairs.allSatisfy({ $0.1.isScalar }) {
                children = [.fields(pairs.map { field(key: $0.0, value: $0.1) })]
            } else {
                children = pairs.compactMap { node(key: $0.0, value: $0.1) }
            }
            return .section(Self.label(key), children)
        }
    }

    private static func arrayNode(key: String, values: [JSONValue]) -> ChapterNode? {
        let nonNull = values.filter { if case .null = $0 { return false } else { return true } }
        guard !nonNull.isEmpty else { return nil }
        // 全字符串 → 条目列
        if case .string = nonNull[0], nonNull.allSatisfy({ if case .string = $0 { return true } else { return false } }) {
            return .bullets(nonNull.map { Self.scalarText(key: key, value: $0) })
        }
        // 对象数组 → 条目卡
        let items = nonNull.compactMap { value -> ChapterItem? in
            guard case .object(let pairs) = value else { return nil }
            return item(from: pairs)
        }
        if items.count == nonNull.count {
            return .items(items)
        }
        // 混合数组(schema 外):退化为字符串条目列
        return .bullets(nonNull.map { Self.inlineText($0) })
    }

    private static func item(from pairs: [(String, JSONValue)]) -> ChapterItem {
        var title: String?
        var fields: [ChapterField] = []
        var bullets: [String] = []
        for (key, value) in pairs {
            if case .array(let arr) = value {
                let strings = arr.compactMap { v -> String? in
                    if case .string(let s) = v { return s } else { return nil }
                }
                if strings.count == arr.count, !arr.isEmpty {
                    bullets.append(contentsOf: strings)
                    continue
                }
            }
            if title == nil, Self.titleKeys.contains(key), value.isScalar {
                title = titleText(key: key, value: value)
                continue
            }
            fields.append(field(key: key, value: value))
        }
        return ChapterItem(title: title, fields: fields, bullets: bullets)
    }

    private static func field(key: String, value: JSONValue) -> ChapterField {
        ChapterField(
            label: Self.label(key),
            value: Self.scalarText(key: key, value: value),
            isNote: noteKeys.contains(key)
        )
    }

    // MARK: - 标量文案化

    private static func scalarText(key: String, value: JSONValue) -> String {
        switch value {
        case .string(let s):
            return Self.valueMap[key]?[s] ?? s
        case .number(let n):
            if key == "day" { return "第 \(Int(n)) 天" }
            if key == "rank" { return "第 \(Int(n)) 顺位" }
            if n.rounded() == n { return String(Int(n)) }
            return String(n)
        case .bool(let b):
            return b ? "是" : "否"
        case .null:
            return "—"
        case .array, .object:
            // 键值组内不应出现(分组逻辑已拦截);防御性内联,不静默丢内容
            return inlineText(value)
        }
    }

    /// 条目题文案(day → 第 N 天;其余走 valueMap)。
    private static func titleText(key: String, value: JSONValue) -> String {
        if key == "day", case .number(let n) = value { return "第 \(Int(n)) 天" }
        return scalarText(key: key, value: value)
    }

    /// 结构值压成内联文本(混合数组防御路径;只降可读性不丢内容)。
    private static func inlineText(_ value: JSONValue) -> String {
        switch value {
        case .string(let s):
            return s
        case .number, .bool:
            return scalarText(key: "", value: value)
        case .null:
            return "—"
        case .array(let values):
            return values.map(inlineText).joined(separator: ";")
        case .object(let pairs):
            return pairs.map { "\(label($0.0)):\(inlineText($0.1))" }.joined(separator: ";")
        }
    }

    // MARK: - 标签表(snake_case → 中文;M0-M7 全量 schema key,2026-09-02 对齐 prompts.py)

    static let labels: [String: String] = [
        // 公共
        "evidence": "据",
        "name": "名称",
        "text": "正文",
        "one_line": "一句话",
        "type": "类型",
        // M0 主线结构
        "main_axis": "主线",
        "dominant": "主导",
        "secondary": "次要",
        "latent": "潜伏",
        "core_loop": "核心循环",
        "from": "起点",
        "to": "终点",
        "flow": "流向",
        "driver": "驱动",
        "leak": "损耗",
        "structure_type": "结构类型",
        "capability_source": "能力来源",
        "structure_fingerprint": "运转概括",
        // M1 天赋能力
        "innate": "天赋能力",
        "trained": "训练能力",
        "defensive": "防御性能力",
        "behavior": "行为表现",
        "energy": "能量",
        "trained_by": "训练来源",
        "looks_like": "看起来像",
        "actual_cost": "实际代价",
        "one_leverage": "唯一杠杆",
        // M2 高配 vs 低配
        "high_config": "高配版",
        "low_config": "低配版",
        "portrait": "画像",
        "observable_signals": "可观察信号",
        "threshold": "分界点",
        "environment": "环境资源",
        "enables": "跑得开的环境",
        "suppresses": "压制它的环境",
        "belief": "限制性信念",
        "limiting_belief": "信念",
        "origin": "来源",
        "ceiling_effect": "上限效应",
        "awareness": "自我觉察",
        "key_moment": "关键节点",
        "what_to_notice": "该看见什么",
        "early_warnings": "低配早期信号",
        "switch_actions": "切回高配的动作",
        // M3 人生系统模式
        "operating_mode": "运行模式",
        "input": "输入",
        "processing": "加工",
        "output": "输出",
        "recovery": "回血",
        "failure_environments": "失效环境",
        "env": "环境",
        "mechanism": "失效机制",
        "ideal_life_structure": "理想生活结构",
        "time": "时间结构",
        "collaboration": "协作密度",
        "feedback_cycle": "反馈周期",
        "income_rhythm": "收入节奏",
        "stability_vs_volatility": "稳定与高变量",
        "verdict": "结论",
        "reason": "理由",
        "precondition": "前提条件",
        "environment_checklist": "环境筛选清单",
        // M4 健康续航
        "battery_type": "电池类型",
        "charge_pattern": "充电规律",
        "drain_pattern": "耗电规律",
        "imbalance_risks": "失衡风险",
        "system": "身体系统",
        "trigger": "触发条件",
        "early_sign": "早期信号",
        "recovery_levers": "恢复杠杆",
        "action": "动作",
        "why_it_works_for_you": "对你有效的原理",
        "cost": "成本",
        "reset_7day": "七天复位",
        "day": "天",
        "focus": "焦点",
        "weekly_maintenance": "每周维护",
        "medical_note": "医嘱",
        // M5 财富结构
        "income_forms": "收入形态",
        "form": "形态",
        "rank": "顺位",
        "fit": "匹配",
        "friction": "摩擦",
        "leaks": "漏财点",
        "how_it_shows": "表现",
        "rule": "止损规则",
        "strategies": "增长策略",
        "conservative": "保守",
        "balanced": "平衡",
        "aggressive": "进攻",
        "asset_ideas": "资产化点子",
        "idea": "点子",
        "uses_talent": "用到的天赋",
        "fits_life_structure": "契合的生活结构",
        "startup_cost": "启动成本",
        "likely_blocker": "最可能卡住的环节",
        "disclaimer": "免责",
        // M6 结构动力学
        "energy_path": "能量路径",
        "stage": "阶段",
        "gain_or_loss": "增益或损耗",
        "leverage": "杠杆点",
        "point": "支点",
        "why": "原理",
        "vulnerability": "易损点",
        "condition": "条件",
        "self_check": "自查",
        "upgrade_path": "升级路线",
        "phase": "阶段",
        "entry_condition": "进入条件",
        "work": "功课",
        "done_signal": "完成标志",
        // M7 落地手册
        "true_leverage": "真正的杠杆",
        "use_cases": "使用场景",
        "next_90_days": "未来九十天",
        "falsification_signals": "推翻信号",
    ]

    /// 条目卡取题优先级(对象数组首字段作题)。
    static let titleKeys: [String] = [
        "name", "idea", "form", "system", "env", "stage", "phase",
        "day", "type", "point", "action", "focus",
    ]

    /// 小字注键(「据 · 」/「注 · 」排版)。
    static let noteKeys: [String] = ["evidence", "medical_note", "disclaimer"]

    /// 枚举值中文化(schema 约定的英文枚举;未知值原样透出)。
    static let valueMap: [String: [String: String]] = [
        "energy": ["gain": "回血", "drain": "耗电"],
        "gain_or_loss": ["gain": "增益", "loss": "损耗"],
        "cost": ["low": "低耗", "mid": "中耗", "high": "高耗"],
    ]

    private static func label(_ key: String) -> String {
        labels[key] ?? key
    }
}

// MARK: - 保序 JSON 解析器
//
// JSONSerialization/JSONDecoder 落到 NSDictionary/Dictionary 会丢 key 书写顺序,
// 而 dominant→secondary→latent 的顺序本身是语义(主线三层)。自写最小保序解析器,
// 只覆盖 JSON 规范子集(对象/数组/字符串含 \u 转义/数字/字面量),非法输入整体 nil。

enum JSONValue {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    var isScalar: Bool {
        switch self {
        case .array, .object: return false
        case .string, .number, .bool, .null: return true
        }
    }
}

enum OrderedJSONParser {
    static func parse(_ text: String) -> JSONValue? {
        var scanner = Scanner(text: text)
        scanner.skipWhitespace()
        guard let value = scanner.parseValue() else { return nil }
        scanner.skipWhitespace()
        return scanner.isAtEnd ? value : nil
    }

    /// 剥 ```json 围栏(prompt 已禁止围栏,LLM 违约时防御;只剥首尾整行围栏)。
    static func stripCodeFences(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t
                .dropFirst(3)
                .drop { $0.isLetter } // ```json 的语言标记
                .drop { $0.isWhitespace || $0.isNewline }
                .description
            if let fenceEnd = t.range(of: "```", options: .backwards) {
                t = String(t[t.startIndex..<fenceEnd.lowerBound])
            }
        }
        return t
    }

    private struct Scanner {
        let text: [Character]
        var pos = 0

        init(text: String) { self.text = Array(text) }

        var isAtEnd: Bool { pos >= text.count }
        var current: Character? { pos < text.count ? text[pos] : nil }

        mutating func skipWhitespace() {
            while let c = current, c.isWhitespace { pos += 1 }
        }

        func expect(_ c: Character) -> Bool { current == c }

        mutating func consume(_ c: Character) -> Bool {
            if expect(c) { pos += 1; return true }
            return false
        }

        mutating func parseValue() -> JSONValue? {
            skipWhitespace()
            guard let c = current else { return nil }
            switch c {
            case "{": return parseObject()
            case "[": return parseArray()
            case "\"": return parseString().map { .string($0) }
            case "t": return parseLiteral("true").map { _ in .bool(true) }
            case "f": return parseLiteral("false").map { _ in .bool(false) }
            case "n": return parseLiteral("null").map { _ in .null }
            default: return parseNumber()
            }
        }

        private mutating func parseLiteral(_ literal: String) -> Bool? {
            let chars = Array(literal)
            guard pos + chars.count <= text.count else { return nil }
            for (offset, lc) in chars.enumerated() where text[pos + offset] != lc { return nil }
            pos += chars.count
            return true
        }

        private mutating func parseObject() -> JSONValue? {
            pos += 1 // {
            var pairs: [(String, JSONValue)] = []
            skipWhitespace()
            if consume("}") { return .object(pairs) }
            while true {
                skipWhitespace()
                guard let key = parseString() else { return nil }
                skipWhitespace()
                guard consume(":"), let value = parseValue() else { return nil }
                pairs.append((key, value))
                skipWhitespace()
                if consume(",") { continue }
                if consume("}") { return .object(pairs) }
                return nil
            }
        }

        private mutating func parseArray() -> JSONValue? {
            pos += 1 // [
            var values: [JSONValue] = []
            skipWhitespace()
            if consume("]") { return .array(values) }
            while true {
                guard let value = parseValue() else { return nil }
                values.append(value)
                skipWhitespace()
                if consume(",") { continue }
                if consume("]") { return .array(values) }
                return nil
            }
        }

        private mutating func parseString() -> String? {
            guard consume("\"") else { return nil }
            var out = ""
            while let c = current {
                pos += 1
                switch c {
                case "\"":
                    return out
                case "\\":
                    guard let esc = current else { return nil }
                    pos += 1
                    switch esc {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/": out.append("/")
                    case "b": out.append("\u{08}")
                    case "f": out.append("\u{0C}")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    case "u":
                        guard let scalar = parseUnicodeEscape() else { return nil }
                        out.append(scalar)
                    default:
                        return nil
                    }
                default:
                    out.append(c)
                }
            }
            return nil // 未闭合
        }

        private mutating func parseUnicodeEscape() -> Character? {
            func hex4() -> Int? {
                guard pos + 4 <= text.count else { return nil }
                var value = 0
                for i in 0..<4 {
                    guard let d = text[pos + i].hexDigitValue else { return nil }
                    value = value * 16 + d
                }
                pos += 4
                return value
            }
            guard let first = hex4() else { return nil }
            // 代理对(BMP 外字符,如生僻字)
            if first >= 0xD800, first <= 0xDBFF, pos + 6 <= text.count,
               text[pos] == "\\", text[pos + 1] == "u",
               let low = hex4Tail(), low >= 0xDC00, low <= 0xDFFF {
                let combined = 0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00)
                return Unicode.Scalar(combined).map { Character($0) }
            }
            return Unicode.Scalar(first).map { Character($0) }
        }

        /// parseUnicodeEscape 内部:吃掉 "\u" 再读 4 位 hex(代理对低位)。
        private mutating func hex4Tail() -> Int? {
            pos += 2 // \u
            var value = 0
            for i in 0..<4 {
                guard pos + i < text.count, let d = text[pos + i].hexDigitValue else { return nil }
                value = value * 16 + d
            }
            pos += 4
            return value
        }

        private mutating func parseNumber() -> JSONValue? {
            let start = pos
            if expect("-") { pos += 1 }
            while let c = current, c.isNumber || c == "." || c == "e" || c == "E" || c == "+" || c == "-" {
                pos += 1
            }
            guard pos > start, let n = Double(String(text[start..<pos])) else {
                pos = start
                return nil
            }
            return .number(n)
        }
    }
}
