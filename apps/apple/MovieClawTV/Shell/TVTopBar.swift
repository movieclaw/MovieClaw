import SwiftUI

/// 顶栏上能落焦点的一项：左上角账号、正中胶囊里的页签、右上角搜索
enum TVBarItem: Hashable {
    case account
    case tab(MainTab)
    case search
}

/// 顶栏（docs/design/tvos-app.md §3.3），与 Netflix、Disney+ 的新版电视界面同一种排布：
/// 左上角当前账号（头像 + 昵称），正中一枚液态玻璃胶囊放 媒体库 / 订阅 / 发现，右上角搜索。
/// 账号、搜索两头对齐页面内容的左右边线（系统安全区 80 点）。
///
/// 为什么自己画而不用系统 `TabView` 的顶部标签栏：系统标签栏的项目一律居中排开，两侧的附加区
/// （`UITabBar.leadingAccessoryView`）只能显示、不能获得焦点，放不下能按的账号头像与搜索；
/// 把系统标签栏藏起来也不行——藏了它照样给页面顶部留着自己的位置（实测内容被压低 97 点），
/// 首页首屏的尺寸就对不上了。所以页签容器在 `TVMainView` 里自己管，这里按系统标签栏的规矩补齐交互：
/// - 焦点移到胶囊里哪一项就切到哪个页签（与系统标签栏一致，不用再按确认）；
/// - 账号与搜索是按钮：焦点路过不动，按确认才打开（账号页是一个页签，搜索压栈成整页）；
/// - 只在根页面出现，压栈进详情、搜索等二级页就整条收起；
/// - 根页面往下滚离顶部时收走（页面挂 `tvTopBarFollowsScroll()` 才会收，没挂的页面顶栏常驻）；
/// - 根页面上按返回键，焦点先回到顶栏的当前页签，再按一次才退出 App（由 `TVMainView` 接）。
struct TVTopBar: View {
    /// 位置与高度照系统标签栏的规格（HIG：上沿距屏幕顶 46 点、高 68 点），下沿在 114 点
    static let top: CGFloat = 46
    static let height: CGFloat = 68
    /// 根页面在系统安全区（顶部 60 点）之外再让出的高度：内容从屏幕顶 120 点排起，顶栏下面留 6 点。
    /// 首页首屏的竖向尺寸是按「内容从 120 点排起」倒推的（TVHomeView.stageInfoHeight），改这里要一起核对
    static let reservedHeight: CGFloat = 60

    let focus: FocusState<TVBarItem?>.Binding
    /// 主界面的焦点作用域；`preferredItem` 是此刻的首选焦点（按返回键回顶栏时是当前页签，平时 nil）
    let focusNamespace: Namespace.ID
    let preferredItem: TVBarItem?
    /// 在某一项上按确认
    let select: (TVBarItem) -> Void

    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router
    @Environment(\.permissions) private var permissions

    var body: some View {
        ZStack {
            HStack {
                account
                Spacer(minLength: 0)
                search
            }
            tabs
        }
        .frame(height: Self.height)
        // 焦点区只框住顶栏这一条：框大了（比如框到整屏）系统按几何找上下邻居时会乱跳
        .focusSection()
        .padding(.top, Self.top)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    /// 胶囊里的页签，从左到右
    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(permissions.canSubscribe ? [MainTab.home, .subscriptions, .discover] : [.home, .discover], id: \.self) { tab in
                Button { select(.tab(tab)) } label: {
                    Text(Self.title(tab))
                        .font(.system(size: 28, weight: .semibold))
                        .padding(.horizontal, 30)
                        .frame(height: 56)
                }
                .buttonStyle(TVTopBarItemStyle(selected: router.selectedTab == tab, padding: 0))
                .focused(focus, equals: .tab(tab))
                .prefersDefaultFocus(preferredItem == .tab(tab), in: focusNamespace)
                .accessibilityIdentifier("tv-topbar-\(tab.rawValue)")
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .capsule)
    }

    private var account: some View {
        Button { select(.account) } label: {
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
        .prefersDefaultFocus(preferredItem == .account, in: focusNamespace)
        .accessibilityIdentifier("tv-topbar-account")
    }

    private var search: some View {
        Button { select(.search) } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .frame(width: Self.height, height: Self.height)
        }
        .buttonStyle(TVTopBarItemStyle(selected: false, padding: 0))
        .glassEffect(.regular, in: .circle)
        .focused(focus, equals: .search)
        .accessibilityLabel("搜索")
        .accessibilityIdentifier("tv-topbar-search")
    }

    static func title(_ tab: MainTab) -> String {
        switch tab {
        case .account: "账号"
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
