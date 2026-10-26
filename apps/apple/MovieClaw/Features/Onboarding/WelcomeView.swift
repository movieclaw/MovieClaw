import SwiftUI

/// 欢迎页：本机没有登录中的账号时的整屏页面，也是「添加账号」的那张卡片。
///
/// 背景始终是同一片写实的深空（`CosmosBackdrop`：星空、银河、行星地平线），几种状态在同一页里切换，不跳页面：
/// - **首页**（本机没有登录中的账号：第一次打开、账号全部退出后）：星空浮现、地平线像轨道日出一样亮起，片名浮现，
///   下方像电影字幕一样轮播科幻电影的台词，底部一个液态玻璃按钮——第一次叫「连接服务器」，连过服务器后叫「登录」。
///   先让人看完首页，点了按钮才升起登录卡片，不一进来就弹键盘；
/// - **登录卡片**：服务器地址、用户名、密码一张表，一步进入；右上角 × 收起卡片回到来的地方（首页等）。
///   服务器是全新的，就在同一张卡片里补一个确认密码，创建超级管理员。登录过期时预填服务器与用户名，只需输密码；
/// - **选择账号**：当前服务器上已经没有登录中的账号、别的服务器上还有时（比如退出了这台上的最后一个账号），
///   先列出来让用户一点即进，不用输密码；也可以「登录其他账号」；
/// - **连不上服务器**：冷启动连不上时不逼人重新登录——登录态还在，给「重试 / 修改服务器地址 / 切换到其他账号」。
///
/// 已登录时从「切换账号」里点「添加账号」，也打开这一页（`Mode.addAccount`）：直接是登录卡片，服务器预填当前这台、
/// 可以改——改成别的地址就是登录到另一台服务器。卡片右上角 × 关掉，回到原来的账号。
///
/// 键盘只在用户点了按钮打开卡片时自动弹出；页面自己出现的卡片（冷启动发现登录过期）不抢焦点，等用户点输入框。
struct WelcomeView: View {
    /// 从哪里打开
    enum Mode: Equatable {
        /// 顶层：没有登录中的账号时由 RootView 渲染，显示哪种状态跟着 `AppModel.phase` 走
        case root
        /// 已登录时从「切换账号」里打开：添加账号，或给某个登录过期的账号重新输密码（带用户名）
        case addAccount(server: ServerAddress?, username: String?)
    }

    private enum Stage {
        /// 首页：星空、片名、台词，底部「连接服务器」/「登录」按钮
        case home
        case form
        case chooser
        case unreachable
    }

    let mode: Mode
    /// 「添加账号」卡片点关闭时调用（登录成功后主界面会整棵重建，用不着回调）
    var onClose: (() -> Void)?

    @Environment(AppModel.self) private var model
    @State private var stage: Stage
    /// 登录卡片点 × 回到哪一页：从哪来回哪去，卡片是自己出现的就回首页
    @State private var formReturn: Stage = .home
    /// 登录卡片出现时要不要直接弹键盘：用户点按钮打开的才弹，页面自己出现的不抢焦点
    @State private var formAutoFocus: Bool
    /// 页内跳转带来的预填（从「选择账号」「连不上」跳到登录卡片时），盖过按状态推出来的默认预填
    @State private var override: WelcomeSignInPanel.Prefill?
    /// 台词：每次打开首页打乱一次顺序，`sceneIndex` 是在这份顺序里的位置
    @State private var scenes = WelcomeScene.all.shuffled()
    @State private var sceneIndex = 0
    /// 宇宙从黑暗中亮起：先是星空，再是地平线
    @State private var lit = false
    /// 片名、副标题、字幕、按钮依次浮现
    @State private var revealed = false
    /// 正在输入（表单里有输入框获得焦点、键盘弹起）时收起顶部片名：
    /// 小屏上「片名 + 表单」高过键盘上方的空间，登录按钮会被键盘挡住。
    /// 用焦点而不是键盘通知判断：转场动画中途弹键盘时，通知的先后顺序不可靠，片名会残留在状态栏下
    @State private var editing = false

