import SwiftUI

/// success 态主布局(**2026-10-01 Today 定稿**,事实源 designs/review-fix-20261001/
/// today-final.html @393px,px≈pt 1:1):
/// 头部区(大字日 + 三行 meta + 左对齐 chips,出图上纸面)+ 宜忌双列包进
/// 同一容器,光晕作**衬底**铺在其后(**2026-10-15 贴 B 稿**:去竖排签文,
/// 光晕不再单独占 340pt 舞台)→ AI 解读(24pt,无卡片直接排纸面,
/// 2026-09-07 起进入即自动生成)→ 居中页脚 →(时辰未知降级盘)末尾补时辰静默行。
/// 各块 ink-in 错峰入场(mockup .content>* 0/.08/.16/.24s 同款节奏)。
///
/// 2026-09-07 历史回看拔除(用户拍板「底部日期选择完全没必要」):
/// - 第二屏 7 日日期带 + 「更早」锁框 + 历史回看 sheet + 付费墙接线全部移除,
///   今日 tab 转为纯免费(MONETIZATION.md §每日运势历史回看 同步删节)
/// - `EntitlementStore.hasAnyActivePurchase` 唯一调用方(本文件的
///   refreshUnlockState)已随历史回看代码移除,该方法无存留调用方,同步删除
///
/// 不直接接 state machine,由 DailyFortuneView 切换后传入。
struct DailyFortuneMainView: View {
    @Bindable var vm: DailyFortuneViewModel
    let response: DailyFortuneResponse
    let interpretState: InterpretState
    let businessDate: Date
    let chartHash: String?
    let ziHourRule: String
    let onRefresh: () -> Void
    let onGenerateInterpret: () -> Void
    /// S10 补时辰触点(D7 触点 2):末尾静默行点击 → 打开补时辰 sheet(宿主
    /// DailyFortuneView 注入)。静默行不是弹窗,是可点的一行文字。
    let onAddHour: () -> Void

    /// 光晕衬底顶边低于头部顶边的距离(B 稿:光晕区从页面 y=110 起,头部从
    /// y=76 起,差 34;真机截图后可微调,但只改这一个常量)。
    private static let haloTopInset: CGFloat = 34

    /// 滚动坐标空间名(S4 问事框距底探针用)。
    private static let scrollSpace = "todayScroll"

    // MARK: - S4 问事窗状态(2026-10-25)

    /// 问事对话模型。换日/换盘重建(对话随旧盘走);解读仍在生成时先以
    /// 确定性候选兜底,解读落地且用户尚未开口(pristine)则刷新开场与候选,
    /// 开口后不再重置(见 syncAskModel)。
    @State private var askModel: DailyAskModel?
    /// askModel 的数据身份(chartHash + dayPillar + businessDate):与现值
    /// 不符 = 换盘/换日。chartHash 必入键——日柱是日期的属性而非命盘的,
    /// 同日换盘 dayPillar/businessDate 都不变,缺它则旧盘对话残留。
    @State private var askDayKey: String?
    /// 聊天页是否拉起(fullScreenCover;拉起期间问事框强制不可见)。
    @State private var chatPresented = false
    /// 内容底(含 32pt 呼吸留白)在滚动坐标系里的 y——探针经 PreferenceKey 回传。
    @State private var contentBottomInScroll: CGFloat = 0
    /// 滚动视口高(overlay GeometryReader 回传;距底剩余 = 内容底 − 视口高)。
    @State private var scrollViewportHeight: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 问事框可见性(DailyAskPresentation 纯函数,测试锁定)。探针几何值
    /// 未回传前(viewport=0,remaining 按 0−0 算成 0 < 64)视为不可见——
    /// 否则进页首帧在顶部也会假判「在底部」闪出问事框。
    private var askComposerVisible: Bool {
        scrollViewportHeight > 0
            && DailyAskPresentation.composerVisible(
                remainingToBottom: contentBottomInScroll - scrollViewportHeight,
                isChatPresented: chatPresented
            )
    }

    /// 同步问事模型:首建 / 换盘换日重建 / 同盘且未开口时随解读态刷新。
    /// 只在事件上下文调用(task/onChange/按钮回调),不在 body 里改 @State。
    @MainActor
    private func syncAskModel() {
        let key = "\(chartHash ?? "nil")-\(response.dayPillar)-\(businessDate.timeIntervalSince1970)"
        if askModel == nil || askDayKey != key {
            askDayKey = key
            askModel = DailyAskModel.make(response: response, interpretState: interpretState)
        } else if askModel?.isPristine == true {
            // 解读态变化(fetching → okFree 等):用户尚未开口,开场/候选可
            // 安全刷新;已开口则保对话不重置。已打的草稿随行保留——刷新
            // 的是盘面文案,不该吃掉用户正在输入的内容。
            let draft = askModel?.draft ?? ""
            askModel = DailyAskModel.make(response: response, interpretState: interpretState)
            if !draft.isEmpty { askModel?.draft = draft }
        }
    }

