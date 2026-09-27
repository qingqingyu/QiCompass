import XCTest
@testable import QiCompass

/// 合盘「无运」+ A/B 代号修复回归测试(2026-09-27)。
///
/// 覆盖:
/// - `ChartPayloadDTO.compatibilityPayload`:luck_pillars + calc_rule_snapshot
///   必须随 payload 下发(「无运」根因:此前复用 daily 构造器两字段恒 nil)
/// - `PromptContextBuilder.buildCompatibility`:name_a/name_b 进 context,
///   synced 表用名字而非 A/B 代号
/// - `CompatibilityChapterText.parse`:第X章/Chapter N 标题行解析 +
///   老散文本容错(nil 退整段)
final class CompatibilityNamesAndChaptersTests: XCTestCase {

    // MARK: - 夹具

    private func makeBaziResponse() -> BaziResponse {
        let pillar = PillarDTO(
            ganZhi: "甲子",
            gan: "甲", zhi: "子",
            ganElement: "wood", zhiElement: "water",
            hideGan: ["癸"],
            shishenGan: "比肩", shishenZhi: ["正印"],
            nayin: "海中金",
            dishi: "", xunkong: "戌亥"
        )
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        return BaziResponse(
            contentHash: "compat_payload_fix_001",
            trueSolarTime: nil,
            trueSolarOffsetMinutes: 0,
            pillars: PillarsDTO(year: pillar, month: pillar, day: pillar, hour: pillar),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: ["木", "水"],
            unfavorableElements: ["土"],
            dayMasterStrength: "balanced",
            tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [],
            luckPillars: [
                LuckPillarDTO(ganZhi: "乙亥", startYear: 2027, endYear: 2036, startAge: 43, endAge: 52),
            ],
            currentLuckPillar: nil, currentYearPillar: nil,
            currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1, birthTimezone: "Asia/Shanghai",
                hourKnown: true, pillarAmbiguity: nil
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox"], yearBranchClash: "Horse"
        )
    }

    // MARK: - compatibilityPayload(「无运」修复)

    func test_compatibilityPayload_带大运与规则快照() throws {
        let payload = ChartPayloadDTO.compatibilityPayload(from: makeBaziResponse())

        XCTAssertEqual(payload.luckPillars?.count, 1,
                       "luck_pillars 必须随合盘 payload 下发(「无运」根因:恒 nil → 后端空表)")
        XCTAssertEqual(payload.luckPillars?.first?.ganZhi, "乙亥")
        XCTAssertNotNil(payload.calcRuleSnapshot, "calc_rule_snapshot 同为合盘必带扩展字段")

        // wire 格式:snake_case 键名对齐后端 ChartPayload
        let data = try APICoder.encoder.encode(payload)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let luck = try XCTUnwrap(obj["luck_pillars"] as? [[String: Any]])
        XCTAssertEqual(luck.first?["gan_zhi"] as? String, "乙亥")
        XCTAssertEqual(luck.first?["start_year"] as? Int, 2027)
        XCTAssertNotNil(obj["calc_rule_snapshot"])
    }

    func test_daily路径from_不带扩展字段_行为不变() throws {
        // daily-fortune 主构造器语义不变(luck/calc 恒 nil,字段不编码)
        let payload = ChartPayloadDTO.from(baziResponse: makeBaziResponse())
        XCTAssertNil(payload.luckPillars)
        XCTAssertNil(payload.calcRuleSnapshot)
        let data = try APICoder.encoder.encode(payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("luck_pillars"))
    }

    // MARK: - buildCompatibility 名字注入

    func test_buildCompatibility_名字进context_流年表去AB代号() throws {
        let chartA = PromptContextBuilder.chartContext(
            from: makeBaziResponse(), gender: "male", cityDisplay: "北京")
        let chartB = PromptContextBuilder.chartContext(
            from: makeBaziResponse(), gender: "female", cityDisplay: "上海")
        let synced = [
            SyncedFortuneDTO(year: 2027, personA: "乙亥运 丁未年", personB: "丁卯运 丁未年", sync: "同步走强"),
        ]

        let context = PromptContextBuilder.buildCompatibility(
            contextLabel: "通用",
            chartA: chartA, chartB: chartB,
            assessment: QualitativeAssessmentDTO(
                fiveElements: "互补佳", dayMasterRelation: "相生",
                zodiacMatch: "六合", branchHarmony: "多合少冲"),
            syncedFortune: synced,
            nameA: "你", nameB: "小林"
        )

        XCTAssertEqual(context["name_a"]?.value as? String, "你")
        XCTAssertEqual(context["name_b"]?.value as? String, "小林")

        let table = try XCTUnwrap(context["synced_fortune_table"]?.value as? String)
        XCTAssertTrue(table.contains("你「乙亥运 丁未年」"), "流年表 A 侧用称呼,实际:\(table)")
        XCTAssertTrue(table.contains("小林「丁卯运 丁未年」"), "流年表 B 侧用称呼")
        XCTAssertFalse(table.contains("A「"), "不得残留 A 代号")
        XCTAssertFalse(table.contains("B「"), "不得残留 B 代号")
    }

    // MARK: - 章节标题行解析

    func test_章节解析_标准v4标题行() throws {
        let text = """
        第一章 基础相处模式

        你倾向于先说结论，小林习惯先想清楚。

        两人的节奏一个快一个稳。

        第二章 互补与冲突总览

        五行互补落在实处。
        """
        let parsed = try XCTUnwrap(CompatibilityChapterText.parse(text))
        XCTAssertNil(parsed.lead)
        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].numeral, "壹")
        XCTAssertEqual(parsed.chapters[0].title, "基础相处模式")
        XCTAssertEqual(parsed.chapters[0].paragraphs.count, 2, "空行分段")
        XCTAssertEqual(parsed.chapters[1].numeral, "贰")
        XCTAssertEqual(parsed.chapters[1].title, "互补与冲突总览")
        XCTAssertEqual(parsed.chapters[1].paragraphs, ["五行互补落在实处。"])
    }

    func test_章节解析_容错v3冒号与加粗包裹() throws {
        let text = "**第一章：基础相处模式**\n老缓存风格正文一行。"
        let parsed = try XCTUnwrap(CompatibilityChapterText.parse(text))
        XCTAssertEqual(parsed.chapters[0].numeral, "壹")
        XCTAssertEqual(parsed.chapters[0].title, "基础相处模式")
        XCTAssertEqual(parsed.chapters[0].paragraphs, ["老缓存风格正文一行。"])
    }

    func test_章节解析_英文Chapter标题() throws {
        let text = "Chapter 1 Basic Interaction Pattern\n\nBody line one.\n"
        let parsed = try XCTUnwrap(CompatibilityChapterText.parse(text))
        XCTAssertEqual(parsed.chapters[0].numeral, "壹")
        XCTAssertEqual(parsed.chapters[0].title, "Basic Interaction Pattern")
        XCTAssertEqual(parsed.chapters[0].paragraphs, ["Body line one."])
    }

    func test_章节解析_标题前引言归lead() throws {
        let text = "开篇引言一句。\n\n第一章 基础相处模式\n\n正文。"
        let parsed = try XCTUnwrap(CompatibilityChapterText.parse(text))
        XCTAssertEqual(parsed.lead, "开篇引言一句。")
        XCTAssertEqual(parsed.chapters.count, 1)
    }

    func test_章节解析_无标题行返回nil_调用方退整段() {
        XCTAssertNil(CompatibilityChapterText.parse("整段散文,没有任何章节标题行。"))
        XCTAssertNil(CompatibilityChapterText.parse(""))
    }
}
