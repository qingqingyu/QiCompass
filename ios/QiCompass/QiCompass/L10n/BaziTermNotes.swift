import SwiftUI

// MARK: - 共享术语释义层(S5,2026-09-30 BP 评审 R9/R10)
//
// 专业术语的"一句人话",三语,第二人称,不带吉凶——所有"点术语出释义"的
// 挂载点(深度解析 hero 四柱十神/旺衰、PillarsTable 十神、合盘中轴日主关系)
// 共用本表,不再各写各的。
//
// 与今日页 HeroShiShenNotes 的分层:那一张是「今日宜…留意…」的每日口径
//(内容属每日运势);本表是术语的通用定义,是唯一事实源。UI 静态文案层
// 立即执行"术语 + 一句人话"(设计文档 §AI Voice 语言层级,2026-09-30 修订)。
//
// 值域:key 用 zh 稳定 id(与 BaziTerms 同 key 空间的子集);偏官 = 七杀同义
// 别名(对齐 BaziTerms.tenGods 11 键 10 义)。查不到 → nil,调用方不挂释义
// 入口(与 HeroShiShenNotes 的"回落通用文案"不同:通用词表宁缺毋滥,
// 未收录的术语不硬编一条)。

enum BaziTermNotes {
    /// 释义条目(zh key → 三语一句话)。
    struct Entry: Sendable, Equatable {
        let zh: String
        let zhHant: String
        let en: String
    }

    static let entries: [String: Entry] = [
        // -- 十神(11 键 10 义;偏官=七杀别名) --
        "比肩": .init(
            zh: "与你同气的力量:独立自主,也容易各持己见。",
            zhHant: "與你同氣的力量:獨立自主,也容易各持己見。",
            en: "Energy like yours — self-reliant, and apt to hold your own line."
        ),
        "劫财": .init(
            zh: "同辈之间的分与争:行动力旺,钱财易有拉扯。",
            zhHant: "同輩之間的分與爭:行動力旺,錢財易有拉扯。",
            en: "Sharing and competing among peers — drive runs high, money gets tangled."
        ),
        "食神": .init(
            zh: "从容的产出与享受:会表达,也懂生活。",
            zhHant: "從容的產出與享受:會表達,也懂生活。",
            en: "Easy output and enjoyment — you express well and know how to live."
        ),
        "伤官": .init(
            zh: "表达欲强、不爱守旧规,才华外露也容易顶撞。",
            zhHant: "表達欲強、不愛守舊規,才華外露也容易頂撞。",
            en: "Your drive to express and challenge the rules — sharp talent, sharp edges."
        ),
        "偏财": .init(
            zh: "流动的机会之财:来得快,去得也快。",
            zhHant: "流動的機會之財:來得快,去得也快。",
            en: "Opportunity money on the move — quick in, quick out."
        ),
        "正财": .init(
            zh: "踏实挣来的稳财:务实,重信用。",
            zhHant: "踏實掙來的穩財:務實,重信用。",
            en: "Money earned steady and square — practical, true to your word."
        ),
        "七杀": .init(
            zh: "外来的压力与魄力,逼你当机立断。",
            zhHant: "外來的壓力與魄力,逼你當機立斷。",
            en: "Pressure from outside that pushes you to act decisively."
        ),
        "偏官": .init(
            zh: "外来的压力与魄力,逼你当机立断。",
            zhHant: "外來的壓力與魄力,逼你當機立斷。",
            en: "Pressure from outside that pushes you to act decisively."
        ),
        "正官": .init(
            zh: "规矩、职位与责任:守约,也被约束。",
            zhHant: "規矩、職位與責任:守約,也被約束。",
            en: "Rules, roles and duty — you keep order, and order keeps you."
        ),
        "偏印": .init(
            zh: "直觉与另类的学法:想得深,易多虑。",
            zhHant: "直覺與另類的學法:想得深,易多慮。",
            en: "Instinct and unorthodox learning — deep thought, prone to doubt."
        ),
        "正印": .init(
            zh: "滋养你的学识与庇护:吸收力强,易依赖。",
            zhHant: "滋養你的學識與庇護:吸收力強,易依賴。",
            en: "Nourishment from learning and shelter — you absorb well, and can lean too much."
        ),
        // -- 日主 --
        "日主": .init(
            zh: "你命盘的核心:出生那天的天干,代表你自己。",
            zhHant: "你命盤的核心:出生那天的天干,代表你自己。",
            en: "The core of your chart — the stem of your birth day, standing for you."
        ),
        // -- 旺衰(5 态) --
        "身强": .init(
            zh: "日主力量充足,更需要出口而不是助力。",
            zhHant: "日主力量充足,更需要出口而不是助力。",
            en: "Your core element is well supported — it needs outlets more than help."
        ),
        "身弱": .init(
            zh: "日主力量偏弱,先补给自己,再谈冲刺。",
            zhHant: "日主力量偏弱,先補給自己,再談衝刺。",
            en: "Your core element runs light — refill first, sprint later."
        ),
        "中和": .init(
            zh: "日主力量均衡,节奏稳,进退都有余地。",
            zhHant: "日主力量均衡,節奏穩,進退都有餘地。",
            en: "Your core element sits balanced — steady rhythm, room to move."
        ),
        "从格": .init(
            zh: "命局能量偏于一侧,顺势而为胜过硬拉平衡。",
            zhHant: "命局能量偏於一側,順勢而為勝過硬拉平衡。",
            en: "The chart leans hard one way — going with it beats forcing balance."
        ),
        "专旺": .init(
            zh: "命局几乎一气独旺,顺势是唯一解。",
            zhHant: "命局幾乎一氣獨旺,順勢是唯一解。",
            en: "One element runs the whole chart — following it is the move."
        ),
        // -- 五行关系(合盘中轴 3 值) --
        "相生": .init(
            zh: "一方滋养另一方,能量的给予。",
            zhHant: "一方滋養另一方,能量的給予。",
            en: "One element feeds the other — energy given."
        ),
        "相克": .init(
            zh: "一方制约另一方,能量的摩擦。",
            zhHant: "一方制約另一方,能量的摩擦。",
            en: "One element checks the other — energy in friction."
        ),
        "同气": .init(
            zh: "同一五行,节奏一致,像彼此的镜子。",
            zhHant: "同一五行,節奏一致,像彼此的鏡子。",
            en: "The same element — same rhythm, mirror temperaments."
        ),
        // -- 喜忌(2) --
        "喜用": .init(
            zh: "对命局平衡有帮助的五行方向。",
            zhHant: "對命局平衡有幫助的五行方向。",
            en: "Elements that help this chart stay balanced."
        ),
        "忌神": .init(
            zh: "对命局平衡不利的五行方向,不是生活禁忌。",
            zhHant: "對命局平衡不利的五行方向,不是生活禁忌。",
            en: "Elements that tilt this chart off balance — not things to avoid in life."
        ),
    ]

