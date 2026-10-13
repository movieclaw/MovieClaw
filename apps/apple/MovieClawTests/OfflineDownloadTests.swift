import Foundation
import Testing
@testable import MovieClaw

/// 离线下载（docs/design/offline-download.md）的纯逻辑：连通性判定规则、图片键、存档自愈、任务标识、离线变换。
struct ReachabilityJudgeTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 网慢：慢请求超时之间总有请求成功（每次成功都重建判定器）——永远不判不可达
    @Test func slowNetworkWithOccasionalSuccessNeverTrips() {
        var judge = ReachabilityJudge()
        var time = t0
        for round in 0 ..< 60 {
            #expect(judge.failure(hard: false, at: time) == false)
            time += 8
            #expect(judge.failure(hard: false, at: time) == false)
            time += 8
            if round % 1 == 0 { judge = ReachabilityJudge() } // 一次成功
        }
    }

    /// 只有超时：要连续三次失败、且从第一次起满 30 秒
    @Test func timeoutsNeedThreeFailuresAndThirtySeconds() {
        var judge = ReachabilityJudge()
        #expect(judge.failure(hard: false, at: t0) == false)
        #expect(judge.failure(hard: false, at: t0 + 8) == false)
        #expect(judge.failure(hard: false, at: t0 + 19) == false, "三次了但还不到 30 秒")
        #expect(judge.failure(hard: false, at: t0 + 29) == false)
        #expect(judge.failure(hard: false, at: t0 + 31) == true)
    }

    /// 黑洞：一个请求发出后 60 秒才超时——「30 秒」从它发出的时刻算，接着两次探测失败就够了
    @Test func spanCountsFromWhenTheFirstFailedRequestWasSent() {
        var judge = ReachabilityJudge()
        #expect(judge.failure(hard: false, at: t0 + 8, startedAt: t0 + 3) == false)
        #expect(judge.failure(hard: false, at: t0 + 15, startedAt: t0 + 10) == false)
        #expect(judge.failure(hard: false, at: t0 + 34, startedAt: t0 + 29) == true, "服务器已经 31 秒没回过话")
    }

    @Test func threeQuickTimeoutsAreNotEnough() {
        var judge = ReachabilityJudge()
        for i in 0 ..< 10 {
            #expect(judge.failure(hard: false, at: t0 + Double(i)) == false, "10 秒内十次超时也不判（可能只是一阵卡）")
        }
    }

    /// 明确连不上（拒绝连接、门户劫持）：连续两次、间隔 ≥3 秒
    @Test func twoHardFailuresThreeSecondsApart() {
        var judge = ReachabilityJudge()
        #expect(judge.failure(hard: true, at: t0) == false)
        #expect(judge.failure(hard: true, at: t0 + 0.05) == false, "同一瞬间的两次不算（一个请求带出的连锁失败）")
        #expect(judge.failure(hard: true, at: t0 + 3.1) == true)
    }

    @Test func softFailureBreaksHardStreak() {
        var judge = ReachabilityJudge()
        #expect(judge.failure(hard: true, at: t0) == false)
        #expect(judge.failure(hard: false, at: t0 + 4) == false)
        #expect(judge.failure(hard: true, at: t0 + 8) == false, "中间夹了一次软失败：硬失败不连续")
    }

    @Test func urlErrorClassification() {
        #expect(ReachabilityOutcome.of(URLError(.timedOut)) == .soft)
        #expect(ReachabilityOutcome.of(URLError(.networkConnectionLost)) == .soft)
        #expect(ReachabilityOutcome.of(URLError(.cannotFindHost)) == .soft, "DNS 失败在信号差时也会出现：不当成确定")
        #expect(ReachabilityOutcome.of(URLError(.cannotConnectToHost)) == .hard)
        #expect(ReachabilityOutcome.of(URLError(.notConnectedToInternet)) == .hard)
        #expect(ReachabilityOutcome.of(URLError(.secureConnectionFailed)) == .hard)
        #expect(ReachabilityOutcome.of(URLError(.cancelled)) == .ignored)
    }

    @Test func responseWithoutServerHeaderIsForeign() throws {
        let url = URL(string: "http://192.168.1.10:3000/api/v1/health")!
        let ours = try #require(HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: ["X-Movieclaw-Spec-Hash": "abc"]))
        let portal = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]))
        #expect(ReachabilityOutcome.of(ours) == .success, "我家服务器回的 500 也是「连得上」")
        #expect(ReachabilityOutcome.of(portal) == .hard, "机场门户页的 200 不是我家服务器")
    }
}

struct OfflineImageKeyTests {
    @Test func keyIgnoresServerAddressAndWidth() throws {
        let lan = try #require(URL(string: "http://192.168.1.10:3000/api/v1/images/assets/12/poster.jpg?v=3&w=342"))
        let domain = try #require(URL(string: "https://movie.example.com/api/v1/images/assets/12/poster.jpg?w=1280&v=3"))
        #expect(OfflineImages.key(for: lan) == OfflineImages.key(for: domain))
        #expect(OfflineImages.key(for: lan) == "/images/assets/12/poster.jpg?v=3")
    }

    @Test func tmdbSizeSegmentIsNormalized() throws {
        let small = try #require(URL(string: "http://nas/api/v1/images/proxy?url=https://image.tmdb.org/t/p/w342/abc.jpg&w=200"))
        let large = try #require(URL(string: "http://nas/api/v1/images/proxy?url=https://image.tmdb.org/t/p/w780/abc.jpg&w=600"))
        #expect(OfflineImages.key(for: small) == OfflineImages.key(for: large))
    }

