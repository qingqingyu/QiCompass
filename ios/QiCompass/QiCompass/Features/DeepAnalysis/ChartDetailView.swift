import SwiftUI

/// hairline 分节容器(盘面小景定稿 ⑩):节标 14.5pt 楷体 + 右侧小注,
/// 上边 hairline 分隔,左右边距 32。替代原九卡的 cardSurface 卡壳——
/// 「改壳不改芯」:内容组件只卸卡,排版进本容器(DESIGN.md 卡片让位 hairline)。
/// trailing 由 String 改 Text(2026-10-14):四柱节「日主 辛金」需值段朱红混排,
/// 样式(字号/灰度)仍统一在容器内施加,调用方只给内容。
private struct HairlineSection<Content: View>: View {
    let title: String
    var trailing: Text? = nil
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
                    trailing
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

                    HairlineSection(title: String(localized: "四柱"), trailing: dayMasterTrailing) {
                        PillarsTable(pillars: response.pillars, onAddHour: onAddHour)
                    }

                    HairlineSection(title: String(localized: "辅柱")) {
                        AuxiliaryCards(
                            mingGong: response.mingGong,
                            shenGong: response.shenGong,
                            taiYuan: response.taiYuan
                        )
                    }

                    HairlineSection(title: String(localized: "五行分布"), trailing: elementTotalTrailing) {
                        ElementBalanceBar(balance: response.elementBalance)
                    }

                    HairlineSection(title: String(localized: "喜忌分析"), trailing: xijiTrailingNote.map(Text.init)) {
                        XijiCard(response: response)
                    }

                    HairlineSection(title: String(localized: "神煞")) {
                        ShenshaChips(shensha: response.shensha)
                    }

                    HairlineSection(title: String(localized: "大运")) {
                        LuckPillarsTimeline(
                            luckPillars: response.luckPillars,
                            currentLuckPillar: response.currentLuckPillar
                        )
                    }

                    HairlineSection(title: String(localized: "当前柱")) {
                        CurrentStatusCard(response: response)
                    }
                }
                // 96:悬浮 Tab 栏(iOS 26 liquid glass)不压末节内容,对齐
                // ProfileView 底部留白先例(2026-10-14 仿 HTML 目标稿)
                .padding(.bottom, 96)
            }
        }
        .navigationTitle("盘面细目")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 四柱节 trailing:「日主 辛金」——标签灰、值段朱红加粗(HTML 目标稿);
    /// 显示串复用 ZodiacHelper.revealDayMasterDisplay(zh「辛金」/ en "Xin Metal",
    /// 单一事实源)。日柱歧义(S05)→ nil 不渲染(不猜)。
    private var dayMasterTrailing: Text? {
        guard let day = response.pillars.day,
              let display = ZodiacHelper.revealDayMasterDisplay(
                  gan: day.gan,
                  ganElement: day.ganElement,
                  language: AppLanguage.current
              ) else { return nil }
        var attributed = AttributedString(L10n.DeepChart.dayMaster(display))
        // 值段找不到(理论不可达:display 就是格式串参数)→ 整段灰,不 crash
        if let range = attributed.range(of: display) {
            attributed[range].foregroundColor = BaziTheme.cinnabar
            attributed[range].inlinePresentationIntent = .stronglyEmphasized
        }
        return Text(attributed)
    }

    /// 五行分布节 trailing:「八字共 8 字」。求和即口径(时辰未知盘自然 = 6,
    /// 对齐 backend compute_element_balance 注释,不加标注字段)。
    private var elementTotalTrailing: Text? {
        let b = response.elementBalance
        return Text(L10n.DeepChart.elementTotal(b.wood + b.fire + b.earth + b.metal + b.water))
    }

    /// 喜忌节右侧小注:旺衰(原 XijiCard badge 迁来)+ 调候触发 + 算法。
    /// 旺衰/算法标注值经 BaziTerms 取显示语。
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
        if let strength { notes.append(BaziTerms.display(strength)) }
        if response.tiaoshouApplied {
            notes.append(L10n.DeepChart.tiaoshouAppliedTrailing)
        }
        if let method = response.xijiMethod {
            notes.append(BaziTerms.display(method))
        }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}