    /// 释义查询。未收录 → nil(调用方不挂入口;宁缺毋滥,不硬编)。
    /// `language` 显式参数供测试断言(不依赖设备语言),生产调用走默认 `.current`。
    static func note(for term: String, language: AppLanguage = AppLanguage.current) -> String? {
        guard let entry = entries[term] else { return nil }
        switch language {
        case .zh: return entry.zh
        case .zhHant: return entry.zhHant
        case .en: return entry.en
        }
    }
}

// MARK: - 释义 sheet 请求(挂载点 @State 载体)

/// `.sheet(item:)` 的请求值:被点的术语 zh key。
struct TermNoteRequest: Identifiable {
    let term: String
    var id: String { term }
}

// MARK: - 术语释义卡(S5)

/// 术语点开的释义卡:术语标题(楷体 display)+ 一句白话(楷体 body)。
/// 结构对齐今日页 HeroShiShenNoteSheet 先例(2026-09-29 D3):
/// EN 标题附汉字括注(「意译 (漢字)」先例);detents 250 起步可拉大
/// (AX 大字号下正文可完整展开);presentationBackground 纸色由调用侧注入。
struct BaziTermNoteSheet: View {
    /// zh 稳定 key(调用方由 BaziTermNotes.note 判存在后才挂入口,
    /// sheet 内再查一次属防御,查不到显式示「暂无释义」不 crash)。
    let term: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: titleText)
                .font(BaziFont.display(size: 21, weight: .medium))
                .foregroundStyle(BaziTheme.ink)
            Text(verbatim: BaziTermNotes.note(for: term) ?? String(localized: "暂无释义"))
                .font(BaziFont.body(size: 15))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 26)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    /// 标题:en → 「意译 (漢字)」;zh/zh-Hant → BaziTerms 显示值。
    private var titleText: String {
        if AppLanguage.current == .en, let entry = BaziTerms.index[term] {
            return "\(entry.en) (\(entry.zhHant))"
        }
        return BaziTerms.display(term)
    }
}