    @Test func differentVersionsAreDifferentImages() throws {
        let v3 = try #require(URL(string: "http://nas/api/v1/images/assets/12/poster.jpg?v=3"))
        let v4 = try #require(URL(string: "http://nas/api/v1/images/assets/12/poster.jpg?v=4"))
        #expect(OfflineImages.key(for: v3) != OfflineImages.key(for: v4), "换了图（v 是文件修改时间）就是另一张")
    }
}

struct OfflineArchiveTests {
    private func unit(_ fileId: Int, state: OfflineUnit.State, ext: String = "mp4") -> OfflineUnit {
        OfflineUnit(fileId: fileId, mediaItemId: 7, season: 1, episode: fileId, profile: "original", profileLabel: "原画",
                    state: state, expectedBytes: 10, fileExtension: ext, createdAt: Date())
    }

    /// 视频已移进来但状态没来得及写（移动与写状态之间被杀）：启动读存档时补标完成；空条目收拾掉
    @Test func snapshotRepairsCompletedButUnmarkedUnits() throws {
        let key = "test-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }
        let summary = OfflineItemSummary(mediaItemId: 7, libraryId: 1, libraryName: "剧集", libraryKind: "tv", kind: "tv",
                                         title: "示例", year: 2024, posterUrl: nil, backdropUrl: nil, primaryAspect: 0.67,
                                         addedAt: Date())
        try OfflineDisk.write(summary, to: OfflineDisk.summaryFile(key, 7))
        try OfflineDisk.write(unit(1, state: .downloading), to: OfflineDisk.unitFile(key, 7, 1))
        try OfflineDisk.write(unit(2, state: .downloading), to: OfflineDisk.unitFile(key, 7, 2))
        try Data(repeating: 1, count: 4096).write(to: OfflineDisk.unitDir(key, 7, 1).appending(path: "media.mp4"))
        // 一个只剩摘要、单元都删光了的条目
        try OfflineDisk.write(summary, to: OfflineDisk.summaryFile(key, 8))

        let snapshot = OfflineDisk.loadSnapshot(key)
        #expect(snapshot.units[1]?.state == .done)
        #expect(snapshot.units[1]?.receivedBytes == 4096)
        #expect(snapshot.units[2]?.state == .downloading, "没有视频文件的照旧，等对账重建任务")
        #expect(snapshot.items[7] != nil)
        #expect(snapshot.items[8] == nil)
        #expect(!FileManager.default.fileExists(atPath: OfflineDisk.itemDir(key, 8).path))
        // 补标写回了盘上
        #expect(OfflineDisk.read(OfflineUnit.self, from: OfflineDisk.unitFile(key, 7, 1))?.state == .done)
    }

    @Test func unknownFormatIsSkippedNotCrashed() throws {
        let key = "test-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }
        var future = OfflineItemSummary(mediaItemId: 9, libraryId: 1, libraryName: "电影", libraryKind: "movie", kind: "movie",
                                        title: "未来", year: nil, posterUrl: nil, backdropUrl: nil, primaryAspect: 0.67, addedAt: Date())
        future.format = 99
        try OfflineDisk.write(future, to: OfflineDisk.summaryFile(key, 9))
        try OfflineDisk.write(unit(5, state: .done), to: OfflineDisk.unitFile(key, 9, 5))
        #expect(OfflineDisk.loadSnapshot(key).items.isEmpty)
    }

    @Test func taskTagRoundTrip() {
        let tag = OfflineTaskTag(owner: "abc", item: 7, file: 42)
        #expect(OfflineTaskTag(tag.encoded) == tag)
        #expect(OfflineTaskTag("not json") == nil)
        #expect(OfflineTaskTag(nil) == nil)
    }

    @Test func ownerKeyIgnoresAddress() {
        let lan = OfflineOwner(instanceId: "abc", username: "family", origin: URL(string: "http://192.168.1.10:3000")!)
        let domain = OfflineOwner(instanceId: "abc", username: "family", origin: URL(string: "https://movie.example.com")!)
        let other = OfflineOwner(instanceId: "def", username: "family", origin: URL(string: "http://192.168.1.10:3000")!)
        #expect(lan.key == domain.key, "同一台服务器换了地址，副本不丢")
        #expect(lan.key != other.key, "同一个地址上换了一台服务器，不串")
    }
}

/// 本机续播点与服务端同一套阈值：离线时显示的「继续 / 已看完」和连上之后服务端算的一致
struct OfflineProgressThresholdTests {
    @Test func matchesServerThresholds() {
        let movie = 6 * 60_000
        #expect(OfflineViewingRecorder.resolve(positionMs: 12_000, runtimeMs: movie, currentlyPlayed: false) == (0, false), "不足 5%")
        #expect(OfflineViewingRecorder.resolve(positionMs: 60_000, runtimeMs: movie, currentlyPlayed: false) == (60_000, false))
        #expect(OfflineViewingRecorder.resolve(positionMs: 340_000, runtimeMs: movie, currentlyPlayed: false) == (0, true), "超过 90%")
        #expect(OfflineViewingRecorder.resolve(positionMs: nil, runtimeMs: movie, currentlyPlayed: false) == (0, true), "播到片尾")
        #expect(OfflineViewingRecorder.resolve(positionMs: 60_000, runtimeMs: 240_000, currentlyPlayed: false) == (0, true), "短片过了开头就算看完")
        #expect(OfflineViewingRecorder.resolve(positionMs: 0, runtimeMs: movie, currentlyPlayed: true) == (0, true), "拖回开头：已看不变")
    }
}
