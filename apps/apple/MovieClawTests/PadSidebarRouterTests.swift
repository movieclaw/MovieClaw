import Foundation
import Testing
@testable import MovieClaw

/// iPad 侧边栏（docs/design/ipad.md §3）：侧边栏里的库、合集、收藏各有一个导航栈，都归「媒体库」页签
@MainActor
struct PadSidebarRouterTests {
    @Test func deepLinkToSidebarLibrarySelectsIt() {
        let router = Router()
        router.adoptSidebarLibraries([19, 20])
        router.selectTab(.discover)
        #expect(router.open(webPath: "/library/19"))
        #expect(router.selection == .mediaLibrary(19))
        #expect(router.selectedTab == .library)
        #expect(router.currentPath.isEmpty)
    }

    @Test func libraryLinkWithViewOrUnlistedLibraryStillPushes() {
        let router = Router()
        router.adoptSidebarLibraries([19])
        #expect(router.open(webPath: "/library/19?view=collections"))
        #expect(router.selection == .tab(.library))
        #expect(router.currentPath == [.library(id: 19, view: "collections")])
        // 手机上侧边栏为空：照旧压栈
        let phone = Router()
        #expect(phone.open(webPath: "/library/19"))
        #expect(phone.selection == .tab(.library))
        #expect(phone.currentPath == [.library(id: 19)])
    }

    @Test func itemOpenedInsideSidebarLibraryStaysOnItsStack() {
        let router = Router()
        router.select(.mediaLibrary(20))
        router.open(.libraryItem(libraryId: 20, itemId: 7211))
        #expect(router.selection == .mediaLibrary(20))
        #expect(router.paths[.mediaLibrary(20)] == [.libraryItem(libraryId: 20, itemId: 7211)])
        #expect(router.paths[.tab(.library)] == nil)
        // 切走再切回来还停在原来那一层；再点一次当前项退回根页面
        router.selection = .tab(.discover)
        router.selection = .mediaLibrary(20)
        #expect(router.currentPath.count == 1)
        router.select(.mediaLibrary(20))
        #expect(router.currentPath.isEmpty)
    }

    @Test func homeLinkLeavesSidebarItem() {
        let router = Router()
        router.select(.collection(5))
        router.push(.libraryHome)
        #expect(router.selection == .tab(.library))
    }

    @Test func resumePointFoldsSidebarItemIntoLibraryTab() {
        let router = Router()
        router.select(.mediaLibrary(19))
        router.push(.libraryItem(libraryId: 19, itemId: 7187))
        let resume = router.resumePoint
        #expect(resume.tab == .library)
        #expect(resume.path == [.library(id: 19), .libraryItem(libraryId: 19, itemId: 7187)])
        router.selectTab(.activity)
        #expect(router.resumePoint.path.isEmpty)
    }

    @Test func coldStartLibraryLinkMovesToSidebarOnceListArrives() {
        // 深链比侧边栏清单先到：先压在首页栈上，清单一到改成选中侧边栏那一项
        let router = Router()
        #expect(router.open(webPath: "/library/19"))
        #expect(router.currentPath == [.library(id: 19)])
        router.adoptSidebarLibraries([19, 20])
        #expect(router.selection == .mediaLibrary(19))
        #expect(router.currentPath.isEmpty)
        #expect(router.paths[.tab(.library)] == [])
    }

    @Test func listArrivalDoesNotHijackDeeperStacks() {
        let router = Router()
        router.open(.library(id: 19))
        router.push(.libraryItem(libraryId: 19, itemId: 7187))
        router.adoptSidebarLibraries([19])
        #expect(router.selection == .tab(.library))
        #expect(router.currentPath.count == 2)
    }
}
