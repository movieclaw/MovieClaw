import Testing
@testable import MovieClaw

/// 欢迎页台词表从 WelcomeQuotes.json 读入；中文界面仍是中文台词 + 外语原句 + 《片名》年份
@MainActor
struct WelcomeSceneTests {
    @Test func chineseQuotesKeepOriginalLayout() throws {
        #expect(WelcomeScene.all.count == 68)
        #expect(Set(WelcomeScene.all.map(\.id)).count == WelcomeScene.all.count)
        let casablanca = try #require(WelcomeScene.all.first { $0.film == "卡萨布兰卡" })
        #expect(casablanca.headline == "我们永远拥有巴黎。")
        #expect(casablanca.subline == "We'll always have Paris.")
        #expect(casablanca.source == "《卡萨布兰卡》1942")
        let bullets = try #require(WelcomeScene.all.first { $0.film == "让子弹飞" })
        #expect(bullets.subline == nil)
    }
}
