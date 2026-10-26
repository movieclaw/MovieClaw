import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct ExternalMediaLinkTests {
    @Test(arguments: [
        "https://movie.douban.com/subject/1292052/",
        "https://m.douban.com/movie/subject/1292052/?from=movieclaw",
    ])
    func installedDoubanOpensOnlyApp(_ address: String) async throws {
        var opened: [URL] = []
        await ExternalMediaLink.open(try #require(URL(string: address))) {
            opened.append($0)
            return true
        }
        #expect(opened.map(\.absoluteString) == ["douban://douban.com/movie/1292052"])
    }

    @Test func unavailableDoubanFallsBackToSameSubject() async throws {
        let webpage = try #require(URL(string: "https://movie.douban.com/subject/1292052/"))
        var opened: [URL] = []
        await ExternalMediaLink.open(webpage) {
            opened.append($0)
            return $0.scheme == "https"
        }
        #expect(opened.map(\.absoluteString) == ["douban://douban.com/movie/1292052", webpage.absoluteString])
    }

    @Test(arguments: [
        "https://www.themoviedb.org/movie/278",
        "https://www.themoviedb.org/tv/1399",
        "https://www.imdb.com/title/tt0111161/",
        "https://movie.douban.com/subject/not-an-id/",
        "https://movie.douban.com/subject/１２３/",
        "https://movie.douban.com/subject/1292052/reviews/",
        "https://movie.douban.com.evil.example/subject/1292052/",
    ])
    func otherLinksUseOriginalURL(_ address: String) async throws {
        let webpage = try #require(URL(string: address))
        var opened: [URL] = []
        await ExternalMediaLink.open(webpage) {
            opened.append($0)
            return true
        }
        #expect(opened == [webpage])
    }
}
