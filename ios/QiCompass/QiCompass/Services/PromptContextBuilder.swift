import Foundation

/// BaziResponse → InterpretRequest.context 映射(bazi_deep module)。
///
/// 必须覆盖后端 `REQUIRED_FIELDS["bazi_deep"]` 全部 40 个字段
/// (见 backend/app/ai/prompts.py:128-145)。缺字段 → 后端 validate_context 抛 422。
///
/// 关键映射:
/// - gender/city 从原始 request 取(BaziResponse 不含这两字段)
/// - day_master_strength 为 nil 时传字面量 "special_pattern" 触发后端
///   `BAZI_DEEP_SPECIAL_PATTERN_SUFFIX` 诚实降级段(方案 §4.7)
/// - favorable/unfavorable 为空数组(special_pattern)时传空字符串
/// - shensha_list / element_balance 拼接为可读字符串
enum PromptContextBuilder {

    /// 时辰未知占位值(S05):柱缺失(时辰未知 / S02 柱歧义)时对应 context key
    /// 走此占位——**key 只增不删**(REQUIRED ⊆ builder keys 校验恒 PASS),值语义
    /// 由 S06 模板定稿;不猜任何干支。真太阳时缺失同理(12:00 占位属假精度)。
    static let hourUnknownPlaceholder = "时辰未知"

    /// 构造 bazi_deep module 的 prompt context。
    static func build(
        response: BaziResponse,
        request: BaziCalculateRequest
    ) -> [String: AnyCodableJSON] {
        let p = response.pillars
        let placeholder = Self.hourUnknownPlaceholder
        // S05:hour_known=false → 后端 true_solar_time=null,柱缺失走占位
        let trueSolarTimeStr = response.trueSolarTime
            .map(Self.dateTimeFormatter.string(from:)) ?? placeholder
        // S03:city key 保留(prompt 契约不变),取值换物理真值来源(Q4)
        let cityDisplay = request.placeName ?? "自定义地点(经度 \(request.longitude))"

        return [
            // 命主(gender 转中文,prompt 模板期望"男"/"女"而非"male"/"female")
            "gender": AnyCodableJSON(Self.genderToChinese(request.gender)),
            "city": AnyCodableJSON(cityDisplay),
            "true_solar_time": AnyCodableJSON(trueSolarTimeStr),
            // 年柱(歧义 → 占位,不猜)
            "year_gan": AnyCodableJSON(p.year?.gan ?? placeholder),
            "year_zhi": AnyCodableJSON(p.year?.zhi ?? placeholder),
            "year_gan_element": AnyCodableJSON(p.year.map { Self.elementToChinese($0.ganElement) } ?? placeholder),
            "year_zhi_element": AnyCodableJSON(p.year.map { Self.elementToChinese($0.zhiElement) } ?? placeholder),
            "year_shishen_gan": AnyCodableJSON(p.year?.shishenGan ?? placeholder),
            "year_hide_gan": AnyCodableJSON(p.year?.hideGan.joined(separator: ", ") ?? placeholder),
            // 月柱(歧义 → 占位)
            "month_gan": AnyCodableJSON(p.month?.gan ?? placeholder),
            "month_zhi": AnyCodableJSON(p.month?.zhi ?? placeholder),
            "month_gan_element": AnyCodableJSON(p.month.map { Self.elementToChinese($0.ganElement) } ?? placeholder),
            "month_zhi_element": AnyCodableJSON(p.month.map { Self.elementToChinese($0.zhiElement) } ?? placeholder),
            "month_shishen_gan": AnyCodableJSON(p.month?.shishenGan ?? placeholder),
            "month_hide_gan": AnyCodableJSON(p.month?.hideGan.joined(separator: ", ") ?? placeholder),
            // 日柱(歧义 → 占位)
            "day_gan": AnyCodableJSON(p.day?.gan ?? placeholder),
            "day_zhi": AnyCodableJSON(p.day?.zhi ?? placeholder),
            "day_gan_element": AnyCodableJSON(p.day.map { Self.elementToChinese($0.ganElement) } ?? placeholder),
            "day_shishen_zhi": AnyCodableJSON(p.day?.shishenZhi.joined(separator: ", ") ?? placeholder),
            "day_hide_gan": AnyCodableJSON(p.day?.hideGan.joined(separator: ", ") ?? placeholder),
            // 时柱(时辰未知 → 占位;7 个 hour_* key 一个不漏,勿漏 hour_nayin)
            "hour_gan": AnyCodableJSON(p.hour?.gan ?? placeholder),
            "hour_zhi": AnyCodableJSON(p.hour?.zhi ?? placeholder),
            "hour_gan_element": AnyCodableJSON(p.hour.map { Self.elementToChinese($0.ganElement) } ?? placeholder),
            "hour_zhi_element": AnyCodableJSON(p.hour.map { Self.elementToChinese($0.zhiElement) } ?? placeholder),
            "hour_shishen_gan": AnyCodableJSON(p.hour?.shishenGan ?? placeholder),
            "hour_hide_gan": AnyCodableJSON(p.hour?.hideGan.joined(separator: ", ") ?? placeholder),
            // 纳音
            "year_nayin": AnyCodableJSON(p.year?.nayin ?? placeholder),
            "month_nayin": AnyCodableJSON(p.month?.nayin ?? placeholder),
            "day_nayin": AnyCodableJSON(p.day?.nayin ?? placeholder),
            "hour_nayin": AnyCodableJSON(p.hour?.nayin ?? placeholder),
            // 命宫
            "ming_gong": AnyCodableJSON(response.mingGong.ganZhi),
            "ming_gong_nayin": AnyCodableJSON(response.mingGong.nayin),
            // 神煞 / 五行
            "shensha_list": AnyCodableJSON(formatShensha(response.shensha)),
            "element_balance": AnyCodableJSON(formatElementBalance(response.elementBalance)),
            // 喜忌(从格时 favorable/unfavorable 为空,day_master_strength 传 "special_pattern")
            "day_master_strength": AnyCodableJSON(response.dayMasterStrength ?? "special_pattern"),
            "favorable_elements": AnyCodableJSON(response.favorableElements.joined(separator: ", ")),
            "unfavorable_elements": AnyCodableJSON(response.unfavorableElements.joined(separator: ", ")),
            "tiaoshou_applied": AnyCodableJSON(response.tiaoshouApplied),
            // 当前柱
            "current_luck_pillar": AnyCodableJSON(response.currentLuckPillar?.ganZhi ?? "未排"),
            "current_year_pillar": AnyCodableJSON(response.currentYearPillar ?? "未排"),
        ]
    }

