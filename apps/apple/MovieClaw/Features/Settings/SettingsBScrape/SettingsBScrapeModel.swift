import Foundation

// 「刮削与整理」分区的静态数据与纯函数（对应 Web `scrape-settings-section.tsx` 顶部常量、
// describeScrapeValues、命名模板渲染器与轻校验）。
//
// 为什么全部放在一个无 UI 的文件里：这些规则都是 Web 的逐字镜像（常用语种表、档位集合、
// 模板渲染三步、校验文案），Web 改规则时这里要跟着改——集中在一处比散落在视图里好对照。
// 命名模板的渲染规则本身镜像自后端 `services/library/naming.py`，是「边打字边看结果」的预览，
// 真正落盘与保存校验以后端为准。

/// 排序芯片的候选项：id 是落库值（语言标签 / 地区码 / meta·orig·null 特殊 token）
struct SettingsBScrapeChipOption: Hashable {
    let id: String
    let name: String
    /// 特殊 token 的说明（Web 悬停提示，App 直接写在芯片下方）
    var tip: String?
}

enum SettingsBScrapeCatalog {
    /// 常用语种快捷芯片（元数据语言，值为带地区的语言标签）
    static let commonMetaLangs: [SettingsBScrapeChipOption] = [
        .init(id: "zh-CN", name: String(localized: .settingsScrapeSimplifiedChinese)),
        .init(id: "zh-TW", name: String(localized: .settingsScrapeTraditionalChinese)),
        .init(id: "en-US", name: "English"),
        .init(id: "ja-JP", name: String(localized: .settingsScrapeJapaneseLanguage)),
        .init(id: "ko-KR", name: "한국어"),
        .init(id: "fr-FR", name: "Français"),
    ]

    /// 图片语言的特殊 token + 常用语种（值为 TMDB 图片语言码）
    static let commonImageLangs: [SettingsBScrapeChipOption] = [
        .init(id: "meta", name: String(localized: .settingsScrapeMetadataPrimary), tip: String(localized: .settingsScrapeMetadataPrimaryHint)),
        .init(id: "orig", name: String(localized: .settingsScrapeOriginalLanguage), tip: String(localized: .settingsScrapeOriginalLanguageHint)),
        .init(id: "en", name: "English"),
        .init(id: "null", name: String(localized: .settingsScrapeTextless), tip: String(localized: .settingsScrapeTextlessHint)),
        .init(id: "ja", name: String(localized: .settingsScrapeJapaneseLanguage)),
    ]

    static let commonCertCountries: [SettingsBScrapeChipOption] = [
        .init(id: "CN", name: String(localized: .settingsScrapeChina)),
        .init(id: "US", name: String(localized: .settingsScrapeUnitedStates)),
        .init(id: "JP", name: String(localized: .settingsScrapeJapan)),
        .init(id: "GB", name: String(localized: .settingsScrapeUnitedKingdom)),
    ]

    /// 可选的 TMDB 图床档位：后端 settings/metadata.py 合法集合里实用的那部分（同 Web，过小的档位不提供）；
    /// 空串 = 跟随上一级（全局页是环境变量，库覆盖页是全局设置）
    static let posterSizes = ["w342", "w500", "w780", "original"]
    static let backdropSizes = ["w780", "w1280", "original"]
    static let stillSizes = ["w185", "w300", "original"]
    /// 演职员头像档位（TMDB 头像档位本身就这几档，h632 是按高 632 的那一档）
    static let profileSizes = ["w185", "h632", "original"]

    /// 本地图片画质的四档（docs/design/image-sizing.md §8.1）：前三档是后端的预设，选了预设时四个档位字段被忽略；
    /// 「自定义」才看四个档位。文案说的是「在哪些设备上够不够清楚」，不是 TMDB 档位名
    struct ImageQuality: Identifiable {
        let id: String
        let title: String
        let desc: String
    }

