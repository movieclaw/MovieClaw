import SwiftUI

/// Mac 版欢迎页：本机没有登录中的账号时，主窗口整个是这一页（`MacRootView` 按 `AppModel.phase` 切过来）。
///
/// 观感与 iPhone、Apple TV 版同一套：写实克制的深空（`CosmosBackdrop`）+ 片名「MovieClaw / 智能影音服务器」，
/// 正中一张液态玻璃卡片，窗口够高时底部像电影字幕一样轮播一句台词。卡片按步骤换内容（`MacWelcomeStep`）：
///
/// | 状态（`AppModel.phase`） | 起始卡片 |
/// |---|---|
/// | 第一次使用（needsServer） | 找服务器（局域网自动发现 / 登录过的 / 手填地址）→ 登录 |
/// | 账号都退出了 / 登录过期（needsLogin） | 登录（服务器沿用上次的；过期时用户名已预填并说明原因） |
/// | 服务器是全新的（needsSetup） | 同一张登录卡片的「初始化」形态：创建超级管理员 |
/// | 当前服务器没有账号了、别处还有（chooseAccount） | 选择账号（头像 + 名字 + 服务器），一点即进 |
/// | 冷启动连不上（unreachable） | 原因 + 重试 / 换服务器 / 切换到其他账号 |
///
/// 起始卡片由状态机决定，用户在页内往前走的步骤（换服务器、从选人跳到某个过期账号的登录）压在 `path` 里，
/// 卡片左上角「返回」或 Esc 退一步；状态机换了状态（重试后发现登录过期、登录成功等）就清空 `path`，回到新状态的起始卡片。
///
/// 键盘：Tab 在输入框之间切换、回车提交（主按钮是窗口的默认按钮）、Esc 返回上一步。
struct MacWelcomeView: View {
    @Environment(AppModel.self) private var model
    /// 用户在页内往前走的步骤（栈顶是当前卡片）；空 = 停在状态机决定的起始卡片
    @State private var path: [MacWelcomeStep] = []

    var body: some View {
        MacWelcomeStage {
            card(for: path.last ?? rootStep)
                .id(path.last ?? rootStep)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.98)), removal: .opacity))
        }
        .animation(.smooth(duration: 0.35), value: path)
        .onChange(of: model.phase) { _, _ in path = [] }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-welcome")
    }

    /// 状态机决定的起始卡片
    private var rootStep: MacWelcomeStep {
        switch model.phase {
        case .chooseAccount:
            return .chooser
        case .unreachable:
            return .unreachable
        case .needsSetup:
            guard let server = model.server else { return .server }
            return .signIn(.init(server: server, setup: true))
        case .needsLogin:
            guard let server = model.server else { return .server }
            let expired = model.expiredUsername
            return .signIn(.init(server: server, username: expired, expired: expired != nil))
        default:
            return .server
        }
    }

    /// 返回上一步：只有页内往前走过才有（起始卡片没有「返回」）
    private var back: (() -> Void)? {
        path.isEmpty ? nil : { path.removeLast() }
    }

    @ViewBuilder
    private func card(for step: MacWelcomeStep) -> some View {
        switch step {
        case .server:
            MacServerPicker(saved: model.savedServers, onBack: back) { address in
                path.append(.signIn(.init(server: address)))
            }
        case let .signIn(target):
            MacSignInStep(
                target: target,
                onBack: back,
                onChangeServer: { path.append(.server) },
                onSwitchAccount: model.accountsOnOtherServers.isEmpty ? nil : { path.append(.chooser) }
            )
        case .chooser:
            MacAccountChooser(
                accounts: model.accountsOnOtherServers,
                onBack: back,
                onSignInAnother: { path.append(.server) },
                onNeedsPassword: { server, username in
                    path.append(.signIn(.init(server: server, username: username, expired: true)))
                }
            )
        case .unreachable:
            MacUnreachableCard(
                server: model.server,
                reason: model.launchError,
                onChangeServer: { path.append(.server) },
                onChooseAccount: model.accountsOnOtherServers.isEmpty ? nil : { path.append(.chooser) }
            )
        }
    }
}

/// 欢迎页的一步（卡片）
enum MacWelcomeStep: Hashable {
    /// 找服务器
    case server
    /// 登录到某台服务器（含「初始化」形态）
    case signIn(MacSignInTarget)
    /// 选择本机登录过的其他账号
    case chooser
    /// 连不上当前服务器
    case unreachable
}

/// 登录卡片要登到哪儿、预填什么
struct MacSignInTarget: Hashable {
    var server: ServerAddress
    /// 预填的用户名（登录过期、从选人跳过来）
    var username: String?
    /// 是不是「登录过期」：标题改「重新登录」，并说明是谁的登录失效了
    var expired = false
    /// 已知这台服务器是全新的：一出来就是「初始化」形态（创建超级管理员）
    var setup = false
}

// MARK: - 舞台：星空 + 片名 + 卡片 + 台词

