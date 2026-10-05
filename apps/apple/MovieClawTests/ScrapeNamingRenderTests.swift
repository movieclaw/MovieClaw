import Foundation
import Testing
@testable import MovieClaw

/// 命名模板预览渲染器（`SettingsBScrapeNaming.render`）与后端 `services/library/naming.py`
/// 的口径对拍：期望值由后端 `render` 对同一组输入算出，预览必须与真实落盘逐字一致。
struct ScrapeNamingRenderTests {
    private let movie: [String: String] = [
        "title": "沙丘：第二部", "original_title": "Dune: Part Two", "english_title": "Dune: Part Two",
        "year": "2024", "resolution": "2160p", "video_codec": "HEVC", "hdr": "DV", "bit_depth": "10bit",
        "audio": "TrueHD Atmos 7.1", "site": "hdsky",
        "release_name": "Dune.Part.Two.2024.2160p.BluRay.DV.HEVC.TrueHD.7.1.Atmos-FRDS",
    ]
    private let episode: [String: String] = [
        "title": "风筝", "original_title": "风筝", "english_title": "Kite", "year": "2017",
        "season": "1", "season_name": "第 1 季", "episode": "3", "episode_title": "延安来的姑娘",
        "resolution": "1080p", "site": "chdbits",
    ]

    @Test func titleTokensAreDeduplicated() {
        let tpl = "{title} ({original_title}) ({english_title}) ({year})"
        #expect(SettingsBScrapeNaming.render(tpl, movie) == "沙丘：第二部 (Dune Part Two) (2024)")
        #expect(SettingsBScrapeNaming.render(tpl, episode) == "风筝 (Kite) (2017)")
    }

    @Test func fileAttributesAndEmptyHdrCollapse() {
        #expect(
            SettingsBScrapeNaming.render(
                "{title} [{resolution} {video_codec} {hdr} {bit_depth} {audio}] [{site}] {release_name}", movie
            ) == "沙丘：第二部 [2160p HEVC DV 10bit TrueHD Atmos 7.1] [hdsky] Dune.Part.Two.2024.2160p.BluRay.DV.HEVC.TrueHD.7.1.Atmos-FRDS"
        )
        #expect(
            SettingsBScrapeNaming.render(
                "{title} - S{season:02d}E{episode:02d} - {episode_title} [{resolution} {hdr}] [{site}]", episode
            ) == "风筝 - S01E03 - 延安来的姑娘 [1080p] [chdbits]"
        )
        #expect(SettingsBScrapeNaming.render("Season {season:02d} {season_name}", episode) == "Season 01 第 1 季")
    }

    @Test func longNamesShrinkFreeTextFirst() {
        let ctx: [String: String] = [
            "title": String(repeating: "很长的剧名", count: 8), "year": "2017", "season": "1", "episode": "3",
            "episode_title": String(repeating: "非常非常长的集名", count: 10), "resolution": "2160p",
        ]
        let name = SettingsBScrapeNaming.render(
            "{title} ({year}) - S{season:02d}E{episode:02d} - {episode_title} [{resolution}]", ctx
        )
        #expect(name == String(repeating: "很长的剧名", count: 8) + " (2017) - S01E03 - 非常非常长的集名非常非常长的集名非 [2160p]")
        #expect(name.utf8.count <= 200)
    }
}
