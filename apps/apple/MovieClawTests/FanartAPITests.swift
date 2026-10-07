import Foundation
import Testing
@testable import MovieClaw

struct FanartAPITests {
    private var legacySetting: [String: Any] {
        [
            "language_priority": [], "cert_country_priority": ["CN", "US"], "poster_mode": "default",
            "poster_language_priority": ["meta", "en", "null"], "backdrop_language_priority": ["null", "meta", "en"],
            "poster_min_width": 500, "backdrop_min_width": 1920, "poster_size": "", "backdrop_size": "",
            "still_size": "", "profile_size": "", "image_quality": "", "naming_entry_dir": "",
            "naming_movie_file": "", "naming_season_dir": "", "naming_episode_file": "",
            "mirror_images": true, "mirror_nfo": true, "mirror_episode_thumbs": true,
        ]
    }

    @Test func olderServerWithoutFanartFieldsStillDecodes() throws {
        let data = try JSONSerialization.data(withJSONObject: legacySetting)
        let value = try JSONDecoder().decode(API.MetadataScrapeSetting.self, from: data)
        #expect(value.fanartEnabled == nil)
        #expect(value.logoLanguagePriority == nil)
        #expect(value.posterSourceOrder == nil)
        #expect(value.backdropSourceOrder == nil)
        #expect(value.logoSourceOrder == nil)
        #expect(value.seasonPosterSourceOrder == nil)
        #expect(value.languagePriority.isEmpty)
        #expect(value.mirrorImages)
    }

    @Test func configuredSourcesAndLogoPrioritySurviveRoundTrip() throws {
        var object = legacySetting
        object["fanart_enabled"] = true
        object["logo_language_priority"] = ["zh", "orig", "en", "null"]
        object["poster_source_order"] = ["fanart", "tmdb"]
        object["backdrop_source_order"] = ["tmdb", "fanart"]
        object["logo_source_order"] = ["tmdb", "fanart"]
        object["season_poster_source_order"] = ["fanart", "tmdb"]
        var value = try JSONDecoder().decode(API.MetadataScrapeSetting.self, from: JSONSerialization.data(withJSONObject: object))
        value.mirrorNfo = false
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(API.MetadataScrapeSetting.self, from: encoded)
        #expect(decoded.fanartEnabled == true)
        #expect(decoded.logoLanguagePriority == ["zh", "orig", "en", "null"])
        #expect(decoded.posterSourceOrder == ["fanart", "tmdb"])
        #expect(decoded.backdropSourceOrder == ["tmdb", "fanart"])
        #expect(decoded.logoSourceOrder == ["tmdb", "fanart"])
        #expect(decoded.seasonPosterSourceOrder == ["fanart", "tmdb"])
        #expect(!decoded.mirrorNfo)
    }

    @Test func sourceUpdateOmitsUneditedFields() throws {
        let payload = API.MetadataScrapeSettingInput(
            fanartEnabled: true, posterSourceOrder: ["tmdb", "fanart"],
            backdropSourceOrder: ["tmdb", "fanart"], logoSourceOrder: ["fanart", "tmdb"],
            seasonPosterSourceOrder: ["fanart", "tmdb"]
        )
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["fanart_enabled", "poster_source_order", "backdrop_source_order", "logo_source_order", "season_poster_source_order"])
        #expect(object["logo_language_priority"] == nil)
        #expect(object["language_priority"] == nil)
    }

    @Test func keyRequestAndStatusUseSeparateWireModels() throws {
        let payload = API.FanartKeyPayload(apiKey: "fixture-fanart-key-abcd")
        let data = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["api_key"])
        #expect(object["api_key"] as? String == "fixture-fanart-key-abcd")
        let status = try JSONDecoder().decode(API.FanartStatusView.self, from: Data(#"{"configured":true,"key_invalid":true,"key_hint":"abcd"}"#.utf8))
        #expect(status.configured)
        #expect(status.keyInvalid)
        #expect(status.keyHint == "abcd")
        let statusObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any])
        #expect(statusObject["api_key"] == nil)
    }
}
