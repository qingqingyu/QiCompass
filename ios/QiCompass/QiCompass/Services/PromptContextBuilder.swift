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

    /// 构造 bazi_deep module 的 prompt context。
    static func build(
        response: BaziResponse,
        request: BaziCalculateRequest
    ) -> [String: AnyCodableJSON] {
        let p = response.pillars
        let trueSolarTimeStr = Self.dateTimeFormatter.string(from: response.trueSolarTime)
        let cityDisplay = request.city ?? "手动经度(\(request.longitude ?? 0))"

        return [
            // 命主(gender 转中文,prompt 模板期望"男"/"女"而非"male"/"female")
            "gender": AnyCodableJSON(Self.genderToChinese(request.gender)),
            "city": AnyCodableJSON(cityDisplay),
            "true_solar_time": AnyCodableJSON(trueSolarTimeStr),
            // 年柱
            "year_gan": AnyCodableJSON(p.year.gan),
            "year_zhi": AnyCodableJSON(p.year.zhi),
            "year_gan_element": AnyCodableJSON(Self.elementToChinese(p.year.ganElement)),
            "year_zhi_element": AnyCodableJSON(Self.elementToChinese(p.year.zhiElement)),
            "year_shishen_gan": AnyCodableJSON(p.year.shishenGan),
            "year_hide_gan": AnyCodableJSON(p.year.hideGan.joined(separator: ", ")),
            // 月柱
            "month_gan": AnyCodableJSON(p.month.gan),
            "month_zhi": AnyCodableJSON(p.month.zhi),
            "month_gan_element": AnyCodableJSON(Self.elementToChinese(p.month.ganElement)),
            "month_zhi_element": AnyCodableJSON(Self.elementToChinese(p.month.zhiElement)),
            "month_shishen_gan": AnyCodableJSON(p.month.shishenGan),
            "month_hide_gan": AnyCodableJSON(p.month.hideGan.joined(separator: ", ")),
            // 日柱
            "day_gan": AnyCodableJSON(p.day.gan),
            "day_zhi": AnyCodableJSON(p.day.zhi),
            "day_gan_element": AnyCodableJSON(Self.elementToChinese(p.day.ganElement)),
            "day_shishen_zhi": AnyCodableJSON(p.day.shishenZhi.joined(separator: ", ")),
            "day_hide_gan": AnyCodableJSON(p.day.hideGan.joined(separator: ", ")),
            // 时柱
            "hour_gan": AnyCodableJSON(p.hour.gan),
            "hour_zhi": AnyCodableJSON(p.hour.zhi),
            "hour_gan_element": AnyCodableJSON(Self.elementToChinese(p.hour.ganElement)),
            "hour_zhi_element": AnyCodableJSON(Self.elementToChinese(p.hour.zhiElement)),
            "hour_shishen_gan": AnyCodableJSON(p.hour.shishenGan),
            "hour_hide_gan": AnyCodableJSON(p.hour.hideGan.joined(separator: ", ")),
            // 纳音
            "year_nayin": AnyCodableJSON(p.year.nayin),
            "month_nayin": AnyCodableJSON(p.month.nayin),
            "day_nayin": AnyCodableJSON(p.day.nayin),
            "hour_nayin": AnyCodableJSON(p.hour.nayin),
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

    // MARK: - Private

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日"
        f.timeZone = .current
        return f
    }()

    /// 后端 prompt 模板期望中文"男"/"女",request.gender 是 "male"/"female"
    private static func genderToChinese(_ gender: String) -> String {
        gender == "male" ? "男" : "女"
    }

    /// 五行英文 → 中文(后端 gan_element/zhi_element 用英文,prompt 期望中文与
    /// element_balance/favorable_elements 统一)。未知值原样返回(不吞,便于排障)。
    private static func elementToChinese(_ element: String) -> String {
        switch element {
        case "wood": return "木"
        case "fire": return "火"
        case "earth": return "土"
        case "metal": return "金"
        case "water": return "水"
        default: return element
        }
    }

    private static func formatShensha(_ items: [ShenshaItemDTO]) -> String {
        if items.isEmpty { return "无" }
        return items.map { "\($0.name)(\($0.position))" }.joined(separator: "、")
    }

    private static func formatElementBalance(_ balance: ElementBalanceDTO) -> String {
        "木:\(balance.wood) 火:\(balance.fire) 土:\(balance.earth) 金:\(balance.metal) 水:\(balance.water)"
    }
}
