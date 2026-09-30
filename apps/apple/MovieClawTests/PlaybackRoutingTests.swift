import Foundation
import Testing
@testable import MovieClaw

/// 兜底阶梯的规则表（`FailurePolicy`，docs/design/player-engine.md §3）：每行一种失败情形 → 下一步。
struct PlaybackRoutingTests {
    private typealias Input = FailurePolicy.Input

    private func input(_ engine: EngineKind, _ cause: EngineFailureCause, original: Bool = true, restart: Bool = true,
                       retry: Bool = true) -> Input {
        Input(engine: engine, cause: cause, playsOriginalFile: original, restartAllowed: restart, nativeRetryAllowed: retry)
    }

    @Test(arguments: [
        // 2026-09-28《哪吒》：外网 54 Mbit/s 放 76 Mbit/s 的原片。线路慢根本不报失败（StallWatch 测试覆盖）；
        // 真断线时也只原地重开（原文件直出先等片源取得到），不换引擎
        (engine: EngineKind.native, cause: EngineFailureCause.network, original: true, restart: true, expected: FailurePolicy.Response.reconnect),
        // 原文件直出一直取不到片源：落错误页让用户重试，不换引擎、不自动转码
        (engine: .native, cause: .network, original: true, restart: false, expected: .failNetwork),
        // 服务端流连续重开都没出画：按这一档放不了降档
        (engine: .avPlayer, cause: .network, original: false, restart: false, expected: .stepDownTier),
        (engine: .avPlayer, cause: .network, original: false, restart: true, expected: .reconnect),
    ])
    func networkNeverSwitchesEngines(engine: EngineKind, cause: EngineFailureCause, original: Bool, restart: Bool,
                                     expected: FailurePolicy.Response) {
        #expect(FailurePolicy.decide(input(engine, cause, original: original, restart: restart)) == expected)
    }

    @Test func decodeFailuresWalkTheLadder() {
        // 一时的问题（引擎楞住、中途出错）：先原位重开一次，额度用完才改走服务端流
        #expect(FailurePolicy.decide(input(.native, .decode)) == .retryNative)
        #expect(FailurePolicy.decide(input(.native, .decode, retry: false)) == .fallbackToServerStream)
        // 确定解不了（硬解拒绝且本机软解也接不住）：重开也一样，直接改走服务端流
        #expect(FailurePolicy.decide(input(.native, .decodeFinal)) == .fallbackToServerStream)
        // 已经在放服务端流还解不了：降一档再试
        #expect(FailurePolicy.decide(input(.native, .decode, original: false)) == .stepDownTier)
        #expect(FailurePolicy.decide(input(.avPlayer, .decode, original: false)) == .stepDownTier)
        #expect(FailurePolicy.decide(input(.avPlayer, .decodeFinal, original: false)) == .stepDownTier)
        // 系统播放器直通原文件（服务端给的 MP4 档 0）解不了：同样降档，没有别的本机播放器可换
        #expect(FailurePolicy.decide(input(.avPlayer, .decode)) == .stepDownTier)
    }

    @Test func notDecodeFailuresNeverSwitchPlayers() {
        // 片源不在了（404）：换什么播放器都一样，直接说明
        #expect(FailurePolicy.decide(input(.native, .sourceMissing)) == .failSourceMissing)
        #expect(FailurePolicy.decide(input(.avPlayer, .sourceMissing, original: false)) == .failSourceMissing)
        // 手机存储写满：收小缓冲原位重开；重开后又写满才改走服务端流（系统播放器边收边放、不落盘）
        #expect(FailurePolicy.decide(input(.native, .storageFull)) == .retryNativeLowStorage)
        #expect(FailurePolicy.decide(input(.native, .storageFull, retry: false)) == .fallbackToServerStream)
    }

    @Test func nativeRetryBudgetAllowsOneRetryPerWindow() {
        var budget = NativeRetryBudget()
        let start = Date(timeIntervalSince1970: 1_000_000)
        // 依次在 0、60、179、181 秒各出一次问题，最后手动重试后又出一次
        let answers = [0.0, 60, 179, 181].map { budget.allowRetry(now: start.addingTimeInterval($0)) }
        budget.reset()
        let afterReset = budget.allowRetry(now: start.addingTimeInterval(182))
        // 第一次重开；3 分钟内又出问题说明不是一时的，不再重开；隔了 3 分钟以上又是新的一时问题
        #expect(answers == [true, false, false, true])
        #expect(afterReset)
    }

