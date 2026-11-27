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

    @Test func multiSeasonScopesStayWithinCurrentSeason() {
        // 多季剧：第 1 季有已看和已下，切到第 2 季选中 S2E2（S2E1 已看、一集未下），范围只包含第 2 季，
        // 且第 1 季已下载不污染第 2 季的提示文案，不把「全部」错写成「剩余」
        let list = episodes(5, season: 1, local: [1: .done, 2: .done], played: [1, 2])
            + episodes(4, season: 2, played: [1])
            + episodes(6, season: 3)
        let choices = OfflineDownloadChoices.make(episodes: list, selected: (2, 2), selectedFile: 2002, multiSeason: true)
        #expect(choices.seasonLabel == "第 2 季")
        #expect(choices.note == nil)
        #expect(choices.scopes.map(\.label) == ["第 2 集", "未看 3 集", "全部 4 集"])
        #expect(choices.scopes.first(where: \.preferred)?.id == "unwatched")
        #expect(choices.scopes[0].fileIds == [2002])
        #expect(choices.scopes[0].detail == "第 2 季第 2 集")
        #expect(choices.scopes[1].fileIds == [2002, 2003, 2004])
        #expect(choices.scopes[1].detail == "第 2 季第 2～4 集，共 3 集")
        #expect(choices.scopes[2].fileIds == [2001, 2002, 2003, 2004])
        #expect(choices.scopes[2].detail == "第 2 季第 1～4 集，共 4 集")
    }

    @Test func multiSeasonNextAndNonContiguousStayInSeason() {
        // S1 共 4 集，E2 已下，S2 还有 3 集：在 S1 选中 E2 时，「接下来」只取 S1 的 E3～E4，不跨到 S2
        let list = episodes(4, season: 1, local: [2: .done]) + episodes(3, season: 2)
        let choices = OfflineDownloadChoices.make(episodes: list, selected: (1, 2), selectedFile: nil, multiSeason: true)
        #expect(choices.seasonLabel == "第 1 季")
        #expect(choices.hasLocal)
        #expect(choices.note == "第 1 季第 2 集已下载 · 已下载 1 集，不会重复下载")
        #expect(choices.scopes.map(\.label) == ["接下来 2 集", "剩余 3 集"])
        #expect(choices.scopes[0].fileIds == [1003, 1004])
        #expect(choices.scopes[0].detail == "第 1 季第 3～4 集，共 2 集")
        #expect(choices.scopes[1].fileIds == [1001, 1003, 1004])
        #expect(choices.scopes[1].detail == "第 1 季第 1 集 起，共 3 集")
    }

    @Test func multiSeasonEndOfSeasonDoesNotSpillIntoNextSeason() {
        // S1 共 3 集，E2 已下、E3 已下（选中 E3），S2 未下：不跨进 S2，只剩 S1E1
        let list = episodes(3, season: 1, local: [2: .done, 3: .done]) + episodes(3, season: 2)
        let choices = OfflineDownloadChoices.make(episodes: list, selected: (1, 3), selectedFile: nil, multiSeason: true)
        #expect(choices.scopes.map(\.label) == ["剩余 1 集"])
        #expect(choices.scopes[0].fileIds == [1001])
        #expect(choices.scopes[0].detail == "第 1 季第 1 集")
    }

    @Test func watchedAndDownloadedEpisodeLabelsRemainingAsUnwatched() {
        // 第 2 季 10 集：第 1 集已下且已看，第 2～10 集未下且未看 → 剩下的全是未看，直接叫「未看 9 集」而非「剩余 9 集」
        let list = episodes(10, season: 2, local: [1: .done], played: [1])
        let choices = OfflineDownloadChoices.make(episodes: list, selected: (2, 2), selectedFile: 2002, multiSeason: true)
        #expect(choices.seasonLabel == "第 2 季")
        #expect(choices.scopes.map(\.label) == ["第 2 集", "未看 9 集"])
        #expect(choices.scopes.first(where: \.preferred)?.label == "未看 9 集")
        #expect(choices.scopes[1].detail == "第 2 季第 2～10 集，共 9 集")
        #expect(choices.note == "已下载 1 集，不会重复下载")
    }

    @Test func specialsSeasonUsesSpecialsName() {
        let list = episodes(3, season: 0, played: [1]) + episodes(2, season: 1)
        let choices = OfflineDownloadChoices.make(episodes: list, selected: (0, 2), selectedFile: nil, multiSeason: true, season: 0)
        #expect(choices.seasonLabel == "特别篇")
        #expect(choices.scopes.map(\.label) == ["第 2 集", "未看 2 集", "全部 3 集"])
        #expect(choices.scopes[0].detail == "特别篇第 2 集")
        #expect(choices.scopes[1].detail == "特别篇第 2～3 集，共 2 集")
    }

    @Test func everythingLocalAndUnownedSeasonAreDistinguished() {
        let downloaded = OfflineDownloadChoices.make(
            episodes: episodes(2, season: 1, local: [1: .done, 2: .done]) + episodes(2, season: 2),
            selected: (1, 1), selectedFile: nil, multiSeason: true, season: 1
        )
        #expect(downloaded.scopes.isEmpty)
        #expect(downloaded.hasLocal)
        #expect(downloaded.seasonLabel == "第 1 季")

        // 切到无片源的第 3 季（即使传了别的季的分集或旧选中集）：返回空且 hasLocal == false
        let emptySeason = OfflineDownloadChoices.make(
            episodes: episodes(2, season: 1),
            selected: (1, 1), selectedFile: nil, multiSeason: true, season: 3
        )
        #expect(emptySeason.scopes.isEmpty)
        #expect(!emptySeason.hasLocal)
        #expect(emptySeason.seasonLabel == "第 3 季")
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

    private func movie(_ fileId: Int, item: Int, _ state: OfflineUnit.State = .downloading) -> OfflineUnit {
        OfflineUnit(fileId: fileId, mediaItemId: item, season: 0, episode: 0, profile: "original", profileLabel: "原画", state: state,
                    expectedBytes: 100, fileExtension: "mp4", createdAt: Date())
    }

    @Test func sumsSpeedAndProgress() {
        let units = [unit(1, item: 7, .downloading, got: 50), unit(2, item: 7, .queued), unit(3, item: 9, .downloading, got: 100)]
        let summary = OfflineDownloadSummary(units, speeds: [1: 1_000_000, 3: 500_000])
        #expect(summary.title == "2 部剧共 3 集正在下载")
        #expect(summary.detail == "\(Formatters.bytes(1_500_000))/s · 50%")
        #expect(summary.fraction == 0.5)
    }

    @Test func titleSaysWhatIsDownloading() {
        let titles = [7: "兰香如故", 9: "深渊无间", 20: "沙丘", 21: "银翼杀手"]
        func title(_ units: [OfflineUnit]) -> String { OfflineDownloadSummary(units, speeds: [:], titles: titles).title }
        #expect(title([movie(1, item: 20)]) == "正在下载《沙丘》")
        #expect(title([movie(1, item: 20), movie(2, item: 21)]) == "2 部电影正在下载")
        #expect(title([unit(1, item: 7, .downloading), unit(2, item: 7, .queued)]) == "正在下载《兰香如故》2 集")
        #expect(title([unit(1, item: 7, .downloading), unit(2, item: 9, .queued)]) == "2 部剧共 2 集正在下载")
        #expect(title([movie(1, item: 20), movie(2, item: 21), movie(3, item: 22), unit(4, item: 7, .queued), unit(5, item: 7, .queued)])
            == "3 部电影、2 集剧集正在下载")
        // 没片名（目录还没读到）：退回计数
        #expect(OfflineDownloadSummary([unit(1, item: 99, .downloading)], speeds: [:]).title == "1 集剧集正在下载")
    }

    @Test func allPausedSaysSo() {
        let summary = OfflineDownloadSummary([unit(1, item: 7, .paused, got: 11)], speeds: [:], titles: [7: "兰香如故"])
        #expect(summary.title == "已暂停下载《兰香如故》1 集")
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

/// 下载顺序（§5.5）：顺序就是优先级，优先下载 = 排到最前
struct OfflineQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func unit(_ fileId: Int, item: Int = 1, episode: Int = 0, _ state: OfflineUnit.State = .queued,
                      added: TimeInterval = 0, order: Double? = nil, retryable: Bool = true) -> OfflineUnit {
        var unit = OfflineUnit(fileId: fileId, mediaItemId: item, season: episode == 0 ? 0 : 1, episode: episode, profile: "original",
                               profileLabel: "原画", state: state, expectedBytes: 100, fileExtension: "mkv", createdAt: t0 + added)
        unit.retryable = retryable
        unit.queueOrder = order
        return unit
    }

    @Test func addedOrderUntilReordered() {
        let queue = OfflineQueue.entries([unit(3, added: 2), unit(1, added: 0), unit(2, added: 1), unit(4, .done, added: 3)])
        #expect(queue.map(\.fileId) == [1, 2, 3], "按加入时间；下完的不在队里")
    }

    /// 调过顺序的编号 0、1、2…，之后新加的按加入时间排在它们后面
    @Test func numberedComeBeforeLaterAdditions() {
        let queue = OfflineQueue.entries([unit(1, added: 0, order: 1), unit(2, added: 1, order: 0), unit(3, added: 5)])
        #expect(queue.map(\.fileId) == [2, 1, 3])
    }

    /// 暂停的、要人处理的失败不算在前面；会自动重试的（含等转码）算
    @Test func aheadCountsOnlyUnitsThatWillRun() {
        let queue = OfflineQueue.entries([
            unit(1, .downloading, added: 0),
            unit(2, .paused, added: 1),
            unit(3, .failed, added: 2, retryable: false),
            unit(4, .failed, added: 3),
            unit(5, added: 4),
        ])
        #expect(OfflineQueue.ahead(of: 1, in: queue) == 0)
        #expect(OfflineQueue.ahead(of: 5, in: queue) == 2)
        #expect(OfflineQueue.ahead(of: 9, in: queue) == 0, "不在队里")
    }

    /// 正在下的排在下载中的最前：继续下载的那集排序在它前面、但不打断它，写「下一个下载」
    @Test func downloadingIsListedFirst() {
        let queue = OfflineQueue.entries([unit(1, added: 0), unit(2, .downloading, added: 1), unit(3, added: 2)])
        #expect(queue.map(\.fileId) == [2, 1, 3])
        #expect(OfflineQueue.ahead(of: 1, in: queue) == 1)
        #expect(OfflineQueue.canPrioritize(fileId: 1, in: queue), "要它立刻开始，就得打断正在下的")
    }

    @Test func prioritizeOfferedUnlessAlreadyFirst() {
        let queue = OfflineQueue.entries([unit(1, .downloading), unit(2, added: 1), unit(3, .paused, added: 2)])
        #expect(!OfflineQueue.canPrioritize(fileId: 1, in: queue), "已经排在最前")
        #expect(OfflineQueue.canPrioritize(fileId: 2, in: queue))
        #expect(OfflineQueue.canPrioritize(fileId: 3, in: queue), "暂停的也能优先（顺带继续）")
        #expect(!OfflineQueue.canPrioritize(fileId: 9, in: queue))
    }

    /// 整部剧插队：只有别的条目排在它某一集前面时才有意义
    @Test func wholeShowOnlyWhenSomethingElseIsAhead() {
        let behind = OfflineQueue.entries([unit(1, item: 1), unit(2, item: 2, episode: 1, added: 1), unit(3, item: 2, episode: 2, added: 2)])
        #expect(OfflineQueue.canPrioritize(itemId: 2, in: behind))
        #expect(!OfflineQueue.canPrioritize(itemId: 1, in: behind), "电影已经在最前")
        let mixed = OfflineQueue.entries([unit(2, item: 2, episode: 1), unit(1, item: 1, added: 1), unit(3, item: 2, episode: 2, added: 2)])
        #expect(OfflineQueue.canPrioritize(itemId: 2, in: mixed), "第 2 集排在电影后面")
        #expect(!OfflineQueue.canPrioritize(itemId: 2, in: OfflineQueue.entries([unit(2, item: 2, episode: 1)])), "只有它一部")
    }

    @Test func newOrderPutsListedFirstAndKeepsTheRest() {
        let queue = OfflineQueue.entries((1 ... 5).map { unit($0, added: Double($0)) })
        #expect(OfflineQueue.order(front: [4], in: queue) == [4, 1, 2, 3, 5])
        #expect(OfflineQueue.order(front: [5, 3, 5, 99], in: queue) == [5, 3, 1, 2, 4], "去重、不认队外的")
    }

    @Test func queuedStatusSaysHowManyAhead() {
        let queued = unit(1)
        #expect(OfflineUnitStatus.text(queued) == "等待下载")
        #expect(OfflineUnitStatus.text(queued, ahead: 1) == "下一个下载")
        #expect(OfflineUnitStatus.text(queued, ahead: 3) == "等待下载，前面还有 3 个")
        #expect(OfflineDownloadStrip.status(queued, ahead: 3) == "前面还有 3 个", "分集卡上写短的")
        #expect(OfflineUnitStatus.text(unit(2, .paused), ahead: 3) == "已暂停", "只有排队的写排第几")
    }

    /// 排序键写进存档；没有这个字段的旧存档照样读
    @Test func orderSurvivesArchiveAndOldArchivesStillRead() throws {
        let saved = unit(1, order: 2)
        let data = try OfflineDisk.encoder.encode(saved)
        #expect(try OfflineDisk.decoder.decode(OfflineUnit.self, from: data).queueOrder == 2)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "queueOrder")
        let old = try OfflineDisk.decoder.decode(OfflineUnit.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.queueOrder == nil)
    }
}

