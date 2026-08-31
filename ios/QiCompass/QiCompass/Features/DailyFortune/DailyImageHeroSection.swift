import SwiftUI

/// V4 每日运势 hero:3:2「五行小景」水墨插画,页面视觉主角(2026-08-30 拍板)。
///
/// 设计事实源:`~/.gstack/projects/qingqingyu-QiCompass/designs/daily-fortune-art-20260830/`
/// (v4-reference.html + approved.json)。布局:左右 17pt 边距,3:2 横幅;右下竖排干支 +
/// 左下朱印为**客户端 Kaiti 矢量叠加**(不靠生图写字,零乱码,换日只换底图)。
///
/// S3(当前):底图来自 `DailyImageStore`(每命主每日一幅,后端 gpt-image-2 生成+缓存)。
/// 三态:loading=墨圆呼吸骨架;ready=成图;failed=静态墨圆+错误一行+重试。
///
/// 深色策略:插画本身是浅纸底,深色模式下保持原样——「暗夜里的一张画」,
/// 不做反色;竖排/投影锁 light scheme(dyn 双值色落在恒浅画面上不可读)。
struct DailyImageHeroSection: View {
    /// 流日干支(如「丙子」),叠加为右下竖排。
    let dayPillar: String
    /// 插画加载状态(DailyImageStore.state)。
    let imageState: DailyImageStore.HeroImageState
    let onRetry: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 无障碍:failed 态含唯一的可操作控件(重试),必须 .contain 让
        // VoiceOver 可达;loading/ready 无子控件,合并为单元素 + 干支 label。
        if case .failed = imageState {
            framedHero
                .accessibilityElement(children: .contain)
        } else {
            framedHero
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(dayPillar) \(L10n.DailyFortune.shortLabel)"))
        }
    }

    /// 三态底 + 叠加 + 3:2 裁形 + 呼吸边(无障碍包装由 body 分态施加)。
    private var framedHero: some View {
        ZStack {
            switch imageState {
            case .loading:
                generatingSkeleton
            case .ready(let image):
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(3.0 / 2.0, contentMode: .fill)
            case .failed(let message):
                failedPlaceholder(message: message)
            }

            // 客户端叠加:三态都保留(骨架/失败态也有当日身份)。
            // 纯装饰:loading/ready 被容器 .ignore 吞掉;failed 态 .contain
            // 下若不隐藏,「印章印」「丙」「子」会排在错误文案/重试前干扰 VoiceOver。
            overlayMarks
                .accessibilityHidden(true)
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm, style: .continuous))
        .overlay(
            // 深浅两态下的一圈呼吸边(hairline 双值随 dyn 反转)
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm, style: .continuous)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
    }

    // MARK: - 骨架(生图中)

    /// 墨圆呼吸 + 「生图中」小字。reduce-motion 时静态呈现(DESIGN.md §Motion)。
    private var generatingSkeleton: some View {
        ZStack {
            Rectangle().fill(BaziTheme.paper)
            VStack(spacing: 14) {
                EnsoView(size: 84, breathing: !reduceMotion)
                Text(L10n.DailyFortune.heroGenerating)
                    .font(BaziFont.caption(size: 11))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
    }

    // MARK: - 失败态

    /// 静态墨圆 + 错误一行(后端 error_message 原文,人话由后端保证)+ 重试。
    private func failedPlaceholder(message: String) -> some View {
        ZStack {
            Rectangle().fill(BaziTheme.paper)
            VStack(spacing: 12) {
                EnsoView(size: 84, animated: false)
                    .opacity(0.45)
                Text(message)
                    .font(BaziFont.caption(size: 11))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button(action: onRetry) {
                    Text(L10n.DailyFortune.heroRetry)
                        .font(BaziFont.display(size: 12))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.ink)
                        .underline()
                }
            }
        }
    }

    // MARK: - 叠加(竖排干支 + 朱印)

    private var overlayMarks: some View {
        ZStack {
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    // 朱印(印章级 cinnabar 授权场景,InkKit 六件套)
                    SealStamp(character: "印", size: 22)
                        .padding(.leading, 14)
                        .padding(.bottom, 12)
                    Spacer()
                    // 竖排干支:纸色字 + 淡墨投影。
                    // paper/inkDeep 是 dyn 双值色,dark 下会翻成夜宣纸色/冷白投影,
                    // 落在恒浅的插画上不可读 → 锁 light scheme 恒取亮值。
                    VText(phrase: dayPillar, size: 19, tracking: 7, color: BaziTheme.paper)
                        .shadow(color: BaziTheme.inkDeep.opacity(0.45), radius: 3, y: 1)
                        .environment(\.colorScheme, .light)
                        .padding(.trailing, 14)
                        .padding(.bottom, 12)
                }
            }
        }
    }
}
