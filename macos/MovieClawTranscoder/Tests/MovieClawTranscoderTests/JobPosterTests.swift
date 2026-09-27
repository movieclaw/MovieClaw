import AppKit
import XCTest

@testable import MovieClawTranscoder

/// 任务卡片的海报：缓存键、面板模型的传递、进程间消息。
@MainActor
final class JobPosterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func job(_ id: String, poster: String?) -> RunningJob {
        RunningJob(
            id: id, name: "蜘蛛侠：英雄无归 (2021)", progress: nil, startedAt: t0,
            videoEncoder: "h264_videotoolbox", paused: false,
            posterURL: poster.flatMap(URL.init(string:))
        )
    }

    func testCacheKeyDropsTheTokenSoSeeksReuseTheSamePoster() {
        // 拖进度条换了任务号和令牌，还是同一个播放会话的同一张海报
        let first = URL(string: "http://192.168.1.10:3000/api/v1/transcode-worker/sessions/s1/poster?token=a")!
        let afterSeek = URL(string: "http://192.168.1.10:3000/api/v1/transcode-worker/sessions/s1/poster?token=b")!
        XCTAssertEqual(JobPosterCache.key(first), JobPosterCache.key(afterSeek))
        XCTAssertFalse(JobPosterCache.key(first).contains("token"))
    }

    func testPanelCardShowsThePosterOfItsOwnJob() {
        let status = WorkerStatus(
            state: .busy, message: "", workerID: "m", maxJobs: 2,
            jobs: [job("j1", poster: "http://nas/p1?token=x"), job("j2", poster: nil)],
            ffmpegVersion: "8.1.2", encoders: [], lastError: nil, updatedAt: t0
        )
        let image = NSImage(size: NSSize(width: 2, height: 3))
        let model = PanelModel.make(status: status, configured: true, nasAddress: nil, today: [], recent: [],
                                    posters: ["j1": image], now: t0)
        guard case let .jobs(cards) = model.body else { return XCTFail("应是任务卡片") }
        XCTAssertTrue(cards[0].poster === image)
        XCTAssertNil(cards[1].poster, "没下发海报的任务保留占位图标")
    }

    func testPosterURLSurvivesTheCorePipe() throws {
        var line = try CoreLine.encode(CoreEvent.status(WorkerStatus(
            state: .busy, message: "", workerID: "m", maxJobs: 1,
            jobs: [job("j1", poster: "http://nas/api/v1/transcode-worker/sessions/s1/poster?token=x")],
            ffmpegVersion: "8.1.2", encoders: [], lastError: nil, updatedAt: t0
        )))
        line.removeLast()
        guard case let .status(decoded) = try CoreLine.decode(CoreEvent.self, from: line) else {
            return XCTFail("应解出状态")
        }
        XCTAssertEqual(decoded.jobs.first?.posterURL?.lastPathComponent, "poster")
    }

    func testCardTitleDropsTheScraperTagsOfLibraryFolders() {
        XCTAssertEqual(DisplayText.withoutExtension("蜘蛛侠：英雄无归 (2021) [tmdbid=634649]"), "蜘蛛侠：英雄无归 (2021)")
        XCTAssertEqual(DisplayText.withoutExtension("盗梦空间 (2010) {tmdb-27205}.mkv"), "盗梦空间 (2010)")
        XCTAssertEqual(DisplayText.withoutExtension("人生一串 S01E02.mkv"), "人生一串 S01E02")
    }
}