/// 详情页剧集文件列表的实时派生（issue #1336）：`reload()` 刷新 `detail` 后（本地快照秒开 → 在线拉新、
/// 生成/删字幕回调、下拉刷新），即使 `fileCount` 不变，也不能停在 `selectedEpisode.files` 旧快照。
@MainActor
struct LibraryDetailTrackFilesTests {
    private func makeFile(
        id: Int,
        season: Int = 6,
        episode: Int = 1,
        state: String = "in_place",
        subtitles: [API.SubtitleStreamView],
        defaults: API.TrackDefaultsView? = nil
    ) -> API.LibraryFileView {
        API.LibraryFileView(
            id: id,
            filePath: "/media/Show/S0\(season)E0\(episode).mkv",
            fileName: "Show - S0\(season)E0\(episode).mkv",
            sizeBytes: 1_000_000,
            container: "mkv",
            resolution: "1080p",
            videoCodec: "hevc",
            hdr: nil,
            bitDepth: 10,
            durationSeconds: 3000,
            bitRate: 5_000_000,
            frameRate: 24,
            colorSpace: "bt709",
            mediaSource: "WEB-DL",
            mediaSourceManual: false,
            releaseGroup: nil,
            source: "scanned",
            seasonNumber: season,
            episodeNumber: episode,
            missing: false,
            state: state,
            purgeAfter: nil,
            trashNote: nil,
            origin: API.FileOriginView(kind: "scan", label: "存量扫描发现", detail: nil),
            keptAt: nil,
            audioStreams: nil,
            subtitleStreams: subtitles,
            playbackDefaults: defaults,
            chapters: nil,
            cloud: nil,
            addedAt: "2026-11-25T10:00:00Z"
        )
    }

