import SwiftUI

/// 命盘头部(2026-10-14 仿盘面细目 HTML 目标稿三行重构):
/// ① tags 行(乾造(男) / 癸酉年·属鸡 chip)② 大字出生日期+时刻 ③ meta 行
/// (真太阳时 · 出生地 · 较钟表时间 ±x 分 + ⓘ 排盘口径说明入口,T3)。
///
/// hash 行移除(开发痕迹不进用户界面,2026-10-14 用户拍板);旧版首行右侧
/// 挤着的「真太阳时偏差」与带前缀的独立行收进 meta 单行;与四柱节标旁的
/// 重复展示由 ChartDetailView 侧删除(时间地点信息单一展示点 = 本 header)。
/// boundaryWarning 旧渲染仅老 payload 保留(T2:新字段 clock_time_pillars /
/// dst_flags 存在 → 三语对照说明,见 solarNotesSection)。
struct ChartHeaderView: View {
    let response: BaziResponse
    let request: BaziCalculateRequest

    /// T3:排盘口径说明页(ⓘ 入口)。个性化行(T6 农历新年生肖差异)由
    /// T6 接线时传入;本页头只负责呈现。
    @State private var showBasisSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ① tags 行(年柱歧义 → 第二枚 chip 整枚省略,不猜)
            HStack(spacing: 6) {
                // 重写 VoiceOver 文案:括号会让读屏不连贯,去括号空格分隔
                chip(genderLabel).accessibilityLabel(genderLabelVoiceOver)
                if let yearTag {
                    chip(yearTag)
                }
            }

