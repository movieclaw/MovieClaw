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

/// 剧集「下载」面板的范围规则（`OfflineDownloadChoices.make`）
struct OfflineDownloadChoicesTests {
    private func episodes(_ count: Int, season: Int = 1, local: [Int: OfflineDownloadChoices.Episode.Local] = [:],
                          played: Set<Int> = []) -> [OfflineDownloadChoices.Episode] {
        (1 ... count).map { .init(season: season, episode: $0, file: season * 1000 + $0, played: played.contains($0), local: local[$0]) }
    }

    @Test func selectedDownloadedOffersNextFiveAndRemaining() {
        // 真机上的情形：47 集，选中的第 1 集已下载，都没看过——原来只剩「全部」、没有分段
        let choices = OfflineDownloadChoices.make(episodes: episodes(47, local: [1: .done]), selected: (1, 1), selectedFile: nil,
                                                  multiSeason: false)
        #expect(choices.scopes.map(\.label) == ["接下来 5 集", "剩余 46 集"])
        #expect(choices.scopes.first(where: \.preferred)?.id == "next")
        #expect(choices.scopes[0].detail == "第 2～6 集，共 5 集")
        #expect(choices.scopes[1].detail == "第 2～47 集，共 46 集")
        #expect(choices.note == "第 1 集已下载 · 已下载 1 集，不会重复下载")
    }

    @Test func freshShowKeepsSelectedUnwatchedAndAll() {
        let choices = OfflineDownloadChoices.make(episodes: episodes(3, played: [1]), selected: (1, 2), selectedFile: 1002,
                                                  multiSeason: false)
        #expect(choices.scopes.map(\.label) == ["第 2 集", "未看 2 集", "全部 3 集"])
        #expect(choices.scopes.first(where: \.preferred)?.id == "unwatched")
        #expect(choices.scopes[1].detail == "第 2～3 集，共 2 集")
        #expect(choices.note == nil)
    }

    @Test func onlySelectedLeftIsASingleScope() {
        let choices = OfflineDownloadChoices.make(episodes: episodes(3, local: [2: .done, 3: .active], played: [1]), selected: (1, 1),
                                                  selectedFile: 1001, multiSeason: false)
        #expect(choices.scopes.map(\.label) == ["第 1 集"])
        #expect(choices.note == "已下载 1 集、正在下载 1 集，不会重复下载")
    }

    @Test func nextThatCoversEverythingLeftIsJustRemaining() {
        let choices = OfflineDownloadChoices.make(episodes: episodes(4, local: [1: .active]), selected: (1, 1), selectedFile: nil,
                                                  multiSeason: false)
        #expect(choices.scopes.map(\.label) == ["剩余 3 集"])
        #expect(choices.scopes[0].preferred)
        #expect(choices.note == "第 1 集正在下载 · 正在下载 1 集，不会重复下载")
    }

    @Test func multiSeasonNamesAndNonContiguousRanges() {
        let list = episodes(3, season: 1, local: [2: .done]) + episodes(2, season: 2)
        let choices = OfflineDownloadChoices.make(episodes: list, selected: (1, 2), selectedFile: nil, multiSeason: true)
        #expect(choices.note?.hasPrefix("第 1 季第 2 集已下载") == true)
        #expect(choices.scopes.map(\.label) == ["接下来 3 集", "剩余 4 集"])
        #expect(choices.scopes[0].detail == "第 1 季第 3 集 起，共 3 集")
        #expect(choices.scopes[1].detail == "第 1 季第 1 集 起，共 4 集")
    }

    @Test func everythingLocalHasNoScopes() {
        let choices = OfflineDownloadChoices.make(episodes: episodes(2, local: [1: .done, 2: .done]), selected: (1, 1), selectedFile: nil,
                                                  multiSeason: false)
        #expect(choices.scopes.isEmpty)
    }
}

