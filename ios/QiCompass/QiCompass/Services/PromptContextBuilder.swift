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

    // MARK: - Private

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
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