/// 欢迎页的整窗布局：深空背景铺满（含标题栏区域），片名在上、卡片居中，窗口够高时底部轮播一句台词。
/// 窗口标题与工具栏底色在这一页隐藏，只留左上角的红绿灯，像一张完整的片头。
struct MacWelcomeStage<Card: View>: View {
    @ViewBuilder let card: () -> Card

    /// 星空从黑暗中亮起、地平线随后亮起（片头）
    @State private var lit = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CosmosBackdrop(lit: lit, dimmed: true)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 28) {
                        MacWelcomeMasthead()
                        card()
                    }
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            // 窗口够高才放台词：矮窗口（最小 600 高）里卡片已占满，再塞台词会和卡片打架
            .overlay(alignment: .bottom) {
                if proxy.size.height >= 820 {
                    MacFilmSubtitle()
                        .padding(.bottom, 34)
                        .transition(.opacity)
                }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4)) { lit = true }
        }
    }
}

/// 片名：衬线体「Movie*Claw*」+ 一道细线 + 宋体「智能影音服务器」（同 iPhone 版片名，Mac 上用小一号的常驻版）
struct MacWelcomeMasthead: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("\(Text("Movie"))\(Text("Claw").italic())")
                .font(.system(size: 40, weight: .light, design: .serif))
                .tracking(1)
                .foregroundStyle(Theme.accentStrong)
            Rectangle()
                .fill(Theme.text.opacity(0.5))
                .frame(width: 28, height: 0.5)
            Text("智能影音服务器")
                .font(.welcomeSerif(size: 12))
                .tracking(7)
                .foregroundStyle(Theme.textMuted)
        }
        .shadow(color: .black.opacity(0.4), radius: 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 窗口底部的电影字幕：一句经典台词（宋体）+ 外语原句 + 片名年份，9 秒换一句，点一下也换
private struct MacFilmSubtitle: View {
    @State private var scenes = WelcomeScene.all.shuffled()
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            if !scenes.isEmpty {
                let scene = scenes[index % scenes.count]
                VStack(spacing: 6) {
                    Text(scene.line)
                        .font(.welcomeSerif(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(Theme.text.opacity(0.85))
                    if let original = scene.original {
                        Text(original)
                            .font(.system(size: 11, design: .serif))
                            .italic()
                            .foregroundStyle(Theme.textMuted)
                    }
                    Text(verbatim: "——《\(scene.film)》\(scene.year)")
                        .font(.welcomeSerif(size: 10))
                        .tracking(2)
                        .foregroundStyle(Theme.textFaint)
                        .padding(.top, 2)
                }
                .multilineTextAlignment(.center)
                .shadow(color: .black.opacity(0.6), radius: 8)
                .id(index)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 560)
        .contentShape(Rectangle())
        .onTapGesture(perform: next)
        .help("点一下换一句")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("mac-welcome-quote")
        // 每换一句（定时到了或用户点的）这个任务都随 id 重启，重新计时
        .task(id: index) {
            try? await Task.sleep(for: .seconds(9))
            guard !Task.isCancelled else { return }
            next()
        }
    }

    private func next() {
        withAnimation(.easeInOut(duration: 0.9)) { index += 1 }
    }
}

// MARK: - 添加账号（sheet）

/// 已登录时从侧边栏账号浮层「添加账号…」打开的 sheet：登录到这台或另一台服务器上的又一个账号。
///
/// 与欢迎页同一套卡片内容（`MacSignInStep` / `MacServerPicker`），只是不铺星空、卡片不套玻璃（sheet 自己就是一层材质）：
/// 起始是登录到当前服务器，「更换服务器」进找服务器那一步，Esc 退回；在起始卡片上 Esc 等于取消。
/// 登录成功后当前账号换成新账号，主界面整棵重建（这个 sheet 随之消失）；登的若正是当前账号，主界面不重建，这里自己关掉。
struct MacAddAccountView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// 正在找服务器（从登录卡片「更换服务器」进来）
    @State private var picking = false
    /// 登录到哪台服务器：默认当前这台，找服务器那一步选了别的就换成那台
    @State private var chosen: ServerAddress?

    var body: some View {
        let server = chosen ?? model.server
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if picking || server == nil {
                    MacServerPicker(saved: model.savedServers, onBack: server == nil ? nil : { picking = false }) { address in
                        chosen = address
                        picking = false
                    }
                } else if let server {
                    MacSignInStep(
                        target: .init(server: server),
                        purpose: .addAccount,
                        onChangeServer: { picking = true },
                        onSignedIn: { dismiss() }
                    )
                    .id(server)
                }
            }
            .environment(\.macWelcomeCardOnGlass, false)

            Divider()
            HStack {
                Spacer()
                // 在找服务器那一步时 Esc 归卡片上的「返回」，这里不抢
                if picking {
                    Button("取消") { dismiss() }
                } else {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: MacWelcomeMetrics.cardWidth)
        .animation(.smooth(duration: 0.3), value: picking)
        .accessibilityIdentifier("mac-add-account")
    }
}
