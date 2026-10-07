import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct FanartSettingsTests {
    private var legacySetting: API.MetadataScrapeSetting {
        .init(languagePriority: [], certCountryPriority: ["CN", "US"], posterMode: "default",
              posterLanguagePriority: ["meta", "en", "null"], backdropLanguagePriority: ["null", "meta"],
              posterMinWidth: 500, backdropMinWidth: 1920, posterSize: "", backdropSize: "",
              stillSize: "", profileSize: "", imageQuality: "",
              namingEntryDir: "", namingMovieFile: "", namingSeasonDir: "", namingEpisodeFile: "",
              mirrorImages: true, mirrorNfo: true, mirrorEpisodeThumbs: false)
    }

    private func encoded(_ value: API.MetadataScrapeSettingInput) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @Test func imageTypeDefaultsMapToTheCorrectServerField() throws {
        // Defaults must match settings/metadata.py: TMDB usually has higher resolution backdrops,
        // while Fanart has more localized logos and season posters.
        let expected: [SettingsBScrapeImageKind: (key: String, order: [String])] = [
            .poster: ("poster_source_order", ["tmdb", "fanart"]),
            .backdrop: ("backdrop_source_order", ["tmdb", "fanart"]),
            .logo: ("logo_source_order", ["fanart", "tmdb"]),
            .seasonPoster: ("season_poster_source_order", ["fanart", "tmdb"]),
        ]
        for kind in SettingsBScrapeImageKind.allCases {
            var setting = legacySetting
            let expectation = try #require(expected[kind])
            setting[keyPath: kind.keyPath] = kind.defaultOrder
            let payload = try encoded(SettingsBScrapeCard.sources.payload(setting))
            #expect(Set(payload.keys) == [expectation.key])
            #expect(payload[expectation.key] as? [String] == expectation.order)
        }
    }

    @Test func immediateSourceSaveOnlySendsTheChosenImageType() throws {
        let expected: [SettingsBScrapeImageKind: String] = [
            .poster: "poster_source_order", .backdrop: "backdrop_source_order",
            .logo: "logo_source_order", .seasonPoster: "season_poster_source_order",
        ]
        for kind in SettingsBScrapeImageKind.allCases {
            let field = try #require(expected[kind])
            let payload = try encoded(kind.payload(["fanart", "tmdb"]))
            #expect(Set(payload.keys) == [field])
            #expect(payload[field] as? [String] == ["fanart", "tmdb"])
        }
    }

    @Test func disablingFanartPreservesPreviouslyChosenSourceOrder() throws {
        var setting = legacySetting
        setting.fanartEnabled = false
        setting.posterSourceOrder = ["fanart", "tmdb"]
        setting.backdropSourceOrder = ["fanart", "tmdb"]
        setting.logoSourceOrder = ["tmdb", "fanart"]
        setting.seasonPosterSourceOrder = ["tmdb", "fanart"]
        let payload = try encoded(SettingsBScrapeCard.sources.payload(setting))
        #expect(payload["fanart_enabled"] as? Bool == false)
        #expect(payload["poster_source_order"] as? [String] == ["fanart", "tmdb"])
        #expect(payload["backdrop_source_order"] as? [String] == ["fanart", "tmdb"])
        #expect(payload["logo_source_order"] as? [String] == ["tmdb", "fanart"])
        #expect(payload["season_poster_source_order"] as? [String] == ["tmdb", "fanart"])
        #expect(payload["poster_mode"] == nil)
        #expect(payload["logo_language_priority"] == nil)
    }

    @Test func posterLanguageChangesNeverOverwriteFanartOrLogoSettings() throws {
        for enabled in [nil, false, true] as [Bool?] {
            var setting = legacySetting
            setting.fanartEnabled = enabled
            setting.posterLanguagePriority = ["zh", "orig", "en", "null"]
            setting.logoLanguagePriority = ["en", "orig"]
            let payload = try encoded(SettingsBScrapeCard.poster.payload(setting))
            #expect(Set(payload.keys) == ["poster_mode", "poster_language_priority"])
            #expect(payload["poster_mode"] as? String == "default")
            #expect(payload["poster_language_priority"] as? [String] == ["zh", "orig", "en", "null"])
        }
    }
}