    // MARK: - v1 Prompt System(Stage 7b)

    /// 构造 v1 prompt 系统的 chart JSON 字符串(对齐 bazi-prompt-system-v1.md §1 schema
    /// + backend `app/engine/chart_builder.py:build_v1_chart` 输出结构)。
    ///
    /// 输出 JSON 结构(与 backend chart_builder.build_v1_chart() 完全一致):
    /// - meta:出生上下文(透传 BaziResponse.meta,Stage 1 后端引入)
    /// - pillars:完整 Pillar(含 gan_zhi/gan/zhi/gan_element/zhi_element/hide_gan/
    ///   shishen_gan/shishen_zhi/nayin/dishi/xunkong),不缩减为 stem/branch
    ///   (backend chart_builder.py:179-182 明确注释"完整信息对 LLM 更友好")
    /// - day_master:{stem, element, strength_score=null, strength_label}
    ///   (strength_score 留 null,BaziResponse 不透传 xiji.score,LLM 走 label 判断)
    /// - ten_gods:{year_stem, month_stem, hour_stem, hidden: {year_branch, ...}}
    ///   (不含 day_stem:lunar_python 日柱 shishen_gan 固定返回"日主"非十神)
    /// - ten_god_weights:全局十神权重(透传 BaziResponse.tenGodWeights)
    /// - five_elements:{木, 火, 土, 金, 水} 计数(英文 key → 中文)
    /// - useful_god_candidates:喜用五行中文 list(透传,special_pattern 时为空)
    /// - luck_pillars:[{start_age, stem, branch}] (gan_zhi 拆前后 1 字)
    /// - current_luck:{start_age, stem, branch, ten_god=null} | null
    ///   (ten_god 留 null,后端没现成工具算 gan-vs-gan 十神,LLM 自推)
    /// - current_year:{stem, branch, ten_god=null}
    ///
    /// - Parameter response:后端 BaziResponse(必须含 meta / tenGodWeights /
    ///   usefulGodCandidates,即 Stage 1+ 后端返回的完整 schema)
    /// - Returns:JSON 字符串(供 render_prompt 的 chart 占位符注入)
    /// - Throws:`PromptContextError.missingMetaBlock` 当 response.meta = nil
    ///   (老 response 兼容性破坏时显式暴露,对齐 CLAUDE.md 错误显式传播)
    static func buildV1ChartJSON(response: BaziResponse) throws -> String {
        guard let meta = response.meta else {
            throw PromptContextError.missingMetaBlock(
                contentHash: response.contentHash
            )
        }

        let p = response.pillars

        // 拆 gan_zhi 2 字为 stem + branch(大运/流年)。
        // 长度异常显式抛错(对齐 backend chart_builder.py:120-122 的 ValueError,
        // 不静默兜底空字符串 — 那会让 LLM 看到空 stem/branch 困惑且难追踪根因)。
        func splitGanZhi(_ gz: String, field: String) throws -> [String: String] {
            guard gz.count == 2 else {
                throw PromptContextError.invalidGanZhi(
                    contentHash: response.contentHash,
                    field: field,
                    value: gz
                )
            }
            return [
                "stem": String(gz.prefix(1)),
                "branch": String(gz.suffix(1)),
            ]
        }

        // 完整 Pillar dict(对齐 backend chart_builder.py:182 "pillars 传完整 Pillar")
        func pillarDict(_ pillar: PillarDTO) -> [String: Any] {
            return [
                "gan_zhi": pillar.ganZhi,
                "gan": pillar.gan,
                "zhi": pillar.zhi,
                "gan_element": pillar.ganElement,
                "zhi_element": pillar.zhiElement,
                "hide_gan": pillar.hideGan,
                "shishen_gan": pillar.shishenGan,
                "shishen_zhi": pillar.shishenZhi,
                "nayin": pillar.nayin,
                "dishi": pillar.dishi,
                "xunkong": pillar.xunkong,
            ]
        }

        // S05 时辰未知:柱缺失 → JSON null 占位(不猜干支,LLM 按设计文档 §2
        // "字段缺失就说明缺失"降级叙事;字段语义由 S06 模板定稿)
        func pillarOrNull(_ pillar: PillarDTO?) -> Any {
            pillar.map(pillarDict) ?? NSNull()
        }

        // luck_pillars 拆 gan_zhi
        let luckPillars: [[String: Any]] = try response.luckPillars.map { lp in
            var dict: [String: Any] = ["start_age": lp.startAge]
            dict.merge(try splitGanZhi(lp.ganZhi, field: "luck_pillar")) { _, new in new }
            return dict
        }

        // current_luck(可能为 nil)+ 反查 start_age
        let currentLuck: [String: Any]?
        if let clp = response.currentLuckPillar {
            let startAge = response.luckPillars.first { $0.startYear == clp.startYear }?.startAge
            var dict: [String: Any] = try splitGanZhi(clp.ganZhi, field: "current_luck_pillar")
            dict["start_age"] = startAge ?? NSNull()
            // ten_god 留 null:后端没现成工具算 gan-vs-gan 十神,LLM 自推
            // (对齐 backend chart_builder.py:153-156)
            dict["ten_god"] = NSNull()
            currentLuck = dict
        } else {
            currentLuck = nil
        }

        // current_year 拆 gan_zhi(后端语义保证非空,但 mock / 老 response 可能 nil)
        // nil 时显式抛错(对齐 backend chart_builder.py:163-167)
        guard let cypStr = response.currentYearPillar else {
            throw PromptContextError.missingCurrentYear(
                contentHash: response.contentHash
            )
        }
        var currentYear: [String: Any] = try splitGanZhi(cypStr, field: "current_year_pillar")
        currentYear["ten_god"] = NSNull()

        // day_master.strength_label:英文枚举 → 中文 label(对齐 backend chart_builder.py:69-72
        // + _STRENGTH_LABEL_ZH 映射)。response.dayMasterStrength 是英文枚举
        // (strong/weak/balanced/special_pattern/unknown_hour)。
        // nil = 老 response,兜底"未判定";非 nil 但不在已知枚举 = 代码 bug,显式抛错。
        // unknown_hour(S01):时柱缺失或日柱歧义 → 引擎不硬算,诚实标注(S06 模板
        // 定稿降级叙事口径)
        let strengthLabel: String
        if let strength = response.dayMasterStrength {
            switch strength {
            case "strong": strengthLabel = "偏旺"
            case "weak": strengthLabel = "偏弱"
            case "balanced": strengthLabel = "中和"
            case "special_pattern": strengthLabel = "从格特征"
            case "unknown_hour": strengthLabel = "时辰未知"
            default:
                throw PromptContextError.unknownDayMasterStrength(
                    contentHash: response.contentHash,
                    value: strength
                )
            }
        } else {
            // 老 response 兜底(对齐 BaziResponse.dayMasterStrength: String? 的 optional 语义)
            strengthLabel = "未判定"
        }

        // S05 日柱歧义(S02/D10):无日主。day_master 是 v1 chart 的轴心字段,
        // 不编造——显式抛错(D5 全拦截用户由 S07 付费墙拦截在内容页之前,
        // 走到这里 = 上游拦截缺口,须暴露而非静默降级)
        guard let dayPillar = p.day else {
            throw PromptContextError.missingDayPillar(
                contentHash: response.contentHash
            )
        }

        // S05:柱缺失 → null 占位。拆局部子表达式(显式 Any),避免大字典
        // 字面量 + Optional ?? NSNull 混排触发 type-check 超时
        let jsonNull: Any = NSNull()
        let pillarsJSON: [String: Any] = [
            "year": pillarOrNull(p.year),
            "month": pillarOrNull(p.month),
            "day": pillarDict(dayPillar),
            "hour": pillarOrNull(p.hour),
        ]
        let dayMasterJSON: [String: Any] = [
            "stem": dayPillar.gan,
            "element": Self.elementToChinese(dayPillar.ganElement),
            // strength_score 留 null:BaziResponse 不透传 xiji.score,
            // LLM 走 strength_label 判断(对齐 backend chart_builder.py:76-79)
            "strength_score": jsonNull,
            "strength_label": strengthLabel,
        ]
        let hiddenTenGods: [String: Any] = [
            "year_branch": p.year?.shishenZhi ?? jsonNull,
            "month_branch": p.month?.shishenZhi ?? jsonNull,
            "day_branch": dayPillar.shishenZhi,
            "hour_branch": p.hour?.shishenZhi ?? jsonNull,
        ]
        let tenGodsJSON: [String: Any] = [
            "year_stem": p.year?.shishenGan ?? jsonNull,
            "month_stem": p.month?.shishenGan ?? jsonNull,
            "hour_stem": p.hour?.shishenGan ?? jsonNull,
            "hidden": hiddenTenGods,
        ]

        let chart: [String: Any] = [
            "meta": [
                "locale": meta.locale,
                "gender": meta.gender,
                "birth_local": meta.birthLocal,
                "true_solar_time": meta.trueSolarTime,
                "late_zishi_rule": meta.lateZishiRule,
                "solar_term_boundary": meta.solarTermBoundary,
            ],
            "pillars": pillarsJSON,
            "day_master": dayMasterJSON,
            "ten_gods": tenGodsJSON,
            "ten_god_weights": response.tenGodWeights,
            "five_elements": [
                "木": response.elementBalance.wood,
                "火": response.elementBalance.fire,
                "土": response.elementBalance.earth,
                "金": response.elementBalance.metal,
                "水": response.elementBalance.water,
            ],
            "useful_god_candidates": response.usefulGodCandidates,
            "luck_pillars": luckPillars,
            "current_luck": currentLuck ?? jsonNull,
            "current_year": currentYear,
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: chart,
                options: [.prettyPrinted, .sortedKeys]
            )
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw PromptContextError.jsonEncodingFailed(
                    contentHash: response.contentHash
                )
            }
            return jsonString
        } catch let error as PromptContextError {
            throw error
        } catch {
            throw PromptContextError.jsonEncodingFailed(
                contentHash: response.contentHash,
                underlying: error
            )
        }
    }

    // MARK: - Daily Fortune

    /// 构造 daily_fortune module 的 prompt context。覆盖后端 `REQUIRED_FIELDS["daily_fortune"]`
    /// 全部 17 字段(见 backend/app/ai/prompts.py:158-167)。
    ///
    /// 输入:
    /// - `chartPayload`:从存档 ChartSnapshot.payload 解出的日主/喜忌/四柱
    /// - `response`:后端 /api/bazi/daily-fortune 返回的 DailyFortuneResponse
    /// - `businessDate`:客户端按 zi_hour_rule 算好的业务日期
    static func buildDailyFortune(
        chartPayload: ChartPayloadDTO,
        response: DailyFortuneResponse,
        businessDate: Date
    ) -> [String: AnyCodableJSON] {
        // 公历格式化
        let dateStr = Self.dateOnlyFormatter.string(from: businessDate)

        // 拆 day_pillar 前后 1 字
        let dayPillar = response.dayPillar
        let dayStem = String(dayPillar.prefix(1))
        let dayBranch = String(dayPillar.suffix(1))
        let dayStemElement = ElementColors.ofGan(dayStem).map { Self.elementToChinese($0) } ?? dayStem
        let dayBranchElement = ElementColors.ofZhi(dayBranch).map { Self.elementToChinese($0) } ?? dayBranch

        // 流日冲(含命中位置)
        let dayChongDisplay: String
        if let chong = response.dayChong {
            let targets = response.dayChongTargets.isEmpty
                ? ""
                : "(冲\(response.dayChongTargets.joined(separator: "、")))"
            dayChongDisplay = "\(chong)\(targets)"
        } else {
            dayChongDisplay = "无"
        }

        // 12 时辰条格式化
        let hourPillarsStr = response.hourPillars.map { hp -> String in
            var line = "- \(hp.hour)时(\(hp.timeRange)):\(hp.pillar) \(hp.relation)"
            if let chong = hp.chong {
                let targets = hp.chongTargets.isEmpty
                    ? ""
                    : "(冲\(hp.chongTargets.joined(separator: "、")))"
                line += " 冲\(chong)\(targets)"
            }
            return line
        }.joined(separator: "\n")

        return [
            // 命主(从 chart_payload)
            "day_master": AnyCodableJSON(chartPayload.dayMaster),
            "day_master_element": AnyCodableJSON(chartPayload.dayMasterElement),
            "day_master_strength": AnyCodableJSON(chartPayload.dayMasterStrength),
            "favorable_elements": AnyCodableJSON(chartPayload.favorableElements.joined(separator: ", ")),
            "unfavorable_elements": AnyCodableJSON(chartPayload.unfavorableElements.joined(separator: ", ")),
            // 日期
            "date": AnyCodableJSON(dateStr),
            "lunar_date": AnyCodableJSON(response.lunarDate),
            // 流日柱
            "day_pillar": AnyCodableJSON(response.dayPillar),
            "day_stem": AnyCodableJSON(dayStem),
            "day_stem_element": AnyCodableJSON(dayStemElement),
            "day_branch": AnyCodableJSON(dayBranch),
            "day_branch_element": AnyCodableJSON(dayBranchElement),
            // 流日对日主关系
            "day_relation": AnyCodableJSON(response.dayRelationToDayMaster),
            "day_chong": AnyCodableJSON(dayChongDisplay),
            // 12 时辰条 + 黄历
            "hour_pillars_with_relations": AnyCodableJSON(hourPillarsStr),
            "huangli_yi": AnyCodableJSON(response.huangliYi.joined(separator: "、")),
            "huangli_ji": AnyCodableJSON(response.huangliJi.joined(separator: "、")),
        ]
    }

    // MARK: - Internal helpers(供 +Compatibility extension 复用)

    static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        f.timeZone = .current
        return f
    }()

    /// 后端 prompt 模板期望中文"男"/"女",request.gender 是 "male"/"female"
    static func genderToChinese(_ gender: String) -> String {
        gender == "male" ? "男" : "女"
    }

    /// 五行英文 → 中文(后端 gan_element/zhi_element 用英文,prompt 期望中文与
    /// element_balance/favorable_elements 统一)。未知值原样返回(不吞,便于排障)。
    static func elementToChinese(_ element: String) -> String {
        switch element {
        case "wood": return "木"
        case "fire": return "火"
        case "earth": return "土"
        case "metal": return "金"
        case "water": return "水"
        default: return element
        }
    }

    static func formatShensha(_ items: [ShenshaItemDTO]) -> String {
        if items.isEmpty { return "无" }
        return items.map { "\($0.name)(\($0.position))" }.joined(separator: "、")
    }

    static func formatElementBalance(_ balance: ElementBalanceDTO) -> String {
        "木:\(balance.wood) 火:\(balance.fire) 土:\(balance.earth) 金:\(balance.metal) 水:\(balance.water)"
    }
}

