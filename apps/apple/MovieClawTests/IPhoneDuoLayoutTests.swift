import CoreGraphics
import Testing
import UIKit
@testable import MovieClaw

/// iPhone Duo 适配（docs/design/iphone-duo.md）：版式按尺寸类别、卡片按观看距离、开合时外壳与播放器的取舍。
/// 单测跑在 iPhone 模拟器上（idiom 是 .phone，同 Duo）
@MainActor
struct IPhoneDuoLayoutTests {
    // MARK: 版式档

    @Test func onlyRegularByRegularIsWide() {
        #expect(WindowLayout.isWide(horizontal: .regular, vertical: .regular))
        // Pro Max 横屏：常规宽 × 紧凑高，仍是手机版式
        #expect(!WindowLayout.isWide(horizontal: .regular, vertical: .compact))
        // iPhone 竖屏、Duo 外屏、分屏
        #expect(!WindowLayout.isWide(horizontal: .compact, vertical: .regular))
        #expect(!WindowLayout.isWide(horizontal: .compact, vertical: .compact))
        #expect(!WindowLayout.isWide(horizontal: nil, vertical: .regular))
    }

    // MARK: 卡片尺寸

    @Test func phoneWindowKeepsPhoneMetrics() {
        #expect(CardMetrics.forWindow(wide: false) == .phone)
    }

    @Test func duoInnerDisplayIsWideLayoutWithPhoneCards() {
        let metrics = CardMetrics.forWindow(wide: true)
        #expect(metrics.isWide)
        #expect(metrics == .widePhone)
        #expect(metrics.posterTarget == CardMetrics.phone.homePoster)
        #expect(metrics.upNext == CardMetrics.phone.upNext)
        #expect(metrics.cast == CardMetrics.phone.cast)
    }

    @Test func duoInnerRowFitsAboutSixPhoneSizedPosters() {
        // 书本横向 951 点，竖排标签栏约 70 点，内容区约 880 点
        let metrics = CardMetrics.widePhone.fitted(contentWidth: 880)
        #expect(metrics.wallColumns().count == 6)
        #expect(abs(metrics.homePoster - CardMetrics.phone.homePoster) < 8)
    }

    @Test func foldPrefersEvenColumns() {
        // 内容区 760 点：手机尺寸排出 5 列；有折痕时取最接近的偶数列，让折痕落在两列之间
        var metrics = CardMetrics.widePhone
        #expect(metrics.fitted(contentWidth: 760).wallColumns().count == 5)
        metrics.evenColumns = true
        #expect(metrics.fitted(contentWidth: 760).wallColumns().count % 2 == 0)
        // 窄到只够一列时也至少两列
        #expect(metrics.fitted(contentWidth: 200).wallColumns().count == 2)
    }

    // MARK: 播放器转屏

    @Test func phoneControlsRotationOnlyInPhoneLayout() {
        #expect(PlayerOrientation.appControlsRotation(wide: false))
        // Duo 内屏不认 App 的方向请求：返回键不能变成「退出横屏」
        #expect(!PlayerOrientation.appControlsRotation(wide: true))
    }

    // MARK: 播放器折痕排法

    private let inner = CGSize(width: 669, height: 951)

    @Test func noActiveFoldIsFlat() {
        #expect(PlayerFold.resolve(size: inner, folds: []) == .flat)
        #expect(PlayerFold.resolve(size: inner, folds: [.null]) == .flat)
        // 全开时折痕宽度为 0
        #expect(PlayerFold.resolve(size: inner, folds: [CGRect(x: 0, y: 470, width: 0, height: 0)]) == .flat)
    }

    @Test func horizontalFoldIsTabletop() {
        let fold = CGRect(x: 0, y: 460, width: 669, height: 30)
        #expect(PlayerFold.resolve(size: inner, folds: [fold]) == .tabletop(videoBottom: 460, deckTop: 490))
    }

