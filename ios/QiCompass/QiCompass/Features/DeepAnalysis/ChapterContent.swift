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
    /// 行内标签段(M0 专用,2026-10-12 S4-A):段首小标签 + 正文连排,
    /// 取代逐行 caption 键值行——8 个小标签连排像表单不像命书(E1)。
    case inlineLabel(label: String, text: String)
    /// 结论句(M0 v9 白话结论层专用,2026-10-14):每节第一层的白话结论,
    /// 不带任何标签、不缩进——宋体 .custom 不吃 weight(BaziFont.songti),
    /// 靠字号 + 浓墨与正文区分(样式经用户真机确认,plan S3-4)。
    case headline(String)
    /// 循环起止行(M0 专用):from/to 两个孤立标签行合成一行小字。
    case loopFromTo(from: String, to: String)
    /// 章末「据」折叠区(M0 专用):各小节的 evidence 收拢,默认收起。
    case evidenceFold([ChapterNote])
}

/// 折叠区里的单条注(M0 evidence 收拢用)。
struct ChapterNote: Equatable {
    let label: String
    let text: String
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
        parse(text, for: nil)
    }

    /// 按模块解析(2026-10-12 S4-A):M0 走行内标签段落化特化组装,
    /// 其余模块走通用节点树。module 为 nil = 通用(中毒判读等不关心排版)。
    /// M0 缺关键结构(main_axis/core_loop 任一非对象,老缓存/违约)→
    /// 回落通用渲染,不静默丢内容。
    static func parse(_ text: String, for module: ModuleID?) -> ChapterContent? {
        guard let root = OrderedJSONParser.parse(OrderedJSONParser.stripCodeFences(text)) else { return nil }
        guard case .object(let pairs) = root else { return nil }
        let nodes: [ChapterNode]
        if module == .m0, let specialized = m0Nodes(from: pairs) {
            nodes = specialized
        } else {
            nodes = pairs.compactMap { node(key: $0.0, value: $0.1) }
        }
        return nodes.isEmpty ? nil : ChapterContent(nodes: nodes)
    }

    /// 内容是否「像 JSON」:剥围栏 + 去首尾空白后以 `{` 或 `[` 开头。
    ///
    /// 阅读页散文退回前的最后防线(2026-10-01):parse 失败但内容呈 JSON 形态
    /// (如截断的半截 JSON)→ 调用方应显示显式「内容异常」态,而不是把 JSON
    /// 原文当散文排版(JSON 裸奔)。散文内容(老缓存 / LLM 散文输出)不受影响,
    /// 照常退回散文。
    static func looksLikeJSON(_ text: String) -> Bool {
        let stripped = OrderedJSONParser.stripCodeFences(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.hasPrefix("{") || stripped.hasPrefix("[")
    }

    // MARK: - 规范化

    // MARK: M0 特化组装(2026-10-12 S4-A,用户拍板方案 A)
    //
    // 通用键值行渲染把 M0 的 8 个小标签(主导/次要/潜伏/起点/终点/流向/
    // 驱动/损耗)排成表单样(plan E1);v7 起 dominant/secondary/latent 值
    // 已是带权重依据的完整长句,逐行 caption 更显割裂。特化:
    // - 三层与循环字段 → 段首行内标签连排(.inlineLabel)
    // - from/to 两行 → 一行小字(.loopFromTo)
    // - 四组 evidence → 章末「据」折叠区默认收起(.evidenceFold)
    // 组装用固定阅读序(不按 JSON 书写序):主线 → 核心循环 → 结构类型 →
    // 能力来源 → 运转概括 → 据。
    //
    // 2026-10-13 review 修复:特化原先只认固定几个键,模型多给的键 / 非对象
    // 形态的已知键(如 structure_type 退化为字符串)被静默丢弃——页面无
    // 显示也无日志。现改为:未成功消费的键一律走通用节点渲染(内容不丢),
    // 并把键路径记日志(schema 漂移信号不吞)。
    private static func m0Nodes(from pairs: [(String, JSONValue)]) -> [ChapterNode]? {
        func inline(
            _ key: String, _ obj: [(String, JSONValue)], consumed: inout Set<String>
        ) -> ChapterNode? {
            guard let s = m0String(obj, key) else { return nil }
            consumed.insert(key)
            return .inlineLabel(label: label(key), text: s)
        }

        guard let mainAxis = m0Object(pairs, "main_axis"),
              let coreLoop = m0Object(pairs, "core_loop") else { return nil }

        // v9 白话结论层(plan docs/命书M0白话结论层-plan.md S3):
        // main_axis.headline 存在 → 三层组装(结论/展开/据);v7/v8 老缓存
        // 无此键,照旧走下方组装,渲染逐字节不变(单测双向锁定)。
        if m0String(mainAxis, "headline") != nil {
            return m0V9Nodes(
                pairs: pairs, mainAxis: mainAxis, coreLoop: coreLoop)
        }

        var notes: [ChapterNote] = []
        var extras: [String] = []

        // 主线:三层行内标签段
        var mainConsumed: Set<String> = []
        var mainChildren: [ChapterNode] = [
            inline("dominant", mainAxis, consumed: &mainConsumed),
            inline("secondary", mainAxis, consumed: &mainConsumed),
            inline("latent", mainAxis, consumed: &mainConsumed),
        ].compactMap { $0 }
        // evidence 收集与 core_loop 同款无条件:退化输入(三层全非 string)
        // 下不静默丢 main_axis.evidence(与 core_loop 一致,见下)
        if let ev = m0String(mainAxis, "evidence") {
            mainConsumed.insert("evidence")
            notes.append(ChapterNote(label: label("main_axis"), text: ev))
        }
        mainChildren += leftoverNodes(
            from: mainAxis, skipping: mainConsumed,
            path: "main_axis", extras: &extras)

        // 核心循环:起止一行小字 + 流向/驱动/损耗行内标签段
        var loopConsumed: Set<String> = []
        var loopChildren: [ChapterNode] = []
        if let from = m0String(coreLoop, "from"), let to = m0String(coreLoop, "to") {
            loopConsumed.formUnion(["from", "to"])
            loopChildren.append(.loopFromTo(from: from, to: to))
        }
        loopChildren += [
            inline("flow", coreLoop, consumed: &loopConsumed),
            inline("driver", coreLoop, consumed: &loopConsumed),
            inline("leak", coreLoop, consumed: &loopConsumed),
        ].compactMap { $0 }
        if let ev = m0String(coreLoop, "evidence") {
            loopConsumed.insert("evidence")
            notes.append(ChapterNote(label: label("core_loop"), text: ev))
        }
        loopChildren += leftoverNodes(
            from: coreLoop, skipping: loopConsumed,
            path: "core_loop", extras: &extras)

        // 结构类型:名称行内标签 + 一句话作引言段
        var typeChildren: [ChapterNode] = []
        if let structureType = m0Object(pairs, "structure_type") {
            var typeConsumed: Set<String> = []
            var typeNodes: [ChapterNode?] = [
                inline("name", structureType, consumed: &typeConsumed),
            ]
            if let line = m0String(structureType, "one_line") {
                typeConsumed.insert("one_line")
                typeNodes.append(.lead(line))
            }
            typeChildren = typeNodes.compactMap { $0 } + leftoverNodes(
                from: structureType, skipping: typeConsumed,
                path: "structure_type", extras: &extras)
        }

        // 能力来源:text 作引言段(既有 2026-10-11 口径),据收拢
        var capabilityChildren: [ChapterNode] = []
        if let capability = m0Object(pairs, "capability_source") {
            var capConsumed: Set<String> = []
            if let text = m0String(capability, "text") {
                capConsumed.insert("text")
                capabilityChildren.append(.lead(text))
            }
            if let ev = m0String(capability, "evidence") {
                capConsumed.insert("evidence")
                notes.append(ChapterNote(label: label("capability_source"), text: ev))
            }
            capabilityChildren += leftoverNodes(
                from: capability, skipping: capConsumed,
                path: "capability_source", extras: &extras)
        }

        // 顶层:已知键按「成功消费」计;未消费(含非约定形态,如退化为
        // 字符串的 structure_type / 非字符串的 structure_fingerprint)
        // 走通用节点,不静默丢
        var topConsumed: Set<String> = ["main_axis", "core_loop"]
        if m0Object(pairs, "structure_type") != nil { topConsumed.insert("structure_type") }
        if m0Object(pairs, "capability_source") != nil { topConsumed.insert("capability_source") }
        var fingerprintLead: ChapterNode?
        if let fingerprint = m0String(pairs, "structure_fingerprint") {
            topConsumed.insert("structure_fingerprint")
            fingerprintLead = .lead(fingerprint)
        }
        let topExtras = leftoverNodes(
            from: pairs, skipping: topConsumed, path: "m0", extras: &extras)

        var nodes: [ChapterNode] = []
        if !mainChildren.isEmpty {
            nodes.append(.section(label("main_axis"), mainChildren))
        }
        if !loopChildren.isEmpty {
            nodes.append(.section(label("core_loop"), loopChildren))
        }
        if !typeChildren.isEmpty {
            nodes.append(.section(label("structure_type"), typeChildren))
        }
        if !capabilityChildren.isEmpty {
            nodes.append(.section(label("capability_source"), capabilityChildren))
        }
        nodes += topExtras
        if let fingerprintLead {
            nodes.append(fingerprintLead)
        }
        if !notes.isEmpty {
            nodes.append(.evidenceFold(notes))
        }
        if !extras.isEmpty {
            // OSLog 插值约束:privacy 参数须在单一字面量内,不可拼接
            AppLogger.app.info(
                "m0 chapter rendered \(extras.count) non-contract field(s) via generic nodes: \(extras.joined(separator: ","), privacy: .public)")
        }
        return nodes.isEmpty ? nil : nodes
    }

    // MARK: M0 v9 白话结论层组装(2026-10-14,plan S3)
    //
    // v9 起每题固定三层:白话结论(headline)/展开(散文 .lead)/据(章末折叠)。
    // 阅读序固定:主线(headline→body)→ 核心循环(headline→flow→leak,两段
    // 散文不带「流向/损耗」小标签)→ 结构类型(name 作结论无「名称 ·」标签
    // →one_line)→ 能力来源(headline→text)→ 章末「据」折叠(主线分层一行
    // →循环起止一行→驱动→各节 evidence)。
    // - dominant/secondary/latent 只写十神名 → 据 fold 首行「主导 X · 次要
    //   Y · 潜伏 Z」(标签复用现有 dot-key)
    // - D6:v9 不展示 structure_fingerprint(仍然产出,下游链式照常继承;
    //   键按已消费计,防经通用节点回流)
    // - v7 组装的兜底口径照搬:未消费键走通用节点 + extras 日志(不静默丢)
    private static func m0V9Nodes(
        pairs: [(String, JSONValue)],
        mainAxis: [(String, JSONValue)],
        coreLoop: [(String, JSONValue)]
    ) -> [ChapterNode]? {
        var extras: [String] = []
        var evidenceNotes: [ChapterNote] = []

        // 主线:结论 + 展开;分层行进据 fold 首位
        var mainConsumed: Set<String> = []
        var mainChildren: [ChapterNode] = []
        var layerLine: ChapterNote?
        if let h = m0String(mainAxis, "headline") {
            mainConsumed.insert("headline")
            mainChildren.append(.headline(h))
        }
        if let body = m0String(mainAxis, "body") {
            mainConsumed.insert("body")
            mainChildren.append(.lead(body))
        }
        var layerParts: [String] = []
        for key in ["dominant", "secondary", "latent"] {
            if let s = m0String(mainAxis, key) {
                mainConsumed.insert(key)
                layerParts.append("\(label(key)) \(s)")
            }
        }
        if !layerParts.isEmpty {
            layerLine = ChapterNote(
                label: label("main_axis"),
                text: layerParts.joined(separator: " · "))
        }
        if let ev = m0String(mainAxis, "evidence") {
            mainConsumed.insert("evidence")
            evidenceNotes.append(ChapterNote(label: label("main_axis"), text: ev))
        }
        mainChildren += leftoverNodes(
            from: mainAxis, skipping: mainConsumed,
            path: "main_axis", extras: &extras)

        // 核心循环:结论 + flow/leak 两段散文;起止/驱动进据 fold
        var loopConsumed: Set<String> = []
        var loopChildren: [ChapterNode] = []
        var loopLine: ChapterNote?
        var driverNote: ChapterNote?
        if let h = m0String(coreLoop, "headline") {
            loopConsumed.insert("headline")
            loopChildren.append(.headline(h))
        }
        for key in ["flow", "leak"] {
            if let s = m0String(coreLoop, key) {
                loopConsumed.insert(key)
                loopChildren.append(.lead(s))
            }
        }
        if let from = m0String(coreLoop, "from"), let to = m0String(coreLoop, "to") {
            loopConsumed.formUnion(["from", "to"])
            loopLine = ChapterNote(
                label: label("core_loop"),
                text: "\(label("from")) \(from)　\(label("to")) \(to)")
        }
        if let driver = m0String(coreLoop, "driver") {
            loopConsumed.insert("driver")
            driverNote = ChapterNote(label: label("driver"), text: driver)
        }
        if let ev = m0String(coreLoop, "evidence") {
            loopConsumed.insert("evidence")
            evidenceNotes.append(ChapterNote(label: label("core_loop"), text: ev))
        }
        loopChildren += leftoverNodes(
            from: coreLoop, skipping: loopConsumed,
            path: "core_loop", extras: &extras)

        // 结构类型:name 作结论(无「名称 ·」标签)→ one_line 展开
        var typeChildren: [ChapterNode] = []
        if let structureType = m0Object(pairs, "structure_type") {
            var typeConsumed: Set<String> = []
            if let name = m0String(structureType, "name") {
                typeConsumed.insert("name")
                typeChildren.append(.headline(name))
            }
            if let line = m0String(structureType, "one_line") {
                typeConsumed.insert("one_line")
                typeChildren.append(.lead(line))
            }
            typeChildren += leftoverNodes(
                from: structureType, skipping: typeConsumed,
                path: "structure_type", extras: &extras)
        }

        // 能力来源:结论 + text 展开;evidence 进据 fold
        var capabilityChildren: [ChapterNode] = []
        if let capability = m0Object(pairs, "capability_source") {
            var capConsumed: Set<String> = []
            if let h = m0String(capability, "headline") {
                capConsumed.insert("headline")
                capabilityChildren.append(.headline(h))
            }
            if let text = m0String(capability, "text") {
                capConsumed.insert("text")
                capabilityChildren.append(.lead(text))
            }
            if let ev = m0String(capability, "evidence") {
                capConsumed.insert("evidence")
                evidenceNotes.append(ChapterNote(label: label("capability_source"), text: ev))
            }
            capabilityChildren += leftoverNodes(
                from: capability, skipping: capConsumed,
                path: "capability_source", extras: &extras)
        }

        // 顶层:structure_fingerprint 按 D6 一律消费不展示(含非字符串形态,
        // 防 null/违约形态经通用节点回流或计入 extras);其余未消费键通用渲染
        var topConsumed: Set<String> = [
            "main_axis", "core_loop", "structure_fingerprint",
        ]
        if m0Object(pairs, "structure_type") != nil { topConsumed.insert("structure_type") }
        if m0Object(pairs, "capability_source") != nil { topConsumed.insert("capability_source") }
        let topExtras = leftoverNodes(
            from: pairs, skipping: topConsumed, path: "m0", extras: &extras)

        var nodes: [ChapterNode] = []
        if !mainChildren.isEmpty {
            nodes.append(.section(label("main_axis"), mainChildren))
        }
        if !loopChildren.isEmpty {
            nodes.append(.section(label("core_loop"), loopChildren))
        }
        if !typeChildren.isEmpty {
            nodes.append(.section(label("structure_type"), typeChildren))
        }
        if !capabilityChildren.isEmpty {
            nodes.append(.section(label("capability_source"), capabilityChildren))
        }
        nodes += topExtras
        // 据 fold 固定序:分层 → 起止 → 驱动 → 各节 evidence(plan S3-3)
        let notes = [layerLine, loopLine, driverNote].compactMap { $0 } + evidenceNotes
        if !notes.isEmpty {
            nodes.append(.evidenceFold(notes))
        }
        if !extras.isEmpty {
            // OSLog 插值约束:privacy 参数须在单一字面量内,不可拼接
            AppLogger.app.info(
                "m0 v9 chapter rendered \(extras.count) non-contract field(s) via generic nodes: \(extras.joined(separator: ","), privacy: .public)")
        }
        return nodes.isEmpty ? nil : nodes
    }

    /// m0 特化键取值:顶层对象(非对象形态返回 nil,交由通用渲染不丢内容)。
    private static func m0Object(
        _ pairs: [(String, JSONValue)], _ key: String
    ) -> [(String, JSONValue)]? {
        for (k, v) in pairs where k == key {
            if case .object(let inner) = v { return inner }
            return nil
        }
        return nil
    }

    /// m0 特化键取值:对象内字符串(非字符串形态返回 nil,交由通用渲染)。
    private static func m0String(
        _ obj: [(String, JSONValue)], _ key: String
    ) -> String? {
        for (k, v) in obj where k == key {
            if case .string(let s) = v { return s }
            return nil
        }
        return nil
    }

    /// 特化组装未消费的键 → 通用节点(内容不丢),键路径记入 extras 供日志。
    private static func leftoverNodes(
        from pairs: [(String, JSONValue)],
        skipping consumed: Set<String>,
        path: String,
        extras: inout [String]
    ) -> [ChapterNode] {
        pairs.compactMap { key, value in
            guard !consumed.contains(key) else { return nil }
            if case .null = value { return nil }
            // node() 对无内容值(全 null 数组)返回 nil:不计入 extras
            // (日志只记真正渲染了的键,防计数失真)
            guard let rendered = node(key: key, value: value) else { return nil }
            extras.append("\(path).\(key)")
            return rendered
        }
    }

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
            // 值全标量 → 子节点为键值组(「text」除外);混结构值 → 子节点递归。
            let children: [ChapterNode]
            if pairs.allSatisfy({ $0.1.isScalar }) {
                // 「text」是节的主散文体(如 capability_source.text):不打
                // 「正文/Body」字段标签、按引言段落排版(2026-10-11 EN 外评:
                // "Body" 数据腔标签);其余标量键照旧键值行。非 string 的
                // text(违约输出 number/null)不转 lead 也不丢,回落键值行
                // (label 未登记 → 裸 key 透出,不静默丢内容)。
                // 谓词只写这一处(单趟分流):lead 组与其余组的边界不可能漂移。
                var proseNodes: [ChapterNode] = []
                var rest: [(String, JSONValue)] = []
                for (k, v) in pairs {
                    if k == "text", case .string(let s) = v {
                        proseNodes.append(.lead(s))
                    } else {
                        rest.append((k, v))
                    }
                }
                children = proseNodes
                    + (rest.isEmpty ? [] : [.fields(rest.map { field(key: $0.0, value: $0.1) })])
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
            // 枚举值中文化后经本地化表取显示语(zh 原词为 defaultValue,行为不变)
            if let zh = Self.valueMap[key]?[s] {
                return Self.localizedWord(zh)
            }
            return s
        case .number(let n):
            if key == "day" { return String(format: String(localized: "第 %lld 天"), Int(n)) }
            if key == "rank" { return String(format: String(localized: "第 %lld 顺位"), Int(n)) }
            if n.rounded() == n { return String(Int(n)) }
            return String(n)
        case .bool(let b):
            return b ? String(localized: "是") : String(localized: "否")
        case .null:
            return "—"
        case .array, .object:
            // 键值组内不应出现(分组逻辑已拦截);防御性内联,不静默丢内容
            return inlineText(value)
        }
    }

    /// 条目题文案(day → 第 N 天;其余走 valueMap)。
    private static func titleText(key: String, value: JSONValue) -> String {
        if key == "day", case .number(let n) = value { return String(format: String(localized: "第 %lld 天"), Int(n)) }
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

    /// 节题本地化(snake_case key → 显示语)。展示层反查用(如
    /// ChapterContentView 的 M1 引导句按节题匹配)——公开此单一实现,
    /// 避免展示层复制 `deepanalysis.chapter.<key>` 查询格式后两侧漂移。
    static func localizedLabel(_ key: String) -> String {
        label(key)
    }

    // MARK: - 标签表(snake_case → 中文;M0-M7 全量 schema key,2026-09-02 对齐 prompts.py)

    static let labels: [String: String] = [
        // 公共
        "evidence": "据",
        "name": "名称",
        // "text" 不登记:全标量对象内按引言段落排版,不打「正文/Body」标签
        // (2026-10-11 EN 外评);顶层/混结构路径本就无标签。
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
        // 展示层语言 U2:标签表是 snake_case → zh 映射,显示语走
        // deepanalysis.chapter.<key> dot-key(zh 缺省回落 defaultValue = zh 原词,
        // zh 行为逐字不变;en 在 xcstrings 登记)。未知 schema key 原样透出。
        guard let zh = labels[key] else { return key }
        return NSLocalizedString("deepanalysis.chapter.\(key)", value: zh, comment: "M0-M7 schema key 标签")
    }

    /// 运行时词面本地化(枚举值译文等闭集小词):zh 回落原词,en 查 xcstrings。
    private static func localizedWord(_ zh: String) -> String {
        NSLocalizedString(zh, value: zh, comment: "枚举值闭集小词")
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
