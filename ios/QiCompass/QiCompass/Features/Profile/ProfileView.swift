import SwiftUI
import SwiftData

/// "我的" Tab(2026-08-01 grill-me 决策 #17 新增的第 4 个 Tab)。
///
/// v1 无账号系统,内容含 4 个 section(详见 issue #3 + STRATEGIC_DIFF.md §iOS App 入口):
/// 1. **我的命盘**:UserSnapshotLink list("我自己" / "妈妈" / "男友" 等 alias)
/// 2. **已购**:active Entitlement list(按 purchasedAt DESC)
/// 3. **设置**:zi_hour_rule default(子时规则,后续 BirthFormView 读取作为默认值)
/// 4. **关于**:app 版本 + build 号
///
/// 退化态:无命盘/无 entitlements 时显示 placeholder 文案,不报错(状态显式表达)。
struct ProfileView: View {
    @Query(sort: \UserSnapshotLink.createdAt, order: .reverse)
    private var snapshotLinks: [UserSnapshotLink]

    @Query(sort: \Entitlement.purchasedAt, order: .reverse)
    private var entitlements: [Entitlement]

    /// 子时规则默认值。BirthFormView 后续 slice 起手读此 @AppStorage 作为初始值。
    /// 默认 zi_next_day(对齐 CLAUDE.md 项目约束 + 既有 DeepAnalysisViewModel 默认值)。
    @AppStorage("defaultZiHourRule") private var defaultZiHourRule = "zi_next_day"

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                List {
                    snapshotLinksSection
                    entitlementsSection
                    settingsSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
                .background(BaziTheme.paper)
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
    }

    // MARK: - Section 1: 我的命盘

    private var snapshotLinksSection: some View {
        Section {
            if snapshotLinks.isEmpty {
                Text("还没有命盘")
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                ForEach(snapshotLinks) { link in
                    HStack {
                        Text(link.alias)
                            .foregroundStyle(BaziTheme.ink)
                        Spacer()
                        Text(String(link.snapshotHash.prefix(8)))
                            .font(.caption.monospaced())
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                }
            }
        } header: {
            sectionHeader("我的命盘")
        }
    }

    // MARK: - Section 2: 已购

    private var entitlementsSection: some View {
        Section {
            let activeEntitlements = entitlements.filter { $0.isActive }
            if activeEntitlements.isEmpty {
                Text("还没有购买")
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                ForEach(activeEntitlements) { ent in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: ent.module))
                            .foregroundStyle(BaziTheme.ink)
                        HStack {
                            Text("购买于")
                            Text(ent.originalPurchaseDate, format: .dateTime.year().month().day())
                        }
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                    }
                }
            }
        } header: {
            sectionHeader("已购")
        }
    }

    // MARK: - Section 3: 设置

    private var settingsSection: some View {
        Section {
            Picker("子时规则默认", selection: $defaultZiHourRule) {
                Text("子时属次日(23:00 换日)").tag("zi_next_day")
                Text("早晚子时(00:00 换日)").tag("zero_oclock")
            }
            .foregroundStyle(BaziTheme.ink)
        } header: {
            sectionHeader("设置")
        } footer: {
            Text("影响新表单的初始值。已存档命盘不受影响(其规则随 snapshot 持久化)。")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - Section 4: 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: appVersion)
            LabeledContent("Build", value: buildNumber)
        } header: {
            sectionHeader("关于")
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BaziTheme.inkMuted)
            .textCase(nil)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private func displayName(for module: String) -> String {
        switch module {
        case "bazi_deep":     return "深度解析"
        case "compatibility": return "合盘"
        default:              return module
        }
    }
}
