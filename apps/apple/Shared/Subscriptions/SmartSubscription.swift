import Foundation

/// 智能接口返回未声明 schema 的 JSON；在客户端保留明确的类型与 snake_case 契约。
nonisolated struct SmartPreferences: Codable, Hashable, Sendable {
    var resolution = "2160p"
    var source = "web-dl"
    var waitSeconds = 10800
    var allowUpgrade = true
    var strictResolution = false

    enum CodingKeys: String, CodingKey {
        case resolution, source
        case waitSeconds = "wait_seconds"
        case allowUpgrade = "allow_upgrade"
        case strictResolution = "strict_resolution"
    }

    var resolutionLabel: String { resolution == "2160p" ? "4K" : "1080p" }
    var targetLabel: String {
        "\(resolutionLabel) \(["web-dl": "WEB-DL", "blu-ray": String(localized: .subscriptionSmartBluray), "remux": "Remux"][source] ?? source)"
    }
    var waitLabel: String {
        if waitSeconds == 0 { return String(localized: .subscriptionSmartAsap) }
        if waitSeconds % 86400 == 0 { return String(localized: .subscriptionSmartWaitDays(waitSeconds / 86400)) }
        return String(localized: .subscriptionSmartWaitHours(waitSeconds / 3600))
    }
    static func defaults(kind: String) -> Self { .init(waitSeconds: kind == "movie" ? 86400 : 10800) }
}

nonisolated struct SmartProfile: Codable, Sendable {
    let kind: String
    let revision: Int
    let preferences: SmartPreferences?
}

nonisolated struct SmartProfilePayload: Encodable, Sendable {
    let revision: Int
    let preferences: SmartPreferences
}

nonisolated struct SmartWaitPayload: Encodable, Sendable {
    let version: Int
    var extendSeconds: Int?
    var candidateKey: String?
    enum CodingKeys: String, CodingKey {
        case version
        case extendSeconds = "extend_seconds"
        case candidateKey = "candidate_key"
    }
}

nonisolated extension APIClient {
    func smartProfile(kind: String) async throws -> SmartProfile {
        try await send("GET", "/subscriptions/smart-profiles/\(kind)")
    }
    func saveSmartProfile(kind: String, body: SmartProfilePayload) async throws -> SmartProfile {
        try await send("PUT", "/subscriptions/smart-profiles/\(kind)", body: body)
    }
    func changeSmartWait(subscriptionId: Int, wantedId: Int, body: SmartWaitPayload) async throws {
        let _: API.JSONValue = try await send("POST", "/subscriptions/\(subscriptionId)/wanted/\(wantedId)/smart-wait", body: body)
    }
}

nonisolated extension API.SubscriptionDetailView {
    var isSmart: Bool { selectionMode == "smart" }
    var smartPreferences: SmartPreferences? {
        guard let smartPolicy, let data = try? JSONEncoder().encode(smartPolicy) else { return nil }
        return try? JSONDecoder().decode(SmartPreferences.self, from: data)
    }
    var smartNotice: String? {
        guard isSmart, let smartStatus, smartStatus != "active" else { return nil }
        switch smartStatus {
        case "invalid_policy": return String(localized: .subscriptionSmartStatusInvalidPolicy)
        case "shadow": return String(localized: .subscriptionSmartStatusShadow)
        default: return String(localized: .subscriptionSmartStatusDisabled)
        }
    }
}

/// 订阅弹层里管理员做的选择（字幕回答、改过的画质与记住的范围），随创建请求提交，由服务端写入记忆。
nonisolated struct SmartChoice: Hashable, Sendable {
    var language: String?
    var resolution: String?
    var source: String?
    var scope = "only"

    /// 题目出现时即使没改也回传默认答案：答过就不再问。成员不能写记忆，什么都不带。
    func payload(for plan: API.SmartPlanView) -> (language: String?, resolution: String?, source: String?, scope: String?, memoryRevision: Int?) {
        guard plan.canEdit else { return (nil, nil, nil, nil, nil) }
        let language = language ?? (plan.question != nil ? "subtitles" : nil)
        let resolution = resolution.flatMap { $0 == plan.resolution ? nil : $0 }
        let source = source.flatMap { $0 == plan.source ? nil : $0 }
        return (language, resolution, source, resolution != nil || source != nil ? scope : nil, plan.memoryRevision)
    }

    func qualityChanged(_ plan: API.SmartPlanView) -> Bool {
        (resolution ?? plan.resolution) != plan.resolution || (source ?? plan.source) != plan.source
    }
}

