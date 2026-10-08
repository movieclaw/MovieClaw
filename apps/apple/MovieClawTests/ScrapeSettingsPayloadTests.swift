import Foundation
import Testing
@testable import MovieClaw

struct ScrapeSettingsPayloadTests {
    private let setting = API.MetadataScrapeSetting(
        languagePriority: [], certCountryPriority: ["CN", "US"], posterMode: "language",
        posterLanguagePriority: ["meta", "en", "null"], backdropLanguagePriority: ["null", "meta"],
        posterMinWidth: 500, backdropMinWidth: 1920, posterSize: "w500", backdropSize: "original",
        stillSize: "w300", profileSize: "w185", imageQuality: "custom",
        logoLanguagePriority: ["meta", "en", "orig", "null"], fanartEnabled: true,
        posterSourceOrder: ["tmdb", "fanart"], backdropSourceOrder: ["tmdb", "fanart"],
        logoSourceOrder: ["fanart", "tmdb"], seasonPosterSourceOrder: ["fanart", "tmdb"],
        namingEntryDir: "", namingMovieFile: "", namingSeasonDir: "", namingEpisodeFile: "",
        mirrorImages: false, mirrorNfo: true, mirrorEpisodeThumbs: false
    )

    @Test func eachEditorOnlySendsItsOwnFields() throws {
        for card in SettingsBScrapeCard.allCases {
            let data = try JSONEncoder().encode(card.payload(setting))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(object.keys) == Set(card.keys))
        }
    }

    @Test func directoryWriteDoesNotMaterializeInheritedLanguage() throws {
        let data = try JSONEncoder().encode(SettingsBScrapeCard.mirror.payload(setting))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["language_priority"] == nil)
        #expect(object["image_quality"] == nil)
        #expect(object["fanart_enabled"] == nil)
        #expect(object["logo_language_priority"] == nil)
        #expect(object["mirror_images"] as? Bool == false)
        #expect(object["mirror_nfo"] as? Bool == true)
    }
}
