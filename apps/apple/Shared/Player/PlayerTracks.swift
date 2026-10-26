import Foundation

/// 语言代码 → 中文名（对应 Web `lib/language-labels.ts`，同一条轨在详情页与播放器里叫同一个名字）。
enum LanguageLabel {
    private static let labels: [String: String] = [
        "chs": String(localized: .mediaLanguagesSimplifiedChinese), "cht": String(localized: .mediaLanguagesTraditionalChinese), "chi": String(localized: .mediaLanguagesChinese), "zho": String(localized: .mediaLanguagesChinese), "cmn": String(localized: .mediaLanguagesChinese),
        "yue": String(localized: .mediaLanguagesCantonese), "eng": String(localized: .mediaLanguagesEnglish), "jpn": String(localized: .mediaLanguagesJapanese), "kor": String(localized: .mediaLanguagesKorean), "fre": String(localized: .mediaLanguagesFrench), "fra": String(localized: .mediaLanguagesFrench),
        "ger": String(localized: .mediaLanguagesGerman), "deu": String(localized: .mediaLanguagesGerman), "spa": String(localized: .mediaLanguagesSpanish), "rus": String(localized: .mediaLanguagesRussian), "ita": String(localized: .mediaLanguagesItalian),
        "por": String(localized: .mediaLanguagesPortuguese), "tha": String(localized: .mediaLanguagesThai), "hin": String(localized: .mediaLanguagesHindi),
    ]

    /// 未知语言（und）与空值返回 nil，由调用方决定占位文案
    static func of(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return labels[code.lowercased()] ?? code
    }
}

/// 字幕菜单里的一条可选轨（对应 Web `SubtitleOption`）。
struct SubtitleOption: Identifiable, Hashable {
    /// 中性轨引用（embedded:N / external:文件名），同时用作轨记忆的值
    let ref: String
    var label: String
    /// vtt（文本）/ ass（特效）/ pgs（图形）
    let kind: String
    /// 服务端地址（已带签名 token，原格式）
    let path: String
    let language: String?
    let isDefault: Bool
    let isAI: Bool
    var title: String? = nil
    var isForced: Bool = false

    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        if let embeddedIndex { return String(localized: .playerSubtitlesEmbeddedTrack(embeddedIndex + 1)) }
        if ref.hasPrefix("external:") { return String(ref.dropFirst("external:".count)) }
        return label
    }

    var detail: String {
        let formats = ["vtt": "WebVTT", "ass": "ASS", "pgs": String(localized: .playerSubtitlesPgs), "text": String(localized: .playerSubtitlesText)]
        var parts = [LanguageLabel.of(language) ?? String(localized: .playerSubtitlesUnknownLanguage), formats[kind] ?? kind]
        if let embeddedIndex {
            parts.append(displayTitle == String(localized: .playerSubtitlesEmbeddedTrack(embeddedIndex + 1)) ? String(localized: .playerSubtitlesEmbedded) : String(localized: .playerSubtitlesEmbeddedTrack(embeddedIndex + 1)))
        } else if ref.hasPrefix("external:") { parts.append(String(localized: .playerSubtitlesExternal)) }
        if isAI { parts.append(String(localized: .playerSubtitlesAiTranslated)) }
        if isDefault { parts.append(String(localized: .playerSubtitlesDefault)) }
        if isForced { parts.append(String(localized: .playerSubtitlesForced)) }
        return parts.joined(separator: " · ")
    }

    var id: String { ref }

    /// 内封轨的数组下标（embedded:N → N）；外挂轨为 nil
    var embeddedIndex: Int? { ref.hasPrefix("embedded:") ? Int(ref.dropFirst("embedded:".count)) : nil }
}

/// 拿不到的轨（连同中文原因），菜单里置灰展示而不是给一个点了没反应的选项。
struct UnavailableSubtitle: Identifiable, Hashable {
    let ref: String
    let label: String
    let reason: String
    var id: String { ref }
}

struct SubtitleTracks: Equatable {
    var options: [SubtitleOption] = []
    var unavailable: [UnavailableSubtitle] = []

    /// 把决策里的字幕计划配上取流地址（与 subtitle_urls 严格一一对应，少一个就当那条没有地址）
    static func plan(_ plans: [API.SubtitlePlanView], urls: [String]) -> SubtitleTracks {
        var result = SubtitleTracks()
        for (index, plan) in plans.enumerated() {
            let label = trackLabel(plan)
            guard index < urls.count else {
                result.unavailable.append(.init(ref: plan.trackRef, label: label, reason: String(localized: .playerSubtitlesNoUrl)))
                continue
            }
            guard ["vtt", "ass", "pgs"].contains(plan.kind) else {
                result.unavailable.append(.init(ref: plan.trackRef, label: label, reason: String(localized: .playerSubtitlesUnsupported(plan.kind))))
                continue
            }
            result.options.append(SubtitleOption(
                ref: plan.trackRef, label: label, kind: plan.kind, path: urls[index],
                language: plan.language, isDefault: plan.isDefault, isAI: plan.isAi,
                title: plan.title, isForced: plan.isForced == true
            ))
        }
        return result
    }