    static let imageQualities: [ImageQuality] = [
        .init(id: "original", title: String(localized: .settingsScrapeOriginalDefault), desc: String(localized: .settingsScrapeOriginalHint)),
        .init(id: "standard", title: String(localized: .settingsAppearanceStandard), desc: String(localized: .settingsScrapeStandardHint)),
        .init(id: "compact", title: String(localized: .settingsScrapeCompact), desc: String(localized: .settingsScrapeCompactHint)),
        .init(id: "custom", title: String(localized: .settingsScrapeCustom), desc: String(localized: .settingsScrapeModelCustomQualityHint)),
    ]

    /// 画质档的简称（折叠头摘要用）
    static func imageQualityName(_ id: String) -> String {
        switch id {
        case "original": String(localized: .settingsScrapeOriginalSummary)
        case "standard": String(localized: .settingsAppearanceStandard)
        case "compact": String(localized: .settingsScrapeCompact)
        default: String(localized: .settingsScrapeCustom)
        }
    }

    /// 「更多」面板的完整候选：从后端全量表派生，剔除已在常用行里的项（同 Web useScrapeChipOptions）
    static func extraMetaLangs(_ languages: [API.LanguageOption]) -> [SettingsBScrapeChipOption] {
        languages
            .filter { l in !commonMetaLangs.contains { $0.id.hasPrefix("\(l.code)-") } }
            .map { .init(id: $0.code, name: displayName($0)) }
    }

    static func extraImageLangs(_ languages: [API.LanguageOption]) -> [SettingsBScrapeChipOption] {
        languages
            .filter { l in !commonImageLangs.contains { $0.id == l.code } }
            .map { .init(id: $0.code, name: displayName($0)) }
    }

    static func extraCountries(_ countries: [API.CountryOption]) -> [SettingsBScrapeChipOption] {
        countries
            .filter { c in !commonCertCountries.contains { $0.id == c.code } }
            .map { .init(id: $0.code, name: $0.name) }
    }

    private static func displayName(_ l: API.LanguageOption) -> String {
        if !l.name.isEmpty { return l.name }
        if !l.englishName.isEmpty { return l.englishName }
        return l.code
    }
}

// MARK: - 折叠头摘要

/// 各卡片折叠头上的「人话」摘要（Web describeScrapeValues 的逐卡拆分）。
///
/// 不给原始值：折叠头要露的是「日本語 → 中文（简体）」而不是 `ja-JP → zh-CN`；
/// 未知语种/地区（从「更多」选的长尾项）回落显示代码本身，不编造名字——与 Web 同口径。
enum SettingsBScrapeSummary {
    private static func label(_ options: [SettingsBScrapeChipOption], _ id: String) -> String {
        options.first { $0.id == id }?.name ?? id
    }

    private static func join(_ options: [SettingsBScrapeChipOption], _ values: [String]) -> String {
        values.map { label(options, $0) }.joined(separator: " → ")
    }

    static func metaLanguage(_ s: API.MetadataScrapeSetting) -> String {
        join(SettingsBScrapeCatalog.commonMetaLangs, s.languagePriority)
    }

    static func certCountry(_ s: API.MetadataScrapeSetting) -> String {
        join(SettingsBScrapeCatalog.commonCertCountries, s.certCountryPriority)
    }

    /// 海报卡把「模式 + 语言优先级」并成一句：默认模式下语言优先级不生效，列出来只会误导
    static func poster(_ s: API.MetadataScrapeSetting) -> String {
        s.posterMode == "default"
            ? String(localized: .settingsScrapeTmdbDefault)
            : String(localized: .settingsScrapeLanguageSummary(join(SettingsBScrapeCatalog.commonImageLangs, s.posterLanguagePriority)))
    }

    static func backdrop(_ s: API.MetadataScrapeSetting) -> String {
        join(SettingsBScrapeCatalog.commonImageLangs, s.backdropLanguagePriority)
    }