nonisolated enum SmartLabels {
    static func quality(resolution: String?, source: String?) -> String {
        let r = resolution == "2160p" ? "4K" : (resolution ?? "")
        let s = ["web-dl": "WEB-DL", "blu-ray": String(localized: .subscriptionSmartBluray), "remux": "Remux"][source ?? ""] ?? (source ?? "")
        return "\(r) \(s)"
    }
    static func wait(_ seconds: Int) -> String {
        if seconds == 0 { return String(localized: .subscriptionSmartAsap) }
        if seconds % 86400 == 0 { return String(localized: .subscriptionSmartWaitDays(seconds / 86400)) }
        return String(localized: .subscriptionSmartWaitHours(seconds / 3600))
    }
}

/// 只呈现服务器已作出的决策；没有合格候选时继续使用原有未播出 / 搜索状态。
nonisolated struct SmartSelection {
    let values: [String: API.JSONValue]
    init?(_ wanted: API.WantedView) {
        guard wanted.status == "wanted", let state = wanted.selectionState else { return nil }
        let reason = state["reason"]?.stringValue ?? ""
        guard state["candidate_key"]?.stringValue != nil || ["identity_unconfirmed", "manual_candidate_unavailable", "reconciling", "submitting"].contains(reason) else { return nil }
        values = state
    }
    subscript(_ key: String) -> String? { values[key]?.stringValue }
    var presentation: (label: String, note: String) {
        let reason = self["reason"] ?? ""
        if reason == "user_extended" || (values["manual_extended"]?.boolValue == true && ["observing", "waiting_target", "waiting_series"].contains(reason)) {
            return (String(localized: .subscriptionSmartObserving), String(localized: .subscriptionSmartExtended))
        }
        switch reason {
        case "awaiting_subtitles":
            let count = values["subtitle_blocked"].flatMap(\.intValue) ?? 1
            return (String(localized: .subscriptionSmartWaitingSubtitles), String(localized: .subscriptionSmartSubtitleCandidates(count)))
        case "deadline_awaiting_subtitles": return (String(localized: .subscriptionSmartWaitingSubtitles), String(localized: .subscriptionSmartSubtitleDeadline))
        case "identity_unconfirmed": return (String(localized: .subscriptionSmartSearching), String(localized: .subscriptionSmartIdentityUnconfirmed))
        case "waiting_target": return (String(localized: .subscriptionSmartWaitingVersion), String(localized: .subscriptionSmartWaitingTarget))
        case "waiting_series": return (String(localized: .subscriptionSmartWaitingVersion), String(localized: .subscriptionSmartWaitingSeries))
        case "manual_requested": return (String(localized: .subscriptionSmartSelecting), String(localized: .subscriptionSmartManualRequested))
        case "manual_candidate_unavailable": return (String(localized: .subscriptionSmartSelecting), String(localized: .subscriptionSmartCandidateUnavailable))
        case "reconciling": return (String(localized: .subscriptionSmartReconciling), String(localized: .subscriptionSmartReconcileNote))
        case "candidate_rejected": return (String(localized: .subscriptionSmartSearching), String(localized: .subscriptionSmartCandidateRejected))
        case "submitting": return (String(localized: .subscriptionSmartSubmitting), String(localized: .subscriptionSmartSubmitNote))
        case "deadline_fallback": return (String(localized: .subscriptionSmartSelecting), String(localized: .subscriptionSmartDeadlineFallback))
        case "published_window_elapsed": return (String(localized: .subscriptionSmartSelecting), String(localized: .subscriptionSmartPublishedWindowElapsed))
        case "observation_finished": return (String(localized: .subscriptionSmartSelecting), String(localized: .subscriptionSmartObservationFinished))
        case "target_available": return (String(localized: .subscriptionSmartSelecting), String(localized: .subscriptionSmartTargetAvailable))
        default: return (String(localized: .subscriptionSmartObserving), String(localized: .subscriptionSmartObserveNote))
        }
    }
    var awaitingSubtitles: Bool { ["awaiting_subtitles", "deadline_awaiting_subtitles"].contains(self["reason"] ?? "") }
    var followingLabel: String? {
        guard let raw = self["following"] else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return raw }
        let source = ["1": String(localized: .subscriptionSmartStatusSourceTv), "2": String(localized: .subscriptionSmartStatusSourceEncode), "3": "WEB-DL", "4": String(localized: .subscriptionSmartBluray), "5": "Remux", "6": String(localized: .subscriptionSmartStatusSourceDisc)][parts[2]] ?? String(localized: .subscriptionSmartStatusSourceUnknown)
        return "\(parts[0]) · \(parts[1]) · \(source)"
    }
}
