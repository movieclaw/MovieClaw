import Foundation
import XCTest
@testable import MovieClaw

nonisolated final class LocalizationTests: XCTestCase {
    func testBundleLanguageNormalization() {
        XCTAssertEqual(AppLanguage.normalize("zh-Hant"), "zh-Hans")
        XCTAssertEqual(AppLanguage.normalize("zh-TW"), "zh-Hans")
        XCTAssertEqual(AppLanguage.normalize("en-GB"), "en")
        XCTAssertEqual(AppLanguage.normalize("ja"), "en")
    }

    func testEnglishFormatting() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(AppFormatting.number(12345, locale: locale), "12,345")
        XCTAssertTrue(AppFormatting.duration(seconds: 4980, locale: locale).contains("hr"))
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(AppFormatting.relative(now.addingTimeInterval(-180), now: now, locale: locale), "3 minutes ago")
    }

    @MainActor func testEnglishTaskCenterLabelsAndSummaries() throws {
        func job(_ type: String, status: String = "succeeded", message: String = "", params: [String: Any]? = nil,
                 details: [String: Any] = [:], current: Int? = nil, total: Int? = nil) throws -> API.JobView {
            var progress: [String: Any] = ["mode": "determinate", "phase": "completed", "message": message, "details": details]
            progress["message_params"] = params
            progress["current"] = current
            progress["total"] = total
            let json: [String: Any] = [
                "id": "j1", "job_type": type, "job_type_label": NSNull(), "subject": NSNull(), "definition_version": 1,
                "handler_revision": "x", "status": status, "input_data": [:], "result": NSNull(), "error": NSNull(), "usage": [:],
                "progress": progress, "resources": [], "origin": "system", "attempt": 1, "max_attempts": 2, "revision": 1,
                "cancel_requested_by": NSNull(), "dismissed_at": NSNull(),
                "created_at": "2026-09-25T10:00:00+00:00", "updated_at": "2026-09-25T10:00:00+00:00",
            ]
            return try JSONDecoder().decode(API.JobView.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertEqual(TaskCenter.jobTypeLabel(try job("library.scan")), "Scan media library")
        // Structured titles replace the quote-scraping of Chinese progress messages; source titles stay raw.
        XCTAssertEqual(TaskCenter.historicalJobTitle(try job("library.ingest", message: "Imported", params: ["title": "深渊无间"])),
                       "“深渊无间” · Import completed")
        XCTAssertEqual(TaskCenter.historicalJobTitle(try job("acme:sync", status: "cancelled")), "acme:sync · cancelled")
        XCTAssertEqual(TaskCenter.cardProgressAmount(try job("library.scan", current: 1, total: 1)), "1 / 1 file")
        XCTAssertEqual(TaskCenter.feedProgressAmount(try job("library.scan", current: 3, total: 12)), "Processed 3 / 12 files")
        XCTAssertEqual(TaskCenter.jobDetailItems(try job("library.scan", details: ["identified": 3, "errors": [1]])).map(\.label),
                       ["3 identified", "1 issue"])
        XCTAssertEqual(TaskCenter.badge(TaskCenter.Activity()).hint, "No tasks running")
        XCTAssertEqual(ActivityFormat.duration(seconds: 5400), "1.5 hours")
        XCTAssertEqual(ActivityFormat.duration(seconds: 1), "1 second")
        XCTAssertEqual(ActivityFormat.watched(7_560_000), "2 hr 6 min")
        XCTAssertEqual(ActivityFormat.relative(nil), "Never")
    }

    func testEnglishPluralVariations() {
        XCTAssertEqual(String(localized: .commonInputMaxLength(1)), "Up to 1 character. Shorten the text to continue.")
        XCTAssertEqual(String(localized: .commonInputMaxLength(2)), "Up to 2 characters. Shorten the text to continue.")
    }

    @MainActor func testEnglishPlaybackLabelsAndParameters() {
        XCTAssertEqual(PlayerDisplayMode.fit.label, "Fit")
        XCTAssertEqual(QualityOption.all.first?.label, "Original")
        XCTAssertEqual(LanguageLabel.of("jpn"), "Japanese")
        XCTAssertEqual(PlaybackSpeed.label(1), "Normal")
        XCTAssertEqual(SkipSegments.label(.init(type: "intro", startMs: 0, endMs: 1000, toEnd: false)), "Skip intro")
        XCTAssertEqual(String(localized: .playerTracksChannels(1)), "1 channel")
        XCTAssertEqual(String(localized: .playerTracksChannels(3)), "3 channels")
        XCTAssertEqual(String(localized: .playerDiagnosticsProduced("seg00001", "seg00000", 1)), "Produced through seg00001 · Head seg00000 · 1 segment total")
        XCTAssertEqual(String(localized: .playerDiagnosticsBuffer(1.26)), "Buffered 1.3s")
        XCTAssertEqual(String(localized: .playerSubtitlesSignedOffset("+", 0.5)), "+0.5s")
    }

    func testEnglishNetworkAndValidationErrors() {
        XCTAssertEqual(ServerAddress.ParseError.empty.errorDescription, "Enter a server address")
        let refused = APIClient.networkMessage(URLError(.cannotConnectToHost))
        XCTAssertTrue(refused.contains("refused the connection"))
        XCTAssertTrue(refused.contains("error -1004"))
        let body = APIErrorBody(message: nil, code: nil, details: nil)
        XCTAssertEqual(body.userMessage(status: 503), "Request failed (HTTP 503)")
        let legacy = APIErrorBody(message: "Legacy server message", code: "LEGACY", details: nil)
        XCTAssertEqual(legacy.userMessage(status: 400), "Legacy server message")
    }

    func testCalibrationReferencesDecodeFromOldAndNewServers() throws {
        let legacy = try JSONDecoder().decode(API.CalibrateResultView.self, from: Data(#"{"ok":true,"message":"Legacy calibration"}"#.utf8))
        XCTAssertEqual(legacy.message, "Legacy calibration")
        XCTAssertNil(legacy.messageKey)
        XCTAssertNil(legacy.params)
        let keyed = try JSONDecoder().decode(API.CalibrateResultView.self, from: Data(#"{"ok":true,"message":"Calibrated","message_key":"library.subtitleCalibration.completed","params":{"reference":"Fixture","scale":1,"offset":1}}"#.utf8))
        XCTAssertEqual(keyed.messageKey, "library.subtitleCalibration.completed")
        XCTAssertEqual(keyed.params?["offset"], .int(1))
    }

    func testRuleAndSearchProvenanceRemainsOptionalAndPreservesRawNames() throws {
        let legacyRule = #"{"id":1,"name":"默认规则组","is_default":true,"spec":{},"match_rules":[],"reference_count":0}"#
        let legacy = try JSONDecoder().decode(API.RuleSetView.self, from: Data(legacyRule.utf8))
        XCTAssertEqual(legacy.name, "默认规则组")
        XCTAssertNil(legacy.nameKey)
        let keyedRule = legacyRule.replacingOccurrences(of: #""id":1"#, with: #""id":1,"name_key":"subscription.rules.defaultName""#)
        let keyed = try JSONDecoder().decode(API.RuleSetView.self, from: Data(keyedRule.utf8))
        XCTAssertEqual(keyed.name, legacy.name)
        XCTAssertEqual(keyed.nameKey, "subscription.rules.defaultName")
        let legacyHistory = #"{"id":1,"keyword":"原始片名","vertical":"torrents","label":"电影","categories":["movies"],"site_ids":[],"poster_mode":false,"search_count":1,"last_searched_at":"2026-10-24T00:00:00Z","has_snapshot":true}"#
        let history = try JSONDecoder().decode(API.SearchHistoryItem.self, from: Data(legacyHistory.utf8))
        XCTAssertNil(history.labelKey)
        let keyedHistory = legacyHistory.replacingOccurrences(of: #""id":1"#, with: #""id":1,"label_key":"search.categories.movie""#)
        let translated = try JSONDecoder().decode(API.SearchHistoryItem.self, from: Data(keyedHistory.utf8))
        XCTAssertEqual(translated.keyword, history.keyword)
        XCTAssertEqual(translated.labelKey, "search.categories.movie")
    }

    func testReaderSpecificPreviewsKeepLegacyDecodingAndStructuredQuestions() throws {
        let route = try JSONDecoder().decode(API.DispatchPreviewView.self, from: Data(#"{"mode":"inplace","ok":false,"warning":"Legacy warning"}"#.utf8))
        XCTAssertEqual(route.warning, "Legacy warning")
        XCTAssertNil(route.warningKey)
        XCTAssertNil(route.routeReasonParams)
        let match = try JSONDecoder().decode(API.LibrarySearchMatch.self, from: Data(#"{"type":"alias","source_field":"aliases","matched_name":"原始别名","label":"Name matched","label_key":"search.match.aliasReason","label_params":{"reason":"原始别名"}}"#.utf8))
        XCTAssertEqual(match.matchedName, "原始别名")
        XCTAssertEqual(match.labelParams?["reason"], .string("原始别名"))
        let oldPlan = #"{"configured":true,"profile_revision":1,"memory_revision":2,"scope_options":[],"can_edit":true}"#
        let legacy = try JSONDecoder().decode(API.SmartPlanView.self, from: Data(oldPlan.utf8))
        XCTAssertNil(legacy.subtitleEditQuestion)
        let planWithQuestion = oldPlan.replacingOccurrences(of: #""can_edit":true"#, with: #""can_edit":true,"subtitle_edit_question":{"language":"en","prompt":"Do you understand English?","subtitles_label":"Require Chinese subtitles","understood_label":"I understand English"}"#)
        let next = try JSONDecoder().decode(API.SmartPlanView.self, from: Data(planWithQuestion.utf8))
        XCTAssertEqual(next.profileRevision, legacy.profileRevision)
        XCTAssertEqual(next.subtitleEditQuestion?.language, "en")
        XCTAssertEqual(next.subtitleEditQuestion?.prompt, "Do you understand English?")
    }

    func testNetworkProbeReferencesRemainOptional() throws {
        let legacy = try JSONDecoder().decode(API.NetworkTestResult.self, from: Data(#"{"ok":true,"latency_ms":12,"message":"Legacy probe"}"#.utf8))
        XCTAssertNil(legacy.messageKey)
        XCTAssertNil(legacy.messageParams)
        let keyed = try JSONDecoder().decode(API.NetworkTestResult.self, from: Data(#"{"ok":true,"latency_ms":12,"message":"Connected (HTTP 503)","message_key":"settings.network.responses.http","message_params":{"status":503,"raw":"原始错误"}}"#.utf8))
        XCTAssertEqual(keyed.ok, legacy.ok)
        XCTAssertEqual(keyed.latencyMs, legacy.latencyMs)
        XCTAssertEqual(keyed.messageKey, "settings.network.responses.http")
        XCTAssertEqual(keyed.messageParams?["status"], .int(503))
        XCTAssertEqual(keyed.messageParams?["raw"], .string("原始错误"))
    }

    func testPortResetTargetPreservesLegacyDefault() throws {
        let oldJSON = #"{"external_url":"","web_port":18881,"web_port_source":"setting","web_port_default":3000,"web_port_rejected":null,"web_port_configurable":true}"#
        let legacy = try JSONDecoder().decode(API.AppConfigView.self, from: Data(oldJSON.utf8))
        XCTAssertNil(legacy.webPortResetTarget)
        let nextJSON = oldJSON.replacingOccurrences(of: #""web_port_default":3000"#, with: #""web_port_default":3000,"web_port_reset_target":18880"#)
        let next = try JSONDecoder().decode(API.AppConfigView.self, from: Data(nextJSON.utf8))
        XCTAssertEqual(next.webPortDefault, legacy.webPortDefault)
        XCTAssertEqual(next.webPort, legacy.webPort)
        XCTAssertEqual(next.webPortResetTarget, 18880)
    }

    func testEnglishStorageMessagesPreserveCountsAndOriginalNames() {
        XCTAssertEqual(String(localized: .settingsStorageUiOrphansTitle("原始目录")), "Clean orphan entries in “原始目录”?")
        XCTAssertEqual(String(localized: .settingsStorageUiClearBytes("2 KB")), "Clear and free 2 KB")
        XCTAssertEqual(String(localized: .settingsStorageCleaned("2 KB", "1")), "Freed 2 KB; entries removed: 1")
        XCTAssertEqual(String(localized: .settingsStorageCleanedSkipped("0 B", "0", "1")), "Freed 0 B; entries removed: 0; entries skipped while in use: 1")
        XCTAssertEqual(String(localized: .settingsStorageComputedUpdating("a few seconds ago")), "Calculated a few seconds ago · Updating")
    }

    @MainActor func testEnglishScheduleMessagesAndRawCronValues() {
        func task(_ seconds: Int, cron: String? = nil) -> API.ScheduledTaskView {
            .init(key: "raw", title: "Raw task", description: "Raw description", enabled: true,
                  triggerType: cron == nil ? "interval" : "cron",
                  intervalSeconds: cron == nil ? seconds : nil, cronExpr: cron)
        }
        XCTAssertEqual(SettingsSchedule.describe(task(1)), "Every 1 second")
        XCTAssertEqual(SettingsSchedule.describe(task(2)), "Every 2 seconds")
        XCTAssertEqual(SettingsSchedule.describe(task(60)), "Every 1 minute")
        XCTAssertEqual(SettingsSchedule.describe(task(120)), "Every 2 minutes")
        XCTAssertEqual(SettingsSchedule.describe(task(3600)), "Every 1 hour")
        XCTAssertEqual(SettingsSchedule.describe(task(7200)), "Every 2 hours")
        XCTAssertEqual(SettingsSchedule.describe(task(3_600_000)), "Every 1,000 hours")
        XCTAssertEqual(SettingsSchedule.describe(task(0)), "Interval not set")
        let daily = task(0, cron: "5 4 * * *")
        XCTAssertEqual(SettingsSchedule.describe(daily), "Daily at 04:05")
        XCTAssertEqual(daily.cronExpr, "5 4 * * *")
        XCTAssertEqual(SettingsSchedule.describe(task(0, cron: "0 4 * * 1")), "cron: 0 4 * * 1")
    }

    private func duplicateFile(id: Int = 1, qualityKey: String? = nil,
                               originKey: String? = nil, label: String = "Same display label") throws -> API.DuplicateFileView {
        var data: [String: Any] = [
            "id": id, "file_name": "Fixture.mkv", "file_path": "/fixture/Fixture.mkv",
            "quality_label": label, "size_bytes": 1024,
            "audio_label": "AAC 2.0", "origin": ["kind": "author", "label": label],
            "version_key": "raw-version-\(id)", "suggested": id == 1,
        ]
        if let qualityKey { data["quality_key"] = qualityKey }
        if let originKey { data["origin_key"] = originKey }
        return try JSONDecoder().decode(API.DuplicateFileView.self,
                                        from: JSONSerialization.data(withJSONObject: data))
    }

    @MainActor func testDuplicateLegacyDecodeAndOriginalKeys() throws {
        let old = try duplicateFile()
        XCTAssertNil(old.qualityKey)
        XCTAssertNil(old.originKey)
        let file = try duplicateFile(qualityKey: "2160p WEB-DL", originKey: "author-source")
        XCTAssertEqual(file.qualityKey, "2160p WEB-DL")
        XCTAssertEqual(file.originKey, "author-source")
        XCTAssertEqual(file.versionKey, "raw-version-1")
        XCTAssertEqual(file.origin.label, "Same display label")
    }

    @MainActor func testDuplicateEqualLabelsKeepDifferentSourceFacts() throws {
        let a = try duplicateFile(qualityKey: "2160p WEB-DL", originKey: "source-A")
        let b = try duplicateFile(id: 2, qualityKey: "1080p WEB-DL", originKey: "source-B")
        let shared = ManageDupText.sharedFacts([a, b])
        XCTAssertNil(shared.quality)
        XCTAssertNil(shared.origin)
        func version(_ key: String) throws -> API.DuplicateVersionView {
            let data: [String: Any] = ["key": key, "quality_label": "1080p WEB-DL",
                                     "origin_label": "Same label", "origin_key": key,
                                     "episodes": [1], "bytes": 1024, "suggested": true]
            return try JSONDecoder().decode(API.DuplicateVersionView.self,
                                            from: JSONSerialization.data(withJSONObject: data))
        }
        XCTAssertNil(ManageDupText.sharedVersionOrigin(try [version("A"), version("B")]))
    }

    @MainActor func testDuplicateUnknownSpecificationUsesOriginalDifferences() throws {
        let unknown = try duplicateFile(qualityKey: "未知规格", label: "Unknown specifications")
        let reference = try duplicateFile(id: 2, qualityKey: "1080p WEB-DL")
        let segments = ManageDupText.specSegments(unknown, reference: reference)
        XCTAssertEqual(segments[0].text, "Unknown specifications")
        XCTAssertTrue(segments[0].diff)
        XCTAssertFalse(segments[1].diff)
    }

    @MainActor func testEnglishSettingsSummaries() {
        let setting = API.MetadataScrapeSetting(
            languagePriority: [], certCountryPriority: [], posterMode: "default",
            posterLanguagePriority: [], backdropLanguagePriority: [],
            posterMinWidth: 0, backdropMinWidth: 1920, posterSize: "", backdropSize: "",
            stillSize: "", profileSize: "", imageQuality: "",
            logoLanguagePriority: [], fanartEnabled: false,
            posterSourceOrder: [], backdropSourceOrder: [], logoSourceOrder: [], seasonPosterSourceOrder: [],
            namingEntryDir: "", namingMovieFile: "", namingSeasonDir: "", namingEpisodeFile: "",
            mirrorImages: false, mirrorNfo: false, mirrorEpisodeThumbs: false
        )
        XCTAssertEqual(SettingsBScrapeSummary.quality(setting), "Quality: original · No poster width limit · Backdrop ≥1920")
    }

    @MainActor func testEnglishSubscriptionCopy() throws {
        XCTAssertEqual(SubsFormat.seasonList([2, 1]), "Seasons 1, 2")
        XCTAssertEqual(SubsFormat.seasonList([3]), "Season 3")
        let timing = try JSONDecoder().decode(API.ResourceTimingView.self, from: JSONSerialization.data(withJSONObject: [
            "site_id": "mteam", "torrent_id": "1", "submitted_at": "2026-01-01T00:00:00Z",
            "publish_to_submit_seconds": 150, "dry_run": false,
        ]))
        XCTAssertEqual(WantedLogic.resourceTimingNote(timing, previous: true), "Previous · mteam: submitted to downloader 2 min, 30 sec after release")
        XCTAssertEqual(SubscriptionsHome.weekday(of: "2026-09-26"), "Sat")
    }

    @MainActor func testEnglishAgentAndLibraryCopy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 23, minute: 59)))
        let label = AgentTimeline.groupTime(earlier, now: now, calendar: calendar)
        XCTAssertTrue(label.contains("Oct") && !label.contains("月"), label)
        XCTAssertEqual(String(localized: .libraryRatingAtLeast(9)), "Rated 9+")
        XCTAssertEqual(String(localized: .libraryPositionOfTotal(3, 120)), "3 of 120")
    }

    @MainActor func testEnglishWelcomeQuotes() throws {
        XCTAssertEqual(WelcomeScene.all.count, 68)
        let casablanca = try XCTUnwrap(WelcomeScene.all.first { $0.film == "卡萨布兰卡" })
        XCTAssertEqual(casablanca.headline, "We'll always have Paris.")
        XCTAssertNil(casablanca.subline)
        XCTAssertEqual(casablanca.source, "Casablanca, 1942")
        let bullets = try XCTUnwrap(WelcomeScene.all.first { $0.film == "让子弹飞" })
        XCTAssertEqual(bullets.headline, "Let the bullets fly a while.")
        XCTAssertEqual(bullets.subline, "让子弹飞一会儿。")
    }

    @MainActor func testEnglishShellAndShareCopy() {
        XCTAssertEqual(ShareLinkKit.copyText(title: "Dune", url: "https://x/s/1", password: "abcd"),
                       "“Dune” Link: https://x/s/1 Password: abcd")
        XCTAssertEqual(MoreConversationPeriod.earlier.label, "Earlier")
        XCTAssertEqual(APIError.http(status: 503, message: "x", code: nil, messageKey: "errors.playback.transcodeLimit").messageKey,
                       "errors.playback.transcodeLimit")
        XCTAssertTrue(ReelPlayer.isTranscodeLimit(.http(status: 503, message: "All transcoding slots are in use", code: nil,
                                                        messageKey: "errors.playback.transcodeLimit")))
        XCTAssertTrue(ReelPlayer.isTranscodeLimit(.http(status: 503, message: "当前转码会话已满（2/2）", code: nil)))
    }

    @MainActor func testEnglishSearchAndOfflineCopy() {
        XCTAssertEqual(OfflineDownloader.transcodeWaitNote(wait: "queue", ahead: 2), "Waiting to transcode; 2 ahead")
        XCTAssertEqual(OfflineDownloader.transcodeWaitNote(wait: "transcoder", ahead: 0), "Waiting for a free transcoder")
        XCTAssertEqual(TorrentSearchLogic.elapsedText(1234), "1.2 s")
    }

}