    private static let kindLabels = ["vtt": String(localized: .playerSubtitlesText), "ass": String(localized: .playerSubtitlesStyled), "pgs": String(localized: .playerSubtitlesImage)]

    private static func trackLabel(_ plan: API.SubtitlePlanView) -> String {
        let title = plan.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? LanguageLabel.of(plan.language) ?? refLabel(plan.trackRef)
        return "\(name) · \(kindLabels[plan.kind] ?? plan.kind)"
    }

    /// 没有语言标记时的兜底名：外挂轨用文件名，内封轨用序号
    private static func refLabel(_ ref: String) -> String {
        if ref.hasPrefix("external:") { return String(ref.dropFirst("external:".count)) }
        if ref.hasPrefix("embedded:"), let index = Int(ref.dropFirst("embedded:".count)) { return String(localized: .playerSubtitlesEmbeddedTrack(index + 1)) }
        return String(localized: .playerSubtitlesUnknownLanguage)
    }

    /// 把自研引擎读到、清单里还没有的内封字幕轨补进来（光盘镜像的全部轨，DVB / ARIB / VobSub 这类服务端不提供的轨）。
    /// 引擎自己读容器、自己画内封字幕，所以这些轨不需要服务端地址。内封轨按编号排在前、外挂轨在后（同服务端口径）。
    /// replacingEmbedded：服务端的内封轨清单不可信（光盘镜像），整份换成引擎读到的。返回清单是否变了
    mutating func adoptEngineSubtitles(_ tracks: [NativeEngine.EmbeddedTrack], replacingEmbedded: Bool = false) -> Bool {
        var added = false
        if replacingEmbedded {
            let before = options.count + unavailable.count
            options.removeAll { $0.embeddedIndex != nil && $0.path.isEmpty == false }
            unavailable.removeAll { $0.ref.hasPrefix("embedded:") }
            added = options.count + unavailable.count != before
        }
        for (index, track) in tracks.enumerated() {
            let ref = "embedded:\(index)"
            if let existing = options.firstIndex(where: { $0.ref == ref }) {
                if options[existing].title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                   let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    options[existing].title = title
                    options[existing].label = "\(title) · \(Self.kindLabels[options[existing].kind] ?? options[existing].kind)"
                    added = true
                }
                if track.isForced && !options[existing].isForced {
                    options[existing].isForced = true
                    added = true
                }
                continue
            }
            // 引擎从画面里读出的隐藏字幕（CEA-608，美剧常见）没有语言标记，直接叫它的名字
            let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? (track.codec == "eia_608" ? String(localized: .playerSubtitlesClosedCaptions) : (LanguageLabel.of(track.language) ?? String(localized: .playerSubtitlesEmbeddedTrack(index + 1))))
            if let reason = Self.undecodableReasons[track.codec] {
                // 引擎里没有这种字幕的解码器（编码名退回成描述名）：置灰给原因，而不是给一个选了不出字的选项
                if !unavailable.contains(where: { $0.ref == ref }) {
                    unavailable.append(.init(ref: ref, label: name, reason: reason))
                    added = true
                }
                continue
            }
            unavailable.removeAll { $0.ref == ref }
            let kind = Self.engineKind(track.codec)
            options.append(SubtitleOption(
                ref: ref, label: "\(name) · \(Self.kindLabels[kind] ?? kind)", kind: kind, path: "",
                language: track.language, isDefault: track.isDefault, isAI: false,
                title: track.codec == "eia_608" ? name : title, isForced: track.isForced
            ))
            added = true
        }
        guard added else { return false }
        let embedded = options.filter { $0.embeddedIndex != nil }.sorted { ($0.embeddedIndex ?? 0) < ($1.embeddedIndex ?? 0) }
        options = embedded + options.filter { $0.embeddedIndex == nil }
        return true
    }

    /// 引擎解不了的字幕（FFmpeg 没编进这些解码器，引擎报的是编码描述名）
    private static let undecodableReasons = [
        "arib_caption": String(localized: .playerSubtitlesAribUnavailable),
        "dvb_teletext": String(localized: .playerSubtitlesTeletextUnavailable),
    ]

    /// 引擎报的编码名归到菜单的三类：图形（位图字幕）、特效（ASS）、其余都算文本。
    /// 引擎报的是解码器名（pgssub / dvdsub / dvbsub），没有解码器时才是编码描述名（hdmv_pgs_subtitle……），两种都认
    private static func engineKind(_ codec: String) -> String {
        switch codec {
        case "pgssub", "dvdsub", "dvbsub", "xsub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "dvb_teletext": "pgs"
        case "ass", "ssa": "ass"
        default: "vtt"
        }
    }

    /// 选哪条轨：优先上次记住的（"off" = 用户明确关掉，必须尊重），其次服务端裁决的默认轨；都没有就不自动开。
    func initialSelection(remembered: String?) -> String? {
        if remembered == "off" { return nil }
        if let remembered, options.contains(where: { $0.ref == remembered }) { return remembered }
        return options.first { $0.isDefault }?.ref
    }
}

