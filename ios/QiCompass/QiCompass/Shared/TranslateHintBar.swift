import SwiftUI

/// 跨语言翻译提示条(D10.5,S7)。
///
/// 切语言后命中其它语言的既有解读时,报告先显示原文 + 本条提示:
/// 「此报告以简体中文生成 · 翻译为繁體中文」——**点按钮才翻译**,不自动批量。
/// 视觉遵守 DESIGN.md:hairline(ink@18%)框,圆角 5(CTA 同级),按钮不用
/// 朱红;翻译中转 loading(不新增动效)。
struct TranslateHintBar: View {
    /// 原文语言(wire 值,zh / zh-hant / en)。
    let sourceLanguage: String
    /// 目标语言(wire 值;显示名与按钮文案随它走)。
    let targetLanguage: String
    /// 翻译在飞(loading 形态;模块级 loading 态复用,不另起动效)。
    let isTranslating: Bool
    let onTranslate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isTranslating {
                ProgressView()
                    .scaleEffect(0.75)
                Text("翻译中…")
                    .font(BaziFont.caption(size: 11))
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                Text(String(
                    format: String(localized: "此报告以%@生成"),
                    AppLanguage.displayName(forWire: sourceLanguage)
                ))
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMuted)
                Spacer(minLength: 12)
                Button(action: onTranslate) {
                    Text(String(
                        format: String(localized: "翻译为%@ ›"),
                        AppLanguage.displayName(forWire: targetLanguage)
                    ))
                    .font(BaziFont.caption(size: 11.5))
                    .foregroundStyle(BaziTheme.ink)
                    .fontWeight(.medium)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(BaziTheme.ink.opacity(0.18), lineWidth: 0.5)
        )
    }
}
