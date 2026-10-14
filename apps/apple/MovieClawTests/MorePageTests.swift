import Testing
import Foundation
@testable import MovieClaw

struct MorePageTests {
    @Test func conversationPeriodsUseLocalCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 夏令时切换后的凌晨，昨天的 00:30 与现在仅相隔 23 小时。
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 30))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0, minute: 30))!
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 59))!
        #expect(MoreConversationPeriod.of(now, now: now, calendar: calendar) == .today)
        #expect(MoreConversationPeriod.of(yesterday, now: now, calendar: calendar) == .yesterday)
        #expect(MoreConversationPeriod.of(earlier, now: now, calendar: calendar) == .earlier)
        #expect(MoreConversationPeriod.of(nil, now: now, calendar: calendar) == .earlier)
    }

    @Test func administratorHasConversationsDownloadsAndServer() {
        #expect(MorePageSection.available(isAdmin: true, canDownload: true, hasDownloads: false, isOffline: false)
                == [.conversations, .downloads, .server])
    }

    @Test func membersNeverSeeConversations() {
        #expect(MorePageSection.available(isAdmin: false, canDownload: true, hasDownloads: false, isOffline: false)
                == [.downloads, .server])
        #expect(MorePageSection.available(isAdmin: false, canDownload: false, hasDownloads: false, isOffline: false)
                == [.server])
    }

    @Test func revokedDownloadPermissionStillAllowsExistingCopies() {
        #expect(MorePageSection.available(isAdmin: false, canDownload: false, hasDownloads: true, isOffline: false)
                == [.downloads, .server])
    }

    @Test func offlineOnlyOffersLocalDownloads() {
        for admin in [true, false] {
            #expect(MorePageSection.available(isAdmin: admin, canDownload: true, hasDownloads: false, isOffline: true)
                    == [.downloads])
            #expect(MorePageSection.available(isAdmin: admin, canDownload: false, hasDownloads: true, isOffline: true)
                    == [.downloads])
            #expect(MorePageSection.available(isAdmin: admin, canDownload: false, hasDownloads: false, isOffline: true).isEmpty)
        }
    }

    @Test func olderServersDoNotGainAnUnsupportedDownloadEntry() {
        #expect(MorePageSection.available(isAdmin: true, canDownload: false, hasDownloads: false, isOffline: false)
                == [.conversations, .server])
    }
}
