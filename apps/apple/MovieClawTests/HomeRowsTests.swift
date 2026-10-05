import Foundation
import Testing
@testable import MovieClaw

/// 首页行清单的合并规则（`HomeRows`），口径对照 Web `lib/home-rows.ts` 与 `test/home-rows.test.mjs`。
/// 两端共用同一份 `home.rows` 偏好，这里重点守「按类型的跨库行」（§8，只在主动添加时出现）：iOS 不认识 `kind:` / `media_kind`
/// 时，自定义页看不到「全部电影」，在 iOS 上存一次还会把网页加的类型行写丢。
struct HomeRowsTests {
    private func library(_ id: Int, _ kind: String, excluded: Bool = false, access: Bool = true) -> API.LibraryView {
        let json: [String: Any] = [
            "id": id, "name": "库\(id)", "kind": kind, "source": "local",
            "capabilities": [
                "scraped": true, "episodic": kind == "tv", "naming": true, "subscribable": true, "write_nfo": false,
                "default_aspect": 0.667, "jellyfin_collection": "movies", "playable": true,
            ],
            "generate_thumbnails": false, "extract_chapter_images": false, "detect_media_segments": false,
            "exclude_from_home": excluded, "auto_series_collections": false, "access_mode": "all", "admin_visible": true,
            "member_ids": [Int](), "viewer_access": access, "root_paths": [String](), "primary_root": NSNull(), "is_default": false,
            "match_rules": [[String: Any]](), "auto_clear_missing": false, "realtime_watch": false, "network_mount": false,
            "custom_cover": false, "scrape_overrides": [String: Any](),
            "stats": ["item_count": 0, "file_count": 0, "total_size_bytes": 0, "unidentified_count": 0, "missing_count": 0, "ignored_count": 0],
            "scanning": false, "scan_progress": NSNull(), "last_scan": NSNull(), "organizing": false, "organize_progress": NSNull(),
            "last_organize": NSNull(), "metadata_refresh": NSNull(), "chapter_job": NSNull(),
            "created_at": "2026-10-01T00:00:00", "updated_at": "2026-10-01T00:00:00",
        ]
        return try! JSONDecoder().decode(API.LibraryView.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func pref(_ id: String, sort: String? = nil, unwatched: Bool? = nil, hidden: Bool? = nil, libraryId: Int? = nil, collectionId: Int? = nil, mediaKind: String? = nil) -> API.HomeRowPref {
        API.HomeRowPref(id: id, sort: sort, unwatched: unwatched, hidden: hidden, libraryId: libraryId, collectionId: collectionId, mediaKind: mediaKind)
    }

    private func collection(_ id: Int, name: String) -> API.CollectionView {
        API.CollectionView(id: id, name: name, libraryId: 1, rules: [], sort: "title", visibility: "household", builtin: nil,
                           editable: true, manageable: true, ruleDriven: false, itemCount: 12, coverItemId: nil, covers: [],
                           kind: "user", hidden: false, position: 0)
    }

    @Test func collectionCardsFollowVisibleRowsAndDeduplicate() {
        let collections = [collection(7, name: "宫崎骏"), collection(8, name: "诺兰")]
        let prefs = [pref("row:hidden", hidden: true, collectionId: 7), pref("row:nolan", sort: "random", collectionId: 8),
                     pref("row:miyazaki", collectionId: 7), pref("row:duplicate", sort: "rating", collectionId: 8),
                     pref("row:deleted", collectionId: 99)]
        let rows = HomeRows.build(prefs: prefs, libraries: [library(1, "movie")], collections: collections)
        #expect(HomeRows.pinnedCollections(rows).map(\.id) == [8, 7])
        #expect(HomeRows.pinnedCollections(rows).map(\.name) == ["诺兰", "宫崎骏"])
        let lostAccess = HomeRows.build(prefs: prefs, libraries: [library(1, "movie")], collections: [collections[0]])
        #expect(HomeRows.pinnedCollections(lostAccess).map(\.id) == [7])
        #expect(HomeRows.pinnedCollections(HomeRows.build(prefs: [], libraries: [library(1, "movie")], collections: collections)).isEmpty)
    }

    @Test func hidingCollectionRowAlsoHidesCard() {
        let collection = collection(8, name: "诺兰")
        let hidden = HomeRows.build(prefs: [pref("row:nolan", hidden: true, collectionId: 8)], libraries: [library(1, "movie")], collections: [collection])
        #expect(HomeRows.pinnedCollections(hidden).isEmpty)
        let restored = HomeRows.build(prefs: [pref("row:nolan", hidden: false, collectionId: 8)], libraries: [library(1, "movie")], collections: [collection])
        #expect(HomeRows.pinnedCollections(restored).map(\.id) == [8])
    }


    @Test func defaultsHaveNoKindRows() {
        // 类型行要主动添加才出现：出厂布局与升级前存的清单都不补（同类型几个库都一样）
        let libs = [library(1, "movie"), library(2, "movie"), library(3, "tv")]
        // 类型色块行（genres:*）是另一回事，见 genreRows* 用例
        #expect(HomeRows.build(prefs: [], libraries: libs, collections: []).map(\.id).filter { !$0.hasPrefix("genres:") } == ["up-next", "favorites", "libraries", "lib:1", "lib:2", "lib:3"])
        let saved = HomeRows.build(prefs: [pref("lib:2"), pref("up-next")], libraries: libs, collections: [])
        #expect(!saved.contains { $0.id.hasPrefix("kind:") })
    }

    @Test func addedKindRowRoundTrip() {
        // 被排除首页、不可见的库不算成员
        let libs = [library(1, "movie"), library(2, "movie"), library(3, "movie", excluded: true), library(4, "movie", access: false), library(5, "tv")]
        let rows = HomeRows.build(prefs: [pref("row:k1", sort: "random", mediaKind: "movie"), pref("lib:1")], libraries: libs, collections: [])
        guard case let .mediaKind(kind, members, sort, _, _, _, _) = rows[0].kind else { Issue.record("row:k1 没解析成类型行"); return }
        #expect(kind == "movie" && members.map(\.id) == [1, 2] && sort == "random")
        #expect(rows[0].removable && rows[0].title == "全部电影 · 随便看看")
        // 写回必须带 media_kind（丢了它，服务端会拒、网页加的行也就没了）
        let saved = HomeRows.toPrefs(rows)
        #expect(saved[0].mediaKind == "movie" && saved[0].libraryId == nil && saved[0].collectionId == nil)
    }

    @Test func legacyKindRows() {
        // v0.30.0 存下的 kind: 行：隐藏的是当年默认塞进来的，丢掉；显示中的保留、能删，写回不带来源字段
        let libs = [library(1, "movie"), library(2, "tv")]
        let rows = HomeRows.build(prefs: [pref("kind:movie", sort: "rating", unwatched: true), pref("kind:tv", hidden: true)], libraries: libs, collections: [])
        #expect(!rows.contains { $0.id == "kind:tv" })
        guard let movie = rows.first(where: { $0.id == "kind:movie" }), case let .mediaKind(_, _, sort, _, unwatched, _, _) = movie.kind else {
            Issue.record("显示中的 kind:movie 应保留"); return
        }
        #expect(sort == "rating" && unwatched && movie.removable)
        let saved = HomeRows.toPrefs([movie])
        #expect(saved[0].mediaKind == nil && saved[0].sort == "rating" && saved[0].unwatched == true)
    }

    @Test func kindRowDisappearsWithoutMembers() {
        // 这一类型的库全被排除首页：行静默消失
        let libs = [library(1, "movie", excluded: true), library(2, "tv")]
        let rows = HomeRows.build(prefs: [pref("kind:movie"), pref("row:x", mediaKind: "movie")], libraries: libs, collections: [])
        #expect(!rows.contains { $0.id == "kind:movie" || $0.id == "row:x" })
    }

    @Test func lastPlayedClearsUnwatched() {
        let rows = HomeRows.build(prefs: [pref("row:k", sort: "last_played", unwatched: true, mediaKind: "movie")], libraries: [library(1, "movie")], collections: [])
        guard case let .mediaKind(_, _, _, _, unwatched, _, _) = rows[0].kind else { Issue.record("不是类型行"); return }
        #expect(!unwatched)
    }

    @Test func kindWallWebPathParses() {
        #expect(AppRoute(webPath: "/library/kind/movie") == .libraryKind(kind: "movie"))
        #expect(AppRoute(webPath: "/library/kind/photo") == nil)
        // 类型色块的落点：?g= 带 TMDB 类型 id，认不出的形状当没带
        #expect(AppRoute(webPath: "/library/kind/movie?g=878") == .libraryKind(kind: "movie", genre: 878))
        #expect(AppRoute(webPath: "/library/kind/tv?g=abc") == .libraryKind(kind: "tv"))
    }

    // MARK: 类型色块行（genres:movie / genres:tv），口径对照 test/home-rows.test.mjs 的同名用例

    @Test func genreRowsFollowLibrariesInDefaults() {
        let libs = [library(1, "movie"), library(2, "tv"), library(3, "tv")]
        let rows = HomeRows.build(prefs: [], libraries: libs, collections: [])
        #expect(Array(rows.map(\.id).prefix(5)) == ["up-next", "favorites", "libraries", "genres:movie", "genres:tv"])
        #expect(rows[3].title == "按类型找电影" && rows[4].title == "按类型找剧集")
        #expect(rows[4].meta == "内置 · 每个类型一格（2 个库）")
        #expect(!rows[3].removable)
        // 只有其他视频库：两条都不出现；剧集库全被排除出首页：剧集那条不出现
        #expect(!HomeRows.build(prefs: [], libraries: [library(9, "video")], collections: []).contains { $0.id.hasPrefix("genres:") })
        let tvExcluded = HomeRows.build(prefs: [], libraries: [library(1, "movie"), library(2, "tv", excluded: true)], collections: [])
        #expect(tvExcluded.map(\.id).filter { $0.hasPrefix("genres:") } == ["genres:movie"])
    }

    @Test func genreRowsInsertedAfterLibrariesOnUpgrade() {
        let libs = [library(1, "movie"), library(2, "tv"), library(3, "tv")]
        let rows = HomeRows.build(prefs: [pref("libraries"), pref("lib:2"), pref("up-next")], libraries: libs, collections: [])
        #expect(Array(rows.map(\.id).prefix(4)) == ["libraries", "genres:movie", "genres:tv", "lib:2"])
        // 一条库行都没存过时，新库的默认行排在类型色块行之后（与出厂布局同序）
        let bare = HomeRows.build(prefs: [pref("libraries"), pref("up-next")], libraries: libs, collections: [])
        #expect(Array(bare.map(\.id).prefix(6)) == ["libraries", "genres:movie", "genres:tv", "lib:1", "lib:2", "lib:3"])
    }

    @Test func genreRowsKeepSavedPlaceAndHidden() {
        let libs = [library(1, "movie"), library(2, "tv")]
        let prefs = [pref("genres:tv", hidden: true), pref("up-next"), pref("genres:movie")]
        let rows = HomeRows.build(prefs: prefs, libraries: libs, collections: [])
        #expect(Array(rows.map(\.id).prefix(3)) == ["genres:tv", "up-next", "genres:movie"])
        #expect(rows[0].hidden)
        // 写回只带 id 与 hidden（服务端不许内置行带排序或来源）
        let saved = HomeRows.toPrefs(Array(rows.prefix(3)))
        #expect(saved.map(\.id) == ["genres:tv", "up-next", "genres:movie"])
        #expect(saved[0].hidden == true && saved[0].sort == nil && saved[0].mediaKind == nil && saved[2].hidden == nil)
        // 这一类型的库都没了：存过的行静默消失
        #expect(!HomeRows.build(prefs: prefs, libraries: [library(1, "movie")], collections: []).contains { $0.id == "genres:tv" })
    }

    @Test func genreLabelsCoverEveryTmdbGenre() {
        #expect(GenreLabels.names.count == 27)
        #expect(GenreLabels.names[878] == "科幻")
        #expect(GenreLabels.names[10765] == "科幻奇幻")
        #expect(GenreLabels.names[999_999] == nil)
    }
}
