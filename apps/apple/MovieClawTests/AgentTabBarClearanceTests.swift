import SwiftUI
import UIKit
import Testing
@testable import MovieClaw

/// 会话页返回时，输入框与液态玻璃标签栏的让位。几何是纯函数；交互返回的中途、取消、完成由 appliedInset 区分。
@MainActor
struct AgentTabBarClearanceTests {
    /// iPhone 全面屏：页 393×852，Home 指示条 34，胶囊顶在 769（高 83，贴到屏幕底）
    private let phone = CGRect(x: 0, y: 0, width: 393, height: 852)
    private let phoneBar = CGRect(x: 0, y: 769, width: 393, height: 83)

    private func inset(
        tabBar: CGRect,
        page: CGRect,
        windowBottom: CGFloat,
        keyboard: CGRect? = nil,
        padding: CGFloat? = nil
    ) -> CGFloat? {
        let composerPadding = padding ?? AgentComposerBottomGap.padding(keyboardShown: keyboard != nil, windowBottomInset: windowBottom)
        return AgentTabBarClearance.additionalBottomInset(
            tabBar: tabBar, page: page, windowBottomInset: windowBottom,
            composerPadding: composerPadding, keyboard: keyboard
        )
    }

    /// 输入框可视底边：安全区上沿再减底部间距（负间距表示伸进安全区）
    private func visualMaxY(page: CGRect, windowBottom: CGFloat, padding: CGFloat, extra: CGFloat) -> CGFloat {
        page.maxY - windowBottom - extra - padding
    }

