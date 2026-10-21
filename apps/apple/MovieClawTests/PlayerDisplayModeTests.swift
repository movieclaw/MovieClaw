@testable import AetherCore
import Foundation
import Testing
import AVFoundation
@testable import MovieClaw

struct PlayerDisplayModeTests {
    @Test func letterboxedMovieFitsWidthWithoutStretching() {
        let bounds = CGRect(x: 0, y: 0, width: 1280, height: 589)
        let source = CGSize(width: 1920, height: 1080)
        let fit = PlayerDisplayMode.fit.rect(in: bounds, videoSize: source)
        #expect(abs(fit.width - 1047.111) < 0.01)
        let width = PlayerDisplayMode.fitWidth.rect(in: bounds, videoSize: source)
        #expect(width.width == 1280)
        #expect(width.height == 720)
        #expect(width.minY == -65.5)
        #expect(804 * width.width / source.width == 536)
    }

    @Test func widthFitPreservesWideMovieSidesOnTablet() {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        for source in [CGSize(width: 1920, height: 804), CGSize(width: 1440, height: 1080)] {
            let width = PlayerDisplayMode.fitWidth.rect(in: bounds, videoSize: source)
            #expect(width.width == bounds.width)
            #expect(width.height <= bounds.height)
            let fill = PlayerDisplayMode.fill.rect(in: bounds, videoSize: source)
            #expect(fill.width >= bounds.width)
            #expect(fill.height >= bounds.height)
        }
    }

    @Test func pausedPortraitSubtitleGeometryUsesCurrentBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 912)
        let rect = PlayerDisplayMode.fitWidth.rect(in: bounds, videoSize: CGSize(width: 640, height: 360)).intersection(bounds)
        #expect(rect == CGRect(x: 0, y: 337.875, width: 420, height: 236.25))
    }

    @MainActor @Test func zoomedBitmapSubtitleStaysInsideViewport() {
        let bounds = CGRect(x: 0, y: 0, width: 912, height: 420)
        let rect = SubtitleLayerView.visibleFrame(CGRect(x: -100, y: 450, width: 1200, height: 100), in: bounds)
        #expect(bounds.contains(rect))
        #expect(abs(rect.width / rect.height - 12) < 0.001)
    }

    @MainActor @Test func systemPlayerChangesLayoutWithoutReplacingItsLayer() {
        let engine = AVPlayerEngine()
        let view = engine.view as! PlayerLayerView
        let layer = view.playerLayer
        view.frame = CGRect(x: 0, y: 0, width: 912, height: 420)
        for (mode, gravity) in [(PlayerDisplayMode.fit, AVLayerVideoGravity.resizeAspect),
                                (.fill, .resizeAspectFill), (.stretch, .resize), (.fitWidth, .resizeAspect)] {
            engine.displayMode = mode
            view.layoutIfNeeded()
            #expect(view.playerLayer === layer)
            #expect(layer.videoGravity == gravity)
        }
        engine.destroy()
    }

    @Test func invalidSizeAndStretchAreBounded() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        for mode in PlayerDisplayMode.allCases {
            #expect(mode.rect(in: bounds, videoSize: .zero) == bounds)
            #expect(mode.rect(in: bounds, videoSize: CGSize(width: CGFloat.infinity, height: 1)) == bounds)
        }
        #expect(PlayerDisplayMode.stretch.rect(in: bounds, videoSize: CGSize(width: 1920, height: 1080)) == bounds)
        #expect(PlayerDisplayMode.stretch.next == .fit)
    }
}