    /// 画质一句话：选过档就写档名；没选过时四个档位都空 = 新默认「原图」，否则是老配置留下的档位，按自定义列出
    /// （后端按档位反推时，恰好等于某个预设会显示成那一档——这里只看设置本身，不做反推）
    static func quality(_ s: API.MetadataScrapeSetting) -> String {
        let sizes = [s.posterSize, s.backdropSize, s.stillSize, s.profileSize]
        let quality: String
        if !s.imageQuality.isEmpty, s.imageQuality != "custom" {
            quality = String(localized: .settingsScrapeModelQualityNamed(SettingsBScrapeCatalog.imageQualityName(s.imageQuality)))
        } else if s.imageQuality.isEmpty, sizes.allSatisfy(\.isEmpty) {
            quality = String(localized: .settingsScrapeModelQualityOriginal)
        } else {
            quality = String(localized: .settingsScrapeModelQualityCustom(sizes.map { $0.isEmpty ? String(localized: .settingsScrapeModelEnv) : $0 }.joined(separator: "/")))
        }
        return [
            quality,
            s.posterMinWidth > 0 ? String(localized: .settingsScrapePosterWidth(String(s.posterMinWidth))) : String(localized: .settingsScrapePosterUnlimited),
            s.backdropMinWidth > 0 ? String(localized: .settingsScrapeBackdropWidth(String(s.backdropMinWidth))) : String(localized: .settingsScrapeBackdropUnlimited),
        ].joined(separator: " · ")
    }

    /// 四个模板并成一句：逐个列模板串太长，只说哪几项不是默认
    static func naming(_ s: API.MetadataScrapeSetting) -> String {
        let changed = SettingsBScrapeNaming.fields.filter { !s[keyPath: $0.keyPath].trimmingCharacters(in: .whitespaces).isEmpty }
        return changed.isEmpty ? String(localized: .settingsScrapeAllDefaultTemplates) : String(localized: .settingsScrapeModelChanged(AppFormatting.list(changed.map(\.label))))
    }

    static func mirror(_ s: API.MetadataScrapeSetting) -> String {
        let off = SettingsBScrapeMirrorRow.all.filter { !s[keyPath: $0.keyPath] }
        return off.isEmpty ? String(localized: .settingsScrapeAllMirrorsEnabled) : String(localized: .settingsScrapeModelNotWritten(AppFormatting.list(off.map(\.label))))
    }
}

// MARK: - 目录写入三项

struct SettingsBScrapeMirrorRow {
    let key: String
    let label: String
    let hint: String
    let keyPath: WritableKeyPath<API.MetadataScrapeSetting, Bool>

    static let all: [SettingsBScrapeMirrorRow] = [
        .init(key: "mirror_images", label: String(localized: .settingsScrapeEntryImages), hint: String(localized: .settingsScrapeModelImagesHint), keyPath: \.mirrorImages),
        .init(key: "mirror_nfo", label: String(localized: .settingsScrapeNfoMetadata), hint: String(localized: .settingsScrapeNfoHint), keyPath: \.mirrorNfo),
        .init(key: "mirror_episode_thumbs", label: String(localized: .settingsScrapeEpisodeStills), hint: String(localized: .settingsScrapeEpisodeStillsHint), keyPath: \.mirrorEpisodeThumbs),
    ]
}

// MARK: - 命名模板

/// 命名模板：字段定义、预览样例、渲染器与轻校验。
///
/// 渲染三步与后端一一对应：① 整组丢弃占位符全空的括号组（收掉 "[tmdbid-]" 这种残留）
/// → ② 替换占位符 → ③ 收缩并清洗。改后端规则时 Web 与这里都要同步改。
enum SettingsBScrapeNaming {
    struct Field {
        /// 后端字段名（也用作 accessibilityIdentifier 后缀）
        let key: String
        let label: String
        let note: String
        let fallback: String
        let tokens: [String]
        let keyPath: WritableKeyPath<API.MetadataScrapeSetting, String>
    }

    static let commonTokens = ["title", "original_title", "english_title", "year", "tmdb_id", "imdb_id", "douban_id"]
    static let fileAttrTokens = [
        "resolution", "video_codec", "hdr", "bit_depth", "audio",
        "media_source", "release_group", "site", "release_name",
    ]