/// 首页「正在下载」提示条只汇总：几部、总速度、还剩几个、总进度
@MainActor
struct OfflineDownloadSummaryTests {
    private func unit(_ fileId: Int, item: Int, _ state: OfflineUnit.State, got: Int64 = 0, of: Int64 = 100) -> OfflineUnit {
        var unit = OfflineUnit(fileId: fileId, mediaItemId: item, season: 1, episode: fileId, profile: "original",
                               profileLabel: "原画", state: state, expectedBytes: of, fileExtension: "mkv", createdAt: Date())
        unit.receivedBytes = got
        return unit
    }

    @Test func countsTitlesNotEpisodesAndSumsSpeed() {
        let units = [unit(1, item: 7, .downloading, got: 50), unit(2, item: 7, .queued), unit(3, item: 9, .downloading, got: 100)]
        let summary = OfflineDownloadSummary(units, speeds: [1: 1_000_000, 3: 500_000])
        #expect(summary.title == "2 部正在下载")
        #expect(summary.detail == "\(Formatters.bytes(1_500_000))/s · 还剩 3 个 · 50%")
        #expect(summary.fraction == 0.5)
    }

    @Test func allPausedSaysSo() {
        let summary = OfflineDownloadSummary([unit(1, item: 7, .paused, got: 11)], speeds: [:])
        #expect(summary.title == "1 部已暂停下载")
        #expect(summary.detail == "11%")
        #expect(summary.allPaused)
    }

    @Test func interruptedOnlyTurnsWarning() {
        let summary = OfflineDownloadSummary([unit(1, item: 7, .failed, got: 30), unit(2, item: 8, .paused)], speeds: [:])
        #expect(summary.detail == "1 个下载中断 · 15%")
        #expect(summary.tint == Theme.warning)
    }

    @Test func queuedWithoutSizeYet() {
        let summary = OfflineDownloadSummary([unit(1, item: 7, .preparing, of: 0)], speeds: [:])
        #expect(summary.detail == "等待下载")
        #expect(summary.fraction == nil)
    }
}

/// 服务器排队转码（503）不是出错：写在等什么、不用警告色，首页汇总也不算「中断」
@MainActor
struct OfflineTranscodeWaitTests {
    private func waiting(_ note: String?) -> OfflineUnit {
        var unit = OfflineUnit(fileId: 1, mediaItemId: 7, season: 1, episode: 1, profile: "720p", profileLabel: "720p",
                               state: .failed, expectedBytes: 100, fileExtension: "mp4", createdAt: Date())
        unit.retryable = true
        unit.transcodeWait = note
        return unit
    }

    @Test func notesFromServerHeaders() {
        #expect(OfflineDownloader.transcodeWaitNote(wait: "queue", ahead: 2) == "等待转码，前面还有 2 个")
        #expect(OfflineDownloader.transcodeWaitNote(wait: "queue", ahead: 0) == "即将开始转码")
        #expect(OfflineDownloader.transcodeWaitNote(wait: "transcoder", ahead: 0) == "等待转码器空闲")
        #expect(OfflineDownloader.transcodeWaitNote(wait: nil, ahead: nil) == "等待转码")  // 旧服务端
    }

    @Test func waitingIsNotAnInterruption() {
        let unit = waiting("等待转码，前面还有 1 个")
        #expect(unit.waitingForTranscode && !unit.needsAttention)
        #expect(OfflineUnitStatus.text(unit) == "等待转码，前面还有 1 个")
        #expect(OfflineDownloadStrip.status(unit) == "等待转码，前面还有 1 个")
        let summary = OfflineDownloadSummary([unit], speeds: [:])
        #expect(summary.detail.hasPrefix("等待转码"))
        #expect(summary.tint == Theme.info)
    }

    @Test func realFailureStillWarns() {
        var unit = waiting(nil)
        unit.error = "网络连接中断"
        #expect(!unit.waitingForTranscode && unit.needsAttention)
        #expect(OfflineUnitStatus.text(unit) == "下载中断，稍后自动重试")
    }
}