/// 音轨菜单项（对应 Web `lib/player/audio-tracks.ts`）。只有一条轨时返回空——没得选的菜单是纯噪音。
struct AudioOption: Identifiable, Hashable {
    let ref: String
    let label: String
    let isDefault: Bool
    /// 放不了的原因：菜单里置灰并写明，不给选（同字幕的「不可用」）
    var unavailableReason: String?
    var id: String { ref }

    var embeddedIndex: Int? { ref.hasPrefix("embedded:") ? Int(ref.dropFirst("embedded:".count)) : nil }

    /// 不经用户选择时会放的轨（同服务端 `_preferred_audio`）：放得了的轨里标了默认的，没有就第一条
    static func defaultRef(in options: [AudioOption]) -> String? {
        let playable = options.filter { $0.unavailableReason == nil }
        let pool = playable.isEmpty ? options : playable
        return (pool.first(where: \.isDefault) ?? pool.first)?.ref
    }

    static func plan(_ tracks: [API.AudioTrackView]) -> [AudioOption] {
        guard tracks.count >= 2 else { return [] }
        let anyRecognized = tracks.contains { !unrecognized($0.codec) }
        return tracks.map {
            AudioOption(ref: $0.ref, label: label($0), isDefault: $0.isDefault,
                        unavailableReason: anyRecognized && unrecognized($0.codec) ? unrecognizedReason : nil)
        }
    }

    /// 服务端一条音轨都没给（光盘镜像：盘内结构它读不了）时，整份用自研引擎读到的内封音轨
    static func engineOptions(_ tracks: [NativeEngine.EmbeddedTrack]) -> [AudioOption] {
        guard tracks.count >= 2 else { return [] }
        let anyRecognized = tracks.contains { !unrecognized($0.codec) }
        return tracks.enumerated().map { index, track in
            let ref = "embedded:\(index)"
            return AudioOption(ref: ref, label: label(ref: ref, language: track.language, codec: track.codec,
                                                      channels: track.channels), isDefault: track.isDefault,
                               unavailableReason: anyRecognized && unrecognized(track.codec) ? unrecognizedReason : nil)
        }
    }

    /// 探测认不出编码的轨（服务端记为空、引擎报 none）：自研引擎、服务端转码用的 FFmpeg 都没有它的解码器。
    /// 真机见于国产 4K 剧的菁彩声（Audio Vivid，样本入口 av3a，5.1.4）。整片都认不出时（没探测过）不下这个结论
    private static func unrecognized(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return true }
        return codec == "none" || codec == "unknown"
    }

    static let unrecognizedReason = String(localized: .playerTracksUnrecognized)

    private static let channelLabels = [1: String(localized: .playerTracksMono), 2: String(localized: .playerTracksStereo), 6: "5.1", 8: "7.1"]

    static func label(_ track: API.AudioTrackView) -> String {
        label(ref: track.ref, language: track.language, codec: track.codec, channels: track.channels)
    }

    /// 语言 · 编码 · 声道（语言放最前：用户找的是「国语还是日语」）
    private static func label(ref: String, language: String?, codec: String?, channels: Int?) -> String {
        let name = LanguageLabel.of(language)
            ?? (ref.hasPrefix("embedded:") ? String(localized: .playerTracksAudioIndex(String(ref.dropFirst("embedded:".count)))) : String(localized: .playerTracksUnknownAudio))
        var rest: [String] = []
        if let codec, !codec.isEmpty { rest.append(codec.uppercased()) }
        if let channels, channels > 0 { rest.append(channelLabels[channels] ?? String(localized: .playerTracksChannels(channels))) }
        return rest.isEmpty ? name : ([name] + rest).joined(separator: " · ")
    }
}