    // MARK: 落盘计划（NativeStoragePlan）

    private let gib = Int64(1) << 30
    private let mib = Int64(1) << 20

    @Test func storagePlanKeepsDefaultsWhenSpaceIsAmple() {
        // 64 GB 空余放 UHD 原盘：默认窗口 + 片源字节缓存 + 线路慢时放大前向缓冲
        #expect(NativeStoragePlan.make(freeBytes: 64 * gib, bitrateBps: 80_000_000) == .normal)
        // 不知道剩余空间：照常
        #expect(NativeStoragePlan.make(freeBytes: nil, bitrateBps: 80_000_000) == .normal)
    }

    @Test func storagePlanShrinksWindowsInsteadOfSwitchingPlayers() {
        // UHD（80 Mbit/s，一段按 80 MB 估）只剩 3 GB：窗口按剩余空间收小，不开片源缓存、不放大前向缓冲
        let tight = NativeStoragePlan.make(freeBytes: 3 * gib, bitrateBps: 80_000_000)
        #expect(tight.forwardSegments == 7)
        #expect(tight.backwardSegments == 10)
        #expect(!tight.sourceCache)
        #expect(!tight.canGrowForward)
        // 1080p（8 Mbit/s）只剩 300 MB（原来低于 512 MB 就改走服务端流）：照样用自研引擎，窗口收到最小
        let low = NativeStoragePlan.make(freeBytes: 300 * mib, bitrateBps: 8_000_000)
        #expect(low.forwardSegments == 2)
        #expect(low.backwardSegments == 2)
        // 1080p 有 2 GB：默认窗口只占一小半，照常
        #expect(NativeStoragePlan.make(freeBytes: 2 * gib, bitrateBps: 8_000_000) == .normal)
        // 台账码率离谱（光盘镜像片长记成 4 秒，算出 6.5 Gbit/s）：按不知道码率算，空间够就照常
        #expect(NativeStoragePlan.make(freeBytes: 12 * gib, bitrateBps: 6_480_594_006) == .normal)
        // 存储写满后重开：强制最小
        #expect(NativeStoragePlan.make(freeBytes: 64 * gib, bitrateBps: 8_000_000, forceMinimal: true) == .minimal)
    }

    // MARK: 片源探测（SourceProbe）

    @Test func sourceProbeVerdicts() {
        #expect(SourceProbe.verdict(status: 206) == .reachable)
        #expect(SourceProbe.verdict(status: 200) == .reachable)
        // 令牌过期：开新会话换张令牌就取得到，按取得到算（重开）
        #expect(SourceProbe.verdict(status: 401) == .reachable)
        #expect(SourceProbe.verdict(status: 403) == .reachable)
        #expect(SourceProbe.verdict(status: 404) == .missing)
        #expect(SourceProbe.verdict(status: 503) == .unreachable("HTTP 503"))
        #expect(SourceProbe.verdict(status: 429) == .unreachable("HTTP 429"))
    }

    // MARK: 换低画质的提示（QualitySuggestion）

    private let mbps = 1_000_000.0

    /// 按秒喂：先正常播 grace 秒，再卡 stallSeconds 秒、恢复 playSeconds 秒，重复 times 次
    private func feed(_ suggestion: inout QualitySuggestion, stallSeconds: Int, playSeconds: Int, times: Int, speed: Double) {
        for _ in 0 ..< QualitySuggestion.graceSeconds { suggestion.tick(stalled: false, loadingBps: nil) }
        for _ in 0 ..< times {
            for _ in 0 ..< stallSeconds { suggestion.tick(stalled: true, loadingBps: speed) }
            for _ in 0 ..< playSeconds { suggestion.tick(stalled: false, loadingBps: 0) }
        }
    }

    @Test func oneShortStallNeverSuggests() {
        // 开播后卡一次、没卡满 8 秒不提示：也许暂停攒一会缓冲就能接着看
        var suggestion = QualitySuggestion()
        feed(&suggestion, stallSeconds: 7, playSeconds: 60, times: 1, speed: 5 * mbps)
        #expect(suggestion.offer(streamBitrate: 76 * mbps, currentHeight: 2160) == nil)
    }

