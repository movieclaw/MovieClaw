import Foundation
import Testing
@testable import MovieClaw

/// 首页行清单的合并规则（`HomeRows`），口径对照 Web `lib/home-rows.ts` 与 `test/home-rows.test.mjs`。
/// 两端共用同一份 `home.rows` 偏好，这里重点守「按类型的跨库行」（§8）：iOS 不认识 `kind:` / `media_kind`
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

    private func pref(_ id: String, sort: String? = nil, unwatched: Bool? = nil, hidden: Bool? = nil, libraryId: Int? = nil, mediaKind: String? = nil) -> API.HomeRowPref {
        API.HomeRowPref(id: id, sort: sort, unwatched: unwatched, hidden: hidden, libraryId: libraryId, mediaKind: mediaKind)
    }

    private func visibleIds(_ rows: [HomeRows.Row]) -> [String] { rows.filter { !$0.hidden }.map(\.id) }

    @Test func defaultsShowKindRowOnlyWithTwoLibraries() {
        // 两个电影库、一个剧集库、一个被排除首页的剧集库：电影行显示，剧集行生成但隐藏（只有一个库，与库行重复）
        let libs = [library(1, "movie"), library(2, "movie"), library(3, "tv"), library(4, "tv", excluded: true)]
        let rows = HomeRows.build(prefs: [], libraries: libs, collections: [])
        #expect(rows.map(\.id) == ["up-next", "favorites", "libraries", "kind:movie", "kind:tv", "lib:1", "lib:2", "lib:3"])
        #expect(visibleIds(rows).contains("kind:movie"))
        #expect(!visibleIds(rows).contains("kind:tv"))
        #expect(rows.first { $0.id == "kind:movie" }?.title == "全部电影 · 最近添加")
        // 照片库不做类型行
        #expect(!HomeRows.build(prefs: [], libraries: [library(5, "photo"), library(6, "photo")], collections: []).contains { $0.id.hasPrefix("kind:") })
    }

    @Test func savedKindRowsRoundTrip() {
        let libs = [library(1, "movie"), library(2, "movie"), library(3, "tv")]
        let prefs = [
            pref("kind:movie", sort: "rating", unwatched: true),
            pref("row:k1", sort: "random", mediaKind: "tv"),
            pref("lib:1"),
        ]
        let rows = HomeRows.build(prefs: prefs, libraries: libs, collections: [])
        // 没存过的默认剧集行（kind:tv）补在第一条库行前面，只有一个剧集库所以隐藏
        #expect(Array(rows.map(\.id).prefix(4)) == ["kind:movie", "row:k1", "kind:tv", "lib:1"])
        #expect(rows[2].hidden)
        guard case let .mediaKind(kind, members, sort, _, unwatched, _, builtin) = rows[0].kind else { Issue.record("kind:movie 没解析成类型行"); return }
        #expect(kind == "movie" && members.map(\.id) == [1, 2] && sort == "rating" && unwatched && builtin)
        #expect(rows[1].removable && rows[1].title == "全部剧集 · 随便看看")

        // 写回：默认类型行不带来源，自加类型行必须带 media_kind（丢了它，服务端会拒、网页加的行也就没了）
        let saved = HomeRows.toPrefs(rows)
        #expect(saved[0].mediaKind == nil && saved[0].sort == "rating" && saved[0].unwatched == true)
        #expect(saved[1].mediaKind == "tv" && saved[1].libraryId == nil && saved[1].collectionId == nil)
    }

    @Test func missingKindRowsInsertBeforeLibraryRows() {
        // 升级前存的清单里没有类型行：补在第一条库行前面，显隐按出厂规则
        let libs = [library(1, "movie"), library(2, "movie")]
        let rows = HomeRows.build(prefs: [pref("lib:2"), pref("up-next"), pref("lib:1")], libraries: libs, collections: [])
        #expect(rows.map(\.id) == ["kind:movie", "lib:2", "up-next", "lib:1", "favorites", "libraries"])
    }

    @Test func kindRowDisappearsWithoutMembers() {
        // 这一类型的库全被排除首页：存过的默认行与自加行都静默消失
        let libs = [library(1, "movie", excluded: true), library(2, "tv")]
        let rows = HomeRows.build(prefs: [pref("kind:movie"), pref("row:x", mediaKind: "movie")], libraries: libs, collections: [])
        #expect(!rows.contains { $0.id == "kind:movie" || $0.id == "row:x" })
        // 不可见的库也不算成员
        let hidden = HomeRows.build(prefs: [], libraries: [library(1, "movie"), library(2, "movie", access: false)], collections: [])
        #expect(hidden.first { $0.id == "kind:movie" }?.hidden == true)
    }

    @Test func lastPlayedClearsUnwatched() {
        let rows = HomeRows.build(prefs: [pref("kind:movie", sort: "last_played", unwatched: true)], libraries: [library(1, "movie")], collections: [])
        guard case let .mediaKind(_, _, _, _, unwatched, _, _) = rows[0].kind else { Issue.record("不是类型行"); return }
        #expect(!unwatched)
    }

    @Test func kindWallWebPathParses() {
        #expect(AppRoute(webPath: "/library/kind/movie") == .libraryKind(kind: "movie"))
        #expect(AppRoute(webPath: "/library/kind/photo") == nil)
    }
}