    private func makeDetail(kind: String = "tv", files: [API.LibraryFileView]) -> API.LibraryItemDetailView {
        API.LibraryItemDetailView(
            mediaItemId: 676,
            kind: kind,
            source: "tmdb",
            tmdbId: 991336,
            imdbId: nil,
            doubanId: nil,
            title: "合成流人",
            originalTitle: "Synthetic Horses",
            englishTitle: nil,
            chineseTitle: nil,
            year: 2022,
            posterUrl: nil,
            backdropUrl: nil,
            logoUrl: nil,
            primaryAspect: 0.67,
            localMeta: nil,
            entryDirs: [],
            files: files,
            fileCount: files.count,
            totalSizeBytes: files.reduce(0) { $0 + $1.sizeBytes },
            seasons: kind == "tv" ? [6] : [],
            scraping: false,
            scrapingPhase: nil,
            chaptersPending: false,
            seriesName: nil,
            seriesCollectionId: nil,
            collections: []
        )
    }

    private func makeEpisode(_ number: Int, fileIds: [Int]) -> API.EpisodeView {
        API.EpisodeView(
            episodeNumber: number,
            name: "第 \(number) 集",
            overview: nil,
            airDate: nil,
            stillUrl: nil,
            owned: !fileIds.isEmpty,
            fileIds: fileIds,
            positionMs: 0,
            played: false,
            progressPercent: nil
        )
    }

    @Test func tvEpisodeUsesFreshDetailFilesWhenFileCountUnchanged() {
        let embedded = API.SubtitleStreamView(codec: "subrip", language: "chi", title: "内封中文", forced: false, default: false, external: false, fileName: nil)
        let aiSub = API.SubtitleStreamView(
            codec: "srt", language: "chi", title: "ai-bilingual-chs-eng", forced: false, default: false, external: true,
            fileName: "Show - S06E01.ai-bilingual-chs-eng.chi.srt"
        )
        let staleFile = makeFile(id: 5056, subtitles: [embedded])
        let freshDefaults = API.TrackDefaultsView(
            audioTrack: "embedded:0", audioReason: "first", audioNote: "第一条",
            subtitleTrack: "external:Show - S06E01.ai-bilingual-chs-eng.chi.srt",
            subtitleReason: "library_language", subtitleNote: "AI 双语字幕"
        )
        let freshFile = makeFile(id: 5056, subtitles: [embedded, aiSub], defaults: freshDefaults)

        // selectedEpisode 仍带着本地 detail.json 秒开时的旧 files 快照，但 detail 已在线刷新（fileCount 同为 1）
        let selection = LibraryItemDetailView.SelectedEpisode(season: 6, episode: makeEpisode(1, fileIds: [5056]), files: [staleFile])
        let freshDetail = makeDetail(kind: "tv", files: [freshFile])

        let resolved = LibraryItemDetailView.resolvedTrackFiles(detail: freshDetail, selectedEpisode: selection)
        #expect(resolved.count == 1)
        #expect(resolved[0].subtitleStreams.count == 2)
        #expect(resolved[0].subtitleStreams.contains { $0.external && $0.fileName == aiSub.fileName })
        #expect(resolved[0].playbackDefaults?.subtitleTrack == "external:Show - S06E01.ai-bilingual-chs-eng.chi.srt")
    }

