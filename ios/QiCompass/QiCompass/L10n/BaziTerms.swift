import Foundation

/// L3 命盘术语三语表(展示层语言交接 U3,事实源 `i18n-display-layer-handoff.md` §3/§5)。
///
/// 定位:排盘响应的中文术语是**稳定术语 id**(决策 B:不给排盘端点接
/// Accept-Language,`contentHash` 与「同一输入同一输出」硬约束不破),本表按
/// `AppLanguage.current` 在**展示层**取显示值——这正是 i18n 决策 1 原文
/// 「API Response 显式返回对应语言 + 术语 id」中 id 那半边的实现。
///
/// 键集合与后端 `backend/app/engine/term_translations.py` 逐字对齐
/// (十神 11 含「偏官/七杀」同义 / 五行 5 / 纳音 30 / 长生 12 / 旺衰 6 /
/// 神煞 20 + 干支 22 供转写),由 `tools/check_term_sync.py` 强制同步;
/// 神煞 en 译名按 handoff §5 提案,**待用户术语 QA 终审(U6 HITL),勿静默改词**。
///
/// 显式注册哲学(对齐后端 TERM_TRANSLATIONS):zh 列显式写出(不做「缺失即原文」
/// 静默透传);查不到的 key 显式回落原值并留日志(不崩、不静默吞)。
///
/// 干支(§3 决策矩阵):三语均**汉字为主**——汉字是「专业不忽悠」卖点;en 额外
/// 提供 `romanized(_:)` 带调拼音小字,只在 chip 主标与首次出现处由调用方加。
enum BaziTerms {
    /// 单条术语:zh = 稳定 id(与后端键逐字相等)/ zhHant / en 显示值。
    struct Term: Sendable, Equatable {
        let zh: String
        let zhHant: String
        let en: String
    }

    // MARK: - 天干(10;三语汉字为主,拉丁转写见 romanization)

    static let heavenlyStems: [Term] = [
        .init(zh: "甲", zhHant: "甲", en: "甲"),
        .init(zh: "乙", zhHant: "乙", en: "乙"),
        .init(zh: "丙", zhHant: "丙", en: "丙"),
        .init(zh: "丁", zhHant: "丁", en: "丁"),
        .init(zh: "戊", zhHant: "戊", en: "戊"),
        .init(zh: "己", zhHant: "己", en: "己"),
        .init(zh: "庚", zhHant: "庚", en: "庚"),
        .init(zh: "辛", zhHant: "辛", en: "辛"),
        .init(zh: "壬", zhHant: "壬", en: "壬"),
        .init(zh: "癸", zhHant: "癸", en: "癸"),
    ]

    // MARK: - 地支(12;三语汉字为主,拉丁转写见 romanization)

    static let earthlyBranches: [Term] = [
        .init(zh: "子", zhHant: "子", en: "子"),
        .init(zh: "丑", zhHant: "丑", en: "丑"),
        .init(zh: "寅", zhHant: "寅", en: "寅"),
        .init(zh: "卯", zhHant: "卯", en: "卯"),
        .init(zh: "辰", zhHant: "辰", en: "辰"),
        .init(zh: "巳", zhHant: "巳", en: "巳"),
        .init(zh: "午", zhHant: "午", en: "午"),
        .init(zh: "未", zhHant: "未", en: "未"),
        .init(zh: "申", zhHant: "申", en: "申"),
        .init(zh: "酉", zhHant: "酉", en: "酉"),
        .init(zh: "戌", zhHant: "戌", en: "戌"),
        .init(zh: "亥", zhHant: "亥", en: "亥"),
    ]

    // MARK: - 五行(5;en 意译,对齐后端 FIVE_ELEMENTS_EN)

    static let fiveElements: [Term] = [
        .init(zh: "木", zhHant: "木", en: "Wood"),
        .init(zh: "火", zhHant: "火", en: "Fire"),
        .init(zh: "土", zhHant: "土", en: "Earth"),
        .init(zh: "金", zhHant: "金", en: "Metal"),
        .init(zh: "水", zhHant: "水", en: "Water"),
    ]