    /// 占位符按类别分组展示，按钮上写中文名（与 Web TOKEN_GROUPS 同一份）
    static let tokenGroups: [(label: String, tokens: [(key: String, name: String)])] = [
        (String(localized: .settingsScrapeTitleTokens), [("title", String(localized: .settingsScrapeTitleToken)), ("original_title", String(localized: .settingsScrapeOriginalTitle)), ("english_title", String(localized: .settingsScrapeEnglishTitle)), ("year", String(localized: .settingsScrapeYear)),
                    ("tmdb_id", "TMDB ID"), ("imdb_id", "IMDb ID"), ("douban_id", String(localized: .settingsScrapeDoubanId))]),
        (String(localized: .settingsScrapeEpisodeTokens), [("season", String(localized: .settingsScrapeSeasonNumber)), ("season_name", String(localized: .settingsScrapeSeasonName)), ("episode", String(localized: .settingsScrapeEpisodeNumber)), ("episode_title", String(localized: .settingsScrapeEpisodeTitle))]),
        (String(localized: .settingsScrapeFileTokens), [("resolution", String(localized: .settingsScrapeResolution)), ("video_codec", String(localized: .settingsScrapeVideoCodec)), ("hdr", "HDR"), ("bit_depth", String(localized: .settingsScrapeBitDepth)), ("audio", String(localized: .settingsScrapeAudio))]),
        (String(localized: .settingsDevicesApprovalSource), [("media_source", String(localized: .settingsScrapeMediaSource)), ("release_group", String(localized: .settingsScrapeReleaseGroup)), ("site", String(localized: .settingsScrapeSite)), ("release_name", String(localized: .settingsScrapeReleaseName))]),
    ]

    static let fields: [Field] = [
        .init(key: "naming_entry_dir", label: String(localized: .settingsScrapeEntryDirectory), note: String(localized: .settingsScrapeSharedNamingHint),
              fallback: "{title} ({year})", tokens: commonTokens, keyPath: \.namingEntryDir),
        .init(key: "naming_movie_file", label: String(localized: .settingsScrapeMovieFilename), note: "",
              fallback: "{title} ({year})", tokens: commonTokens + fileAttrTokens, keyPath: \.namingMovieFile),
        .init(key: "naming_season_dir", label: String(localized: .settingsScrapeSeasonDirectory), note: "",
              fallback: "Season {season:02d}", tokens: commonTokens + ["season", "season_name"], keyPath: \.namingSeasonDir),
        .init(key: "naming_episode_file", label: String(localized: .settingsScrapeEpisodeFilename), note: "",
              fallback: "{title} ({year}) - S{season:02d}E{episode:02d}",
              tokens: commonTokens + fileAttrTokens + ["season", "season_name", "episode", "episode_title"],
              keyPath: \.namingEpisodeFile),
    ]

    /// 预览样例：一部电影 + 一集剧集，字段齐全便于看清每个占位符的效果（与 Web 同一组样例）
    static let sampleMovie: [String: String] = [
        "title": String(localized: .settingsScrapeSampleMovieTitle),
        "original_title": "Dune: Part Two",
        "english_title": "Dune: Part Two",
        "year": "2024",
        "tmdb_id": "693134",
        "imdb_id": "tt15239678",
        "douban_id": "35575567",
        "resolution": "2160p",
        "video_codec": "HEVC",
        "hdr": "DV",
        "bit_depth": "10bit",
        "audio": "TrueHD Atmos 7.1",
        "media_source": "BluRay",
        "release_group": "FRDS",
        "site": "hdsky",
        "release_name": "Dune.Part.Two.2024.2160p.BluRay.DV.HEVC.TrueHD.7.1.Atmos-FRDS",
    ]
    /// 剧集样例是 SDR：不给 hdr，演示 {hdr} 渲染为空后的收缩
    static let sampleEpisode: [String: String] = [
        "title": String(localized: .settingsScrapeSampleTvTitle),
        "original_title": String(localized: .settingsScrapeSampleTvTitle),
        "english_title": "Kite",
        "year": "2017",
        "tmdb_id": "68035",
        "imdb_id": "tt6952510",
        "douban_id": "26340419",
        "season": "1",
        "season_name": String(localized: .settingsScrapeSampleSeason),
        "episode": "3",
        "episode_title": String(localized: .settingsScrapeSampleEpisodeTitle),
        "resolution": "1080p",
        "video_codec": "H.264",
        "bit_depth": "8bit",
        "audio": "AAC 2.0",
        "media_source": "WEB-DL",
        "release_group": "CHDWEB",
        "site": "chdbits",
        "release_name": "Kite.2017.S01E03.1080p.WEB-DL.H264.AAC-CHDWEB",
    ]