    @Test func tvEpisodeFallsBackBySeasonAndEpisodeWhenFileIdReplaced() {
        let staleFile = makeFile(id: 5056, season: 6, episode: 1, subtitles: [])
        let upgradedFile = makeFile(id: 5057, season: 6, episode: 1, subtitles: [
            API.SubtitleStreamView(codec: "srt", language: "chi", title: "ai-chs", forced: false, default: false, external: true, fileName: "Show - S06E01.ai-chs.srt"),
        ])
        let otherEpisodeFile = makeFile(id: 5058, season: 6, episode: 2, subtitles: [])

        let selection = LibraryItemDetailView.SelectedEpisode(season: 6, episode: makeEpisode(1, fileIds: [5056]), files: [staleFile])
        let freshDetail = makeDetail(kind: "tv", files: [upgradedFile, otherEpisodeFile])

        let resolved = LibraryItemDetailView.resolvedTrackFiles(detail: freshDetail, selectedEpisode: selection)
        #expect(resolved.map(\.id) == [5057])
    }

    @Test func unownedEpisodeReturnsEmptyAndMovieReturnsAllFiles() {
        let file = makeFile(id: 5056, season: 6, episode: 1, subtitles: [])
        let tvDetail = makeDetail(kind: "tv", files: [file])
        let missingSelection = LibraryItemDetailView.SelectedEpisode(season: 6, episode: makeEpisode(2, fileIds: []), files: [])
        #expect(LibraryItemDetailView.resolvedTrackFiles(detail: tvDetail, selectedEpisode: missingSelection).isEmpty)
        #expect(LibraryItemDetailView.resolvedTrackFiles(detail: tvDetail, selectedEpisode: nil).isEmpty)

        let movieDetail = makeDetail(kind: "movie", files: [file])
        #expect(LibraryItemDetailView.resolvedTrackFiles(detail: movieDetail, selectedEpisode: nil).map(\.id) == [5056])
    }

    @Test func tvEpisodeReflectsMultiVersionChangesWhenFileIdsPartiallyStale() {
        let v1 = makeFile(id: 5056, season: 6, episode: 1, subtitles: [])
        let v2 = makeFile(id: 5057, season: 6, episode: 1, subtitles: [])
        let v3 = makeFile(id: 5059, season: 6, episode: 1, subtitles: [])
        let trashed = makeFile(id: 5060, season: 6, episode: 1, state: "trashed", subtitles: [])

        // 1) 单版本快照 [5056] 在线刷新出第二版本 5057（fileIds 仍只有 [5056]）→ 两个版本都可见且原顺序在前
        let singleSelection = LibraryItemDetailView.SelectedEpisode(season: 6, episode: makeEpisode(1, fileIds: [5056]), files: [v1])
        let twoVersionDetail = makeDetail(kind: "tv", files: [v2, v1])
        #expect(LibraryItemDetailView.resolvedTrackFiles(detail: twoVersionDetail, selectedEpisode: singleSelection).map(\.id) == [5056, 5057])

        // 2) 双版本 [5056, 5057] 中 5057 洗版换成 5059（fileCount 不变）→ 不丢新版本 5059
        let multiSelection = LibraryItemDetailView.SelectedEpisode(season: 6, episode: makeEpisode(1, fileIds: [5056, 5057]), files: [v1, v2])
        let replacedDetail = makeDetail(kind: "tv", files: [v1, v3])
        #expect(LibraryItemDetailView.resolvedTrackFiles(detail: replacedDetail, selectedEpisode: multiSelection).map(\.id) == [5056, 5059])

        // 3) 同集包含 in_place + trashed：全部返回供文件区展示（轨道区自行过滤 in_place）
        let mixedDetail = makeDetail(kind: "tv", files: [v1, trashed])
        #expect(LibraryItemDetailView.resolvedTrackFiles(detail: mixedDetail, selectedEpisode: singleSelection).map(\.id) == [5056, 5060])
    }
}

/// Issue #1336：已下载本机副本联网补齐外挂字幕（不重下视频、不改默认选轨、失败保留原字幕）
struct OfflineSubtitleSyncTests {
    private enum SyncTestError: Error { case simulatedFailure }

    private func makeFile(id: Int = 1, subtitles: [API.SubtitleStreamView]) -> API.LibraryFileView {
        API.LibraryFileView(
            id: id,
            filePath: "/media/Show/S06E01.mkv",
            fileName: "Show - S06E01.mkv",
            sizeBytes: 1_024_000,
            container: "mkv",
            resolution: "1080p",
            videoCodec: "h264",
            hdr: nil,
            bitDepth: 8,
            durationSeconds: 1800,
            bitRate: 5_000_000,
            frameRate: 24,
            colorSpace: "bt709",
            mediaSource: "WEB-DL",
            mediaSourceManual: false,
            releaseGroup: nil,
            source: "scanned",
            seasonNumber: 6,
            episodeNumber: 1,
            missing: false,
            state: "in_place",
            purgeAfter: nil,
            trashNote: nil,
            origin: API.FileOriginView(kind: "scan", label: "存量扫描发现", detail: nil),
            keptAt: nil,
            audioStreams: nil,
            subtitleStreams: subtitles,
            playbackDefaults: nil,
            chapters: nil,
            cloud: nil,
            addedAt: "2026-11-25T10:00:00Z"
        )
    }

    private func makeSpec(subtitles: [OfflinePlaybackSpec.Subtitle], fonts: [String] = []) -> OfflinePlaybackSpec {
        OfflinePlaybackSpec(
            durationMs: 1_800_000,
            chapters: [],
            segments: [],
            audioTracks: [],
            defaultAudio: "embedded:0",
            subtitles: subtitles,
            fonts: fonts,
            resolution: "1080p",
            videoCodec: "h264",
            container: "mkv"
        )
    }

    private func makeUnit(fileId: Int = 1, profile: String = "original", state: OfflineUnit.State = .done) -> OfflineUnit {
        OfflineUnit(
            fileId: fileId,
            mediaItemId: 1,
            season: 6,
            episode: 1,
            profile: profile,
            profileLabel: profile == "original" ? "原画" : profile,
            state: state,
            expectedBytes: 4096,
            receivedBytes: 4096,
            fileExtension: profile == "original" ? "mkv" : "mp4",
            createdAt: Date(),
            completedAt: Date()
        )
    }

