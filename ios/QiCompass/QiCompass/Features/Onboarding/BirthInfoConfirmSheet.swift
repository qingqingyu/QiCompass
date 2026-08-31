import SwiftUI

/// 提交前二次确认 sheet(生肖阶段 3,仅 onboarding 用)。
///
/// 设计意图(生肖设计决策 line 116):新用户首次排盘输错只能"重置命盘"全部重来(Q20),
/// 代价大。确认 sheet 让用户在 commit 前再核对一次出生信息,降低首次输入错误率。
///
/// 文案模板:"2000-05-03 / 14:30 / 男 / 广州"(S03 拆双 picker 后日期与时刻分行)。
/// 不在此 view 内拼接完整句子,而是分行展示(更易扫读)。
///
/// 视觉:对齐 ZodiacRevealView 同款 BaziTheme / BaziFont,不另起风格。
struct BirthInfoConfirmSheet: View {
    @Bindable var vm: DeepAnalysisViewModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xl) {
            Text("确认出生信息")
                .font(BaziFont.display(size: 20))
                .foregroundStyle(BaziTheme.ink)

            VStack(spacing: BaziTheme.Spacing.md) {
                // S03 拆双 picker:日期与时刻分行展示,与表单两行共用同一 VM 事实源(数值一致)
                infoRow(label: L10n.BirthForm.birthDateLabel, value: vm.wallBirthDateString ?? "—")
                // S04 时辰未知:无时辰态明示「未知(半夜:是/否/不确定)」,防误提交
                infoRow(label: L10n.BirthForm.birthTimeLabel, value: vm.confirmBirthTimeText)
                infoRow(label: "性别", value: vm.gender == "male" ? "男" : "女")
                infoRow(label: "出生地", value: vm.selectedPlace?.displayLabel ?? "—")
            }

            VStack(spacing: BaziTheme.Spacing.sm) {
                Button(action: {
                    HapticEngine.medium()
                    onConfirm()
                }) {
                    Text("确认排盘")
                        .font(BaziFont.button())
                        .foregroundStyle(BaziTheme.onInkDeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BaziTheme.Spacing.md)
                        .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
                }
                .accessibilityHint("用以上信息排盘,进入今日运势")

                Button(action: { onCancel() }) {
                    Text("返回修改")
                        .font(BaziFont.body())
                        .foregroundStyle(BaziTheme.inkMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BaziTheme.Spacing.sm)
                }
                .accessibilityHint("回到表单修改出生信息")
            }
        }
        .padding(BaziTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BaziTheme.paper)
        .onAppear {
            // 规则 1:用户主动触发的入口日志(便于排查"sheet 没弹 / 反复弹")
            AppLogger.app.info("BirthInfoConfirmSheet.shown birth=\(vm.wallBirthDateString ?? "nil") time=\(vm.confirmBirthTimeText, privacy: .public) gender=\(vm.gender, privacy: .public) place=\(vm.selectedPlace?.displayLabel ?? "nil", privacy: .public)")
        }
    }

    // MARK: - 子组件

    @ViewBuilder
    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(BaziFont.caption())
                .foregroundStyle(BaziTheme.inkMuted)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(BaziFont.body())
                .foregroundStyle(BaziTheme.ink)
            Spacer()
        }
        .padding(.vertical, BaziTheme.Spacing.xs)
    }
}
