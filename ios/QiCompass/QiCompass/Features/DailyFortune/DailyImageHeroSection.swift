import SwiftUI

/// V4 每日运势 hero:3:2「五行小景」水墨插画,页面视觉主角(2026-08-30 拍板)。
///
/// 设计事实源:`~/.gstack/projects/qingqingyu-QiCompass/designs/daily-fortune-art-20260830/`
/// (v4-reference.html + approved.json)。布局:左右 17pt 边距,3:2 横幅;右下竖排干支 +
/// 左下朱印为**客户端 Kaiti 矢量叠加**(不靠生图写字,零乱码,换日只换底图)。
///
/// S0(当前):内置静态样图 `DailyFortuneHeroSample`(gpt-image-2 1536×1024,丙子日示例)。
/// S3 将切 `DailyImageStore` 动态拉取(每命主每日一幅,后端生成+缓存),本 view 契约不变。
///
/// 深色策略:插画本身是浅纸底,深色模式下保持原样——「暗夜里的一张画」,不做反色。
struct DailyImageHeroSection: View {
    /// 流日干支(如「丙子」),叠加为右下竖排。
    let dayPillar: String

    var body: some View {
        Image("DailyFortuneHeroSample")
            .resizable()
            .aspectRatio(3.0 / 2.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomTrailing) {
                // 竖排干支:纸色字 + 淡墨投影保证浅色画面上的可读性。
                // 插画深色模式保持浅纸底不反色(V4 拍板),而 paper/inkDeep 都是 dyn 双值色,
                // dark 下会翻成夜宣纸色/冷白投影导致不可读 → 锁 light scheme 恒取亮值。
                VText(phrase: dayPillar, size: 19, tracking: 7, color: BaziTheme.paper)
                    .shadow(color: BaziTheme.inkDeep.opacity(0.45), radius: 3, y: 1)
                    .environment(\.colorScheme, .light)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .bottomLeading) {
                // 朱印(印章级 cinnabar 授权场景,InkKit 六件套)
                SealStamp(character: "印", size: 22)
                    .padding(.leading, 14)
                    .padding(.bottom, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm, style: .continuous))
            .overlay(
                // 深浅两态下的一圈呼吸边(hairline 双值随 dyn 反转)
                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm, style: .continuous)
                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
            )
            .accessibilityLabel(Text(verbatim: "\(dayPillar) \(L10n.DailyFortune.shortLabel)"))
    }
}