    // MARK: - 十神(11 含偏官/七杀同义;en 对齐后端 TEN_GODS_EN,Joey Yap 体系。
    // 劫财例外:2026-09-29 拍板弃直译「Rob Wealth」改「Wealth Rival」,后端同步)

    static let tenGods: [Term] = [
        .init(zh: "比肩", zhHant: "比肩", en: "Companion"),
        .init(zh: "劫财", zhHant: "劫財", en: "Wealth Rival"),
        .init(zh: "食神", zhHant: "食神", en: "Eating God"),
        .init(zh: "伤官", zhHant: "傷官", en: "Hurting Officer"),
        .init(zh: "偏财", zhHant: "偏財", en: "Indirect Wealth"),
        .init(zh: "正财", zhHant: "正財", en: "Direct Wealth"),
        .init(zh: "正官", zhHant: "正官", en: "Direct Officer"),
        .init(zh: "七杀", zhHant: "七殺", en: "Seven Killings"),
        .init(zh: "偏官", zhHant: "偏官", en: "Seven Killings"),
        .init(zh: "正印", zhHant: "正印", en: "Direct Resource"),
        .init(zh: "偏印", zhHant: "偏印", en: "Indirect Resource"),
    ]

    // MARK: - 日主(对齐后端 MISC_TERMS_EN;日柱十神位显示)

    static let misc: [Term] = [
        .init(zh: "日主", zhHant: "日主", en: "Day Master"),
    ]

    // MARK: - 神煞(20 = 11 吉 + 9 凶;键序对齐后端 shensha.py SHENSHA_NAMES,
    // en 对齐 SHENSHA_EN——译名提案待用户终审,勿改词)

    static let shensha: [Term] = [
        // 吉神 11
        .init(zh: "天乙贵人", zhHant: "天乙貴人", en: "Nobleman"),
        .init(zh: "太极贵人", zhHant: "太極貴人", en: "Supreme Nobleman"),
        .init(zh: "文昌", zhHant: "文昌", en: "Academic Star"),
        .init(zh: "天德", zhHant: "天德", en: "Heavenly Virtue"),
        .init(zh: "月德", zhHant: "月德", en: "Monthly Virtue"),
        .init(zh: "驿马", zhHant: "驛馬", en: "Travelling Horse"),
        .init(zh: "桃花", zhHant: "桃花", en: "Peach Blossom"),
        .init(zh: "将星", zhHant: "將星", en: "General Star"),
        .init(zh: "华盖", zhHant: "華蓋", en: "Canopy Star"),
        .init(zh: "金舆", zhHant: "金輿", en: "Golden Carriage"),
        .init(zh: "禄神", zhHant: "祿神", en: "Prosperity Star"),
        // 凶煞 9
        .init(zh: "羊刃", zhHant: "羊刃", en: "Goat Blade"),
        .init(zh: "劫煞", zhHant: "劫煞", en: "Robbery Star"),
        .init(zh: "亡神", zhHant: "亡神", en: "Loss Spirit"),
        .init(zh: "孤辰", zhHant: "孤辰", en: "Solitary Star"),
        .init(zh: "寡宿", zhHant: "寡宿", en: "Widowhood Star"),
        .init(zh: "元辰", zhHant: "元辰", en: "Grievance Star"),
        .init(zh: "灾煞", zhHant: "災煞", en: "Calamity Star"),
        .init(zh: "天罗地网", zhHant: "天羅地網", en: "Heaven Net, Earth Snare"),
        .init(zh: "红艳", zhHant: "紅艷", en: "Red Beauty"),
    ]

    // MARK: - 纳音(30;en 对齐后端 NAYIN_EN,组合式意译)