    init(
        vm: DailyFortuneViewModel,
        response: DailyFortuneResponse,
        interpretState: InterpretState,
        businessDate: Date,
        chartHash: String?,
        ziHourRule: String,
        onRefresh: @escaping () -> Void,
        onGenerateInterpret: @escaping () -> Void,
        onAddHour: @escaping () -> Void,
    ) {
        self._vm = Bindable(wrappedValue: vm)
        self.response = response
        self.interpretState = interpretState
        self.businessDate = businessDate
        self.chartHash = chartHash
        self.ziHourRule = ziHourRule
        self.onRefresh = onRefresh
        self.onGenerateInterpret = onGenerateInterpret
        self.onAddHour = onAddHour
    }

    var body: some View {
        ScrollView {
            // alignment .leading(2026-10-01 真机截图修复):头部区是本列唯一的
            // 收缩包裹子视图(其余区块都有 maxWidth .infinity 贪宽),VStack 默认
            // .center 会把日期行+chips 整块水平居中(mockup 与 hero 都是左缘对齐)。
            VStack(alignment: .leading, spacing: 0) {
                // 离线查看角标(方案 step 6):网络失败 fallback 到本地缓存时显示。
                if vm.isOffline {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                        Text(L10n.DailyFortune.mainOffline)
                    }
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .padding(.bottom, 10)
                    .background(BaziTheme.ink.opacity(0.05), in: Capsule())
                }

                // ===== 头部 + 宜忌(2026-10-15 贴 B 稿:光晕是这一块的衬底,
                // 不再单独占舞台)=====
                VStack(alignment: .leading, spacing: 0) {
                    // 头部区(D3 定稿:信息一行看全,页边距 24)
                    DailyHeaderSection(
                        businessDate: businessDate,
                        lunarDate: response.lunarDate,
                        dayPillar: response.dayPillar,
                        dayRelation: response.dayRelationToDayMaster,
                        dayChong: response.dayChong,
                        dayChongTargets: response.dayChongTargets,
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 6)
                    .inkIn()

                    // 宜忌双列(紧跟 chips,B 稿 .block padding-top 30;水平 24
                    // = 与头部/解读区同左缘,2026-10-18 S2 统一——原 28 是已删的
                    // 「光晕舞台 17 + 宜忌内边距 11」遗留)
                    DailyImageHeroSection(dayRelation: response.dayRelationToDayMaster)
                        .padding(.horizontal, 24)
                        .padding(.top, 30)
                        .inkIn(delay: 0.08)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .top) {
                    // 光晕衬底:全屏宽、420pt 高、顶边低于头部 34pt。
                    // 2026-10-18 S4 修订 10-15「溢出不裁切」:加一层跟着宿主
                    // 高度走的渐变遮罩,光晕到宜忌底(+16)渐隐至全透明——
                    // 「今日解读」区域不再洇进光晕(外评 H:绿团压「忌」红字后
                    // 像污渍)。遮罩是艺术层 mask 非页面背景,不违反禁渐变背景
                    // (同 bottomFadeLayer 先例)。mask 坐标系跟随被遮罩视图的
                    // 布置位置(offset 只改渲染不改布局),故 mask 的 offset
                    // 须与 HaloBackdrop 的 offset 同值对齐。
                    GeometryReader { host in
                        let visible = max(host.size.height - Self.haloTopInset + 16, 0)
                        HaloBackdrop(
                            dayPillar: response.dayPillar,
                            dayElements: response.dayElements,
                            daySignal: response.daySignal,
                        )
                        .frame(height: HaloBackdrop.height)
                        .offset(y: Self.haloTopInset)
                        .mask(alignment: .top) {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.72),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: visible)
                            .offset(y: Self.haloTopInset)
                        }
                    }
                    .inkIn(delay: 0.08)
                }

                // 今日五行条(S3,2026-10-25):确定性力量分布(后端
                // day_element_strength,纯历法推算)+ 宜借标(day_signal ↑
                // 规则引擎产物)。老后端/老快照缺键 → nil 整块隐藏
                // (2026-08-15 教训:payload 加字段必须可缺省)。
                if let strength = response.dayElementStrength, !strength.isEmpty {
                    DailyElementStrengthSection(
                        strength: strength,
                        daySignal: response.daySignal,
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 44)
                    .inkIn(delay: 0.12)
                }