    /// 片名类占位符：同一模板里值相同的只保留第一次出现（「风筝 (风筝)」→「风筝」）
    private static let titleTokens = ["title", "original_title", "english_title"]
    /// 超长时可截短的自由文本占位符；编号、年份、规格不截
    private static let shrinkableTokens = titleTokens + ["episode_title", "season_name", "release_name"]
    /// 单段名字字节上限与截短保底，与后端 MAX_SEGMENT_BYTES / _SHRINK_FLOOR_BYTES 一致
    private static let maxSegmentBytes = 200
    private static let shrinkFloorBytes = 30

    // 与 Web 的正则逐字对应（JS 的 \w 只含 ASCII，这里显式写成 [A-Za-z0-9_]）
    private static let tokenRE = try! NSRegularExpression(pattern: #"\{([A-Za-z0-9_]+)(?::0(\d)d)?\}"#)
    private static let bracketGroupRE = try! NSRegularExpression(pattern: #"[(\[【][^()\[\]【】]*[)\]】]"#)
    private static let forbiddenRE = try! NSRegularExpression(pattern: "[\\\\/:*?\"<>|]")

    /// 模板里出现的占位符名（按出现顺序）
    static func tokens(in template: String) -> [String] {
        matches(tokenRE, template).compactMap { m in substring(template, m.range(at: 1)) }
    }

    /// 前端侧轻校验：与后端同口径，只为即时反馈；能否保存以后端返回为准
    static func error(for field: Field, template: String) -> String? {
        if template.trimmingCharacters(in: .whitespaces).isEmpty { return nil } // 空 = 用默认模板
        if template.contains("/") || template.contains("\\") { return String(localized: .settingsScrapeNoPathSeparators) }
        let used = tokens(in: template)
        let unknown = used.filter { !field.tokens.contains($0) }
        if !unknown.isEmpty {
            return String(localized: .settingsScrapeModelUnknownTokens(AppFormatting.list(unknown.map { "{\($0)}" })))
        }
        return nil
    }

    /// 生效模板：留空时用默认模板
    static func effective(_ field: Field, in s: API.MetadataScrapeSetting) -> String {
        let value = s[keyPath: field.keyPath]
        return value.trimmingCharacters(in: .whitespaces).isEmpty ? field.fallback : value
    }

    static func render(_ template: String, _ ctx: [String: String]) -> String {
        // 片名去重 → 渲染 → 超长时逐个截短最长的自由文本（与后端 render 同序）
        var context = ctx
        var seen = Set<String>()
        for name in tokens(in: template) where titleTokens.contains(name) {
            let value = tokenValue(context, name, nil).lowercased()
            if value.isEmpty { continue }
            if seen.contains(value) { context[name] = nil }
            seen.insert(value)
        }
        var text = renderOnce(template, context)
        for _ in 0..<(shrinkableTokens.count * 2) {
            let over = text.utf8.count - maxSegmentBytes
            if over <= 0 { return text }
            let sizes = shrinkableTokens.map { ($0, tokenValue(context, $0, nil).utf8.count) }
            guard let best = sizes.max(by: { $0.1 < $1.1 }), best.1 > shrinkFloorBytes else { break }
            let cut = cutBytes(tokenValue(context, best.0, nil), max(best.1 - over, shrinkFloorBytes))
            context[best.0] = cut.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
            text = renderOnce(template, context)
        }
        let result = sanitize(cutBytes(text, maxSegmentBytes))
        return result.isEmpty ? "未命名" : result // i18n-ignore: matches the server’s on-disk naming fallback
    }

    /// 按 UTF-8 字节截断，不切坏多字节字符
    private static func cutBytes(_ text: String, _ limit: Int) -> String {
        var out = ""
        var used = 0
        for char in text {
            used += String(char).utf8.count
            if used > limit { break }
            out.append(char)
        }
        return out
    }

    private static func renderOnce(_ template: String, _ ctx: [String: String]) -> String {
        // ① 占位符全空的括号组连同组内字面文本一起丢弃
        let dropped = replace(bracketGroupRE, in: template) { full, m in
            let group = substring(full, m.range) ?? ""
            let found = matches(tokenRE, group)
            if found.isEmpty { return group }
            let allEmpty = found.allSatisfy { m in
                tokenValue(ctx, substring(group, m.range(at: 1)) ?? "", substring(group, m.range(at: 2))).isEmpty
            }
            return allEmpty ? "" : group
        }
        // ② 替换占位符
        let filled = replace(tokenRE, in: dropped) { text, m in
            tokenValue(ctx, substring(text, m.range(at: 1)) ?? "", substring(text, m.range(at: 2)))
        }
        // ③ 收缩：括号内侧 → 重复分隔符 → 多余空白 → 首尾分隔符
        var collapsed = filled
        collapsed = regexReplace(#"([(\[【])[\s\-–]+"#, in: collapsed, with: "$1")
        collapsed = regexReplace(#"[\s\-–]+([)\]】])"#, in: collapsed, with: "$1")
        collapsed = regexReplace(#"(?:\s*-\s*){2,}"#, in: collapsed, with: " - ")
        collapsed = regexReplace(#"\s{2,}"#, in: collapsed, with: " ")
        collapsed = regexReplace(#"^[\s\-–.]+|[\s\-–.]+$"#, in: collapsed, with: "")
        let result = sanitize(collapsed)
        return result.isEmpty ? "未命名" : result // i18n-ignore: matches the server’s on-disk naming fallback
    }

    private static func sanitize(_ value: String) -> String {
        var v = forbiddenRE.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: " ")
        v = regexReplace(#"\s+"#, in: v, with: " ")
        return regexReplace(#"^[\s.]+|[\s.]+$"#, in: v, with: "")
    }

    private static func tokenValue(_ ctx: [String: String], _ name: String, _ pad: String?) -> String {
        guard let raw = ctx[name], !raw.isEmpty else { return "" }
        var text = sanitize(raw)
        if let pad, let width = Int(pad), !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), text.count < width {
            text = String(repeating: "0", count: width - text.count) + text
        }
        return text
    }

    // MARK: 正则小工具

    private static func matches(_ re: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func substring(_ text: String, _ range: NSRange) -> String? {
        guard range.location != NSNotFound, let r = Range(range, in: text) else { return nil }
        return String(text[r])
    }

    /// 回调式替换（JS 的 `replace(re, fn)`）：倒序替换，避免前面的替换改变后面的偏移。
    /// transform 收到原串与匹配结果（捕获组区间相对原串）
    private static func replace(_ re: NSRegularExpression, in text: String, _ transform: (String, NSTextCheckingResult) -> String) -> String {
        var result = text
        for m in matches(re, text).reversed() {
            guard let r = Range(m.range, in: text) else { continue }
            let replacement = transform(text, m)
            // 在原串上取区间，再按相同 utf16 偏移写回 result（倒序保证前段偏移不变）
            if let target = Range(NSRange(r, in: text), in: result) {
                result.replaceSubrange(target, with: replacement)
            }
        }
        return result
    }

    private static func regexReplace(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