    static let nayin: [Term] = [
        .init(zh: "海中金", zhHant: "海中金", en: "Sea Metal"),
        .init(zh: "炉中火", zhHant: "爐中火", en: "Furnace Fire"),
        .init(zh: "大林木", zhHant: "大林木", en: "Great Forest Wood"),
        .init(zh: "路旁土", zhHant: "路旁土", en: "Roadside Earth"),
        .init(zh: "剑锋金", zhHant: "劍鋒金", en: "Sword Metal"),
        .init(zh: "山头火", zhHant: "山頭火", en: "Mountain-Top Fire"),
        .init(zh: "涧下水", zhHant: "澗下水", en: "Stream Water"),
        .init(zh: "城头土", zhHant: "城頭土", en: "Rampart Earth"),
        .init(zh: "白蜡金", zhHant: "白蠟金", en: "White Wax Metal"),
        .init(zh: "杨柳木", zhHant: "楊柳木", en: "Willow Wood"),
        .init(zh: "泉中水", zhHant: "泉中水", en: "Spring Water"),
        .init(zh: "屋上土", zhHant: "屋上土", en: "Rooftop Earth"),
        .init(zh: "霹雳火", zhHant: "霹靂火", en: "Thunderbolt Fire"),
        .init(zh: "松柏木", zhHant: "松柏木", en: "Pine-Cypress Wood"),
        .init(zh: "长流水", zhHant: "長流水", en: "Long-Running Water"),
        .init(zh: "沙中金", zhHant: "沙中金", en: "Sand Metal"),
        .init(zh: "山下火", zhHant: "山下火", en: "Foothill Fire"),
        .init(zh: "平地木", zhHant: "平地木", en: "Plains Wood"),
        .init(zh: "壁上土", zhHant: "壁上土", en: "Wall Earth"),
        .init(zh: "金箔金", zhHant: "金箔金", en: "Gold-Leaf Metal"),
        .init(zh: "覆灯火", zhHant: "覆燈火", en: "Lantern Fire"),
        .init(zh: "天河水", zhHant: "天河水", en: "Heavenly River Water"),
        .init(zh: "大驿土", zhHant: "大驛土", en: "Post-Road Earth"),
        .init(zh: "钗钏金", zhHant: "釵釧金", en: "Hairpin Metal"),
        .init(zh: "桑柘木", zhHant: "桑柘木", en: "Mulberry Wood"),
        .init(zh: "大溪水", zhHant: "大溪水", en: "Great Stream Water"),
        .init(zh: "沙中土", zhHant: "沙中土", en: "Sand Earth"),
        .init(zh: "天上火", zhHant: "天上火", en: "Sky Fire"),
        .init(zh: "石榴木", zhHant: "石榴木", en: "Pomegranate Wood"),
        .init(zh: "大海水", zhHant: "大海水", en: "Great Sea Water"),
    ]

    // MARK: - 十二长生(12;en 对齐后端 TWELVE_STAGES_EN)

    static let twelveStages: [Term] = [
        .init(zh: "长生", zhHant: "長生", en: "Growth"),
        .init(zh: "沐浴", zhHant: "沐浴", en: "Bathing"),
        .init(zh: "冠带", zhHant: "冠帶", en: "Crowning"),
        .init(zh: "临官", zhHant: "臨官", en: "Officer"),
        .init(zh: "帝旺", zhHant: "帝旺", en: "Emperor"),
        .init(zh: "衰", zhHant: "衰", en: "Decline"),
        .init(zh: "病", zhHant: "病", en: "Sickness"),
        .init(zh: "死", zhHant: "死", en: "Death"),
        .init(zh: "墓", zhHant: "墓", en: "Grave"),
        .init(zh: "绝", zhHant: "絕", en: "Extinction"),
        .init(zh: "胎", zhHant: "胎", en: "Womb"),
        .init(zh: "养", zhHant: "養", en: "Nurture"),
    ]

    // MARK: - 旺衰标签(两套 zh 词汇并蓄:UI 词汇 身强/身弱/中和/从格 +
    // chart 词汇 偏旺/偏弱/从格特征/时辰未知/未判定,后者键集合与后端
    // STRENGTH_LABEL_ZH_EN 对齐,由 check_term_sync.py 比对)