                // AI 解读(D5 定稿:无卡片底直接排纸面,页边距 24、hero 下 40
                // (2026-10-18 S3 纵向节奏,原 24);
                // S6 结构化今日洞察:v4 JSON 五段 + 确定性今日信号;2026-09-07 起
                // 进入即自动生成;2026-09-24 失败降级:AI 失败 → 引擎模板文案 +
                // 后台静默重试——降级小注维持现状,Retry 按钮 2026-10-06 拍板移除)。
                DailyInterpretationSection(
                    state: interpretState,
                    dayRelation: response.dayRelationToDayMaster,
                    dayElements: response.dayElements,
                    daySignal: response.daySignal,
                    signalNote: signalNote,
                    isSilentRetrying: vm.isSilentRetrying,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                )
                .padding(.horizontal, 24)
                .padding(.top, 40)
                .inkIn(delay: 0.16)

                // 页脚免责声明(2026-10-18 S6 只留「解读仅供参照」——
                // 「乙丑日 · 偏财 · …」与头部信息重复,外评 L;居中、ink-faint)
                heroFootnote
                    .padding(.horizontal, 24)
                    .padding(.top, 36)
                    .inkIn(delay: 0.24)

                // S10 接线(D7 触点 2,「一行文字,不是弹窗」):仅时辰未知·日柱
                // 确定的降级版展示(判据 = vm.hourGate,单一事实源),点击进补时辰
                // sheet。静默态(「我确实不知道」)行保留可点击、文案降中性——
                // 入口在,提示不在。
                if vm.hourGate == .hourUnknownDayDetermined {
                    Button {
                        HapticEngine.light()
                        onAddHour()
                    } label: {
                        Text(vm.isHourUnknownAccepted
                             ? L10n.DailyFortune.degradedHintSilent
                             : L10n.DailyFortune.degradedHint)
                            .font(BaziFont.caption(size: 10.5))
                            .tracking(1)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.DailyFortune.degradedHint)
                }
            }
            // D7:页脚滚动到底完整可见——tab 栏由系统 safe area 承担
            // (iOS 26 浮动 tab 实测参与 safe area,2026-09-19 验证),
            // 此处 32pt 为 tab 栏上方的呼吸留白。
            .padding(.bottom, 32)
            // S4 距底探针:0 高探针贴在内容底(含呼吸留白),报内容底在
            // 滚动坐标系里的 y;allowsHitTesting 防探针吃滚动子视图的手势。
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: TodayContentBottomKey.self,
                        value: geo.frame(in: .named(Self.scrollSpace)).maxY
                    )
                }
                .frame(height: 0)
                .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: Self.scrollSpace)
        .onPreferenceChange(TodayContentBottomKey.self) { contentBottomInScroll = $0 }
        // S4 视口高:距底剩余 = 内容底 − 视口高;尺寸变化(旋转/分屏)同步。
        // allowsHitTesting(false) 同底部探针——本层铺满 ScrollView 正面且
        // 纯测量,Color.clear 可命中,不关会截走全部内容点按(全仓前层
        // overlay 惯例:InkKit/Splash 等无一例外)。
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .onAppear { scrollViewportHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, height in
                        scrollViewportHeight = height
                    }
            }
            .allowsHitTesting(false)
        )
        // S4 ① 问事框:滚到最底(< 64pt)从 tab 栏上方滑出,收在顶部不可见。
        // 出现/离开均走 spring(HTML transition .45s cubic-bezier 的近似);
        // reduce-motion 降级为纯淡入淡出(动效三式纪律)。
        .overlay(alignment: .bottom) {
            Group {
                if askComposerVisible {
                    DailyAskComposerCard(
                        model: askModel ?? fallbackAskModel,
                        onOpen: {
                            HapticEngine.light()
                            syncAskModel()
                            chatPresented = true
                        },
                        onQuickAsk: { question in
                            HapticEngine.light()
                            syncAskModel()
                            askModel?.sendOffer(question)
                            chatPresented = true
                        }
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .transition(
                        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom))
                    )
                }
            }
            .animation(
                .spring(response: 0.45, dampingFraction: 0.9),
                value: askComposerVisible
            )
        }
        // S4 ② 聊天页:整页拉起,无 tab 栏;关闭后在底部则问事框重新滑出
        // (可见性计算含 chatPresented,fullScreenCover dismiss 自然重算)。
        .fullScreenCover(isPresented: $chatPresented) {
            if let model = askModel {
                DailyAskChatView(model: model, onClose: { chatPresented = false })
            } else {
                // 防御:model 为 nil 时不可呈现空白整页(fullScreenCover 无
                // 下滑 dismiss,空内容 = 用户被困)。理论不可达(.task 先于
                // 任何交互),真发生则立即自愈收回。
                Color.clear.onAppear { chatPresented = false }
            }
        }
        .modifier(TodayScrollEdge())
        .refreshable { onRefresh() }
        .task {
            syncAskModel()
        }
        .onChange(of: interpretState) { _, _ in
            // 解读态落地/变化 → 未开口时刷新开场与候选(已开口保对话)
            syncAskModel()
        }
        .onChange(of: response.dayPillar) { _, _ in
            // 换日:整模型重建(含对话历史——旧盘的对话不留到新盘)
            syncAskModel()
        }
        .onChange(of: chartHash) { _, _ in
            // 换盘:同日换盘 dayPillar/日期都不变,直接监听 chartHash 触发
            // 重建——否则依赖 interpretState 变化间接触发,存在状态值巧合
            // 相等(如双盘都 dailyLimitReached 且 nextReset 相同)不 fire 的
            // 残余路径。key 仍是唯一裁决,这里只是敲门。
            syncAskModel()
        }
        .background(
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Color.clear.onAppear {
                    vm.checkBusinessDateChanged(
                        currentChartHash: chartHash,
                        ziHourRule: ziHourRule,
                    )
                }
            }
        )
    }

    /// 渲染兜底:task 尚未跑过(理论不可达——.task 在首帧后即刻执行)时
    /// 问事框也要有内容可画;只读不落 @State,随后 task 的真模型即刻接管。
    private var fallbackAskModel: DailyAskModel {
        DailyAskModel.make(response: response, interpretState: interpretState)
    }

    // MARK: - hero 小注

    /// 今日信号降级注释(S6):信号空表 = 喜忌不可用时才注释。时辰未知盘
    /// (日柱确定)说「喜忌待补时辰」;hourKnown 且喜忌双空(从格)说
    /// 「特殊格局不下结论」;hourKnown 且喜忌非空但流日五行未命中 = 正常
    /// 无交集(后端 `_day_signal` 对无交集同样返回空表),不编注释只显五行。
    /// dayElements 为 nil(老后端/老快照)时信号行整体隐藏,注释无意义 → nil。
    private var signalNote: String? {
        guard response.dayElements != nil else { return nil }
        guard (response.daySignal ?? []).isEmpty else { return nil }
        if vm.hourGate == .hourUnknownDayDetermined {
            return L10n.DailyFortune.insightNoteHourUnknown
        }
        // 喜忌可用却无交集 → 不是降级,不显示;payload 缺失不臆断从格,同样不显示
        if vm.hasAvailableXiji == false {
            return L10n.DailyFortune.insightNoteSpecialPattern
        }
        return nil
    }

    /// 页脚免责声明(2026-10-18 S6 修订 10-01 D4):只显示
    /// L10n.DailyFortune.disclaimer(「解读仅供参照」)——「乙丑日 · 偏财 · …」
    /// 前两段与头部信息重复,拔除;居中、ink-faint 10.5、无字距。
    private var heroFootnote: some View {
        Text(L10n.DailyFortune.disclaimer)
            .font(BaziFont.caption(size: 10.5))
            .foregroundStyle(BaziTheme.inkMutedSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - iOS 26 底缘滚动边缘效果(2026-10-02 留白修复 §4)

/// Tab 栏下透出正文(2026-10-02 外评「透字显得脏」):iOS 26 浮动 Liquid
/// Glass tab 栏下正文透视属系统默认行为,改用系统滚动边缘效果收底——
/// **不手写 LinearGradient 盖 tab 栏**(DESIGN.md 禁渐变背景,且暗色易穿帮)。
/// 2026-10-18 S5:`.hard` → `.soft`(方案 §4 预留的回退分支已执行——真机
/// 外评 I:hard 在 tab 栏上方形成一条硬色带,与水墨纸面冲突,用户拍板)。
/// 部署目标 17.2:#available 之下 17/18 行为不变。其余三个 tab 同病,
/// 本轮只改今日页,另开任务(方案 §4)。
/// Bug7(2026-10-06 review 核实):`scrollEdgeEffectStyle` 是 iOS 26 SDK 独有
/// 符号,`#available` 只有运行时效果——Xcode 26 之前编译直接失败。外包
/// `#if compiler(>=6.2)`(Xcode 26 = Swift 6.2)做编译期门槛,老工具链
/// 走无效果分支,新工具链行为与原先完全一致。
private struct TodayScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - S4 距底探针 PreferenceKey

/// 内容底在滚动坐标系里的 y(单探针,max 归并只为防御多探针形态)。
private struct TodayContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