    @Test func repeatedStallsOnASlowLinkSuggestOnce() {
        // 《哪吒》：76 Mbit/s 的原片、实测 54 Mbit/s，5 分钟里卡了 2 次（每次都不到 8 秒）→ 提示一次，推荐 1080p
        var suggestion = QualitySuggestion()
        feed(&suggestion, stallSeconds: 5, playSeconds: 60, times: 2, speed: 54 * mbps)
        let offer = suggestion.offer(streamBitrate: 76 * mbps, currentHeight: 2160)
        #expect(offer == .init(measuredBps: 54 * mbps, requiredBps: 76 * mbps, maxHeight: 1080))
        // 本单元不再提第二次
        feed(&suggestion, stallSeconds: 8, playSeconds: 60, times: 3, speed: 54 * mbps)
        #expect(suggestion.offer(streamBitrate: 76 * mbps, currentHeight: 2160) == nil)
    }

    @Test func longStartupWaitSuggestsAtEightSeconds() {
        // 09-30 外网实测《爱情怎么翻译？》：20.7 Mbit/s 的 4K 原片、等首帧的速度约 6 Mbit/s，首帧等了 18.5 秒——
        // 起播本身有 10 秒宽限，但一次等满 8 秒就该提示，不必等它开播后再卡
        var suggestion = QualitySuggestion()
        suggestion.restartGrace()
        for _ in 0 ..< 7 { suggestion.tick(stalled: true, loadingBps: 6 * mbps) }
        #expect(suggestion.offer(streamBitrate: 20.7 * mbps, currentHeight: 2160) == nil)
        suggestion.tick(stalled: true, loadingBps: 6 * mbps)
        #expect(suggestion.offer(streamBitrate: 20.7 * mbps, currentHeight: 2160)?.maxHeight == 720)
    }

    @Test func longWaitJudgesTheLinkByItsFastestSecond() {
        // 冷起播时读数时有时无（开容器时没有、之后 0～2 Mbit/s）：按最快那秒估线路、推荐档位
        var slow = QualitySuggestion()
        slow.restartGrace()
        for speed in [nil, nil, nil, nil, 2.0, 1.0, 0, 0.5] { slow.tick(stalled: true, loadingBps: speed.map { $0 * mbps }) }
        #expect(slow.offer(streamBitrate: 19 * mbps, currentHeight: 2160) == .init(measuredBps: 2 * mbps, requiredBps: 19 * mbps, maxHeight: 480))
        // 最快那秒已经够码率（等的是别的：服务端慢、引擎在做别的）：不是线路问题，不提示
        var fast = QualitySuggestion()
        fast.restartGrace()
        for speed in [0.5, 1, 25, 0, 0, 1, 0.2, 0.1] { fast.tick(stalled: true, loadingBps: speed * mbps) }
        #expect(fast.offer(streamBitrate: 19 * mbps, currentHeight: 2160) == nil)
    }

    @Test func longSeekWaitSuggestsButShortSeeksAreNotStalls() {
        // 《我不是大师》：14.4 Mbit/s 原片，拖动后等了 16.6 秒才落地 → 第 8 秒提示
        var suggestion = QualitySuggestion()
        feed(&suggestion, stallSeconds: 0, playSeconds: 30, times: 1, speed: 0)
        suggestion.restartGrace()
        for _ in 0 ..< 8 { suggestion.tick(stalled: true, seeking: true, loadingBps: 4 * mbps) }
        #expect(suggestion.offer(streamBitrate: 14.4 * mbps, currentHeight: 2160)?.maxHeight == 720)
        // 跳转的等待不算「卡」：几次都没等满 8 秒的跳转（哪怕跳完已过了宽限期）不会凑成「反复卡」
        var seeks = QualitySuggestion()
        feed(&seeks, stallSeconds: 0, playSeconds: 30, times: 1, speed: 0)
        for _ in 0 ..< 4 {
            seeks.restartGrace()
            for _ in 0 ..< 11 { seeks.tick(stalled: false, loadingBps: nil) }
            for _ in 0 ..< 7 { seeks.tick(stalled: true, seeking: true, loadingBps: 4 * mbps) }
            for _ in 0 ..< 30 { seeks.tick(stalled: false, loadingBps: nil) }
        }
        #expect(seeks.offer(streamBitrate: 14.4 * mbps, currentHeight: 2160) == nil)
        // 拖动中连续换落点：等待从最后一次跳转重新算，每段都不满 8 秒就不提示
        var scrub = QualitySuggestion()
        for _ in 0 ..< 5 {
            scrub.restartGrace()
            for _ in 0 ..< 6 { scrub.tick(stalled: true, seeking: true, loadingBps: 4 * mbps) }
        }
        #expect(scrub.offer(streamBitrate: 14.4 * mbps, currentHeight: 2160) == nil)
    }

