import SwiftUI

/// 跨语言翻译提示条(D10.5,S7;L3/F1 修订为失败/离线两态)。
///
/// 2026-10-01 拍板(修订 D10.5):切语言后打开报告即**自动翻译**——翻译中
/// 不显示本条(进度走章首「正在译为××」小注 + 模块 loading),本条只在
/// 翻译失败时出现,作为重试入口;离线类失败显示「联网后自动译为××」
/// (回前台自动重试一次,无按钮)。视觉遵守 DESIGN.md:hairline(ink@18%)
/// 框,圆角 5(CTA 同级),按钮不用朱红,不新增动效。
struct TranslateHintBar: View {
    /// 展示形态(由调用方按 VM 状态决定;进行中/成功不渲染本条)。
    enum Mode {
        /// 翻译失败(可重试):正文 = 「此报告以%@生成 · <失败文案>」+ 重试按钮。
        /// 失败文案调用方传(深度解析 = 部分章节失败 / 合盘 = 整体失败)。
        case failure(sourceLanguage: String, failureText: String)
        /// 离线:联网后回前台自动译(无按钮)。
        case offline(targetLanguage: String)
    }

    let mode: Mode
    /// 重试动作(离线态不渲染按钮,闭包保留统一签名)。
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            switch mode {
            case .failure(let sourceLanguage, let failureText):
                Text(String(
                    format: String(localized: "此报告以%@生成 · %@"),
                    AppLanguage.displayName(forWire: sourceLanguage),
                    failureText
                ))
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMuted)
                Spacer(minLength: 12)
                Button(action: onRetry) {
                    Text(String(localized: "重试"))
                        .font(BaziFont.caption(size: 11.5))
                        .foregroundStyle(BaziTheme.ink)
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
            case .offline(let targetLanguage):
                Text(String(
                    format: String(localized: "联网后自动译为%@"),
                    AppLanguage.displayName(forWire: targetLanguage)
                ))
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMuted)
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