            // ② 大字日期 + 时刻(时辰未知 → 只显日期:12:00 占位时刻禁泄漏,S01)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let dateText {
                    Text(dateText)
                        .font(BaziFont.display(size: 25))
                        .fontWeight(.bold)
                        .foregroundStyle(BaziTheme.ink)
                }
                if let timeText, response.isHourKnown {
                    Text(timeText)
                        .font(BaziFont.display(size: 19))
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }

            // ③ meta 行(真太阳时 nil → 跳过该段,时辰未知不造时间)
            // T3:行末 ⓘ = 排盘口径说明页入口(真太阳时 / 立春换年 / 生肖 vs 日主)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metaLine)
                    .font(BaziFont.caption(size: 13))
                    .foregroundStyle(BaziTheme.inkMuted)
                Button {
                    showBasisSheet = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(BaziFont.caption(size: 13))
                        .foregroundStyle(BaziTheme.inkMuted)
                        // 44pt 最小命中区(HIG,同 DeepAnalysisView 取消钮惯例):
                        // 13pt 图标在密集 meta 行内误触率高。alignment: .leading
                        // 让图标贴住 meta 文本,命中区向右伸入行尾空白,不改视觉
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.ChartBasis.title)
            }

            // T2(2026-11-21 竞品差评对照):新字段(clock_time_pillars / dst_flags)
            // 存在 → 渲染三语对照说明(真太阳时校正是正常行为,不是错误:无 ⚠、
            // 无朱红,DESIGN.md 说明类信息用 inkMuted);柱全同且无 dst 边角 →
            // 零行无事可说。新字段都缺(老 payload,仅内测机)→ 旧 boundaryWarning
            // 渲染原样保留
            if response.clockTimePillars != nil || !response.dstFlags.isEmpty {
                solarNotesSection
            } else if let warning = response.boundaryWarning {
                Text("⚠ \(warning)")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.cinnabar)
                    .padding(BaziTheme.Spacing.sm)
                    .background(BaziTheme.cinnabarSoft, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            }
        }
        // 盘面小景 S1 卸卡:进 ChartDetailView 的 hairline 分节排版
        // (边距由宿主统一 32,这里只留纵向呼吸)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: $showBasisSheet) {
            ChartBasisSheet()
        }
    }

    // MARK: - tags

    /// Capsule chip(Capsule 只留给 chip 的纪律;HTML .tag 同款:卡底+hairline 边)。
    private func chip(_ text: String) -> some View {
        Text(text)
            .font(BaziFont.caption(size: 12))
            .foregroundStyle(BaziTheme.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(BaziTheme.cardSurface, in: Capsule())
            .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
    }

    private var genderLabel: String {
        // 2026-08-13 收拢:与 OnboardingView 共用 ZodiacHelper.genderLabel(单一事实源)
        ZodiacHelper.genderLabel(forGender: request.gender)
    }

    /// VoiceOver 用:去括号,空格分隔,避免读屏读"左括号 男 右括号"不连贯。
    private var genderLabelVoiceOver: String {
        genderLabel
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: "")
    }

    /// 第二枚 chip(T7 三语):zh / zh-Hant「癸酉年 · 属鸡」;en「Wood Ox ·
    /// 乙丑 (Yǐ Chǒu)」(元素+生肖 + 干支拼音括注,不再裸露无元素干支——
    /// 用户再看到别处 "Day Master Water" 会拼成「水牛」,竞品差评对症)。
    /// 年柱干支空(歧义)或生肖未知 → 对应段省略;两段皆无 → 整枚省略
    /// (生肖经 isKnownZodiac 挡住未知值,animalChar 对未知 fatalError 不触发)。
    /// language 显式传参:纯函数可单测(2026-09-23 假红教训)。
    static func yearTagText(
        ganZhi: String?,
        zodiac: String?,
        ganElement: String?,
        language: AppLanguage = AppLanguage.current
    ) -> String? {
        var parts: [String] = []
        let gz = ganZhi ?? ""
        // displayName(forZodiac:) 绑定设备语言,显式 language 纯函数里按分支取
        // (zh=animalChar / zhHant=animalCharHant / en=英文名原值)
        func zodiacName(_ z: String) -> String {
            switch language {
            case .zh: return ZodiacHelper.animalChar(forZodiac: z)
            case .zhHant: return ZodiacHelper.animalCharHant(forZodiac: z)
            case .en: return z
            }
        }
        if case .en = language {
            if let zodiac, ZodiacHelper.isKnownZodiac(zodiac) {
                let name = zodiacName(zodiac)
                // 元素缺失(理论不可达)退裸生肖,与 revealSubLabel 兜底同约定
                parts.append(
                    ZodiacHelper.yearSignLabel(yearGanElement: ganElement, zodiac: name)
                    ?? name)
            }
            if !gz.isEmpty {
                parts.append(Self.ganzhiDisplay(gz, language: language))
            }
        } else {
            if !gz.isEmpty {
                parts.append(String(format: String(localized: "%@年"), gz))
            }
            if let zodiac, ZodiacHelper.isKnownZodiac(zodiac) {
                parts.append(L10n.DeepChart.zodiacTag(zodiacName(zodiac)))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var yearTag: String? {
        Self.yearTagText(
            ganZhi: response.pillars.year?.ganZhi,
            zodiac: response.yearBranchZodiac,
            ganElement: response.pillars.year?.ganElement)
    }

    // MARK: - 大字日期(裸钟面字符串解析,纯函数供单测)

    /// UTC 固定时区(identifier 是编译期常量,失败即运行环境异常)。
    private static let utc = TimeZone(identifier: "UTC")!

    /// 解析 birth_datetime(裸钟面 yyyy-MM-dd'T'HH:mm:ss)→ UTC Date。
    /// **时区锁 UTC**:字符串是出生地钟面值,解析与回显都不做任何时区换算
    /// (换了就会跨日漂移);解析失败 → nil + 日志(调用方不渲染,不猜)。
    static func heroDate(fromBirthDatetime raw: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = Self.utc
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = f.date(from: raw) else {
            AppLogger.app.error("ChartHeaderView.heroDate parse_failed raw=\(raw, privacy: .public)")
            return nil
        }
        return date
    }

    /// 日期大字(locale 感知 dateStyle .long,zh「1993年3月21日」/ en "March 21, 1993";
    /// UTC 锁定保持钟面值不漂移)。locale 显式传参:纯函数可单测,不受测试机
    /// 系统语言左右(2026-09-23 设备语言测试假红教训)。
    static func heroDateText(fromBirthDatetime raw: String, locale: Locale = .current) -> String? {
        guard let date = heroDate(fromBirthDatetime: raw) else { return nil }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = Self.utc
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// 时刻(HH:mm,钟面原值;调用方按 isHourKnown 决定是否展示)。
    static func heroTimeText(fromBirthDatetime raw: String) -> String? {
        guard let date = heroDate(fromBirthDatetime: raw) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.utc
        let comps = cal.dateComponents([.hour, .minute], from: date)
        guard let hour = comps.hour, let minute = comps.minute else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private var dateText: String? {
        Self.heroDateText(fromBirthDatetime: request.birthDatetime)
    }

    private var timeText: String? {
        Self.heroTimeText(fromBirthDatetime: request.birthDatetime)
    }

    // MARK: - meta 行

    /// 真太阳时 · 出生地 · 较钟表时间 ±x 分(中点分隔;真太阳时 nil → 跳过)。
    /// 偏移口径:相对出生地时区中央经线(含夏令时),T3 前文案误写「较北京时间」。
    /// 真太阳时钟面串(纯函数供单测):按**出生地时区**渲染,不随设备时区
    /// 漂移(A1)——真太阳时是出生地当地时间值,跨时区设备(美东手机看北京
    /// 盘)按 .current 渲染会把钟面/日期错位。tzID nil/非法(老快照)兜底
    /// 设备时区(老快照无处回退,维持既有行为)。
    static func trueSolarTimeText(_ date: Date, timezoneID: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = timezoneID.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: date)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let ts = response.trueSolarTime {
            parts.append(L10n.DeepChart.trueSolarTime(
                Self.trueSolarTimeText(ts, timezoneID: response.calcRuleSnapshot.birthTimezone)
            ))
        }
        parts.append(cityDisplay)
        let offset = response.trueSolarOffsetMinutes
        let sign = offset >= 0 ? "+" : ""
        parts.append(L10n.DeepChart.solarOffset(sign: sign, minutes: offset))
        return parts.joined(separator: " · ")
    }

    private var cityDisplay: String {
        // S03:物理真值契约——城市显示名或自定义经度
        request.placeName ?? String(format: String(localized: "自定义经度 %@"), String(request.longitude))
    }

    // MARK: - T2 真太阳时对照说明(2026-11-21 竞品差评对照)

    /// 对照说明区(hairline 竖线 + inkMuted 小字;说明类信息不用 ⚠/朱红/卡片,
    /// DESIGN.md)。notes 在此计算一次,ForEach 只做布局。
    private var solarNotesSection: some View {
        let notes = Self.solarAdjustNotes(response: response)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(notes.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 8) {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(width: 1)
                    Text(notes[i])
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
        }
    }

    /// 钟表时间排盘 vs 真太阳时排盘的逐柱差异 + 夏令时边角说明(纯函数供单测,
    /// language 显式传参不依赖设备语言,2026-09-23 假红教训)。
    ///
    /// - K1:与真太阳时排盘不同的柱,每柱一句(年→月→日→时序)
    /// - K2:日柱不同且日干随之不同 → 追加日主差异句
    /// - K3:dst_flags 逐码一句(a 回拨 / b 跳段 / c 切换点附近)
    /// - 新字段全缺(老 payload)→ 空数组(调用方走旧 boundaryWarning 渲染);
    ///   clock_time_pillars 存在但柱全同 → 空数组(无事可说,不渲染该区)
    static func solarAdjustNotes(
        response: BaziResponse,
        language: AppLanguage = AppLanguage.current
    ) -> [String] {
        let clock = response.clockTimePillars ?? [:]
        guard !clock.isEmpty || !response.dstFlags.isEmpty else { return [] }
        var notes: [String] = []
        let slots: [(key: String, pillar: PillarDTO?, name: String)] = [
            ("year", response.pillars.year, "年柱"),
            ("month", response.pillars.month, "月柱"),
            ("day", response.pillars.day, "日柱"),
            ("hour", response.pillars.hour, "时柱"),
        ]
        for slot in slots {
            guard let clockGZ = clock[slot.key] else { continue }
            guard let main = slot.pillar else {
                // 契约不可达(clock_time_pillars 非 nil ⟹ 后端 hour_known=true 四柱全);
                // 命中即数据不一致,留痕不猜
                AppLogger.app.warning(
                    "ChartHeaderView.solarAdjustNotes pillar_missing pos=\(slot.key, privacy: .public)")
                continue
            }
            guard clockGZ != main.ganZhi else { continue }
            var pillarName = BaziTerms.display(slot.name, language: language)
            if case .en = language { pillarName = pillarName.lowercased() }
            notes.append(L10n.DeepChart.solarNotePillarDiff(
                pillarName,
                clock: Self.ganzhiDisplay(clockGZ, language: language),
                actual: Self.ganzhiDisplay(main.ganZhi, language: language)))
            // K2:日柱差异且日干不同 → 日主也不同(竞品「水牛 vs 木牛」误读的对症句)
            if slot.key == "day", let clockGan = clockGZ.first.map(String.init),
               clockGan != main.gan {
                let mainDM = ZodiacHelper.revealDayMasterDisplay(
                    gan: main.gan, ganElement: main.ganElement, language: language)
                let clockDM = ZodiacHelper.revealDayMasterDisplay(
                    gan: clockGan, ganElement: ElementColors.ofGan(clockGan),
                    language: language)
                if let mainDM, let clockDM {
                    notes.append(L10n.DeepChart.solarNoteDayMasterDiff(mainDM, clock: clockDM))
                } else {
                    // 契约不可达(gan / ganElement 恒为有效值域);命中即数据
                    // 不一致,留痕不猜(与 pillar_missing / unknown_dst_flag 同纪律)
                    AppLogger.app.warning(
                        "ChartHeaderView.solarAdjustNotes day_master_unavailable")
                }
            }
        }
        for flag in response.dstFlags {
            switch flag {
            case "dst_ambiguous": notes.append(L10n.DeepChart.dstAmbiguousNote)
            case "dst_nonexistent": notes.append(L10n.DeepChart.dstNonexistentNote)
            case "dst_transition": notes.append(L10n.DeepChart.dstTransitionNote)
            default:
                // 后端新增码前端未跟进:留痕留白,不猜(展示层显式降级)
                AppLogger.app.warning(
                    "ChartHeaderView.solarAdjustNotes unknown_dst_flag=\(flag, privacy: .public)")
            }
        }
        return notes
    }

    /// 干支展示串:en = 汉字 + 带调拼音括注「乙巳 (Yǐ Sì)」;zh / zh-Hant =
    /// 汉字原值(干支简繁同形,不重复查表)。
    static func ganzhiDisplay(_ gz: String, language: AppLanguage) -> String {
        guard case .en = language, let pinyin = BaziTerms.romanized(gz) else { return gz }
        return "\(gz) (\(pinyin))"
    }
}
