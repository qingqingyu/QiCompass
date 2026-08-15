import SwiftUI

/// 出生地选择入口(假搜索框,Q8 交互形态)。
///
/// - 显示当前选中「城市, 国家」/「自定义地点 · GMT+8」或占位(无默认,必选)
/// - 点击推 `CitySearchSheet`(S05:底部含「自定义地点」入口,三入口自动继承)
/// - 视觉对齐 DESIGN.md:cardSurface 底 + hairline 描边 + 4pt 圆角,无阴影无渐变
struct CityPickerField: View {
    @Binding var selection: PlaceSelection?
    @State private var showSearch = false

    var body: some View {
        Button {
            HapticEngine.light()
            showSearch = true
        } label: {
            HStack {
                if let selection {
                    Text(selection.displayLabel)
                        .foregroundStyle(BaziTheme.ink)
                } else {
                    Text(L10n.CitySearch.placeholder)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .padding(BaziTheme.Spacing.sm)
            .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSearch) {
            CitySearchSheet(selection: $selection)
        }
    }
}