    private func makeManifestSub(
        ref: String,
        format: String = "srt",
        language: String? = "chi",
        title: String? = nil,
        isDefault: Bool = false,
        isAi: Bool = false,
        embedded: Bool = false,
        url: String? = nil
    ) -> API.OfflineSubtitleView {
        API.OfflineSubtitleView(
            trackRef: ref,
            format: format,
            language: language,
            title: title,
            isDefault: isDefault,
            isForced: false,
            isAi: isAi,
            embedded: embedded,
            url: url ?? "/api/v1/playback/files/1/subtitles?track=\(ref)"
        )
    }

    @Test func needsSyncComparesOnlySupportedExternalTextSubtitles() {
        let embedded = API.SubtitleStreamView(codec: "subrip", language: "chi", title: "内封", forced: false, default: true, external: false, fileName: nil)
        let bitmapExt = API.SubtitleStreamView(codec: "sup", language: "eng", title: nil, forced: false, default: false, external: true, fileName: "ep.eng.sup")
        let aiExt = API.SubtitleStreamView(codec: "srt", language: "chi", title: "AI", forced: false, default: false, external: true, fileName: "ep.ai.chi.srt")

        let emptySpec = makeSpec(subtitles: [])
        #expect(!OfflineSubtitleSync.needsSync(localSpec: emptySpec, serverFile: makeFile(subtitles: [embedded, bitmapExt])), "仅有内封与图形外挂时无需同步")
        #expect(OfflineSubtitleSync.needsSync(localSpec: emptySpec, serverFile: makeFile(subtitles: [embedded, aiExt])), "新增外挂文字字幕应触发同步")

        // 转码档本地 spec 里有 embedded:0，且已含 ep.ai.chi.srt → 不应误判需同步
        let syncedSpec = makeSpec(subtitles: [
            .init(ref: "external:0-chi.srt", fileName: "0-chi.srt", kind: "vtt", language: "chi", title: "内封", isDefault: true, isForced: false, isAi: false, sourceRef: "embedded:0"),
            .init(ref: "external:sync-abc-chi.srt", fileName: "sync-abc-chi.srt", kind: "vtt", language: "chi", title: "AI", isDefault: false, isForced: false, isAi: true, sourceRef: "external:ep.ai.chi.srt"),
        ])
        #expect(!OfflineSubtitleSync.needsSync(localSpec: syncedSpec, serverFile: makeFile(subtitles: [embedded, aiExt])))
        #expect(!OfflineSubtitleSync.needsSync(localSpec: nil, serverFile: makeFile(subtitles: [aiExt])))
    }

    @Test func planPreservesDefaultSelectionAndEmbeddedTracks() {
        let existing: [OfflinePlaybackSpec.Subtitle] = [
            // 转码档已打包的内封轨：必须原样保留
            .init(ref: "external:0-eng.srt", fileName: "0-eng.srt", kind: "vtt", language: "eng", title: "内封英文", isDefault: true, isForced: false, isAi: false, sourceRef: "embedded:3"),
            // 既有外挂轨：保留原文件名与 isDefault
            .init(ref: "external:1-eng.srt", fileName: "1-eng.srt", kind: "vtt", language: "eng", title: "旧外挂", isDefault: true, isForced: false, isAi: false, sourceRef: "external:old.eng.srt"),
            // 服务端已删除的外挂轨：标记清理
            .init(ref: "external:2-jpn.srt", fileName: "2-jpn.srt", kind: "vtt", language: "jpn", title: "已删", isDefault: false, isForced: false, isAi: false, sourceRef: "external:removed.jpn.srt"),
        ]
        let manifestSubs = [
            makeManifestSub(ref: "embedded:3", language: "eng", title: "内封英文", isDefault: false, embedded: true),
            makeManifestSub(ref: "external:old.eng.srt", language: "eng", title: "旧外挂", isDefault: false),
            makeManifestSub(ref: "external:ai-bilingual.chi.srt", language: "chi", title: "简体中文 + 英语", isDefault: true, isAi: true),
        ]

        let plan = OfflineSubtitleSync.plan(
            existing: existing,
            manifestSubtitles: manifestSubs,
            existingSubFiles: ["0-eng.srt", "1-eng.srt", "2-jpn.srt"]
        )

        #expect(plan.subtitles.count == 3)
        #expect(plan.subtitles[0].sourceRef == "embedded:3")
        #expect(plan.subtitles[0].isDefault == true, "既有内封轨默认标记不变")
        #expect(plan.subtitles[1].fileName == "1-eng.srt")
        #expect(plan.subtitles[1].isDefault == true, "既有外挂轨保留原默认标记")
        #expect(plan.subtitles[2].sourceRef == "external:ai-bilingual.chi.srt")
        #expect(plan.subtitles[2].isDefault == false, "后补齐的外挂字幕即使服务端标默认也不改默认选轨")
        #expect(plan.subtitles[2].fileName.hasPrefix("sync-"))
        #expect(plan.downloads.map(\.fileName) == [plan.subtitles[2].fileName], "只下载新增外挂字幕，不重下内封和既有外挂")
        #expect(plan.obsoleteFiles == ["2-jpn.srt"])
    }

