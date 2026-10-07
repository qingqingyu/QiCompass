import SwiftUI

// MARK: - 人物牌展示模型(P2)

/// 结果壳头部人物牌展示数据(纯值;VM `currentSelfDisplay` / `currentPartner` 派生,
/// 头部与换人 sheet 勾选态共用同一事实源)。
struct PartnerDisplay: Equatable {
    /// roster entry id(对方牌;「我」侧为 nil)。
    let entryID: String?
    let name: String
    /// 日主天干(nil / "—" = 日柱歧义或推演前未知 → 墨色不按五行着色)。
    let dayMaster: String?
    /// 日主五行英文 key(着色用;nil → inkMuted 兜底)。
    let dayMasterElementKey: String?
    /// 展示用生日串(yyyy-MM-dd;nil 不渲染日期段)。存档行按设备时区格式化;
    /// 临时人推演前 = 出生地钟面前缀(经设备时区换算会错一天,VM 侧预格式化)。
    let birthDateString: String?
}

// MARK: - 命主无时辰锁 banner(S07 全锁解释行,结果壳家族共用)

/// 「你的命盘缺出生时辰,所有对暂不可合盘」解释行(dashed 框 = 锁定/临时态,
/// DESIGN.md)。P5 内联表单上方与换人 sheet 顶部共用同一表达。
struct RosterSelfLockBanner: View {
    var body: some View {
        Text(L10n.CompatibilityRosterGate.selfBanner)
            .font(BaziFont.caption(size: 11.5))
            .tracking(1)
            .foregroundStyle(BaziTheme.inkMuted)
            .padding(BaziTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                    .stroke(BaziTheme.hairlineDashed, lineWidth: 1)
            )
    }
}

// MARK: - 人物牌头(P2)

/// 结果壳头部人物牌(P1 结果页主页化,2026-09-29):
/// 左「你」(日主 + 生日,纯展示;命主无时辰显「补时辰」入口,S07 语义)·
/// 右对方牌(点击开换人 sheet,P3 原地刷新)。
///
/// 2026-10-07:中缝「合」朱印移除——「一枚朱印」只留双盘表中轴一枚
/// (此前顶部+中轴+列表卡三处同屏重复);两牌因此各得半宽,兜底名
/// 「对方 · 日期」不再截断。换人重盖动效由内容区 `.id(compatibilityHash)`
/// 重建承接(whole-view ink-in + 中轴印自然重播)。
///
/// 视觉约束(DESIGN.md):容器无底色、底部 hairline 收边(卡片让位 hairline);
/// 对方牌可点区域 hairline 描边圆角矩形,**不用 Capsule**;无对方 = dashed
/// hairline 占位(临时态);日主字按五行着色(BaziTheme.elementColor)。
struct PartnerHeader: View {
    let me: PartnerDisplay
    let partner: PartnerDisplay?
    /// 名单是否为空(空 → 占位「＋ 添加对方」;非空 → 「选择对方 ▾」,P5/P6 语义)。
    let rosterIsEmpty: Bool
    let isSelfHourUnknown: Bool
    let onTapPartner: () -> Void
    /// 命主无时辰时的补时辰入口(nil 无宿主不渲染)。
    var onAddSelfHour: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            meCard
                .frame(maxWidth: .infinity, alignment: .leading)
            partnerCard
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, BaziTheme.Spacing.md)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
        }
    }

    // MARK: 左「我」(纯展示 + 补时辰入口)

    private var meCard: some View {
        HStack(spacing: 10) {
            dayMasterAvatar(me)
            VStack(alignment: .leading, spacing: 3) {
                Text(me.name)
                    .font(BaziFont.display(size: 15.5))
                    .lineLimit(1)
                    // 兜底名(「对方 · 1990-03-15」)过长时缩字号而非截断(#1,
                    // 2026-10-01):被截掉的恰是最关键的区分信息
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(BaziTheme.ink)
                subline(me)
            }
            if isSelfHourUnknown, let onAddSelfHour {
                Button(action: onAddSelfHour) {
                    HStack(spacing: 2) {
                        Text(L10n.CompatibilityPartner.addSelfHour)
                        Text("›")
                    }
                    .font(BaziFont.caption(size: 10.5))
                    // EN "Add hour" 混排不带字距(大字距只留给全大写,
                    // DESIGN.md 09-28;先例同 PairSummaryCard,2026-10-07)
                    .tracking(AppLanguage.current.isChinese ? 1.5 : 0)
                    .foregroundStyle(BaziTheme.inkMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.CompatibilityPartner.addSelfHour)
            }
        }
    }

    // MARK: 右对方牌(点击开换人 sheet)/ 无对方占位

    @ViewBuilder
    private var partnerCard: some View {
        if let partner {
            Button(action: onTapPartner) {
                HStack(spacing: 10) {
                    dayMasterAvatar(partner)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(partner.name)
                            .font(BaziFont.display(size: 15.5))
                            .lineLimit(1)
                            // 同「我」侧:缩字号防截断(#1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(BaziTheme.ink)
                        subline(partner)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(
                    RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                        .stroke(BaziTheme.hairline, lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.CompatibilityPartner.switchA11y(partner.name))
        } else {
            Button(action: onTapPartner) {
                HStack(spacing: 7) {
                    if rosterIsEmpty {
                        Image(systemName: "plus")
                            .font(.caption2.weight(.medium))
                    }
                    Text(rosterIsEmpty
                         ? L10n.CompatibilityPartner.addPartner
                         : L10n.CompatibilityPartner.choosePartner)
                        .font(BaziFont.caption(size: 12))
                        .tracking(2)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(BaziTheme.inkMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                        .stroke(BaziTheme.hairlineDashed,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(rosterIsEmpty
                                ? L10n.CompatibilityPartner.addPartner
                                : L10n.CompatibilityPartner.choosePartner)
        }
    }

    // MARK: 共享件

    /// 日主字头像:hairline 描边小方 + 五行着色天干(未知 → 「—」墨色,不猜;
    /// 着色 key 由 VM 派生,单一事实源)。
    private func dayMasterAvatar(_ person: PartnerDisplay) -> some View {
        let gan = person.dayMaster.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let color = (gan == "—" || person.dayMasterElementKey == nil)
            ? BaziTheme.inkMuted
            : BaziTheme.elementColor(person.dayMasterElementKey ?? "")
        return Text(gan)
            .font(BaziFont.ganzhi(size: 15))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                    .stroke(BaziTheme.hairline, lineWidth: 0.8)
            )
    }

    /// 副行两行式(#1,2026-10-01):「日主 X」一行 + 生日一行(单行式在窄屏
    /// 会截日期,被截的恰是关键信息)。无生日只显日主行;日期走 tabular-nums。
    /// 日主行 lineLimit(2026-10-07):EN "Day Master 丁" 挤压时折两行
    /// 破坏两牌副行对齐,单行兜底。
    private func subline(_ person: PartnerDisplay) -> some View {
        let gan = person.dayMaster.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return VStack(alignment: .leading, spacing: 2) {
            Text(String(format: String(localized: "日主 %@"), gan))
                .lineLimit(1)
                // 挤压时(窄屏 + EN "Day Master 丁" + 同排「补时辰」入口)缩字号
                // 而非截断——截掉的恰是日主本身(同名字行 0.75 先例,2026-10-01 #1)
                .minimumScaleFactor(0.8)
            if let date = person.birthDateString {
                Text(date)
                    .monospacedDigit()
            }
        }
        .font(BaziFont.caption(size: 10.5))
        .foregroundStyle(BaziTheme.inkMuted)
    }
}