    private static let panelID = "welcome-panel"

    /// 每句台词停留的时长（点一下换句后重新计时）
    private static let sceneDuration: Duration = .seconds(9)

    /// - Parameter expired: 当前是不是「登录过期」（`AppModel.expiredUsername` 非空）：过期直接给重新登录的卡片，
    ///   否则没有账号时先停在首页
    init(mode: Mode, phase: AppModel.Phase, expired: Bool = false, onClose: (() -> Void)? = nil) {
        self.mode = mode
        self.onClose = onClose
        _stage = State(initialValue: Self.stage(for: phase, expired: expired, mode: mode))
        // 添加账号是用户点出来的，直接弹键盘；顶层的卡片是页面自己出现的，不抢焦点
        _formAutoFocus = State(initialValue: mode != .root)
    }

    var body: some View {
        ZStack {
            CosmosBackdrop(lit: lit, dimmed: stage != .home)
                .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 0) {
                        if stage == .home || !editing {
                            WelcomeMasthead(revealed: revealed, compact: stage != .home)
                                .padding(.top, stage == .home ? proxy.size.height * 0.22 : 12)
                                .transition(.opacity)
                        }

                        Spacer(minLength: 28)

                        switch stage {
                        case .home:
                            // 叠在同一个位置过渡（ZStack）：放在 VStack 里新旧两句会上下挤在一起、把按钮顶来顶去
                            ZStack(alignment: .bottom) {
                                FilmSubtitle(scene: scenes[sceneIndex], onNext: nextScene)
                                    .id(sceneIndex)
                                    .transition(.quoteChange)
                            }
                            .opacity(revealed ? 1 : 0)
                                .animation(.easeInOut(duration: 1.4).delay(revealed ? 2.2 : 0), value: revealed)
                            Spacer(minLength: 40)
                            startButton
                        case .form:
                            WelcomeSignInPanel(
                                editing: $editing,
                                purpose: purpose,
                                prefill: prefill,
                                autoFocus: formAutoFocus,
                                onSwitchAccount: canChooseAccount ? { go(.chooser) } : nil,
                                onSignedIn: onClose,
                                onClose: mode == .root ? { go(formReturn) } : onClose
                            )
                            // 预填变了（从「选择账号」点到另一个过期账号）就换一张新卡片，按新的预填初始化
                            .id(prefill)
                            .id(Self.panelID)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .chooser:
                            WelcomeAccountChooser(
                                onSignInAnother: { openForm(from: .chooser, prefill: .init(server: model.server, username: nil)) },
                                onNeedsPassword: { server, username in openForm(from: .chooser, prefill: .init(server: server, username: username)) }
                            )
                            .id(Self.panelID)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        case .unreachable:
                            WelcomeUnreachableCard(
                                onEditAddress: { openForm(from: .unreachable, prefill: .init(server: model.server, username: nil)) },
                                onChooseAccount: canChooseAccount ? { go(.chooser) } : nil
                            )
                            .id(Self.panelID)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 440)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                // 收起 / 放出片名后内容高度变了，滚动位置却还停在原处（卡片会被顶到状态栏下）：
                // 等键盘动画走完，把卡片底边贴回可视区底部（键盘上方）
                .onChange(of: editing) {
                    Task {
                        try? await Task.sleep(for: .milliseconds(380))
                        withAnimation(.smooth(duration: 0.3)) { scroller.scrollTo(Self.panelID, anchor: .bottom) }
                    }
                }
                }
            }
        }
        .task { await play() }
        // 台词定时轮换：每换一句（不管是定时到了还是用户点的）这个任务都会随 id 重启，重新计时
        .task(id: sceneIndex) {
            try? await Task.sleep(for: Self.sceneDuration)
            guard !Task.isCancelled, stage == .home else { return }
            nextScene()
        }
        .onChange(of: model.phase) { _, phase in
            // 顶层：状态机换了状态（重试后发现登录过期等）就换到对应的卡片；
            // 用户正在填的登录卡片不会被「回首页」打断
            guard mode == .root else { return }
            let next = Self.stage(for: phase, expired: model.expiredUsername != nil, mode: mode)
            guard next != stage, !(stage == .form && next == .home) else { return }
            formAutoFocus = false
            formReturn = .home
            go(next)
        }
    }

    private static func stage(for phase: AppModel.Phase, expired: Bool, mode: Mode) -> Stage {
        if case .addAccount = mode { return .form }
        switch phase {
        case .needsServer: return .home
        case .needsLogin: return expired ? .form : .home
        case .chooseAccount: return .chooser
        case .unreachable: return .unreachable
        default: return .form
        }
    }

    /// 登录卡片的预填：页内跳转带来的优先；否则添加账号用传进来的，顶层用当前服务器与登录过期的用户名
    private var prefill: WelcomeSignInPanel.Prefill {
        if let override { return override }
        switch mode {
        case let .addAccount(server, username): return .init(server: server ?? model.server, username: username)
        case .root: return .init(server: model.server, username: model.expiredUsername)
        }
    }

    private var purpose: WelcomeSignInPanel.Purpose {
        if prefill.username != nil { return .reauth }
        if case .addAccount = mode { return .addAccount }
        return prefill.server == nil ? .connect : .signIn
    }

    /// 别的服务器上还有登录中的账号，才给「切换到其他账号」（添加账号的卡片不给：身后就是切换账号列表）
    private var canChooseAccount: Bool {
        mode == .root && !model.accountsOnOtherServers.isEmpty
    }

    private func go(_ next: Stage, prefill: WelcomeSignInPanel.Prefill? = nil) {
        withAnimation(.smooth(duration: 0.6)) {
            override = prefill
            stage = next
            // 离开登录卡片时输入框随之销毁，焦点回调不一定来得及触发：手动复位，免得回到首页片名还藏着
            if next != .form { editing = false }
        }
    }

    /// 用户点按钮打开登录卡片：记下从哪来（× 回那里），卡片升起后直接弹键盘
    private func openForm(from origin: Stage, prefill: WelcomeSignInPanel.Prefill? = nil) {
        formReturn = origin
        formAutoFocus = true
        go(.form, prefill: prefill)
    }

    /// 首页底部的主按钮。第一次（本机没连过服务器）叫「连接服务器」：这一步要做的就是把 App 连上自己部署的服务器，
    /// 填地址是主角、登录是顺带；连过之后只是账号退出了，地址已经填好，叫「登录」
    private var startButton: some View {
        Button {
            openForm(from: .home)
        } label: {
            Text(model.server == nil ? String(localized: .authServerConnect) : String(localized: .authLoginSubmit))
                .font(.welcomeSerif(size: 17))
                .tracking(AppLanguage.identifier == "zh-Hans" ? 4 : 0.5)
                .frame(minWidth: 132)
                .padding(.horizontal, 28)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 12)
        .animation(.easeOut(duration: 1.0).delay(revealed ? 2.8 : 0), value: revealed)
        .accessibilityIdentifier("welcome-start")
    }

    /// 片头调度：先点亮星空、再依次浮出片名、台词、按钮
    private func play() async {
        withAnimation(.easeInOut(duration: stage == .home ? 2.6 : 1.2)) { lit = true }
        revealed = true
    }

    /// 换下一句台词：旧句上移淡出、新句从下方淡入（`quoteChange`）；一轮放完再打乱一次
    private func nextScene() {
        withAnimation(.easeInOut(duration: 0.9)) {
            if sceneIndex + 1 < scenes.count {
                sceneIndex += 1
            } else {
                scenes = WelcomeScene.all.shuffled()
                sceneIndex = 0
            }
        }
    }
}

