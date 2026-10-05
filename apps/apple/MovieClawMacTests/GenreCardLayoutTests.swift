import AppKit
import SwiftUI
import Testing
@testable import MovieClaw

struct GenreCardLayoutTests {
    @Test func compactCardsKeepTheirAspectRatioWithMissingArtwork() {
        for kind in ["movie", "tv"] {
            let host = NSHostingView(rootView: MacGenreCard(label: "科幻奇幻", count: 999999,
                                                          mediaKind: kind, coverURL: nil, action: {}))
            let size = host.fittingSize
            #expect(abs(size.width - 196) < 0.01)
            #expect(abs(size.width / size.height - 236.0 / 150.0) < 0.01)
            // AppKit 的 fittingSize 按点取整，允许不到一点评估误差。
            #expect(abs(size.height - MacMetrics.genreHeight) < 1)
        }
    }
}