    @Test func midSwipeLiftsTheComposerClearOfTheGlassTabBar() {
        let padding = AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: 34)
        #expect(padding == -10)
        let extra = inset(tabBar: phoneBar, page: phone, windowBottom: 34, padding: padding)
        #expect(extra == 67)
        let visual = visualMaxY(page: phone, windowBottom: 34, padding: padding, extra: extra ?? 0)
        #expect(visual == phoneBar.minY - AgentTabBarClearance.gap)
        // 页面已经跟着右移约四成，标签栏仍是整条：让位只看垂直方向，不跟水平进度变。
        let shifted = CGRect(x: phone.width * 0.4, y: 0, width: phone.width, height: phone.height)
        #expect(inset(tabBar: phoneBar, page: shifted, windowBottom: 34, padding: padding) == extra)
        // 输入框高约 126。抬起后即使页面右移，也不再与胶囊相交。
        let composer = CGRect(x: phone.width * 0.4, y: visual - 126, width: phone.width, height: 126)
        #expect(!composer.intersects(phoneBar))
        #expect(composer.maxY <= phoneBar.minY - 8)
    }

    @Test func cancelAndSettledKeepTheComposerOnTheHomeIndicator() {
        let measured: CGFloat = 67
        // 停稳、取消结束：标签栏藏回，不再抬
        #expect(AgentTabBarClearance.appliedInset(tabBarHidden: true, pageOnScreen: true, measured: measured) == 0)
        // 返回完成：会话页已经不在窗口里
        #expect(AgentTabBarClearance.appliedInset(tabBarHidden: false, pageOnScreen: false, measured: measured) == 0)
        #expect(AgentTabBarClearance.appliedInset(tabBarHidden: true, pageOnScreen: false, measured: measured) == 0)
        // 中途：标签栏露着，会话页还在
        #expect(AgentTabBarClearance.appliedInset(tabBarHidden: false, pageOnScreen: true, measured: measured) == measured)
    }

    /// 2026-11-08 iPhone Air 真机日志里的几何：页 420×912，胶囊 frame (0, 829, 420, 83)，Home 指示条 34
    @Test func iPhoneAirMidSwipeGeometryFromDeviceLogs() throws {
        let page = CGRect(x: 0, y: 0, width: 420, height: 912)
        let bar = CGRect(x: 0, y: 829, width: 420, height: 83)
        let padding = AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: 34)
        let lift = try #require(inset(tabBar: bar, page: page, windowBottom: 34))
        #expect(lift == 67)
        #expect(visualMaxY(page: page, windowBottom: 34, padding: padding, extra: lift) == bar.minY - AgentTabBarClearance.gap)
    }

    @Test func keyboardCoveringTheTabBarDoesNotAddAnotherLift() {
        let docked = CGRect(x: 0, y: 520, width: 393, height: 332)
        #expect(inset(tabBar: phoneBar, page: phone, windowBottom: 34, keyboard: docked) == 0)
        // 收起之后回到同一条让位
        #expect(inset(tabBar: phoneBar, page: phone, windowBottom: 34) == 67)
        // 悬浮键盘停在中部，碰不到胶囊，不能把它当成「已经盖住」而放弃让位
        let floating = CGRect(x: 40, y: 360, width: 313, height: 180)
        let lifted = inset(tabBar: phoneBar, page: phone, windowBottom: 34, keyboard: floating)
        #expect(lifted == inset(tabBar: phoneBar, page: phone, windowBottom: 34, padding: 8))
    }

    @Test func safeAreaChangesTheLiftButTheVisualEdgeStaysOneGapAboveTheCapsule() throws {
        for windowBottom: CGFloat in [0, 21, 34, 47] {
            let padding = AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: windowBottom)
            let extra = try #require(inset(tabBar: phoneBar, page: phone, windowBottom: windowBottom, padding: padding))
            let visual = visualMaxY(page: phone, windowBottom: windowBottom, padding: padding, extra: extra)
            #expect(abs(visual - (phoneBar.minY - AgentTabBarClearance.gap)) < 0.01)
        }
    }

    @Test func phoneAndPadWidthsShareTheSameVerticalClearance() {
        let padding = AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: 34)
        var seen: CGFloat?
        for width: CGFloat in [320, 390, 402, 430, 440, 768, 834, 1024, 1366] {
            let page = CGRect(x: 0, y: 0, width: width, height: 852)
            let bar = CGRect(x: 0, y: 769, width: width, height: 83)
            let extra = inset(tabBar: bar, page: page, windowBottom: 34, padding: padding)
            if let seen { #expect(extra == seen) } else { seen = extra }
        }
        #expect(seen == 67)
        #expect(AgentTabBarClearance.gap == AgentQuickInput.bottomGap)
    }

    @Test func padSidebarAndTopTabBarDoNotLiftTheComposer() throws {
        let page = CGRect(x: 0, y: 0, width: 1366, height: 1024)
        let sidebar = CGRect(x: 0, y: 0, width: 320, height: 1024)
        #expect(inset(tabBar: sidebar, page: page, windowBottom: 20) == 0)
        // 内容区已经让开侧栏：水平方向不相交
        let beside = CGRect(x: 320, y: 0, width: 1046, height: 1024)
        #expect(inset(tabBar: sidebar, page: beside, windowBottom: 20) == 0)
        let topBar = CGRect(x: 0, y: 0, width: 1366, height: 50)
        #expect(inset(tabBar: topBar, page: page, windowBottom: 20) == 0)
        // 窄窗口底栏仍然要让
        let compact = CGRect(x: 0, y: 0, width: 744, height: 1133)
        let compactBar = CGRect(x: 0, y: 1050, width: 744, height: 83)
        let extra = try #require(inset(tabBar: compactBar, page: compact, windowBottom: 20))
        let padding = AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: 20)
        let visual = visualMaxY(page: compact, windowBottom: 20, padding: padding, extra: extra)
        #expect(abs(visual - (compactBar.minY - 8)) < 0.01)
    }

    @Test func floatingCapsuleAboveTheHomeIndicatorIsClearedAtItsTopEdge() throws {
        // 胶囊不一定铺到物理底边：顶 748、高 62，底下还有空档
        let capsule = CGRect(x: 21, y: 748, width: 351, height: 62)
        let padding = AgentComposerBottomGap.padding(keyboardShown: false, windowBottomInset: 34)
        let extra = try #require(inset(tabBar: capsule, page: phone, windowBottom: 34, padding: padding))
        let visual = visualMaxY(page: phone, windowBottom: 34, padding: padding, extra: extra)
        #expect(abs(visual - (capsule.minY - 8)) < 0.01)
        #expect(!CGRect(x: 12, y: visual - 126, width: 369, height: 126).intersects(capsule))
    }

    @Test func unfinishedBarFrameIsLeftAloneAndAFullyOffscreenPageIsNotLifted() {
        #expect(inset(tabBar: .zero, page: phone, windowBottom: 34) == nil)
        let below = CGRect(x: 0, y: 860, width: 393, height: 83)
        #expect(inset(tabBar: below, page: phone, windowBottom: 34) == nil)
        let gone = CGRect(x: 400, y: 0, width: 393, height: 852)
        #expect(inset(tabBar: phoneBar, page: gone, windowBottom: 34) == 0)
    }

    @Test func longTranscriptReadableBottomFollowsTheLiftedComposerOnBothWidths() {
        // 长会话可见高度 912，顶栏 122；输入区从 127 再抬 67。宽度不参与贴底判断。
        let insets = EdgeInsets(top: 122, leading: 0, bottom: 127 + 67, trailing: 0)
        func viewport(width: CGFloat) -> AgentTranscriptScroll.Viewport {
            AgentConversationView.viewport(
                contentHeight: 4_000,
                visible: CGRect(x: 0, y: 0, width: width, height: 912),
                insets: insets
            )
        }
        let phone = viewport(width: 390)
        let pad = viewport(width: 1024)
        #expect(!phone.atBottom && !phone.nearBottom && !phone.offscreen)
        #expect(pad.atBottom == phone.atBottom && pad.nearBottom == phone.nearBottom)
        // 可读底边 = 912 - (127+67)。内容末端正好落在抬起后的输入框上沿仍算贴底。
        let readableBottom = 912 - insets.bottom
        let pinned = AgentConversationView.viewport(
            contentHeight: readableBottom,
            visible: CGRect(x: 0, y: 0, width: 390, height: 912),
            insets: insets
        )
        #expect(pinned.atBottom && pinned.nearBottom)
    }
}
