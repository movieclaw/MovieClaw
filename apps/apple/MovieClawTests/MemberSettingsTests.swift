import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct MemberSettingsTests {
    private var member: API.MemberView {
        .init(id: 1, username: "family-user", nickname: "家人", status: "active",
              allowSubscribe: true, allowSearch: false, allowDirectDownload: true,
              allLibraries: true, libraryIds: [7, 42], allSites: false, siteIds: ["site-a"],
              contentAgeLimit: 12, allowUnrated: false, createdAt: "2026-10-01T00:00:00Z", deviceCount: 0)
    }

    @Test func searchMatchesNicknameOrUsernameAndTrimsWhitespace() {
        #expect(MemberPresentation.matching([member], search: " FAMILY-USER \n").count == 1)
        #expect(MemberPresentation.matching([member], search: "家人").count == 1)
        #expect(MemberPresentation.matching([member], search: "missing").isEmpty)
    }

    @Test func sectionUpdatesDoNotOverwriteOtherPermissions() throws {
        let profile = MemberEditSection.profile.update(member, libraries: [])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as! [String: Any]
        #expect(Set(json.keys) == ["nickname"])
        let permissions = MemberEditSection.permissions.update(member, libraries: [])
        #expect(permissions.allowDirectDownload == false, "搜索关闭时，下载必须关闭")
        #expect(permissions.libraryIds == nil)
        #expect(permissions.allSites == nil)
        #expect(permissions.contentAgeLimit == nil)
    }

    @Test func removingAgeLimitAndPreservingUnknownLibraryGrants() {
        var draft = member
        draft.contentAgeLimit = nil
        #expect(MemberEditSection.content.update(draft, libraries: []).contentAgeLimit == -1)
        let libraries = MemberEditSection.libraries.update(draft, libraries: [])
        #expect(libraries.libraryIds == [7, 42], "未出现在清单中的授权不能被静默删除")
        #expect(libraries.siteIds == nil)
        #expect(libraries.allowSearch == nil)
    }
}
