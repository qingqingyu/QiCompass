import SwiftUI

/// 出生地选择入口(假搜索框,Q8 交互形态)。
///
/// - 显示当前选中「城市, 国家」/「自定义地点 · GMT+8」或占位(无默认,必选)
/// - 点击推 `CitySearchSheet`(S05:底部含「自定义地点」入口,三入口自动继承)
/// - 视觉两形态(`style`,默认 `.card`,既有调用方零改动):
///   - `.card`:cardSurface 底 + hairline 描边 + 4pt 圆角(合盘配置等既有场景,样式不变)
///   - `.underlined`:无框 + 底部 hairline 下划线(水墨 O2 生辰表单;楷体值行,占位淡墨)
/// - 引擎与排序(CitySearchSheet / CitySearchEngine)不在本组件职责内,不碰
struct CityPickerField: View {
    @Binding var selection: PlaceSelection?

    /// 入口视觉形态。
    enum Style {
        /// cardSurface 底 + hairline 描边(既有形态)。
        case card
        /// 无框 + 底部 hairline 下划线(O2 生辰表单)。
        case underlined
    }

    var style: Style = .card

    @State private var showSearch = false

    var body: some View {
        Button {
            HapticEngine.light()
            showSearch = true
        } label: {
            switch style {
            case .card:
                cardLabel
            case .underlined:
                underlinedLabel
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSearch) {
            CitySearchSheet(selection: $selection)
        }
    }

    // MARK: - 形态一:卡片(既有,样式与旧版一致)

    private var cardLabel: some View {
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

    // MARK: - 形态二:无框下划线(O2 生辰表单)

    private var underlinedLabel: some View {
        HStack(alignment: .firstTextBaseline) {
            if let selection {
                Text(selection.displayLabel)
                    .foregroundStyle(BaziTheme.ink)
            } else {
                Text(L10n.CitySearch.placeholder)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .font(BaziFont.body(size: 16))
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 1)
        }
    }
}
