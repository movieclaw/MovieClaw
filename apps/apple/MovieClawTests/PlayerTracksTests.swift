import Foundation
import Testing
@testable import MovieClaw

/// 播放器轨道菜单的纯逻辑：自研引擎读到的轨怎样补进服务端给的清单（disc-direct-play.md §2.6）。
struct PlayerTracksTests {
    private typealias Track = NativeEngine.EmbeddedTrack

    private func option(_ ref: String, kind: String = "vtt", path: String = "/api/v1/sub") -> SubtitleOption {
        SubtitleOption(ref: ref, label: ref, kind: kind, path: path, language: nil, isDefault: false, isAI: false)
    }

    @Test func fillsEmbeddedTracksTheServerDidNotList() {
        // 服务端只认得 PGS，不提供 DVB：引擎读到的第 1 条（DVB）补进来，排在外挂轨前面
        var tracks = SubtitleTracks(options: [option("embedded:0", kind: "pgs"), option("external:a.srt")])
        let changed = tracks.adoptEngineSubtitles([
            Track(language: "eng", codec: "pgssub", channels: 0, isDefault: false),
            Track(language: "chi", codec: "dvbsub", channels: 0, isDefault: true),
        ])
        #expect(changed)
        #expect(tracks.options.map(\.ref) == ["embedded:0", "embedded:1", "external:a.srt"])
        let added = tracks.options[1]
        #expect(added.kind == "pgs" && added.label == "中文 · 图形" && added.path.isEmpty && added.isDefault)
        // 再来一次什么都不变
        let again = tracks.adoptEngineSubtitles([
            Track(language: "eng", codec: "pgssub", channels: 0, isDefault: false),
            Track(language: "chi", codec: "dvbsub", channels: 0, isDefault: true),
        ])
        #expect(!again)
    }

    @Test func discImageReplacesTheServerGuess() {
        // 光盘镜像：服务端的清单是猜的，整份换成引擎读到的主片轨（外挂轨保留）
        var tracks = SubtitleTracks(options: [option("embedded:0"), option("embedded:1"), option("external:a.srt")])
        let changed = tracks.adoptEngineSubtitles(
            [Track(language: "zho", codec: "dvdsub", channels: 0, isDefault: false)], replacingEmbedded: true)
        #expect(changed)
        #expect(tracks.options.map(\.ref) == ["embedded:0", "external:a.srt"])
        #expect(tracks.options[0].kind == "pgs" && tracks.options[0].path.isEmpty)
    }

    @Test func undecodableSubtitleIsGreyedOutWithAReason() {
        var tracks = SubtitleTracks()
        let changed = tracks.adoptEngineSubtitles([Track(language: nil, codec: "arib_caption", channels: 0, isDefault: false)])
        #expect(changed)
        #expect(tracks.options.isEmpty)
        #expect(tracks.unavailable.map(\.ref) == ["embedded:0"])
        #expect(tracks.unavailable[0].reason.contains("ARIB"))
    }

    @Test func textAndAssKindsFollowTheDecoderName() {
        var tracks = SubtitleTracks()
        _ = tracks.adoptEngineSubtitles([
            Track(language: "eng", codec: "subrip", channels: 0, isDefault: false),
            Track(language: nil, codec: "ass", channels: 0, isDefault: false),
        ])
        #expect(tracks.options.map(\.kind) == ["vtt", "ass"])
        #expect(tracks.options[1].label == "内封轨 2 · 特效")
    }

    @Test func engineAudioOptionsNeedTwoTracks() {
        #expect(AudioOption.engineOptions([Track(language: "eng", codec: "dca", channels: 6, isDefault: false)]).isEmpty)
        let options = AudioOption.engineOptions([
            Track(language: "eng", codec: "dca", channels: 6, isDefault: false),
            Track(language: "chi", codec: "ac3", channels: 2, isDefault: true),
        ])
        #expect(options.map(\.ref) == ["embedded:0", "embedded:1"])
        #expect(options.map(\.label) == ["英语 · DCA · 5.1", "中文 · AC3 · 立体声"])
        #expect(options[1].isDefault)
    }

    @Test func defaultAudioSkipsUnplayableTracks() {
        // 不经用户选择时会放的轨，同服务端 _preferred_audio：标了默认的菁彩声放不了，退到第一条放得了的
        let vivid = AudioOption.plan([
            API.AudioTrackView(ref: "embedded:0", codec: nil, channels: 10, language: "chi", isDefault: true),
            API.AudioTrackView(ref: "embedded:1", codec: "eac3", channels: 6, language: "chi", isDefault: false),
        ])
        #expect(AudioOption.defaultRef(in: vivid) == "embedded:1")
        // 容器没标默认轨（蓝光 m2ts 就不标）：第一条
        let unflagged = AudioOption.plan([
            API.AudioTrackView(ref: "embedded:0", codec: "truehd", channels: 8, language: "eng", isDefault: false),
            API.AudioTrackView(ref: "embedded:1", codec: "ac3", channels: 6, language: "chi", isDefault: false),
        ])
        #expect(AudioOption.defaultRef(in: unflagged) == "embedded:0")
    }

