import SwiftUI

/// hairline 分节容器(盘面小景定稿 ⑩):节标 14.5pt 楷体 + 右侧小注,
/// 上边 hairline 分隔,左右边距 32。替代原九卡的 cardSurface 卡壳——
/// 「改壳不改芯」:内容组件只卸卡,排版进本容器(DESIGN.md 卡片让位 hairline)。
/// 文案与被替换页面同口径中文直出(i18n 开口子随既有 i18n slices)。
private struct HairlineSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(BaziFont.display(size: 14.5))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.ink)
                Spacer(minLength: 12)
                if let trailing {
                    Text(trailing)
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMuted)
                        .lineLimit(1)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, 32)
        }
    }
}

/// 盘面细目页(盘面小景定稿 ⑩,读查分离的「查」):
/// 主页 hero 只留盘面仪式感,全部确定性数据(四柱全表/辅柱/五行/喜忌/神煞/大运/
/// 当前柱)收编到本页 hairline 分节呈现。数据源单一(response + request),纯展示。
struct ChartDetailView: View {
    let response: BaziResponse
    let request: BaziCalculateRequest
    /// 时柱未知留白列点击 → 补时辰 sheet(与主页 hero 时柱空位同一触点,宿主注入)。
    var onAddHour: (() -> Void)? = nil

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 命主信息(无节标,首块不画 hairline)
                    ChartHeaderView(response: response, request: request)
                        .padding(.horizontal, 32)
                        .padding(.top, 8)
                        .padding(.bottom, 4)

                    HairlineSection(title: "四柱", trailing: chartHeaderNote) {
                        PillarsTable(pillars: response.pillars, onAddHour: onAddHour)
                    }

                    HairlineSection(title: "辅柱") {
                        AuxiliaryCards(
                            mingGong: response.mingGong,
                            shenGong: response.shenGong,
                            taiYuan: response.taiYuan
                        )
                    }

                    HairlineSection(title: "五行分布") {
                        ElementBalanceBar(balance: response.elementBalance)
                    }

                    HairlineSection(title: "喜忌分析", trailing: xijiTrailingNote) {
                        XijiCard(response: response)
                    }

                    HairlineSection(title: "神煞") {
                        ShenshaChips(shensha: response.shensha)
                    }

                    HairlineSection(title: "大运") {
                        LuckPillarsTimeline(
                            luckPillars: response.luckPillars,
                            currentLuckPillar: response.currentLuckPillar
                        )
                    }

                    HairlineSection(title: "当前柱") {
                        CurrentStatusCard(response: response)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("盘面细目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.light, for: .navigationBar)
    }

    /// 四柱节右侧小注:真太阳时 + 出生地 + 偏差(时辰未知 → 不造时间,只显其余)。
    private var chartHeaderNote: String {
        var parts: [String] = []
        if let ts = response.trueSolarTime {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm"
            f.timeZone = .current
            parts.append("真太阳时 \(f.string(from: ts))")
        }
        if let place = request.placeName, !place.isEmpty {
            parts.append(place)
        }
        let offset = response.trueSolarOffsetMinutes
        let sign = offset >= 0 ? "+" : ""
        parts.append(String(format: "偏差 %@%.1f 分", sign, offset))
        return parts.joined(separator: " · ")
    }

    /// 喜忌节右侧小注:旺衰(原 XijiCard badge 迁来)+ 调候触发 + 算法。
    private var xijiTrailingNote: String? {
        let strength: String?
        switch response.dayMasterStrength {
        case "strong":          strength = "身强"
        case "weak":            strength = "身弱"
        case "balanced":        strength = "中和"
        case "special_pattern": strength = "从格"
        default:                strength = nil
        }
        var notes: [String] = []
        if let strength { notes.append(strength) }
        if response.tiaoshouApplied {
            notes.append("◎ 调候已触发")
        }
        if let method = response.xijiMethod {
            notes.append(method)
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}
