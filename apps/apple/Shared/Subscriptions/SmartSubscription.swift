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
        "\(resolutionLabel) \(["web-dl": "WEB-DL", "blu-ray": "蓝光", "remux": "Remux"][source] ?? source)"
    }
    var waitLabel: String {
        if waitSeconds == 0 { return "尽快下载" }
        if waitSeconds % 86400 == 0 { return "最多等 \(waitSeconds / 86400) 天" }
        return "最多等 \(waitSeconds / 3600) 小时"
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
        case "invalid_policy": return "智能设置无法读取，自动选择已暂停。"
        case "shadow": return "当前仅记录选择结果，尚未开启自动下载。"
        default: return "智能自动选择已关闭。已有下载和入库继续完成。"
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
        let s = ["web-dl": "WEB-DL", "blu-ray": "蓝光", "remux": "Remux"][source ?? ""] ?? (source ?? "")
        return "\(r) \(s)"
    }
    static func wait(_ seconds: Int) -> String {
        if seconds == 0 { return "尽快下载" }
        if seconds % 86400 == 0 { return "最多等 \(seconds / 86400) 天" }
        return "最多等 \(seconds / 3600) 小时"
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
            return ("观察中", "按你延长的时间继续等待合适版本")
        }
        switch reason {
        case "awaiting_subtitles": return ("等字幕", "已有 \(values["subtitle_blocked"].flatMap(\.intValue) ?? 1) 个原版，在等带字幕的版本")
        case "deadline_awaiting_subtitles": return ("等字幕", "等待期已过，仍没有字幕版；原版不会自动下载")
        case "identity_unconfirmed": return ("寻找中", "部分资源未通过影片身份核验，已跳过，继续寻找。")
        case "waiting_target": return ("等版本", "历史发布记录支持等待目标品质版本")
        case "waiting_series": return ("等版本", "已有合格候选，等待当前跟随版本")
        case "manual_requested": return ("选择中", "已请求立即下载，正在核验当前候选")
        case "manual_candidate_unavailable": return ("选择中", "指定候选已不可用，正在重新选择")
        case "reconciling": return ("待核对", "正在核对提交结果，系统会恢复同一任务")
        case "candidate_rejected": return ("寻找中", "所选资源无法提供这一集，已改为寻找其他资源")
        case "submitting": return ("提交中", "正在提交所选资源")
        case "deadline_fallback": return ("选择中", "等待上限已到，正在选择当前合格版本")
        case "published_window_elapsed": return ("选择中", "资源已发布一段时间，正在选择当前合格版本")
        case "observation_finished": return ("选择中", "观察结束，正在选择当前合格版本")
        case "target_available": return ("选择中", "目标版本已出现，正在选择")
        default: return ("观察中", "已有合格候选，短暂观察更合适的版本")
        }
    }
    var awaitingSubtitles: Bool { ["awaiting_subtitles", "deadline_awaiting_subtitles"].contains(self["reason"] ?? "") }
    var followingLabel: String? {
        guard let raw = self["following"] else { return nil }
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return raw }
        let source = ["1": "电视 / DVD", "2": "压制版", "3": "WEB-DL", "4": "蓝光", "5": "Remux", "6": "原盘"][parts[2]] ?? "未知片源"
        return "\(parts[0]) · \(parts[1]) · \(source)"
    }
}