    @Test func unrecognizedAudioCodecIsGreyedOut() {
        // 《交锋》：第 0 条是菁彩声（av3a，服务端探测编码为空），其余能放——它置灰写明原因，其余照常
        let options = AudioOption.plan([
            API.AudioTrackView(ref: "embedded:0", codec: nil, channels: 10, language: "chi", isDefault: false),
            API.AudioTrackView(ref: "embedded:1", codec: "eac3", channels: 6, language: "chi", isDefault: false),
            API.AudioTrackView(ref: "embedded:2", codec: "aac", channels: 2, language: "chi", isDefault: true),
        ])
        #expect(options.map { $0.unavailableReason != nil } == [true, false, false])
        #expect(options[0].label == "中文 · 10 声道")
        // 整片都认不出（没探测过）：不下「放不了」的结论
        let unprobed = AudioOption.plan([
            API.AudioTrackView(ref: "embedded:0", codec: nil, channels: nil, language: nil, isDefault: true),
            API.AudioTrackView(ref: "embedded:1", codec: nil, channels: nil, language: nil, isDefault: false),
        ])
        #expect(unprobed.allSatisfy { $0.unavailableReason == nil })
        // 引擎读到的轨同一口径（编码报 none）
        let engine = AudioOption.engineOptions([
            NativeEngine.EmbeddedTrack(language: "chi", codec: "none", channels: 10, isDefault: false),
            NativeEngine.EmbeddedTrack(language: "chi", codec: "aac", channels: 2, isDefault: true),
        ])
        #expect(engine.map { $0.unavailableReason != nil } == [true, false])
    }

    @Test func subtitleTitlesDoNotReplaceTrackIdentity() throws {
        let title = "国配简体特效 · 蓝光修订版 · " + String(repeating: "保留屏幕文字🎬", count: 60)
        let plans = [
            API.SubtitlePlanView(trackRef: "embedded:3", kind: "pgs", language: "chi", isDefault: false, isAi: false, title: "  \(title)  ", isForced: true),
            API.SubtitlePlanView(trackRef: "embedded:4", kind: "pgs", language: "chi", isDefault: true, isAi: false, title: title),
        ]
        let tracks = SubtitleTracks.plan(plans, urls: ["/a", "/b"])
        #expect(tracks.options.map(\.displayTitle) == [title, title])
        #expect(tracks.options[0].detail == "中文 · PGS 图形 · 内封轨 4 · 强制")
        #expect(tracks.options[1].detail == "中文 · PGS 图形 · 内封轨 5 · 默认")
        #expect(tracks.options.map(\.id) == ["embedded:3", "embedded:4"])
        #expect(tracks.options.map(\.path) == ["/a", "/b"])
    }

    @Test func oldServerAndBlankTitlesKeepDistinctFallbacks() throws {
        let json = #"[{"track_ref":"embedded:0","kind":"vtt","language":"und","is_default":false,"is_ai":false}]"#
        let plans = try JSONDecoder().decode([API.SubtitlePlanView].self, from: Data(json.utf8))
        let old = SubtitleTracks.plan(plans, urls: ["/a"]).options[0]
        #expect(old.displayTitle == "内封轨 1")
        #expect(old.detail == "未知语言 · WebVTT · 内封")
        #expect(!old.isForced)
        for title in [nil, "", " \n\t　"] as [String?] {
            var embedded = option("embedded:6")
            embedded.title = title
            #expect(embedded.displayTitle == "内封轨 7")
            var external = option("external:film.chs.ass")
            external.title = title
            #expect(external.displayTitle == "film.chs.ass")
            #expect(external.detail.contains("外挂"))
        }
    }

    @Test func engineOnlyFillsMissingTitlesWithoutReplacingServerChoices() {
        var server = option("embedded:0")
        server.title = "服务端标题"
        var tracks = SubtitleTracks(options: [server, option("embedded:1"), option("external:a.srt")])
        let engine = [
            Track(language: "chi", codec: "pgssub", channels: 0, isDefault: true, title: "引擎标题"),
            Track(language: "chi", codec: "pgssub", channels: 0, isDefault: true, title: "简英 · 修订版", isForced: true),
        ]
        let changed = tracks.adoptEngineSubtitles(engine)
        #expect(changed)
        #expect(tracks.options[0].displayTitle == "服务端标题")
        #expect(tracks.options[1].displayTitle == "简英 · 修订版")
        #expect(tracks.options[1].path == "/api/v1/sub")
        #expect(!tracks.options[1].isDefault)
        #expect(tracks.options[1].isForced)
        let again = tracks.adoptEngineSubtitles(engine)
        #expect(!again)
        var disc = SubtitleTracks(options: [server])
        let replaced = disc.adoptEngineSubtitles(engine, replacingEmbedded: true)
        #expect(replaced)
        #expect(disc.options[1].isForced)
        #expect(disc.options[1].detail.contains("内封轨 2"))
    }


    @Test func manyIdenticalSubtitleNamesDoNotCollapseTracks() {
        let plans = (0 ..< 200).map { index in
            API.SubtitlePlanView(trackRef: "embedded:\(index)", kind: "vtt", language: "chi", isDefault: index == 0, isAi: false, title: "简英特效")
        }
        let tracks = SubtitleTracks.plan(plans, urls: plans.enumerated().map { "/sub?track=\($0.offset)" })
        #expect(tracks.options.count == 200)
        #expect(Set(tracks.options.map(\.id)).count == 200)
        #expect(tracks.options.last?.detail == "中文 · WebVTT · 内封轨 200")
        #expect(tracks.initialSelection(remembered: "embedded:199") == "embedded:199")
    }

}
