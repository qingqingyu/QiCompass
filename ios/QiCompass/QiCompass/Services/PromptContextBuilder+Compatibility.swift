import Foundation

/// 单人 prompt 上下文(从 ChartSnapshot / BaziResponse 提炼的字段集合)。
///
/// 设计理由:bazi_deep 的 prompt 用单个 chart;compatibility 需要两份。
/// 抽出此结构后 PromptContextBuilder 不依赖具体数据源,只接受提炼后的字段。
struct ChartPromptContext {
    let gender: String              // "男" / "女"
    let cityDisplay: String         // 格式化好的可读字符串
    let birthDisplay: String        // "yyyy-MM-dd HH:mm"
    let dayMaster: String           // 天干字,如 "甲"
    let dayMasterStrength: String   // weak/balanced/strong/special_pattern
    let favorable: String           // 已 join 好的中文五行
    let yearPillar: String          // 干支,如 "甲子"
    let monthPillar: String
    let dayPillar: String
    let hourPillar: String
    let elementBalance: String      // "木:2 火:1 土:1 金:1 水:3"
}

extension PromptContextBuilder {

    // MARK: - Compatibility

    /// 构造 compatibility module 的 prompt context。
    /// 覆盖后端 `REQUIRED_FIELDS["compatibility"]` 全部 26 字段(见 prompts.py:147-158)。
    ///
    /// - Parameters:
    ///   - contextLabel: 中文语境标签("通用" / "婚姻" / "事业")
    ///   - chartA: A 盘提炼字段
    ///   - chartB: B 盘提炼字段
    ///   - assessment: 后端 4 项定性评估
    ///   - syncedFortune: 3 年流年同步
    static func buildCompatibility(
        contextLabel: String,
        chartA: ChartPromptContext,
        chartB: ChartPromptContext,
        assessment: QualitativeAssessmentDTO,
        syncedFortune: [SyncedFortuneDTO]
    ) -> [String: AnyCodableJSON] {
        return [
            // 通用
            "context_label": AnyCodableJSON(contextLabel),
            // A 盘
            "gender_a": AnyCodableJSON(chartA.gender),
            "city_a": AnyCodableJSON(chartA.cityDisplay),
            "birth_a": AnyCodableJSON(chartA.birthDisplay),
            "day_master_a": AnyCodableJSON(chartA.dayMaster),
            "day_master_strength_a": AnyCodableJSON(chartA.dayMasterStrength),
            "favorable_a": AnyCodableJSON(chartA.favorable),
            "year_a": AnyCodableJSON(chartA.yearPillar),
            "month_a": AnyCodableJSON(chartA.monthPillar),
            "day_a": AnyCodableJSON(chartA.dayPillar),
            "hour_a": AnyCodableJSON(chartA.hourPillar),
            "element_balance_a": AnyCodableJSON(chartA.elementBalance),
            // B 盘
            "gender_b": AnyCodableJSON(chartB.gender),
            "city_b": AnyCodableJSON(chartB.cityDisplay),
            "birth_b": AnyCodableJSON(chartB.birthDisplay),
            "day_master_b": AnyCodableJSON(chartB.dayMaster),
            "day_master_strength_b": AnyCodableJSON(chartB.dayMasterStrength),
            "favorable_b": AnyCodableJSON(chartB.favorable),
            "year_b": AnyCodableJSON(chartB.yearPillar),
            "month_b": AnyCodableJSON(chartB.monthPillar),
            "day_b": AnyCodableJSON(chartB.dayPillar),
            "hour_b": AnyCodableJSON(chartB.hourPillar),
            "element_balance_b": AnyCodableJSON(chartB.elementBalance),
            // 定性评估
            "five_elements_assessment": AnyCodableJSON(assessment.fiveElements),
            "day_master_relation": AnyCodableJSON(assessment.dayMasterRelation),
            "zodiac_match": AnyCodableJSON(assessment.zodiacMatch),
            "branch_harmony": AnyCodableJSON(assessment.branchHarmony),
            // 流年同步
            "synced_fortune_table": AnyCodableJSON(formatSyncedFortune(syncedFortune)),
        ]
    }

    // MARK: - 提炼助手

    /// 从存档 BaziResponse 提炼单人 prompt 上下文。
    /// `gender` 取 "male"/"female" 字符串(由调用方从 ChartSnapshot.gender / request 取)。
    /// `cityDisplay` 取城市名(或经度格式化)。
    static func chartContext(
        from response: BaziResponse,
        gender: String,
        cityDisplay: String
    ) -> ChartPromptContext {
        let p = response.pillars
        return ChartPromptContext(
            gender: genderToChinese(gender),
            cityDisplay: cityDisplay,
            birthDisplay: dateTimeFormatter.string(from: response.trueSolarTime),
            dayMaster: p.day.gan,
            dayMasterStrength: response.dayMasterStrength ?? "special_pattern",
            favorable: response.favorableElements.isEmpty
                ? "—(从格未下喜忌)"
                : response.favorableElements.joined(separator: ", "),
            yearPillar: p.year.ganZhi,
            monthPillar: p.month.ganZhi,
            dayPillar: p.day.ganZhi,
            hourPillar: p.hour.ganZhi,
            elementBalance: formatElementBalance(response.elementBalance)
        )
    }

    /// context 字段 → 中文标签(后端 prompt 模板期望中文)。
    static func contextLabel(_ context: String) -> String {
        switch context {
        case "general":  return "通用"
        case "marriage": return "婚姻"
        case "business": return "事业"
        default:         return context
        }
    }

    // MARK: - Private

    private static func formatSyncedFortune(_ items: [SyncedFortuneDTO]) -> String {
        items.map { sf in
            "- \(sf.year):A「\(sf.personA)」 B「\(sf.personB)」→ \(sf.sync)"
        }.joined(separator: "\n")
    }
}