    static let strengthLabels: [Term] = [
        // UI 词汇(hero 旁注 / 喜忌节小注,由 raw key 映射而来)
        .init(zh: "身强", zhHant: "身強", en: "Strong"),
        .init(zh: "身弱", zhHant: "身弱", en: "Weak"),
        .init(zh: "中和", zhHant: "中和", en: "Balanced"),
        .init(zh: "从格", zhHant: "從格", en: "Special Pattern"),
        // chart 词汇(v1 chart strength_label / XijiCard 特征)
        .init(zh: "偏旺", zhHant: "偏旺", en: "Slightly Strong"),
        .init(zh: "偏弱", zhHant: "偏弱", en: "Slightly Weak"),
        .init(zh: "从格特征", zhHant: "從格特徵", en: "Special Pattern"),
        .init(zh: "时辰未知", zhHant: "時辰未知", en: "Hour Unknown"),
        .init(zh: "未判定", zhHant: "未判定", en: "Undetermined"),
        // 从格检测 D3 的两个亚型提示之一(专旺;另一亚型 从格 已在 UI 词汇)
        .init(zh: "专旺", zhHant: "專旺", en: "Dominant Structure"),
    ]

    // MARK: - 柱位标签(神煞 position 值;键集合对齐后端 shensha.py _PILLAR_LABELS)

    static let pillarPositions: [Term] = [
        .init(zh: "年柱", zhHant: "年柱", en: "Year Pillar"),
        .init(zh: "月柱", zhHant: "月柱", en: "Month Pillar"),
        .init(zh: "日柱", zhHant: "日柱", en: "Day Pillar"),
        .init(zh: "时柱", zhHant: "時柱", en: "Hour Pillar"),
    ]

    // MARK: - 喜忌算法标注(XijiCard;值域事实源 backend/app/engine/xiji.py,
    // 4 个字面值,en 为工程译名——算法名非神煞名,不在 §5 终审清单内)

    static let xijiMethods: [Term] = [
        .init(zh: "扶抑+调候", zhHant: "扶抑+調候",
              en: "Day-master balance + seasonal adjustment"),
        .init(zh: "扶抑+调候(中和)", zhHant: "扶抑+調候(中和)",
              en: "Day-master balance + seasonal adjustment (balanced)"),
        .init(zh: "扶抑+调候(从格特征检测命中,未判定具体格局)",
              zhHant: "扶抑+調候(從格特徵檢測命中,未判定具體格局)",
              en: "Day-master balance + seasonal adjustment (special-pattern check triggered; specific pattern undetermined)"),
        .init(zh: "时辰未知,喜忌未计算(需补时辰)", zhHant: "時辰未知,喜忌未計算(需補時辰)",
              en: "Birth hour unknown — favorable elements not computed (add your birth hour)"),
    ]

    // MARK: - 合盘定性枚举 + context 标签(22;键集合与 en 值对齐后端
    // COMPAT_TERMS_EN——AssessmentCardGrid 评估值 / DualPillarsTable 等展示消费)

    static let compatTerms: [Term] = [
        // five_elements_assessment
        .init(zh: "互补佳", zhHant: "互補佳", en: "Strongly complementary"),
        .init(zh: "有一定互补", zhHant: "有一定互補", en: "Somewhat complementary"),
        .init(zh: "互补较弱", zhHant: "互補較弱", en: "Weakly complementary"),
        .init(zh: "信息不足", zhHant: "信息不足", en: "Insufficient data"),
        // day_master_relation
        .init(zh: "同气", zhHant: "同氣", en: "Same element"),
        .init(zh: "相生", zhHant: "相生", en: "Generating cycle"),
        .init(zh: "相克", zhHant: "相剋", en: "Controlling cycle"),
        // zodiac_match
        .init(zh: "六合", zhHant: "六合", en: "Six Harmony"),
        .init(zh: "三合", zhHant: "三合", en: "Three Harmony"),
        .init(zh: "六冲", zhHant: "六沖", en: "Six Clash"),
        .init(zh: "三刑", zhHant: "三刑", en: "Three Punishment"),
        .init(zh: "相害", zhHant: "相害", en: "Harm"),
        .init(zh: "无特殊合冲", zhHant: "無特殊合沖", en: "No notable harmony or clash"),
        // branch_harmony
        .init(zh: "无冲无刑", zhHant: "無沖無刑", en: "No clash, no punishment"),
        .init(zh: "一冲一合", zhHant: "一沖一合", en: "One clash, one harmony"),
        .init(zh: "多冲少合", zhHant: "多沖少合", en: "More clashes than harmonies"),
        .init(zh: "多合少冲", zhHant: "多合少沖", en: "More harmonies than clashes"),
        .init(zh: "多刑多害", zhHant: "多刑多害", en: "Multiple punishments and harms"),
        .init(zh: "略有冲刑害", zhHant: "略有沖刑害", en: "Slight clash / punishment / harm"),
        // context_label(小写:en 句内联)
        .init(zh: "通用", zhHant: "通用", en: "general"),
        .init(zh: "婚姻", zhHant: "婚姻", en: "marriage"),
        .init(zh: "事业", zhHant: "事業", en: "career"),
    ]