    @Test func stallsWithEnoughBandwidthDoNotSuggest() {
        // 实测速度够（不是线路问题）：换码率没用，不提示
        var suggestion = QualitySuggestion()
        feed(&suggestion, stallSeconds: 8, playSeconds: 30, times: 4, speed: 90 * mbps)
        #expect(suggestion.offer(streamBitrate: 76 * mbps, currentHeight: 2160) == nil)
        // 卡的时候一点速度读数都没有（断线、等转码）：没有线路证据，也不提示
        var silent = QualitySuggestion()
        feed(&silent, stallSeconds: 8, playSeconds: 30, times: 4, speed: 0)
        #expect(silent.offer(streamBitrate: 76 * mbps, currentHeight: 2160) == nil)
    }

    @Test func graceAndOldStallsAreIgnored() {
        // 起播 / 跳转后 10 秒内的缓冲不算「卡」：每次都在宽限期内等、又没等满 8 秒，永远不提示
        var suggestion = QualitySuggestion()
        for _ in 0 ..< 6 {
            suggestion.restartGrace()
            for _ in 0 ..< 7 { suggestion.tick(stalled: true, loadingBps: 5 * mbps) }
            for _ in 0 ..< 30 { suggestion.tick(stalled: false, loadingBps: nil) }
        }
        #expect(suggestion.offer(streamBitrate: 76 * mbps, currentHeight: 2160) == nil)
        // 5 分钟之前的卡顿过期：卡一次、隔了 6 分钟再卡一次，窗口里只有 1 次
        var spread = QualitySuggestion()
        feed(&spread, stallSeconds: 5, playSeconds: 30, times: 1, speed: 5 * mbps)
        for _ in 0 ..< 360 { spread.tick(stalled: false, loadingBps: nil) }
        feed(&spread, stallSeconds: 5, playSeconds: 30, times: 1, speed: 5 * mbps)
        #expect(spread.offer(streamBitrate: 76 * mbps, currentHeight: 2160) == nil)
    }

    @Test func recommendedHeightFitsTheLink() {
        #expect(QualitySuggestion.recommendedHeight(for: 54 * mbps, below: 2160) == 1080)
        #expect(QualitySuggestion.recommendedHeight(for: 4 * mbps, below: 2160) == 720)
        #expect(QualitySuggestion.recommendedHeight(for: 1 * mbps, below: 2160) == 480)
        // 已经在 1080p 转码还卡：往下推一档
        #expect(QualitySuggestion.recommendedHeight(for: 54 * mbps, below: 1080) == 720)
        // 已经在最低档：没有可换的
        #expect(QualitySuggestion.recommendedHeight(for: 1 * mbps, below: 480) == nil)
    }

    // MARK: 网络环境（画质按它分开记）

    private func ip(_ text: String) -> UInt32 { PlaybackNetwork.parseIPv4(text)! }