/// 片名：衬线体「Movie*Claw*」+ 一道细线 + 宋体「智能影音服务器」。
/// 片头时字距从宽收紧、缓缓浮现；进入登录后整体缩小留在顶部。
private struct WelcomeMasthead: View {
    let revealed: Bool
    let compact: Bool

    var body: some View {
        VStack(spacing: 14) {
            Text("\(Text("Movie"))\(Text("Claw").italic())")
                .font(.system(size: 46, weight: .light, design: .serif))
                .tracking(revealed ? 1 : 12)
                .foregroundStyle(Theme.accentStrong)
                .opacity(revealed ? 1 : 0)
                .animation(.easeOut(duration: 2.4).delay(revealed ? 0.6 : 0), value: revealed)

            Rectangle()
                .fill(Theme.text.opacity(0.5))
                .frame(width: revealed ? 28 : 0, height: 0.5)
                .animation(.easeInOut(duration: 1.2).delay(revealed ? 1.4 : 0), value: revealed)

            Text(String(localized: .authBrandTagline))
                .font(.welcomeSerif(size: 13))
                .tracking(AppLanguage.identifier == "zh-Hans" ? 8 : 0.5)
                .foregroundStyle(Theme.textMuted)
                .opacity(revealed ? 1 : 0)
                .animation(.easeOut(duration: 1.4).delay(revealed ? 1.6 : 0), value: revealed)
        }
        .shadow(color: .black.opacity(0.35), radius: 16)
        .scaleEffect(compact ? 0.72 : 1, anchor: .top)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 电影字幕（宋体）：中文一行（或两行）在上，外语原句小一号斜体在下，再下是片名与年份。
/// 固定最小高度，换场时一行与三行的字幕不会把下面的按钮顶来顶去。
private struct FilmSubtitle: View {
    let scene: WelcomeScene
    /// 点一下换下一句
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(scene.headline)
                .font(.welcomeSerif(size: 18))
                .lineSpacing(7)
                .foregroundStyle(Theme.text)
            if let original = scene.subline {
                Text(original)
                    .font(.system(size: 13, weight: .regular, design: .serif))
                    .italic()
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textMuted)
            }
            Text(verbatim: "—— " + scene.source)
                .font(.welcomeSerif(size: 11))
                .tracking(2)
                .foregroundStyle(Theme.textFaint)
                .padding(.top, 6)
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.6), radius: 10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .bottom)
        // 整块台词区都能点（包括行间空白），点一下换一句
        .contentShape(Rectangle())
        .onTapGesture(perform: onNext)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(String(localized: .authBrandNextQuote))
        .accessibilityIdentifier("welcome-quote")
    }
}

/// 换台词的文字过渡：旧句向上飘走、渐隐并虚化，新句从下方浮上来、由虚变实——像字幕淡出淡入，
/// 比整块交叉淡化更有「翻过一句」的方向感。位移与模糊都很小，只是一点点呼吸感
private struct QuoteShift: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

private extension AnyTransition {
    /// 旧句先走（0.45 秒），新句稍晚进来（晚 0.25 秒、0.7 秒浮上来）：两句只短暂交叠，读起来是一句接一句
    static var quoteChange: AnyTransition {
        .asymmetric(
            insertion: AnyTransition.modifier(
                active: QuoteShift(offset: 14, blur: 6, opacity: 0),
                identity: QuoteShift(offset: 0, blur: 0, opacity: 1)
            )
            .animation(.easeOut(duration: 0.7).delay(0.25)),
            removal: AnyTransition.modifier(
                active: QuoteShift(offset: -14, blur: 6, opacity: 0),
                identity: QuoteShift(offset: 0, blur: 0, opacity: 1)
            )
            .animation(.easeIn(duration: 0.45))
        )
    }
}
