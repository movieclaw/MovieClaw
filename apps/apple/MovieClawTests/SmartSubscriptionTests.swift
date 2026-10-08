import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct SmartSubscriptionTests {
    private func wanted(status: String = "wanted", state: [String: Any]? = nil) throws -> API.WantedView {
        var json: [String: Any] = [
            "id": 1, "season_number": 1, "episode_number": 1, "status": status,
            "priority": 1, "search_attempts": 0, "next_search_at": "2026-01-01T00:00:00Z",
        ]
        if let state { json["selection_state"] = state; json["selection_version"] = 12 }
        return try JSONDecoder().decode(API.WantedView.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func oldServerWantedRemainsReadableAndKeepsOriginalStatus() throws {
        let row = try wanted()
        #expect(row.selectionVersion == nil)
        #expect(SmartSelection(row) == nil)
        #expect(WantedLogic.presentation(row).label != "观察中")
    }

    @Test func smartStatesOnlyReplaceWaitingRowsWithActionableEvidence() throws {
        for reason in ["observing", "waiting_target", "waiting_series", "user_extended", "published_window_elapsed", "target_available"] {
            let row = try wanted(state: ["candidate_key": "site/1", "reason": reason])
            let state = try #require(SmartSelection(row))
            #expect(WantedLogic.presentation(row).label == state.presentation.label)
            #expect(WantedLogic.presentation(row).note == state.presentation.note)
            #expect(SmartSelection(try wanted(status: "imported", state: ["candidate_key": "site/1", "reason": reason])) == nil)
        }
        #expect(SmartSelection(try wanted(state: ["reason": "no_candidate"])) == nil)
        #expect(SmartSelection(try wanted(state: ["reason": "observing"])) == nil)
        #expect(SmartSelection(try wanted(state: ["reason": "reconciling"]))?.presentation.label == "待核对")
        #expect(SmartSelection(try wanted(state: ["reason": "submitting"]))?.presentation.label == "提交中")
        #expect(SmartSelection(try wanted(state: ["reason": "manual_candidate_unavailable"]))?.presentation.label == "选择中")
    }

    @Test func identityIssueIsInformationalAndUsesSearchMilestone() throws {
        let row = try wanted(state: ["reason": "identity_unconfirmed", "identity_explanation": "同名资源，缺少影片编号"])
        let state = try #require(SmartSelection(row))
        #expect(state.presentation.label == "寻找中")
        #expect(state.presentation.note.contains("已跳过"))
        #expect(state["candidate_key"] == nil)
        let chain = WantedLogic.milestones(row, isMovie: true, live: nil, failure: nil, isSmart: true)
        #expect(chain[1].why == nil)
        #expect(chain[1].detail == state.presentation.note)
    }

    @Test func userExtensionAndFollowingVersionMatchWeb() throws {
        let row = try wanted(state: ["candidate_key": "site/1", "reason": "waiting_target", "manual_extended": true, "following": "UBWEB|2160p|3"])
        let state = try #require(SmartSelection(row))
        #expect(state.presentation.note == "按你延长的时间继续等待合适版本")
        #expect(state.followingLabel == "UBWEB · 2160p · WEB-DL")
    }

    @Test func preferenceDefaultsAndWireContract() throws {
        #expect(SmartPreferences.defaults(kind: "tv").waitSeconds == 10800)
        #expect(SmartPreferences.defaults(kind: "movie").waitSeconds == 86400)
        for (seconds, label) in [(0, "尽快下载"), (10800, "最多等 3 小时"), (21600, "最多等 6 小时"), (86400, "最多等 1 天"), (604800, "最多等 7 天")] {
            let preferences = SmartPreferences(waitSeconds: seconds)
            #expect(preferences.waitLabel == label)
            let encoded = try JSONEncoder().encode(preferences)
            let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(json["wait_seconds"] as? Int == seconds)
            #expect(json["waitSeconds"] == nil)
            #expect(try JSONDecoder().decode(SmartPreferences.self, from: encoded) == preferences)
        }
    }

    @Test(.enabled(if: LiveServer.enabled)) func liveSubscriptionsAndProfilesDecode() async throws {
        let api = try await LiveServer.client()
        let subscriptions = try await api.subscriptionsList()
        #expect(!subscriptions.isEmpty)
        for sub in subscriptions {
            let detail = try await api.subscriptionsGet(subscriptionId: sub.id)
            if detail.isSmart {
                #expect(detail.ruleSetId == 0)
                #expect(detail.smartPreferences != nil || detail.smartStatus == "invalid_policy")
            }
        }
        for kind in ["movie", "tv"] {
            let profile = try await api.smartProfile(kind: kind)
            #expect(profile.kind == kind)
        }
    }

    @Test func waitActionsSendRevisionAndExactlyOneAction() throws {
        let now = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SmartWaitPayload(version: 12, candidateKey: "site/1"))) as! [String: Any]
        #expect(now["version"] as? Int == 12)
        #expect(now["candidate_key"] as? String == "site/1")
        #expect(now["extend_seconds"] == nil)
        let extend = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SmartWaitPayload(version: 13, extendSeconds: 7200))) as! [String: Any]
        #expect(extend["extend_seconds"] as? Int == 7200)
        #expect(extend["candidate_key"] == nil)
    }
}