    @Test func networkClassification() {
        let homeWiFi = PlaybackNetwork.Interface(address: ip("192.168.1.23"), netmask: ip("255.255.255.0"))
        let cellular = PlaybackNetwork.Interface(address: ip("10.123.4.5"), netmask: ip("255.255.255.255"))
        let vpnTunnel = PlaybackNetwork.Interface(address: ip("198.18.0.1"), netmask: ip("255.255.0.0"))
        // 家里 Wi-Fi 直连 NAS
        #expect(PlaybackNetwork.classify(serverIPv4: ip("192.168.1.10"), interfaces: [cellular, homeWiFi]) == .home)
        // 服务器是内网地址、手机不在那个网段：走 VPN 回家 / 在别处
        #expect(PlaybackNetwork.classify(serverIPv4: ip("192.168.1.10"), interfaces: [cellular, vpnTunnel]) == .away)
        // 蜂窝网的 /32 地址恰好也是 10 段：掩码全 1 的点对点网卡不算同网段
        #expect(PlaybackNetwork.classify(serverIPv4: ip("10.123.4.9"), interfaces: [cellular]) == .away)
        // 公网地址（或域名解析出公网）：在家回流和在外面连的是同一个地址，分不清
        #expect(PlaybackNetwork.classify(serverIPv4: ip("203.0.113.7"), interfaces: [homeWiFi]) == .unknown)
        // 域名还没查到
        #expect(PlaybackNetwork.classify(serverIPv4: nil, interfaces: [homeWiFi]) == .unknown)
    }

    /// 2026-09-29 回归：服务器填域名时后台查地址，曾因查询函数默认隔离在主线程而 trap，登录演示站点后每次启动必崩。
    /// 没有断言可写——修复前这里整个测试进程直接崩掉；localhost 不走网络，查询很快结束
    @MainActor @Test func domainServerPrewarmDoesNotTrap() async throws {
        PlaybackNetwork.prewarm(server: try ServerAddress(parsing: "http://localhost:3000"))
        try await Task.sleep(for: .milliseconds(500))
    }

    @Test func privateRangesAndParsing() {
        #expect(PlaybackNetwork.isPrivate(ip("10.0.0.1")))
        #expect(PlaybackNetwork.isPrivate(ip("172.16.0.1")))
        #expect(PlaybackNetwork.isPrivate(ip("172.31.255.255")))
        #expect(!PlaybackNetwork.isPrivate(ip("172.32.0.1")))
        #expect(PlaybackNetwork.isPrivate(ip("192.168.0.1")))
        // Tailscale 的 100.64/10 不是 RFC 1918
        #expect(!PlaybackNetwork.isPrivate(ip("100.101.102.103")))
        #expect(PlaybackNetwork.parseIPv4("movie.example.com") == nil)
        #expect(PlaybackNetwork.parseIPv4("192.168.1") == nil)
        #expect(PlaybackNetwork.parseIPv4("192.168.1.256") == nil)
    }

    // MARK: 按片记画质、开播提示

    @Test func qualityIsRememberedPerTitleAndNetwork() {
        let title = Int.random(in: 900_000_000 ..< 999_999_999)
        defer {
            QualityMemory.remember(nil, mediaItemId: title, network: .home)
            QualityMemory.remember(nil, mediaItemId: title, network: .away)
        }
        QualityMemory.remember(720, mediaItemId: title, network: .away)
        #expect(QualityMemory.quality(mediaItemId: title, network: .away) == 720)
        // 在外面限了 720p，回家照样原画
        #expect(QualityMemory.quality(mediaItemId: title, network: .home) == nil)
        // 别的片不受影响
        #expect(QualityMemory.quality(mediaItemId: title + 1, network: .away) == nil)
        // 改回「自动」= 忘掉
        QualityMemory.remember(nil, mediaItemId: title, network: .away)
        #expect(QualityMemory.quality(mediaItemId: title, network: .away) == nil)
    }

    @Test func rememberedChoiceNotice() {
        #expect(RememberedChoices.notice(quality: nil, network: .home, audio: nil, subtitle: nil) == nil)
        #expect(RememberedChoices.notice(quality: 720, network: .away, audio: "日语", subtitle: "关闭")
            == "已沿用上次的选择：画质 720p（外网），音轨 日语，字幕 关闭")
        // 分不清网络环境时不写环境
        #expect(RememberedChoices.notice(quality: 1080, network: .unknown, audio: nil, subtitle: nil)
            == "已沿用上次的选择：画质 1080p")
        // 提示里只留语言；同语言有两条时留全称
        let audio = ["英语 · EAC3 · 5.1", "国语 · AC3 · 5.1", "国语 · AAC · 立体声"]
        #expect(RememberedChoices.shortLabel(audio[0], among: audio) == "英语")
        #expect(RememberedChoices.shortLabel(audio[1], among: audio) == "国语 · AC3 · 5.1")
    }
}
