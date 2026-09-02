import XCTest
@testable import QiCompass

/// 章节正文结构化解析测试(2026-09-02 JSON 渲染层):
/// 保序/标签表/条目卡取题/枚举值中文化/围栏容错/散文降级。
final class ChapterContentTests: XCTestCase {

    // MARK: - M0 主线结构(对象全标量 → 键值组,顺序保持)

    func test_m0_fieldsOrderPreserved() {
        let json = """
        {
          "main_axis": {
            "dominant": "正财",
            "secondary": "比肩",
            "latent": "劫财",
            "evidence": "ten_god_weights 中正财=14 最高"
          },
          "core_loop": {
            "from": "正财",
            "to": "比肩",
            "flow": "正财 → 比肩 → 正财",
            "driver": "务实目标",
            "leak": "过度求稳",
            "evidence": "月柱比肩"
          },
          "structure_type": { "name": "财比结构", "one_line": "以稳生财,以财带人" },
          "structure_fingerprint": "务实积累型:先立住成果,再放大协作"
        }
        """
        guard let content = ChapterContent.parse(json) else {
            return XCTFail("M0 样例应解析成功")
        }
        XCTAssertEqual(content.nodes.count, 4)

        // 主线:键值组,顺序 = JSON 书写顺序(主导 → 次要 → 潜伏 → 据)
        guard case .section(let title, let children) = content.nodes[0],
              case .fields(let fields)? = children.first else {
            return XCTFail("main_axis 应为含键值组的小节,实际:\(content.nodes[0])")
        }
        XCTAssertEqual(title, "主线")
        XCTAssertEqual(fields.map(\.label), ["主导", "次要", "潜伏", "据"])
        XCTAssertEqual(fields[0].value, "正财")
        XCTAssertTrue(fields[3].isNote)

        // structure_fingerprint:顶层标量 → 引言
        guard case .lead(let lead) = content.nodes[3] else {
            return XCTFail("structure_fingerprint 应为引言,实际:\(content.nodes[3])")
        }
        XCTAssertEqual(lead, "务实积累型:先立住成果,再放大协作")
    }

    // MARK: - 嵌套小节(M2 threshold:对象里混结构值 → 递归小节)

    func test_m2_nestedSection() {
        let json = """
        {
          "threshold": {
            "environment": { "enables": "资源充足的环境", "suppresses": "人情捆绑的环境" },
            "belief": { "limiting_belief": "我不配", "origin": "早年", "ceiling_effect": "不敢要" },
            "awareness": { "key_moment": "被压价时", "what_to_notice": "身体反应" }
          }
        }
        """
        guard let content = ChapterContent.parse(json) else {
            return XCTFail("M2 样例应解析成功")
        }
        guard case .section("分界点", let children) = content.nodes[0] else {
            return XCTFail("threshold 应为「分界点」小节,实际:\(content.nodes[0])")
        }
        XCTAssertEqual(children.count, 3)
        guard case .section("环境资源", let envChildren) = children[0],
              case .fields(let envFields)? = envChildren.first else {
            return XCTFail("environment 应为「环境资源」嵌套小节")
        }
        XCTAssertEqual(envFields.map(\.label), ["跑得开的环境", "压制它的环境"])
    }

    // MARK: - 对象数组 → 条目卡(M1 天赋 / M4 七天复位)

    func test_m1_itemsWithTitleFromName() {
        let json = """
        {
          "innate": [
            { "name": "深度理解与转述", "behavior": "把复杂的东西吃透再讲明白", "evidence": "印星旺", "energy": "gain" },
            { "name": "落地执行", "behavior": "先做出能跑的版本", "evidence": "财星制印", "energy": "gain" }
          ]
        }
        """
        guard let content = ChapterContent.parse(json) else {
            return XCTFail("M1 样例应解析成功")
        }
        guard case .items(let items) = content.nodes[0] else {
            return XCTFail("innate 应为条目卡,实际:\(content.nodes[0])")
        }
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "深度理解与转述")
        // name 已被取作题,不再进字段
        XCTAssertEqual(items[0].fields.map(\.label), ["行为表现", "据", "能量"])
        // energy 枚举中文化:gain → 回血
        XCTAssertEqual(items[0].fields.last?.value, "回血")
    }

    func test_m4_dayNumberBecomesTitle() {
        let json = """
        {
          "reset_7day": [
            { "day": 1, "focus": "睡眠时点", "action": "23 点前躺下" },
            { "day": 2, "focus": "信息节食", "action": "上午不刷热点" }
          ]
        }
        """
        guard let content = ChapterContent.parse(json) else {
            return XCTFail("M4 样例应解析成功")
        }
        guard case .items(let items) = content.nodes[0] else {
            return XCTFail("reset_7day 应为条目卡,实际:\(content.nodes[0])")
        }
        XCTAssertEqual(items[0].title, "第 1 天")
        XCTAssertEqual(items[0].fields.map(\.label), ["焦点", "动作"])
    }

    // MARK: - 字符串数组 → 条目列;顶层注 → 小字注

    func test_stringArrayBecomesBullets() {
        let json = """
        { "early_warnings": ["开始讨好难缠的人", "作息漂移", "只做熟悉的杂活"],
          "medical_note": "若症状持续加重,请就医" }
        """
        guard let content = ChapterContent.parse(json) else {
            return XCTFail("M2/M4 混合样例应解析成功")
        }
        guard case .bullets(let bullets) = content.nodes[0] else {
            return XCTFail("early_warnings 应为条目列,实际:\(content.nodes[0])")
        }
        XCTAssertEqual(bullets.count, 3)
        guard case .note(let label, let text) = content.nodes[1] else {
            return XCTFail("medical_note 应为小字注,实际:\(content.nodes[1])")
        }
        XCTAssertEqual(label, "医嘱")
        XCTAssertTrue(text.contains("就医"))
    }

    // MARK: - 容错

    func test_proseTextReturnsNil() {
        let prose = "你的天赋能力在深度理解与转述——印星旺的人擅长把复杂的东西吃透再讲明白。"
        XCTAssertNil(ChapterContent.parse(prose))
    }

    func test_codeFenceWrappedJsonParses() {
        let fenced = """
        ```json
        { "one_leverage": "把理解力产品化" }
        ```
        """
        guard case .lead("把理解力产品化")? = ChapterContent.parse(fenced)?.nodes.first else {
            return XCTFail("围栏包裹的 JSON 应剥围栏后解析")
        }
    }

    func test_trailingGarbageReturnsNil() {
        XCTAssertNil(ChapterContent.parse("{ \"a\": 1 } 以上就是分析。"))
    }

    func test_unicodeAndEscapeSequences() {
        let json = "{ \"text\": \"引号\\\"换行\\n\\u4e2d\\u6587\" }"
        guard case .lead(let s)? = ChapterContent.parse(json)?.nodes.first else {
            return XCTFail("转义样例应解析成功")
        }
        XCTAssertEqual(s, "引号\"换行\n中文")
    }

    // MARK: - 标签兜底

    func test_unknownKeyFallsBackToRawKey() {
        // 未登记 key:小节题/字段标签原样透出(schema 外防御,不静默丢字段)
        let json = "{ \"group\": { \"surprise_key\": \"值\" } }"
        guard case .section(let title, let children)? = ChapterContent.parse(json)?.nodes.first,
              case .fields(let fields)? = children.first else {
            return XCTFail("未知 key 对象仍应解析为小节+键值组")
        }
        XCTAssertEqual(title, "group")
        XCTAssertEqual(fields.first?.label, "surprise_key")
        XCTAssertNil(ChapterContent.labels["surprise_key"])
    }
}
