import SwiftUI

/// 命盘头部(2026-10-14 仿盘面细目 HTML 目标稿三行重构):
/// ① tags 行(乾造(男) / 癸酉年·属鸡 chip)② 大字出生日期+时刻 ③ meta 行
/// (真太阳时 · 出生地 · 较北京时间 ±x 分)。
///
/// hash 行移除(开发痕迹不进用户界面,2026-10-14 用户拍板);旧版首行右侧
/// 挤着的「真太阳时偏差」与带前缀的独立行收进 meta 单行;与四柱节标旁的
/// 重复展示由 ChartDetailView 侧删除(时间地点信息单一展示点 = 本 header)。
/// boundaryWarning 展示保留(原样)。
struct ChartHeaderView: View {
    let response: BaziResponse
    let request: BaziCalculateRequest

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
            Text(metaLine)
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.inkMuted)

            if let warning = response.boundaryWarning {
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

    /// 第二枚 chip:「癸酉年 · 属鸡」。年柱干支空(歧义)或生肖未知 → 对应段
    /// 省略;两段皆无 → 整枚省略(生肖经 isKnownZodiac 挡住未知值,
    /// animalChar 对未知 fatalError 不触发)。
    private var yearTag: String? {
        var parts: [String] = []
        let gz = response.pillars.year?.ganZhi ?? ""
        if !gz.isEmpty {
            parts.append(String(format: String(localized: "%@年"), gz))
        }
        if let zodiac = response.yearBranchZodiac, ZodiacHelper.isKnownZodiac(zodiac) {
            parts.append(L10n.DeepChart.zodiacTag(ZodiacHelper.displayName(forZodiac: zodiac)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

    /// 真太阳时 · 出生地 · 较北京时间 ±x 分(中点分隔;真太阳时 nil → 跳过)。
    private var metaLine: String {
        var parts: [String] = []
        if let ts = response.trueSolarTime {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.timeZone = .current
            parts.append(L10n.DeepChart.trueSolarTime(f.string(from: ts)))
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
}
