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

    // MARK: - M0 特化组装(2026-10-12 S4-A:行内标签段落化 + 章末据折叠)

    func test_m0_moduleAssemblesInlineLabels() {
        let json = """
        {
          "main_axis": {
            "dominant": "七杀与劫财(并列最重)",
            "secondary": "正印与偏印",
            "latent": "伤官与财星藏而不透",
            "evidence": "七杀 6=劫财 6 并列最高"
          },
          "core_loop": {
            "from": "七杀",
            "to": "正印",
            "flow": "压力被吸收为方法",
            "driver": "年干丙火七杀透出",
            "leak": "输出通道窄,水运打开",
            "evidence": "水透出计数为 0"
          },
          "structure_type": { "name": "硬扛聚能型", "one_line": "压力进来,能量聚在事里" },
          "capability_source": { "text": "你最强的时刻,是硬需求递到手上的时候。", "evidence": "七杀重(6)。" },
          "structure_fingerprint": "吸收压力转为系统,输出等水木运"
        }
        """
        guard let content = ChapterContent.parse(json, for: .m0) else {
            return XCTFail("M0 模块应特化解析成功")
        }
        // 固定阅读序:主线 / 核心循环 / 结构类型 / 能力来源 / 概括 / 据折叠
        XCTAssertEqual(content.nodes.count, 6)

        guard case .section("主线", let mainChildren) = content.nodes[0] else {
            return XCTFail("首节点应为「主线」小节,实际:\(content.nodes[0])")
        }
        XCTAssertEqual(mainChildren.compactMap { node -> String? in
            if case .inlineLabel(let label, _) = node { return label }
            return nil
        }, ["主导", "次要", "潜伏"], "三层应为行内标签段")
        guard case .inlineLabel(_, let dominantText)? = mainChildren.first else {
            return XCTFail("dominant 应为 inlineLabel,实际:\(mainChildren)")
        }
        XCTAssertTrue(dominantText.contains("并列最重"))

        guard case .section("核心循环", let loopChildren) = content.nodes[1] else {
            return XCTFail("次节点应为「核心循环」小节")
        }
        guard case .loopFromTo(let from, let to)? = loopChildren.first else {
            return XCTFail("core_loop 首子节点应为 loopFromTo,实际:\(loopChildren)")
        }
        XCTAssertEqual(from, "七杀")
        XCTAssertEqual(to, "正印")
        let loopLabels = loopChildren.dropFirst().compactMap { node -> String? in
            if case .inlineLabel(let label, _) = node { return label }
            return nil
        }
        XCTAssertEqual(loopLabels, ["流向", "驱动", "损耗"])

        guard case .section("结构类型", let typeChildren) = content.nodes[2] else {
            return XCTFail("第三节点应为「结构类型」小节")
        }
        XCTAssertTrue(typeChildren.contains {
            if case .inlineLabel("名称", _) = $0 { return true }
            return false
        }, "名称应为行内标签段")
        XCTAssertTrue(typeChildren.contains {
            if case .lead(let prose) = $0 { return prose.contains("压力进来") }
            return false
        }, "one_line 应作引言段")

        guard case .section("能力来源", let capChildren) = content.nodes[3],
              case .lead(let capText)? = capChildren.first else {
            return XCTFail("能力来源 text 应作引言段")
        }
        XCTAssertTrue(capText.contains("硬需求"))

        guard case .lead(let fingerprint) = content.nodes[4] else {
            return XCTFail("structure_fingerprint 应为引言")
        }
        XCTAssertTrue(fingerprint.contains("吸收压力"))

        guard case .evidenceFold(let notes) = content.nodes[5] else {
            return XCTFail("末节点应为据折叠区,实际:\(content.nodes[5])")
        }
        XCTAssertEqual(notes.map(\.label), ["主线", "核心循环", "能力来源"])
        XCTAssertTrue(notes[1].text.contains("透出计数"))
    }

    func test_m0_specializationFallsBackOnMissingCoreLoop() {
        // 老缓存/违约:缺 core_loop → 回落通用渲染,不静默丢内容
        let json = """
        { "main_axis": { "dominant": "七杀", "secondary": "正印", "latent": "伤官" } }
        """
        guard let content = ChapterContent.parse(json, for: .m0) else {
            return XCTFail("缺 core_loop 仍应通用解析成功")
        }
        guard case .section("主线", let children) = content.nodes[0],
              case .fields(let fields)? = children.first else {
            return XCTFail("回落路径应为通用键值组,实际:\(content.nodes)")
        }
        XCTAssertEqual(fields.map(\.label), ["主导", "次要", "潜伏"])
    }

    func test_m0_degenerateMainAxisKeepsEvidenceNote() {
        // 退化输入:main_axis 对象在但三层全非 string(无主线节),其
        // evidence 不得静默丢——与 core_loop 同款无条件收进「据」折叠
        let json = """
        {
          "main_axis": { "evidence": "七杀 6=劫财 6 并列最高" },
          "core_loop": { "from": "七杀", "to": "正印", "flow": "压力被吸收为方法" }
        }
        """
        guard let content = ChapterContent.parse(json, for: .m0) else {
            return XCTFail("退化 main_axis 仍应特化解析成功")
        }
        XCTAssertFalse(content.nodes.contains {
            if case .section("主线", _) = $0 { return true }
            return false
        }, "三层全缺不应有空主线节")
        guard case .evidenceFold(let notes)? = content.nodes.last else {
            return XCTFail("末节点应为据折叠区,实际:\(content.nodes)")
        }
        XCTAssertEqual(notes.map(\.label), ["主线"])
        XCTAssertEqual(notes.first?.text, "七杀 6=劫财 6 并列最高")
    }

    func test_m0_jsonWithNilModuleStaysGeneric() {
        // module = nil(中毒判读等):行为与既有通用路径逐字一致
        let json = "{ \"main_axis\": { \"dominant\": \"正财\" } }"
        guard case .section("主线", let children)? = ChapterContent.parse(json)?.nodes.first,
              case .fields(let fields)? = children.first else {
            return XCTFail("nil module 应走通用渲染")
        }
        XCTAssertEqual(fields.first?.label, "主导")
        XCTAssertFalse(fields.first?.isNote ?? true)
    }

    func test_m0_extraFieldsNotSilentlyDropped() {
        // 2026-10-13 review 修复:schema 外字段与非对象形态的已知键不得
        // 静默丢弃(原先页面无显示也无日志)——未消费键走通用节点渲染
        let json = """
        {
          "main_axis": {
            "dominant": "七杀与劫财(并列最重)",
            "secondary": "正印",
            "latent": "伤官",
            "evidence": "七杀 6=劫财 6 并列最高",
            "note": "权重口径见据"
          },
          "core_loop": {
            "from": "七杀",
            "to": "正印",
            "flow": "压力被吸收为方法",
            "driver": "年干丙火七杀透出",
            "leak": "输出通道窄,水运打开"
          },
          "structure_type": "硬扛聚能型",
          "summary": "整体:吸入强输出弱",
          "structure_fingerprint": "吸收压力转为系统,输出等水木运"
        }
        """
        guard let content = ChapterContent.parse(json, for: .m0) else {
            return XCTFail("含 schema 外字段的 M0 应特化解析成功")
        }
        // main_axis 内多余键:主线节内走通用节点渲染(string → .lead 引言段,
        // node() 不打裸键标签),不丢
        guard case .section("主线", let mainChildren)? = content.nodes.first else {
            return XCTFail("首节点应为「主线」小节,实际:\(content.nodes)")
        }
        XCTAssertTrue(mainChildren.contains {
            if case .lead("权重口径见据") = $0 { return true }
            return false
        }, "main_axis.note 应走通用节点渲染(lead),不得静默丢弃")

        // structure_type 退化为字符串:顶层通用节点(引言),不丢
        XCTAssertTrue(content.nodes.contains {
            if case .lead("硬扛聚能型") = $0 { return true }
            return false
        }, "非对象 structure_type 应作顶层引言渲染")

        // schema 外顶层键:通用节点,不丢
        XCTAssertTrue(content.nodes.contains {
            if case .lead("整体:吸入强输出弱") = $0 { return true }
            return false
        }, "schema 外顶层键应走通用渲染")

        // 阅读序不受影响:据折叠仍收尾,fingerprint 仍为引言
        guard case .evidenceFold(let notes)? = content.nodes.last else {
            return XCTFail("末节点应为据折叠区,实际:\(content.nodes)")
        }
        XCTAssertEqual(notes.map(\.label), ["主线"])
        XCTAssertTrue(content.nodes.contains {
            if case .lead(let t) = $0 { return t.contains("吸收压力") }
            return false
        }, "structure_fingerprint 应作引言渲染")
    }

    func test_m0_nonStringLayerNotSilentlyDropped() {
        // 违约形态:dominant 非字符串(数字)——特化 inline 拿不到,原值
        // 走通用节点(裸标量作引言),不静默丢
        let json = """
        {
          "main_axis": { "dominant": 6, "secondary": "正印", "latent": "伤官" },
          "core_loop": { "from": "七杀", "to": "正印", "flow": "压力被吸收为方法" }
        }
        """
        guard let content = ChapterContent.parse(json, for: .m0) else {
            return XCTFail("非 string 层的 M0 应特化解析成功")
        }
        guard case .section("主线", let children)? = content.nodes.first else {
            return XCTFail("首节点应为「主线」小节,实际:\(content.nodes)")
        }
        XCTAssertTrue(children.contains {
            if case .lead("6") = $0 { return true }
            return false
        }, "非 string 的 dominant 应回落通用渲染,不得静默丢弃")
        XCTAssertTrue(children.contains {
            if case .inlineLabel("次要", _) = $0 { return true }
            return false
        }, "正常层不受影响")
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

    // MARK: - looksLikeJSON(2026-10-01 阅读页最后防线:parse 失败 + JSON 形态 → 异常态)

    func test_looksLikeJSON_trueForJSONForms() {
        XCTAssertTrue(ChapterContent.looksLikeJSON("{ \"structure_fingerprint\": \"x\" }"))
        // 09-27 事故形态:max_tokens 截断的半截 JSON
        XCTAssertTrue(ChapterContent.looksLikeJSON("{\n  \"looks_like\": \"To outsiders"))
        XCTAssertTrue(ChapterContent.looksLikeJSON("[{\"day\": 1}]"))
        XCTAssertTrue(ChapterContent.looksLikeJSON("```json\n{ \"a\": \"b\" }\n```"), "围栏形态应剥围栏后判定")
        XCTAssertTrue(ChapterContent.looksLikeJSON("  \n{ \"a\": 1 }"), "前导空白不影响判定")
    }

    func test_looksLikeJSON_falseForProseAndEmpty() {
        XCTAssertFalse(ChapterContent.looksLikeJSON("这是一段散文解读。"))
        XCTAssertFalse(ChapterContent.looksLikeJSON("2026 年运势:先立住成果,再放大协作。"))
        XCTAssertFalse(ChapterContent.looksLikeJSON(""))
        XCTAssertFalse(ChapterContent.looksLikeJSON("   "))
    }

    // MARK: - text 主散文体无标签(2026-10-11 EN 外评)

    func test_scalarObjectTextKeyRendersAsLeadNotLabeledField() {
        // "Body/正文" 数据腔标签修复:全标量对象里的 text 按引言段落排版,
        // 不打字段标签;其余标量键照旧键值行(混结构路径本就 .lead)。
        let json = """
        { "capability_source": { "text": "你最强的时刻,是硬需求递到手上的时候。", "evidence": "七杀重(6)——月支酉金当令。" } }
        """
        guard case .section(_, let children)? = ChapterContent.parse(json)?.nodes.first,
              case .lead(let prose)? = children.first,
              case .fields(let fields)? = children.last else {
            return XCTFail("text 应为引言段 + 其余键值组,实际: \(String(describing: ChapterContent.parse(json)?.nodes))")
        }
        XCTAssertTrue(prose.contains("硬需求"), "text 值按引言段落全文呈现")
        XCTAssertEqual(fields.map(\.label), ["据"], "text 不再占用字段标签位")
    }

    func test_nonStringTextKeyFallsBackToFieldNotDropped() {
        // 违约输出防御:text 值为 number/null 时不转引言段,但也不静默丢弃
        // ——回落键值行(label 未登记 → 裸 key 透出,对齐未知 key 约定)。
        let json = """
        { "capability_source": { "text": 5, "evidence": "七杀重。" } }
        """
        guard case .section(_, let children)? = ChapterContent.parse(json)?.nodes.first,
              case .fields(let fields)? = children.first else {
            return XCTFail("非 string text 应回落键值组,实际: \(String(describing: ChapterContent.parse(json)?.nodes))")
        }
        XCTAssertEqual(fields.count, 2, "number text 不消失")
        XCTAssertTrue(fields.contains { $0.label == "text" && $0.value == "5" }, "裸 key + 原值透出")
    }

    // MARK: - M0 v9 白话结论层(2026-10-14,plan docs/命书M0白话结论层-plan.md S3)

    private static let m0V9JSON = """
    {
      "main_axis": {
        "headline": "压力推着你走,你靠「学规矩、攒资历」接住它。",
        "body": "主导是七杀,也就是外部压力和硬要求;其次是正印,也就是体系、资质和靠山。",
        "dominant": "七杀、劫财(并列最重)",
        "secondary": "正印",
        "latent": "伤官、偏财",
        "evidence": "七杀与劫财并列最重(各 6)。"
      },
      "core_loop": {
        "headline": "扛压 → 沉淀 → 扛更大的压。",
        "from": "七杀",
        "to": "正印",
        "flow": "每次被逼着解决难题,你都会把它变成一套方法或一份资历。",
        "driver": "日主庚金偏旺,官杀旺而有印星化之。",
        "leak": "不爱表现。约 32 岁起的那十年,表达会变得容易。",
        "evidence": "月柱辛丑,日支午藏丁火正官。"
      },
      "structure_type": { "name": "被逼出来的专业型", "one_line": "分量靠一件件扛下来的事攒出来。" },
      "capability_source": {
        "headline": "最强在「给你一个难题,并让你自己搭体系」的时候;最弱在要你公开展示、自己推销自己的时候。",
        "text": "比如接手一个没人碰过的烂摊子,你会先把它拆成一块块可管的小事。",
        "evidence": "七杀权重 6,与劫财并列最重。"
      },
      "structure_fingerprint": "杀劫并列,以规矩和资历承压"
    }
    """

    func test_m0_v9AssemblesThreeLayers() {
        guard let content = ChapterContent.parse(Self.m0V9JSON, for: .m0) else {
            return XCTFail("v9 形态应特化解析成功")
        }
        // 阅读序:主线 / 核心循环 / 结构类型 / 能力来源 / 据(D6:无运转概括)
        XCTAssertEqual(content.nodes.count, 5)

        guard case .section("主线", let mainChildren) = content.nodes[0] else {
            return XCTFail("首节点应为「主线」,实际:\(content.nodes[0])")
        }
        guard case .headline(let mainHeadline)? = mainChildren.first,
              case .lead(let mainBody)? = mainChildren.dropFirst().first else {
            return XCTFail("主线应为 结论句→展开 两层,实际:\(mainChildren)")
        }
        XCTAssertTrue(mainHeadline.contains("压力推着你走"))
        XCTAssertTrue(mainBody.contains("七杀"))

        guard case .section("核心循环", let loopChildren) = content.nodes[1] else {
            return XCTFail("次节点应为「核心循环」")
        }
        guard case .headline(let loopHeadline)? = loopChildren.first else {
            return XCTFail("循环首子节点应为结论句,实际:\(loopChildren)")
        }
        XCTAssertTrue(loopHeadline.contains("扛压"))
        let loopProse = loopChildren.dropFirst().compactMap { node -> String? in
            if case .lead(let s) = node { return s }
            return nil
        }
        XCTAssertEqual(loopProse.count, 2, "flow/leak 应为两段散文,不带「流向/损耗」小标签")
        XCTAssertTrue(loopProse[0].contains("方法"), "flow 在前")
        XCTAssertTrue(loopProse[1].contains("32 岁"), "leak 在后")
        XCTAssertFalse(loopChildren.contains {
            if case .inlineLabel = $0 { return true }
            return false
        }, "v9 循环节不得出现行内标签段")

        guard case .section("结构类型", let typeChildren) = content.nodes[2] else {
            return XCTFail("第三节点应为「结构类型」")
        }
        guard case .headline(let name)? = typeChildren.first else {
            return XCTFail("name 应作结论句(无「名称 ·」标签),实际:\(typeChildren)")
        }
        XCTAssertEqual(name, "被逼出来的专业型")
        guard case .lead(let oneLine)? = typeChildren.dropFirst().first else {
            return XCTFail("one_line 应作展开段")
        }
        XCTAssertTrue(oneLine.contains("攒出来"))

        guard case .section("能力来源", let capChildren) = content.nodes[3] else {
            return XCTFail("第四节点应为「能力来源」")
        }
        guard case .headline(let capHeadline)? = capChildren.first,
              case .lead(let capText)? = capChildren.dropFirst().first else {
            return XCTFail("能力来源应为 结论句→展开 两层,实际:\(capChildren)")
        }
        XCTAssertTrue(capHeadline.contains("最强在"))
        XCTAssertTrue(capText.contains("烂摊子"))

        // 据 fold 固定序:分层 → 起止 → 驱动 → 各节 evidence
        guard case .evidenceFold(let notes) = content.nodes[4] else {
            return XCTFail("末节点应为据折叠,实际:\(content.nodes[4])")
        }
        XCTAssertEqual(notes.count, 6)
        XCTAssertEqual(notes[0].label, "主线")
        XCTAssertEqual(notes[0].text, "主导 七杀、劫财(并列最重) · 次要 正印 · 潜伏 伤官、偏财")
        XCTAssertEqual(notes[1].label, "核心循环")
        XCTAssertEqual(notes[1].text, "起点 七杀　终点 正印")
        XCTAssertEqual(notes[2].label, "驱动")
        XCTAssertEqual(notes[3].label, "主线", "evidence 段开始")
        XCTAssertEqual(notes[4].label, "核心循环")
        XCTAssertEqual(notes[5].label, "能力来源")
    }

    func test_m0_v9FingerprintHidden() {
        // D6:v9 不展示 structure_fingerprint(仍产出,下游链式照常继承);
        // v7 的运转概括引言段由既有 test_m0_moduleAssemblesInlineLabels 锁定
        guard let content = ChapterContent.parse(Self.m0V9JSON, for: .m0) else {
            return XCTFail("v9 形态应特化解析成功")
        }
        XCTAssertFalse(content.nodes.contains { node in
            if case .lead(let s) = node { return s.contains("承压") }
            return false
        }, "v9 顶层不得出现运转概括引言段")
    }

    func test_m0_v9MissingSectionHeadlineStillRendersSection() {
        // 某节缺 headline:该节照常渲染其余字段,不丢内容(plan S3-5)
        let json = """
        {
          "main_axis": { "headline": "压力推着你走。", "body": "主导是七杀,也就是外部压力。" },
          "core_loop": { "from": "七杀", "to": "正印", "flow": "压力被吸收为方法。" },
          "capability_source": { "text": "你最强的时刻,是硬需求递到手上的时候。" }
        }
        """
        guard let content = ChapterContent.parse(json, for: .m0) else {
            return XCTFail("缺 headline 的 v9 形态(main_axis 有 headline)仍应特化")
        }
        guard content.nodes.count > 1,
              case .section("核心循环", let loopChildren) = content.nodes[1] else {
            return XCTFail("核心循环节应在,实际:\(content.nodes)")
        }
        XCTAssertTrue(loopChildren.contains {
            if case .lead(let s) = $0 { return s.contains("压力被吸收") }
            return false
        }, "flow 不得因缺 headline 丢失")
        guard content.nodes.count > 2,
              case .section("能力来源", let capChildren) = content.nodes[2] else {
            return XCTFail("能力来源节应在")
        }
        XCTAssertTrue(capChildren.contains {
            if case .lead(let s) = $0 { return s.contains("硬需求") }
            return false
        }, "text 不得因缺 headline 丢失")
        // 起止行仍进据 fold
        guard case .evidenceFold(let notes)? = content.nodes.last else {
            return XCTFail("据折叠应在")
        }
        XCTAssertTrue(notes.contains { $0.text.contains("起点 七杀") })
    }

    func test_m0_v9PartialLayersKeptInFoldLine() {
        // 分层行:缺的层跳过,不写「主导 —」占位
        let json = """
        {
          "main_axis": { "headline": "机会推着你走。", "secondary": "食神", "latent": "比肩" },
          "core_loop": { "headline": "看见 → 做出 → 再看。" }
        }
        """
        guard let content = ChapterContent.parse(json, for: .m0),
              case .evidenceFold(let notes)? = content.nodes.last else {
            return XCTFail("应解析出据折叠")
        }
        XCTAssertEqual(notes.first?.text, "次要 食神 · 潜伏 比肩", "缺 dominant 不占位")
    }

    func test_m0_v9ExtraKeysNotSilentlyDropped() {
        // v9 兜底口径与 v7 相同:未消费键走通用节点(内容不丢)
        let json = """
        {
          "main_axis": {
            "headline": "压力推着你走。",
            "body": "主导是七杀,也就是外部压力。",
            "extra_note": "schema 外的键"
          },
          "core_loop": { "headline": "扛压 → 沉淀。" }
        }
        """
        guard let content = ChapterContent.parse(json, for: .m0),
              case .section("主线", let mainChildren)? = content.nodes.first else {
            return XCTFail("v9 应解析成功")
        }
        XCTAssertTrue(mainChildren.contains {
            if case .lead(let s) = $0 { return s == "schema 外的键" }
            return false
        }, "schema 外的键应走通用引言段渲染(v7 同款兜底),不静默丢")
    }

    // MARK: - 段落拆分与结论句章判定(A′ 2026-10-21,plan
    // docs/命书阅读页段落排版A′-plan.md S1)

    func test_leadParagraphs_splitsOnAllNewlineForms() {
        // \n\n / \n / 首尾空行混合:非空行各成一段,空行忽略
        XCTAssertEqual(
            ChapterContent.leadParagraphs("\n第一段。\n\n第二段:代价。\n第三段:怎么做。\n\n"),
            ["第一段。", "第二段:代价。", "第三段:怎么做。"])
        // CRLF 也按换行拆(行尾 \r 随空白裁掉)
        XCTAssertEqual(
            ChapterContent.leadParagraphs("段一\r\n\r\n段二"),
            ["段一", "段二"])
        // 单段无换行:原样一段
        XCTAssertEqual(ChapterContent.leadParagraphs("只有一段。"), ["只有一段。"])
    }

    func test_leadParagraphs_neverEmitsIndentPrefixOrEmptyGap() {
        // A′ 起正文不再有全角空格首行缩进(段与段靠间距分层);连续空行
        // 不产生额外空隙(空段全部过滤);全空白文本 → 空数组
        let paragraphs = ChapterContent.leadParagraphs("  段一  \n \n\n段二\n\t\n")
        XCTAssertEqual(paragraphs, ["段一", "段二"])
        XCTAssertFalse(paragraphs.contains { $0.hasPrefix("　　") },
                       "不得出现全角空格首行缩进前缀")
        XCTAssertEqual(ChapterContent.leadParagraphs("  \n\n \n\t"), [])
    }

    func test_containsHeadline_falseForV7Cache_trueForV9() {
        // A′ 小节小标/结论句 21pt/节间距 44 都只随「章内含 .headline」启用;
        // v7/v8 老缓存(无 headline)containsHeadline=false → 渲染树与
        // 间距口径(28/20pt 小节题)逐字不变
        let v7 = """
        {
          "main_axis": { "dominant": "七杀", "secondary": "正印", "latent": "伤官",
            "evidence": "七杀 6" },
          "core_loop": { "from": "七杀", "to": "正印", "flow": "压力被吸收为方法",
            "driver": "日主庚金偏旺", "leak": "输出通道窄", "evidence": "水透出计数为 0" }
        }
        """
        guard let v7Content = ChapterContent.parse(v7, for: .m0) else {
            return XCTFail("v7 老缓存形态应解析成功")
        }
        XCTAssertFalse(v7Content.containsHeadline,
                       "v7/v8 无 headline → 小节样式与节间距照旧")

        guard let v9Content = ChapterContent.parse(Self.m0V9JSON, for: .m0) else {
            return XCTFail("v9 形态应解析成功")
        }
        XCTAssertTrue(v9Content.containsHeadline,
                      "v9+ 含结论句(headline 是小节子节点,须递归命中)")
    }
}
