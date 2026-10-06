import Foundation
import Testing
@testable import MovieClaw

struct OpenSourceDependencyTests {
    @Test @MainActor func engineSourcePointsAtAnImmutableForkCommit() throws {
        let engine = try #require(OpenSourceComponent.all.first { $0.name.hasPrefix("AetherEngine") })
        let url = try #require(URL(string: engine.source))
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path.hasPrefix("/yipengfei329/AetherEngine/tree/"))
        #expect(url.lastPathComponent.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil)
    }

    @Test @MainActor func engineLicensesAreDistributedWithTheApp() throws {
        let engine = try #require(OpenSourceComponent.all.first { $0.name.hasPrefix("AetherEngine") })
        for name in engine.licenseFiles {
            let url = try #require(Bundle.main.url(forResource: name, withExtension: "txt"))
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.count > 1_000)
        }
    }
}