    @Test func syncSubtitlesBackfillsAtomicallyWithoutTouchingMedia() async throws {
        let key = "test-sync-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }

        let unit = makeUnit(fileId: 1)
        let unitDir = OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId)
        try OfflineDisk.write(unit, to: OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId))
        try OfflineDisk.write(makeSpec(subtitles: []), to: OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId))
        let mediaURL = unitDir.appending(path: unit.mediaFileName)
        let mediaBytes = Data("synthetic-video-bytes".utf8)
        try mediaBytes.write(to: mediaURL)

        let aiSub = makeManifestSub(
            ref: "external:Show - S06E01.ai-bilingual-chs-eng.chi.srt",
            format: "srt", language: "chi", title: "简体中文 + 英语", isDefault: true, isAi: true,
            url: "/sub/ai"
        )
        let changed = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: unit,
            manifestFileId: 1,
            manifestDefaultAudio: "embedded:0",
            manifestSubtitles: [makeManifestSub(ref: "embedded:3", language: "eng", isDefault: true, embedded: true), aiSub],
            fontsUrl: nil
        ) { path, _ in
            #expect(path == "/sub/ai")
            return Data("1\n00:00:01,000 --> 00:00:10,000\n合成双语AI字幕\n".utf8)
        }

        #expect(changed == true)
        let updatedSpec = try #require(OfflineDisk.read(OfflinePlaybackSpec.self, from: OfflineDisk.playbackFile(key, 1, 1)))
        #expect(updatedSpec.subtitles.count == 1)
        #expect(updatedSpec.subtitles[0].sourceRef == aiSub.trackRef)
        #expect(updatedSpec.subtitles[0].isDefault == false, "补齐的 AI 字幕不改默认选轨")
        #expect(updatedSpec.subtitles[0].isAi == true)

        let savedText = try String(contentsOf: unitDir.appending(path: "subs/\(updatedSpec.subtitles[0].fileName)"), encoding: .utf8)
        #expect(savedText.contains("合成双语AI字幕"))
        #expect(try Data(contentsOf: mediaURL) == mediaBytes, "视频文件毫发无损")
    }

    @Test func syncFailurePreservesExistingSubtitlesAndPlaybackSpec() async throws {
        let key = "test-sync-fail-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }

        let unit = makeUnit(fileId: 1)
        let unitDir = OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId)
        let originalSub = OfflinePlaybackSpec.Subtitle(
            ref: "external:0-chi.srt", fileName: "0-chi.srt", kind: "vtt",
            language: "chi", title: "原有字幕", isDefault: false, isForced: false, isAi: true,
            sourceRef: "external:keep.chi.srt"
        )
        let originalSpec = makeSpec(subtitles: [originalSub])
        try OfflineDisk.write(unit, to: OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId))
        try OfflineDisk.write(originalSpec, to: OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId))
        let subsDir = unitDir.appending(path: "subs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        let keepData = Data("1\n00:00:01,000 --> 00:00:05,000\n原字幕\n".utf8)
        try keepData.write(to: subsDir.appending(path: "0-chi.srt"))

        // 第一条新增字幕成功，第二条失败 → 整体抛出，不得改写 playback.json，不得写入半截新字幕或删掉原字幕
        let s1 = makeManifestSub(ref: "external:new1.eng.srt", language: "eng", url: "/sub/1")
        let s2 = makeManifestSub(ref: "external:new2.jpn.srt", language: "jpn", url: "/sub/2")
        await #expect(throws: SyncTestError.self) {
            try await OfflinePackager.syncSubtitles(
                ownerKey: key,
                unit: unit,
                manifestFileId: 1,
                manifestDefaultAudio: "embedded:0",
                manifestSubtitles: [s1, s2],
                fontsUrl: nil
            ) { path, _ in
                if path == "/sub/2" { throw SyncTestError.simulatedFailure }
                return Data("ok".utf8)
            }
        }

        let afterSpec = try #require(OfflineDisk.read(OfflinePlaybackSpec.self, from: OfflineDisk.playbackFile(key, 1, 1)))
        #expect(afterSpec.subtitles == [originalSub], "失败后 playback.json 必须保持原样")
        let filesOnDisk = Set(OfflineDisk.children(subsDir).map(\.lastPathComponent))
        #expect(filesOnDisk == ["0-chi.srt"], "失败后原有字幕文件保留且不遗留半截文件")
        #expect(try Data(contentsOf: subsDir.appending(path: "0-chi.srt")) == keepData)
    }

    @Test func syncDownloadsAssFontsAndCleansUpDeletedExternalSubtitle() async throws {
        let key = "test-sync-ass-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }

        let unit = makeUnit(fileId: 1)
        let unitDir = OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId)
        let oldSub = OfflinePlaybackSpec.Subtitle(
            ref: "external:0-old.srt", fileName: "0-old.srt", kind: "vtt",
            language: "eng", title: nil, isDefault: false, isForced: false, isAi: false,
            sourceRef: "external:old.eng.srt"
        )
        try OfflineDisk.write(unit, to: OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId))
        try OfflineDisk.write(makeSpec(subtitles: [oldSub]), to: OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId))
        let subsDir = unitDir.appending(path: "subs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: subsDir.appending(path: "0-old.srt"))

        let assSub = makeManifestSub(ref: "external:anime.chi.ass", format: "ass", language: "chi", title: "特效字幕", url: "/sub/ass")
        let changed = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: unit,
            manifestFileId: 1,
            manifestDefaultAudio: "embedded:0",
            manifestSubtitles: [assSub],
            fontsUrl: "/fonts/list"
        ) { path, _ in
            switch path {
            case "/sub/ass": Data("[Script Info]\nTitle: Test\n".utf8)
            case "/fonts/list": Data(#"{"success":true,"data":{"fonts":["/fonts/NotoSans.ttf"]}}"#.utf8)
            case "/fonts/NotoSans.ttf": Data("TTF_BYTES".utf8)
            default: throw SyncTestError.simulatedFailure
            }
        }

        #expect(changed == true)
        let afterSpec = try #require(OfflineDisk.read(OfflinePlaybackSpec.self, from: OfflineDisk.playbackFile(key, 1, 1)))
        #expect(afterSpec.subtitles.count == 1)
        #expect(afterSpec.subtitles[0].kind == "ass")
        #expect(afterSpec.fonts == ["NotoSans.ttf"])
        #expect(FileManager.default.fileExists(atPath: unitDir.appending(path: "fonts/NotoSans.ttf").path))
        #expect(!FileManager.default.fileExists(atPath: subsDir.appending(path: "0-old.srt").path), "已删除的旧外挂字幕在新 playback.json 落盘后清理")
    }

    @Test func syncAbortsCleanlyIfUnitDeletedBeforeCommit() async throws {
        let key = "test-sync-deleted-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }

        let unit = makeUnit(fileId: 1)
        let unitDir = OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId)
        try OfflineDisk.write(unit, to: OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId))
        try OfflineDisk.write(makeSpec(subtitles: []), to: OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId))

        let newSub = makeManifestSub(ref: "external:late.chi.srt", url: "/sub/late")
        let changed = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: unit,
            manifestFileId: 1,
            manifestDefaultAudio: "embedded:0",
            manifestSubtitles: [newSub],
            fontsUrl: nil
        ) { _, _ in
            // 模拟网络拉取期间用户删掉了本机副本
            try await OfflineDisk.perform { OfflineDisk.remove(unitDir) }
            return Data("late".utf8)
        }

        #expect(changed == false)
        #expect(!FileManager.default.fileExists(atPath: unitDir.path), "已删除的单元目录不应被后台同步重新建出来")
    }

    /// 回归 1a：慢网后台任务超时后立即结束等待（不阻塞起播），且不取消后台任务
    @Test func awaitBoundedReturnsAtTimeoutWithoutCancellingBackgroundTask() async {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var completed: Bool {
                lock.lock(); defer { lock.unlock() }
                return value
            }
            func mark() {
                lock.lock(); value = true; lock.unlock()
            }
        }

        let flag = Flag()
        let slowTask = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { flag.mark() }
        }

        let start = ContinuousClock.now
        await OfflineSubtitleSync.awaitBounded(slowTask, timeout: 0.15)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(500), "超时应尽快返回，不得阻塞到慢网任务结束（实际 \(elapsed)）")
        #expect(!flag.completed, "超时返回时后台任务仍在继续")
        await slowTask.value
        #expect(flag.completed, "超时只结束等待、不取消后台任务，后台任务应顺利收尾")
    }

    /// 回归 1b：等待方被取消时应立即结束等待（不阻塞退出），且不取消后台任务
    @Test func awaitBoundedReturnsImmediatelyWhenCallerCancelledWithoutCancellingBackgroundTask() async {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var value = false
            var completed: Bool {
                lock.lock(); defer { lock.unlock() }
                return value
            }
            func mark() {
                lock.lock(); value = true; lock.unlock()
            }
        }

        let flag = Flag()
        let slowTask = Task<Void, Never> {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { flag.mark() }
        }

        let start = ContinuousClock.now
        let waiter = Task {
            await OfflineSubtitleSync.awaitBounded(slowTask, timeout: 5.0)
        }
        try? await Task.sleep(for: .milliseconds(80))
        waiter.cancel()
        await waiter.value
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(450), "等待方取消后必须立即返回（实际 \(elapsed)）")
        await slowTask.value
        #expect(flag.completed, "等待方取消不应连带取消后台同步任务")
    }

    /// 回归 2：降级 HTTP 200 空清单（如文件缺失、需转码同意、策略拒绝、原盘）不得清掉本机已有字幕
    @Test func degradedHttp200EmptyManifestPreservesExistingSubtitles() async throws {
        let key = "test-sync-degraded-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }

        let unit = makeUnit(fileId: 1)
        let unitDir = OfflineDisk.unitDir(key, unit.mediaItemId, unit.fileId)
        let existingSub = OfflinePlaybackSpec.Subtitle(
            ref: "external:sync-keep-chi.srt", fileName: "sync-keep-chi.srt", kind: "vtt",
            language: "chi", title: "双语 AI", isDefault: false, isForced: false, isAi: true,
            sourceRef: "external:ai.chi.srt"
        )
        let spec = makeSpec(subtitles: [existingSub])
        try OfflineDisk.write(unit, to: OfflineDisk.unitFile(key, unit.mediaItemId, unit.fileId))
        try OfflineDisk.write(spec, to: OfflineDisk.playbackFile(key, unit.mediaItemId, unit.fileId))
        let subsDir = unitDir.appending(path: "subs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        let savedBytes = Data("1\n00:00:01,000 --> 00:00:05,000\n保留\n".utf8)
        try savedBytes.write(to: subsDir.appending(path: existingSub.fileName))

        // 2a) HTTP 200 但 PlaybackPlan 未生成：audioTracks / defaultAudio / subtitles 全空
        let changedEmpty = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: unit,
            manifestFileId: 1,
            unavailableReason: nil,
            manifestAudioTracks: [],
            manifestDefaultAudio: nil,
            manifestSubtitles: [],
            fontsUrl: nil
        ) { _, _ in
            Issue.record("降级空清单不应发起任何下载")
            return Data()
        }
        #expect(changedEmpty == false)

        // 2b) HTTP 200 但 unavailableReason 非空
        let changedUnavailable = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: unit,
            manifestFileId: 1,
            unavailableReason: "原盘不支持离线下载",
            manifestAudioTracks: [],
            manifestDefaultAudio: nil,
            manifestSubtitles: [],
            fontsUrl: nil
        ) { _, _ in Data() }
        #expect(changedUnavailable == false)

        // 2c) HTTP 200 但 serverFile 仍报告有外挂文字字幕，manifestSubtitles 却无外挂轨
        let serverFileWithExt = makeFile(id: 1, subtitles: [
            API.SubtitleStreamView(codec: "srt", language: "chi", title: "AI", forced: false, default: false, external: true, fileName: "ai.chi.srt"),
        ])
        let changedMismatch = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: unit,
            manifestFileId: 1,
            unavailableReason: nil,
            manifestAudioTracks: [],
            manifestDefaultAudio: "embedded:0",
            manifestSubtitles: [makeManifestSub(ref: "embedded:0", embedded: true)],
            fontsUrl: nil,
            serverFile: serverFileWithExt
        ) { _, _ in Data() }
        #expect(changedMismatch == false)

        // 核对：原有 playback.json 和字幕文件 100% 保留
        let afterSpec = try #require(OfflineDisk.read(OfflinePlaybackSpec.self, from: OfflineDisk.playbackFile(key, 1, 1)))
        #expect(afterSpec.subtitles == [existingSub])
        #expect(try Data(contentsOf: subsDir.appending(path: existingSub.fileName)) == savedBytes)

        // 对照：正常非降级清单（有 defaultAudio 且服务端已真正删掉该外挂字幕）仍能正常清理
        let serverFileWithoutExt = makeFile(id: 1, subtitles: [])
        let changedLegitDelete = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: unit,
            manifestFileId: 1,
            unavailableReason: nil,
            manifestAudioTracks: [],
            manifestDefaultAudio: "embedded:0",
            manifestSubtitles: [makeManifestSub(ref: "embedded:0", embedded: true)],
            fontsUrl: nil,
            serverFile: serverFileWithoutExt
        ) { _, _ in Data() }
        #expect(changedLegitDelete == true)
        let cleanedSpec = try #require(OfflineDisk.read(OfflinePlaybackSpec.self, from: OfflineDisk.playbackFile(key, 1, 1)))
        #expect(cleanedSpec.subtitles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: subsDir.appending(path: existingSub.fileName).path))
    }

    /// 回归 3a：同步拉取字幕期间用户删除并同档重下（哪怕同一秒内），旧同步不得覆盖新副本与新副本的默认选轨
    @Test func syncAbortsWithoutOverwritingWhenDeletedAndRedownloadedSameProfileDuringFetch() async throws {
        let key = "test-sync-redownload-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }

        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        var mutableOldUnit = makeUnit(fileId: 1, profile: "original", state: .done)
        mutableOldUnit.createdAt = t0
        mutableOldUnit.completedAt = t0
        let oldUnit = mutableOldUnit
        let unitDir = OfflineDisk.unitDir(key, oldUnit.mediaItemId, oldUnit.fileId)
        let subsDir = unitDir.appending(path: "subs", directoryHint: .isDirectory)
        try OfflineDisk.write(oldUnit, to: OfflineDisk.unitFile(key, 1, 1))
        try OfflineDisk.write(makeSpec(subtitles: []), to: OfflineDisk.playbackFile(key, 1, 1))

        let aiSub = makeManifestSub(
            ref: "external:Show - S06E01.ai-bilingual.chi.srt",
            format: "srt", language: "chi", title: "简体中文 + 英语", isDefault: true, isAi: true,
            url: "/sub/ai"
        )
        let freshDefaultSub = OfflinePlaybackSpec.Subtitle(
            ref: "external:0-chi.srt", fileName: "0-chi.srt", kind: "vtt",
            language: "chi", title: "简体中文 + 英语", isDefault: true, isForced: false, isAi: true,
            sourceRef: aiSub.trackRef
        )
        let freshBytes = Data("FRESH_REDOWNLOAD_SUBTITLE".utf8)

        let changed = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: oldUnit,
            manifestFileId: 1,
            manifestDefaultAudio: "embedded:0",
            manifestSubtitles: [aiSub],
            fontsUrl: nil
        ) { _, _ in
            // 模拟网络拉取期间：删除旧副本并立刻以相同 fileId、相同 original 档（甚至同一秒时间戳）重新下载完成
            try await OfflineDisk.perform {
                OfflineDisk.remove(unitDir)
                try OfflineDisk.write(oldUnit, to: OfflineDisk.unitFile(key, 1, 1))
                try FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
                try freshBytes.write(to: subsDir.appending(path: "0-chi.srt"), options: .atomic)
                try OfflineDisk.write(
                    OfflinePlaybackSpec(
                        durationMs: 1_800_000, chapters: [], segments: [], audioTracks: [],
                        defaultAudio: "embedded:0", subtitles: [freshDefaultSub], fonts: [],
                        resolution: "1080p", videoCodec: "h264", container: "mkv"
                    ),
                    to: OfflineDisk.playbackFile(key, 1, 1)
                )
            }
            return Data("STALE_OLD_SYNC_SUBTITLE".utf8)
        }

        #expect(changed == false, "旧同步检测到副本已重建后必须放弃落盘")
        let afterSpec = try #require(OfflineDisk.read(OfflinePlaybackSpec.self, from: OfflineDisk.playbackFile(key, 1, 1)))
        #expect(afterSpec.subtitles == [freshDefaultSub], "新副本的 playback.json 与默认选轨（isDefault=true）不得被旧同步覆盖")
        let filesOnDisk = Set(OfflineDisk.children(subsDir).map(\.lastPathComponent))
        #expect(filesOnDisk == ["0-chi.srt"], "旧同步不得写入多余的 sync-... 文件")
        #expect(try Data(contentsOf: subsDir.appending(path: "0-chi.srt")) == freshBytes)
    }

    /// 回归 3b：拉取 manifest 慢网期间删除并同档重下，通过前置 expectedStamp 在拉取字幕前即中止
    @Test func syncAbortsWhenDeletedAndRedownloadedSameProfileBeforeManifestReturns() async throws {
        let key = "test-sync-redownload-manifest-\(UUID().uuidString.prefix(8))"
        defer { OfflineDisk.remove(OfflineDisk.ownerDir(key)) }

        let t0 = Date(timeIntervalSince1970: 1_760_000_100)
        var mutableOldUnit = makeUnit(fileId: 1, profile: "original", state: .done)
        mutableOldUnit.createdAt = t0
        mutableOldUnit.completedAt = t0
        let oldUnit = mutableOldUnit
        let unitDir = OfflineDisk.unitDir(key, 1, 1)
        try OfflineDisk.write(oldUnit, to: OfflineDisk.unitFile(key, 1, 1))
        try OfflineDisk.write(makeSpec(subtitles: []), to: OfflineDisk.playbackFile(key, 1, 1))

        // 在发出 /offline/manifest 前先读取磁盘指纹
        let expectedStamp = try #require(try await OfflinePackager.readSyncStamp(ownerKey: key, unit: oldUnit))

        // 模拟 manifest 慢网返回前：删除并同档重下（含新默认外挂字幕）
        let aiSub = makeManifestSub(ref: "external:ai.chi.srt", language: "chi", isDefault: true, isAi: true, url: "/sub/ai")
        let freshDefaultSub = OfflinePlaybackSpec.Subtitle(
            ref: "external:0-chi.srt", fileName: "0-chi.srt", kind: "vtt",
            language: "chi", title: "AI", isDefault: true, isForced: false, isAi: true,
            sourceRef: aiSub.trackRef
        )
        try await OfflineDisk.perform {
            OfflineDisk.remove(unitDir)
            try OfflineDisk.write(oldUnit, to: OfflineDisk.unitFile(key, 1, 1))
            try OfflineDisk.write(
                OfflinePlaybackSpec(
                    durationMs: 1_800_000, chapters: [], segments: [], audioTracks: [],
                    defaultAudio: "embedded:0", subtitles: [freshDefaultSub], fonts: [],
                    resolution: "1080p", videoCodec: "h264", container: "mkv"
                ),
                to: OfflineDisk.playbackFile(key, 1, 1)
            )
        }

        let changed = try await OfflinePackager.syncSubtitles(
            ownerKey: key,
            unit: oldUnit,
            manifestFileId: 1,
            manifestDefaultAudio: "embedded:0",
            manifestSubtitles: [aiSub],
            fontsUrl: nil,
            expectedStamp: expectedStamp
        ) { _, _ in
            Issue.record("expectedStamp 已失效时不应再拉取字幕")
            return Data()
        }

        #expect(changed == false)
        let afterSpec = try #require(OfflineDisk.read(OfflinePlaybackSpec.self, from: OfflineDisk.playbackFile(key, 1, 1)))
        #expect(afterSpec.subtitles == [freshDefaultSub])
    }
}