    @Test func verticalFoldShiftsCenterControlsToRightHalf() {
        let size = CGSize(width: 951, height: 669)
        let fold = CGRect(x: 460.5, y: 0, width: 30, height: 669)
        guard case let .book(shift) = PlayerFold.resolve(size: size, folds: [fold]) else {
            Issue.record("应为书本半折")
            return
        }
        // 右半边正中：490.5 + 460.5 / 2 = 720.75，相对整屏中线 475.5 右移 245.25
        #expect(abs(shift - 245.25) < 0.01)
    }

    @Test func bookShiftNeverPushesControlsOffScreen() {
        // 窄屏（466 宽）的右半边放不下 260 点宽的按钮组：挪到贴右边 16 点为止
        let size = CGSize(width: 466, height: 678)
        let fold = CGRect(x: 221, y: 0, width: 24, height: 678)
        guard case let .book(shift) = PlayerFold.resolve(size: size, folds: [fold]) else {
            Issue.record("应为书本半折")
            return
        }
        #expect(abs(shift - (233 - 130 - 16)) < 0.01)
    }

    @Test func foldTooCloseToEdgeIsIgnored() {
        #expect(PlayerFold.resolve(size: inner, folds: [CGRect(x: 0, y: 60, width: 669, height: 20)]) == .flat)
        #expect(PlayerFold.resolve(size: CGSize(width: 951, height: 669), folds: [CGRect(x: 900, y: 0, width: 20, height: 669)]) == .flat)
    }

    // MARK: 桌面模式控制台

    @Test func deckCardsAlwaysFillTwoRows() {
        // 电影 6 张（无「下一集」）3×2；剧集 7 张 4 + 3；访客分享少画质时 5 张 3 + 2
        #expect(PlayerDeckCards.columns(for: 6) == 3)
        #expect(PlayerDeckCards.columns(for: 7) == 4)
        #expect(PlayerDeckCards.columns(for: 8) == 4)
        #expect(PlayerDeckCards.columns(for: 5) == 3)
        #expect(PlayerDeckCards.columns(for: 2) == 3)
    }

    // MARK: 头像页签

    @Test func avatarIsRightmostInHorizontalTabBar() {
        let frames = (0..<5).map { CGRect(x: CGFloat($0) * 70, y: 0, width: 60, height: 44) }
        #expect(AccountGestureHub.lastTabIndex(frames) == 4)
    }

    @Test func avatarIsBottommostInVerticalTabBar() {
        // Duo 外屏：标签栏竖在右侧，各按钮横坐标相同（取「最右」会取到任意一个）
        let frames = (0..<5).map { CGRect(x: 410, y: 380 + CGFloat($0) * 52, width: 44, height: 44) }
        #expect(AccountGestureHub.lastTabIndex(frames) == 4)
        #expect(AccountGestureHub.lastTabIndex([]) == nil)
    }

    // MARK: 开合时的外壳

    @Test func foldingFromSidebarLibraryLandsOnLibraryTabWithItsPageOnStack() {
        let router = Router()
        router.adoptSidebarLibraries([19])
        router.select(.mediaLibrary(19))
        router.open(.libraryItem(libraryId: 19, itemId: 7211))
        router.collapseSidebarSelection()
        #expect(router.selection == .tab(.library))
        #expect(router.currentPath == [.library(id: 19), .libraryItem(libraryId: 19, itemId: 7211)])
        #expect(router.paths[.mediaLibrary(19)]?.isEmpty ?? true)
        // 合上后深链打开库照旧压栈，不去选中底栏里没有的侧边栏项
        router.popToRoot()
        #expect(router.open(webPath: "/library/19"))
        #expect(router.selection == .tab(.library))
        #expect(router.currentPath == [.library(id: 19)])
    }

    @Test func foldingFromRegularTabKeepsNavigation() {
        let router = Router()
        router.selectTab(.discover)
        router.open(.person(tmdbId: 31))
        let selection = router.selection, path = router.currentPath
        router.collapseSidebarSelection()
        #expect(router.selection == selection)
        #expect(router.currentPath == path)
        #expect(!path.isEmpty)
    }
}