// MARK: - PromptContextError

/// v1 prompt 系统 chart 构建错误(Stage 7b)。
///
/// 显式错误传播(对齐 CLAUDE.md):不静默吞错。buildV1ChartJSON 失败时由
/// Orchestrator throw 透传,VM 转为 UI 错误路径(DeepAnalysisViewModel
/// 在 Stage 7c 接入时用 UserFacingError.from 包装显示给用户)。
enum PromptContextError: Error, LocalizedError {
    /// response.meta 为 nil(老 response 或后端版本未升级到 Stage 1+)
    case missingMetaBlock(contentHash: String)
    /// response.currentYearPillar 为 nil(后端语义保证非空,nil = 数据损坏)
    case missingCurrentYear(contentHash: String)
    /// response.pillars.day 为 nil(日柱歧义,S02/D10)。无日主不编造 day_master
    /// 轴心字段;D5 全拦截用户应由 S07 付费墙拦在内容页之前,走到这里 = 上游拦截缺口
    case missingDayPillar(contentHash: String)
    /// gan_zhi 长度异常(期望 2 字符天干+地支)。splitGanZhi 拒绝静默兜底空字符串。
    case invalidGanZhi(contentHash: String, field: String, value: String)
    /// dayMasterStrength 非 nil 但不在已知枚举(strong/weak/balanced/special_pattern)
    /// 代码 bug 显式暴露(对齐 backend chart_builder._STRENGTH_LABEL_ZH 严格性)
    case unknownDayMasterStrength(contentHash: String, value: String)
    /// JSONSerialization 失败(理论不可达,Dict 结构都是 JSON-safe)
    case jsonEncodingFailed(contentHash: String, underlying: Error? = nil)

    var errorDescription: String? {
        switch self {
        case .missingMetaBlock(let hash):
            return "命盘缺 meta 块(contentHash=\(hash.prefix(8))),可能后端版本未升级到 Stage 1+,或 response 过期"
        case .missingCurrentYear(let hash):
            return "命盘缺 current_year_pillar(contentHash=\(hash.prefix(8))),数据损坏"
        case .missingDayPillar(let hash):
            return "命盘日柱未知(日柱歧义,时辰未知所致,contentHash=\(hash.prefix(8))),该盘不应进入内容页(S07 拦截)"
        case .invalidGanZhi(let hash, let field, let value):
            return "命盘 \(field) gan_zhi 长度异常(期望 2 字符):\(value)(contentHash=\(hash.prefix(8)))"
        case .unknownDayMasterStrength(let hash, let value):
            return "命盘 day_master_strength 未知值:\(value)(contentHash=\(hash.prefix(8))),期望 strong/weak/balanced/special_pattern"
        case .jsonEncodingFailed(let hash, let underlying):
            let detail = underlying.map { "(\(type(of: $0)): \($0))" } ?? ""
            return "chart JSON 序列化失败(contentHash=\(hash.prefix(8)))\(detail)"
        }
    }
}
