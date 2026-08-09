import SwiftUI

/// 命盘别名编辑小表单(v2 PR1)。
///
/// ProfileView swipe 改名时弹出。TextField + 保存/取消。
/// 空白 alias 显式报错(对齐 UserSnapshotLinkStore.updateAlias 约束)。
struct AliasEditView: View {
    let initialAlias: String
    let onSave: (String) -> Void

    @State private var alias: String
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(initialAlias: String, onSave: @escaping (String) -> Void) {
        self.initialAlias = initialAlias
        self.onSave = onSave
        _alias = State(initialValue: initialAlias)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: BaziTheme.Spacing.lg) {
                TextField("命盘别名", text: $alias)
                    .foregroundStyle(BaziTheme.ink)
                    .padding(BaziTheme.Spacing.md)
                    .background(
                        BaziTheme.cardSurface,
                        in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                            .stroke(BaziTheme.hairline, lineWidth: 0.5)
                    )
                    .submitLabel(.done)
                    .onSubmit(save)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                PrimaryCTAButton(
                    title: "保存",
                    loadingTitle: "保存中…",
                    isLoading: false,
                    action: save
                )
            }
            .padding(.horizontal, BaziTheme.Spacing.lg)
            .padding(.bottom, BaziTheme.Spacing.lg)
            .background(BaziTheme.paper.ignoresSafeArea())
            .navigationTitle("改名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(BaziTheme.cinnabar)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func save() {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "别名不能为空"
            return
        }
        guard trimmed != initialAlias else {
            // 没改,直接 dismiss(避免无意义的 store 写入)
            dismiss()
            return
        }
        onSave(trimmed)
        dismiss()
    }
}
