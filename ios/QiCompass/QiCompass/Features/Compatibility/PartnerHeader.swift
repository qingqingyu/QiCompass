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

// MARK: - 人物牌头(P2)

/// 结果壳头部人物牌(P1 结果页主页化,2026-09-29):
/// 左「我」(日主 + 生日,纯展示;命主无时辰显「补时辰」入口,S07 语义)·
/// 中「合」朱印 · 右对方牌(点击开换人 sheet,P3 原地刷新)。
///
/// 视觉约束(DESIGN.md):容器无底色、底部 hairline 收边(卡片让位 hairline);
/// 对方牌可点区域 hairline 描边圆角矩形,**不用 Capsule**;无对方 = dashed
/// hairline 占位(临时态);日主字按五行着色(BaziTheme.elementColor);
/// 朱红只出现在「合」印章(SealStamp 授权场景)。
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
            SealStamp(character: "合", size: 26, rotation: -4)
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
                    .tracking(1.5)
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

    /// 副行「日主 X · yyyy-MM-dd」(caption + tabular-nums;无生日只显日主段)。
    private func subline(_ person: PartnerDisplay) -> some View {
        let gan = person.dayMaster.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        return Text(L10n.CompatibilityPartner.subline(
            gan, person.birthDateString ?? "—"
        ))
        .font(BaziFont.caption(size: 10.5).monospacedDigit())
        .lineLimit(1)
        .foregroundStyle(BaziTheme.inkMuted)
    }
}
