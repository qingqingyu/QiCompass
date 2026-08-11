import SwiftUI

/// 提交前二次确认 sheet(生肖阶段 3,仅 onboarding 用)。
///
/// 设计意图(生肖设计决策 line 116):新用户首次排盘输错只能"重置命盘"全部重来(Q20),
/// 代价大。确认 sheet 让用户在 commit 前再核对一次出生信息,降低首次输入错误率。
///
/// 文案模板:"2000-05-03 14:30 男 · 广州"。对齐设计文档原意,不在此 view 内拼接完整句子,
/// 而是分行展示(更易扫读)。
///
/// 视觉:对齐 ZodiacRevealView 同款 BaziTheme / BaziFont,不另起风格。
struct BirthInfoConfirmSheet: View {
    @Bindable var vm: DeepAnalysisViewModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    /// 复用 ZodiacRevealView 的 dateFormatter 风格(`yyyy-MM-dd HH:mm`)。
    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xl) {
            Text("确认出生信息")
                .font(BaziFont.display(size: 20))
                .foregroundStyle(BaziTheme.ink)

            VStack(spacing: BaziTheme.Spacing.md) {
                infoRow(label: "出生时间", value: Self.dateFormatter.string(from: vm.birthDate))
                infoRow(label: "性别", value: vm.gender == "male" ? "男" : "女")
                if vm.useManualLongitude {
                    infoRow(label: "出生地", value: "经度 \(formattedLongitude(vm.manualLongitude))")
                } else {
                    infoRow(label: "出生地", value: vm.selectedCity)
                }
            }

            VStack(spacing: BaziTheme.Spacing.sm) {
                Button(action: {
                    HapticEngine.medium()
                    onConfirm()
                }) {
                    Text("确认排盘")
                        .font(BaziFont.button())
                        .foregroundStyle(BaziTheme.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BaziTheme.Spacing.md)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
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
            AppLogger.app.info("BirthInfoConfirmSheet.shown birth=\(Self.dateFormatter.string(from: vm.birthDate)) gender=\(vm.gender, privacy: .public) city=\(vm.selectedCity, privacy: .public) useManualLon=\(vm.useManualLongitude, privacy: .public)")
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

    // MARK: - 格式化 helper

    /// 经度格式化:保留 2 位小数(如 `116.41`)。
    /// manualLongitude 是 Double,直接 String(format:) 渲染。
    private func formattedLongitude(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
