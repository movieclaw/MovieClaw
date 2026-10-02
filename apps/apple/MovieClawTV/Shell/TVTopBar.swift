import SwiftUI

/// 顶栏（docs/design/tvos-app.md §3.3）：左上角是当前账号（头像 + 昵称），正中一枚液态玻璃胶囊
/// 放 🔍 / 媒体库 / 订阅 / 发现，与 Netflix、Disney+ 的新版电视界面同一种排布。
///
/// 为什么自己画而不用系统 `TabView` 的顶部标签栏：系统标签栏的项目一律居中排开，两侧的附加区
/// （`UITabBar.leadingAccessoryView`）只能显示、不能获得焦点，放不下一个能按的账号头像。
/// 所以系统标签栏藏起来（`TabView` 只负责各页签的导航栈与切换），这里按同样的规矩补齐交互：
/// - 焦点移到胶囊里哪一项就切到哪个页签（与系统标签栏一致，不用再按确认）；账号头像按确认才打开；
/// - 只在根页面出现，压栈进详情等二级页就整条收起；
/// - 根页面往下滚离顶部时收走（页面挂 `tvTopBarFollowsScroll()` 才会收，没挂的页面顶栏常驻）；
/// - 根页面上按返回键，焦点先回到顶栏的当前页签，再按一次才退出 App（由 `TVMainView` 接）。
struct TVTopBar: View {
    /// 顶栏占掉的高度：根页面的内容从这条线往下排（首页大图例外，铺到屏幕上沿、顶栏浮在图上）
    static let reservedHeight: CGFloat = 110

    let focus: FocusState<MainTab?>.Binding
    /// 主界面的焦点作用域；`preferred` 时当前页签是首选焦点（按返回键回顶栏）
    let focusNamespace: Namespace.ID
    let preferred: Bool
    /// 在胶囊里的页签上按确认：焦点下到页面内容（同系统标签栏）
    let enterContent: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router
    @Environment(\.permissions) private var permissions
    @Environment(\.api) private var api

    var body: some View {
        ZStack {
            HStack {
                account
                Spacer(minLength: 0)
            }
            tabs
        }
        .padding(.horizontal, TVMetrics.edge)
        .padding(.top, 44)
        .focusSection()
        // 焦点进顶栏（含冷启动时系统挑的第一个焦点）落在当前页签上，而不是最左上角的账号——否则一启动就切到了账号页
        .defaultFocus(focus, router.selectedTab)
    }

    /// 页签：顺序即胶囊里从左到右
    private var items: [MainTab] {
        permissions.canSubscribe ? [.search, .home, .subscriptions, .discover] : [.search, .home, .discover]
    }

    private var account: some View {
        // 账号是一枚按钮而不是页签：焦点路过不切页（冷启动时系统常把第一个焦点给屏幕最左上角，
        // 不然一启动就进了账号页），按确认才打开账号页
        Button { router.selectedTab = .account } label: {
            HStack(spacing: 16) {
                if let session = model.session {
                    TVAvatar(url: model.server?.imageURL(AvatarURL.tagged(session.avatarUrl, username: session.username)),
                             name: session.nickname, size: 52)
                    Text(session.nickname)
                        .font(.system(size: 28, weight: .semibold))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(TVTopBarItemStyle(selected: router.selectedTab == .account, padding: 8))
        .focused(focus, equals: .account)
        .accessibilityIdentifier("tv-topbar-account")
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { tab in
                Button(action: enterContent) { label(for: tab) }
                    .buttonStyle(TVTopBarItemStyle(selected: router.selectedTab == tab, padding: 0))
                    .focused(focus, equals: tab)
                    .prefersDefaultFocus(preferred && router.selectedTab == tab, in: focusNamespace)
                    .accessibilityIdentifier("tv-topbar-\(tab.rawValue)")
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private func label(for tab: MainTab) -> some View {
        switch tab {
        case .search:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .semibold))
                .frame(width: 64, height: 56)
                .accessibilityLabel("搜索")
        default:
            Text(Self.title(tab))
                .font(.system(size: 28, weight: .semibold))
                .padding(.horizontal, 30)
                .frame(height: 56)
        }
    }

    static func title(_ tab: MainTab) -> String {
        switch tab {
        case .account: "账号"
        case .search: "搜索"
        case .home: "媒体库"
        case .subscriptions: "订阅"
        case .discover: "发现"
        }
    }
}

/// 顶栏一项的样子：获得焦点是白底黑字、微微放大；当前页签（焦点不在它身上时）是一层浅白底；其余半透明白字
private struct TVTopBarItemStyle: ButtonStyle {
    let selected: Bool
    let padding: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        ItemBody(configuration: configuration, selected: selected, padding: padding)
    }

    private struct ItemBody: View {
        let configuration: Configuration
        let selected: Bool
        let padding: CGFloat
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .padding(padding)
                .padding(.trailing, padding > 0 ? 12 : 0)
                .foregroundStyle(focused ? .black : .white.opacity(selected ? 1 : 0.7))
                .background {
                    Capsule()
                        .fill(focused ? .white : .white.opacity(selected ? 0.18 : 0))
                }
                .scaleEffect(focused ? 1.06 : 1)
                .shadow(color: .black.opacity(focused ? 0.35 : 0), radius: 14, y: 6)
                .animation(.easeOut(duration: 0.18), value: focused)
                .animation(.easeOut(duration: 0.18), value: selected)
        }
    }
}

extension EnvironmentValues {
    /// 当前视图是哪个页签的根页面（压栈页面里是 nil）：顶栏随根页面滚动收起时用
    @Entry var tvRootTab: MainTab?
}

extension View {
    /// 根页面的竖向滚动视图挂上它：滚离顶部顶栏收走，回到顶部再出现（同系统标签栏随内容滚出屏幕）
    func tvTopBarFollowsScroll() -> some View {
        modifier(TVTopBarScrollTracking())
    }
}

private struct TVTopBarScrollTracking: ViewModifier {
    @Environment(TVRouter.self) private var router
    @Environment(\.tvRootTab) private var tab

    @State private var position = ScrollPosition(edge: .top)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 60
            } action: { _, away in
                guard let tab else { return }
                if away { router.scrolledAway.insert(tab) } else { router.scrolledAway.remove(tab) }
            }
            .onChange(of: tab.flatMap { router.scrollToTopRequests[$0] }) {
                withAnimation(.easeOut(duration: 0.3)) { position.scrollTo(edge: .top) }
            }
    }
}