    // MARK: - 干支拉丁转写(带调拼音,首字母大写;§3:只在 chip 主标/首次出现加)

    static let romanization: [String: String] = [
        "甲": "Jiǎ", "乙": "Yǐ", "丙": "Bǐng", "丁": "Dīng",
        "戊": "Wù", "己": "Jǐ", "庚": "Gēng", "辛": "Xīn",
        "壬": "Rén", "癸": "Guǐ",
        "子": "Zǐ", "丑": "Chǒu", "寅": "Yín", "卯": "Mǎo",
        "辰": "Chén", "巳": "Sì", "午": "Wǔ", "未": "Wèi",
        "申": "Shēn", "酉": "Yǒu", "戌": "Xū", "亥": "Hài",
    ]

    // MARK: - 查表

    /// 全表融合索引(zh id → 条目)。表间键冲突属实现错误,由 BaziTermsTests 断言。
    static let index: [String: Term] = {
        var merged: [String: Term] = [:]
        for table in [heavenlyStems, earthlyBranches, fiveElements, tenGods, misc,
                      shensha, nayin, twelveStages, strengthLabels,
                      pillarPositions, xijiMethods, compatTerms] {
            for term in table {
                merged[term.zh] = term
            }
        }
        return merged
    }()

    /// 术语显示值(统一入口)。
    ///
    /// - zh → 原值(显式 identity:表内注册,非静默透传)
    /// - zh-hant → 繁体显示值
    /// - en → 英文显示值(干支仍为汉字,§3 决策;辅助转写另走 `romanized`)
    /// - 未注册 key → 显式回落原值 + 日志(不崩、不静默吞;值域缺口可据此扩表,
    ///   对齐后端 translate_term 的显式失败哲学,展示层降级为留痕回落)
    ///
    /// `language` 显式参数供测试断言(不依赖设备语言,2026-09-23 假红教训),
    /// 生产调用方走默认 `.current` 零改动。
    static func display(_ term: String, language: AppLanguage = AppLanguage.current) -> String {
        guard let entry = index[term] else {
            AppLogger.app.warning(
                "op=baziTerms.miss term=\(term, privacy: .public) -> raw(展示层回落原值,值域缺口可据此扩表)"
            )
            return term
        }
        switch language {
        case .zh: return entry.zh
        case .zhHant: return entry.zhHant
        case .en: return entry.en
        }
    }

    /// 神煞 chip 主标(§3:en = 意译 + 汉字括注 `Nobleman (天乙貴人)`;
    /// 括注只在 chip 主标/首次出现给,正文内不重复)。
    static func shenshaChipText(_ name: String, language: AppLanguage = AppLanguage.current) -> String {
        guard let entry = shensha.first(where: { $0.zh == name }) else {
            AppLogger.app.warning(
                "op=baziTerms.shenshaMiss name=\(name, privacy: .public) -> raw"
            )
            return name
        }
        switch language {
        case .zh: return entry.zh
        case .zhHant: return entry.zhHant
        case .en: return "\(entry.en) (\(entry.zhHant))"
        }
    }

    /// 干支串拉丁转写(带调拼音):"甲子" → "Jiǎ Zǐ",单字 "甲" → "Jiǎ"。
    /// 串内任一字符不在 22 干支表 → 返回 nil(调用方自行决定是否省略小字,
    /// 不静默输出半译串)。
    static func romanized(_ ganzhi: String) -> String? {
        let syllables = ganzhi.map { romanization[String($0)] }
        guard !syllables.isEmpty, syllables.allSatisfy({ $0 != nil }) else { return nil }
        return syllables.compactMap { $0 }.joined(separator: " ")
    }
}
