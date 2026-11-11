import Foundation
import SwiftUI
import Testing
@testable import MovieClaw

/// 选集面板打开时的让位布局（`EpisodeStageLayout`）与面板里几处纯计算
struct EpisodeStageLayoutTests {
    /// iPhone Air 横屏：912 × 420，左右安全区 62，底部 21
    private let landscape = CGSize(width: 912, height: 420)
    private let landscapeInsets = EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
    /// 竖屏：420 × 912，顶部 62，底部 34
    private let portrait = CGSize(width: 420, height: 912)
    private let portraitInsets = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)

    private func fit(_ video: CGSize, in container: CGSize) -> CGRect {
        PlayerDisplayMode.fit.rect(in: CGRect(origin: .zero, size: container), videoSize: video)
    }

    /// 变换后画面矩形确实落在目标上：缩放（锚点左上）再位移
    private func transformed(_ picture: CGRect, by layout: EpisodeStageLayout) -> CGRect {
        CGRect(x: picture.minX * layout.scale + layout.offset.width, y: picture.minY * layout.scale + layout.offset.height,
               width: picture.width * layout.scale, height: picture.height * layout.scale)
    }

    private func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    @Test func landscapeVideoYieldsToTheLeftOfTheDrawer() throws {
        let picture = fit(CGSize(width: 1920, height: 1080), in: landscape)
        let layout = EpisodeStageLayout.resolve(container: landscape, safeArea: landscapeInsets, picture: picture, islandTrailing: false)
        #expect(layout.yields)
        // 面板贴右、上下各留 8
        #expect(layout.drawer == CGRect(x: 571, y: 8, width: 333, height: 404))
        // 画面从安全区左缘 + 16 起，右边离面板 16，保持 16:9
        #expect(abs(layout.video.minX - 78) < 0.01)
        #expect(abs(layout.video.maxX - (layout.drawer.minX - 16)) < 0.01)
        #expect(abs(layout.video.width / layout.video.height - 16.0 / 9) < 0.001)
        #expect(close(transformed(picture, by: layout), layout.video))
        // 集名简介在画面正下方、与画面同宽，不压到主屏幕指示条
        let caption = try #require(layout.caption)
        #expect(caption.minX == layout.video.minX && caption.width == layout.video.width)
        #expect(caption.minY == layout.video.maxY + 12)
        #expect(caption.maxY <= landscape.height - landscapeInsets.bottom)
        #expect(!layout.video.intersects(layout.drawer))
    }

    @Test func landscapeDrawerClearsTheIslandWhenItIsOnTheRight() {
        let picture = fit(CGSize(width: 1920, height: 1080), in: landscape)
        let layout = EpisodeStageLayout.resolve(container: landscape, safeArea: landscapeInsets, picture: picture, islandTrailing: true)
        #expect(layout.drawer.maxX == landscape.width - 62)
        // 岛不在左边：画面贴到离左缘 20
        #expect(abs(layout.video.minX - 20) < 0.01)
        #expect(!layout.video.intersects(layout.drawer))
        #expect(close(transformed(picture, by: layout), layout.video))
    }

    @Test func wideMovieKeepsItsAspectAndStaysCentredInTheBlock() throws {
        let picture = fit(CGSize(width: 1920, height: 804), in: landscape)
        let layout = EpisodeStageLayout.resolve(container: landscape, safeArea: landscapeInsets, picture: picture, islandTrailing: false)
        #expect(abs(layout.video.width / layout.video.height - 1920.0 / 804) < 0.001)
        #expect(layout.video.minY >= 20)
        let caption = try #require(layout.caption)
        #expect(caption.maxY <= landscape.height - landscapeInsets.bottom)
    }

    @Test func shortLandscapeWindowDropsTheCaption() {
        // 分屏的小窗：高度放不下「画面 + 集名简介」，全给画面
        let size = CGSize(width: 700, height: 220)
        let picture = fit(CGSize(width: 1920, height: 1080), in: size)
        let layout = EpisodeStageLayout.resolve(container: size, safeArea: EdgeInsets(), picture: picture, islandTrailing: false)
        #expect(layout.caption == nil)
        #expect(layout.video.maxY <= size.height)
        #expect(!layout.video.intersects(layout.drawer))
    }

    @Test func portraitVideoMovesToTheTopAndDrawerSitsBelow() {
        let picture = fit(CGSize(width: 1920, height: 1080), in: portrait)
        let layout = EpisodeStageLayout.resolve(container: portrait, safeArea: portraitInsets, picture: picture, islandTrailing: false)
        #expect(layout.yields)
        #expect(layout.scale == 1)
        #expect(layout.video == CGRect(x: 0, y: 66, width: 420, height: 236.25))
        #expect(layout.caption == nil)
        #expect(layout.drawer.minY == layout.video.maxY + 12)
        #expect(layout.drawer.maxY == portrait.height - 8)
        #expect(layout.drawer.minX == 8 && layout.drawer.width == 404)
        #expect(close(transformed(picture, by: layout), layout.video))
    }

    @Test func portraitFillModeLeavesThePictureAndFloatsTheDrawer() {
        // 竖屏「填满」：画面占满整屏，没处可让，面板浮在下半屏
        let picture = CGRect(origin: .zero, size: portrait)
        let layout = EpisodeStageLayout.resolve(container: portrait, safeArea: portraitInsets, picture: picture, islandTrailing: false)
        #expect(!layout.yields)
        #expect(layout.scale == 1 && layout.offset == .zero)
        #expect(layout.drawer.minY == 410)
    }

    // MARK: iPhone Duo

    /// 内屏横拿：951 × 669，竖排系统栏在右（安全区只有右边与底边）
    private let duoInner = CGSize(width: 951, height: 669)
    private let duoInnerInsets = EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 62)

    @Test func duoInnerLandscapeClearsTheSideBarWhateverTheOrientationSays() {
        // 左右安全区不一样宽：照安全区排，不靠界面方向猜灵动岛在哪
        let picture = fit(CGSize(width: 1920, height: 1080), in: duoInner)
        for islandTrailing in [false, true] {
            let layout = EpisodeStageLayout.resolve(container: duoInner, safeArea: duoInnerInsets, picture: picture, islandTrailing: islandTrailing)
            #expect(layout.drawer.maxX == duoInner.width - 62)
            #expect(abs(layout.video.minX - 16) < 0.01)
            #expect(!layout.video.intersects(layout.drawer))
        }
    }

    @Test func bookFoldPutsPictureOnTheLeftPageAndDrawerOnTheRight() throws {
        let picture = fit(CGSize(width: 1920, height: 1080), in: duoInner)
        let crease = CGRect(x: 463.5, y: 0, width: 24, height: 669)
        let layout = EpisodeStageLayout.resolve(container: duoInner, safeArea: duoInnerInsets, picture: picture, islandTrailing: false, crease: crease)
        #expect(layout.yields)
        // 右页：从折痕右边 12 点起，到系统栏为止
        #expect(layout.drawer == CGRect(x: 499.5, y: 8, width: 389.5, height: 653))
        // 左页：画面与集名简介整块在折痕左边，不碰折痕
        #expect(abs(layout.video.minX - 16) < 0.01)
        #expect(layout.video.maxX <= crease.minX - 16 + 0.01)
        let caption = try #require(layout.caption)
        #expect(caption.maxX <= crease.minX)
        #expect(abs(layout.video.width / layout.video.height - 16.0 / 9) < 0.001)
        #expect(close(transformed(picture, by: layout), layout.video))
    }

    @Test func tabletopKeepsThePictureAndFillsTheLowerHalf() {
        // 内屏竖拿半折：画面在折痕以上不动，面板占满折痕以下
        let size = CGSize(width: 669, height: 951)
        let insets = EdgeInsets(top: 28, leading: 0, bottom: 20, trailing: 0)
        let picture = CGRect(x: 0, y: 55, width: 669, height: 376.3)
        let crease = CGRect(x: 0, y: 463.5, width: 669, height: 24)
        let layout = EpisodeStageLayout.resolve(container: size, safeArea: insets, picture: picture, islandTrailing: false, crease: crease)
        #expect(!layout.yields)
        #expect(layout.scale == 1 && layout.offset == .zero)
        #expect(layout.caption == nil)
        #expect(layout.drawer == CGRect(x: 8, y: 495.5, width: 653, height: 447.5))
    }

    @Test func duoOuterPortraitDrawerClearsTheSideIsland() {
        // 外屏竖拿：灵动岛竖排在右，面板右边让开它；画面照旧占满宽度
        let size = CGSize(width: 466, height: 678)
        let insets = EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 56)
        let picture = fit(CGSize(width: 1920, height: 1080), in: size)
        let layout = EpisodeStageLayout.resolve(container: size, safeArea: insets, picture: picture, islandTrailing: false)
        #expect(layout.video.width == 466)
        #expect(layout.drawer.minX == 8 && layout.drawer.maxX == 466 - 56)
    }

    @Test func duoOuterLandscapeDrawerClearsTheTopIsland() {
        // 外屏横放：灵动岛转到顶边，面板顶部让开它
        let size = CGSize(width: 678, height: 466)
        let insets = EdgeInsets(top: 46, leading: 0, bottom: 20, trailing: 0)
        let picture = fit(CGSize(width: 1920, height: 1080), in: size)
        let layout = EpisodeStageLayout.resolve(container: size, safeArea: insets, picture: picture, islandTrailing: false)
        #expect(layout.drawer.minY == 46)
        #expect(layout.drawer.maxY == size.height - 8)
        #expect(!layout.video.intersects(layout.drawer))
    }

    @Test func remainingMinutesRoundUpAndNeverReadZero() {
        #expect(EpisodePicker.minutesLeft(position: 18 * 60_000 + 42_000, duration: 53 * 60_000) == 35)
        #expect(EpisodePicker.minutesLeft(position: 52 * 60_000 + 40_000, duration: 53 * 60_000) == 1)
        #expect(EpisodePicker.minutesLeft(position: 53 * 60_000, duration: 53 * 60_000) == 1)
    }

    @Test func rowMetaReflectsOwnedPlayedAndProgress() {
        func episode(owned: Bool = true, played: Bool = false, positionMs: Int = 0, percent: Int? = nil) -> API.EpisodeView {
            API.EpisodeView(episodeNumber: 1, owned: owned, fileIds: [], positionMs: positionMs, played: played, progressPercent: percent)
        }
        #expect(EpisodePicker.meta(episode()) == nil)
        #expect(EpisodePicker.meta(episode(played: true))?.done == true)
        #expect(EpisodePicker.meta(episode(owned: false, played: true))?.done == false)
        let half = EpisodePicker.meta(episode(positionMs: 750_000, percent: 40))
        #expect(half?.done == false)
        #expect(half?.text.contains("12:30") == true)
        #expect(EpisodePicker.partial(episode(positionMs: 750_000, percent: 40)) == 0.4)
        #expect(EpisodePicker.partial(episode(played: true, percent: 40)) == nil)
        #expect(EpisodePicker.caption(3, name: "") == EpisodePicker.caption(3, name: nil))
    }
}
