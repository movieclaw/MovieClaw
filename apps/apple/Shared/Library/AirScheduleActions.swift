import SwiftUI

/// 「订阅追更」在 Mac、Apple TV 上的样子：这两端没有 iPhone 那张能改选项的订阅弹层（`SubscribeSheet`），
/// 只确认一下同一套默认值（全部已播正季、在播剧自动续订、智能选择）就建好订阅，要改范围、品质到手机或网页。
struct QuickSubscribe: Equatable {
    let media: API.MediaBrief
    let seasons: [Int]
    let followFuture: Bool
    /// 智能选择摘要；服务器早于 0.42.0 时为空，按规则模式订阅（同 `SubscribeSheet`）
    let smart: API.SmartPlanView?

    init?(_ prepared: API.PrepareView) {
        guard prepared.status == "ready", let media = prepared.media else { return nil }
        self.media = media
        seasons = prepared.suggestedSeasons.isEmpty
            ? prepared.seasons.filter { $0.seasonNumber > 0 && $0.airedCount > 0 }.map(\.seasonNumber)
            : prepared.suggestedSeasons
        // 一季都还没播的（首季定档）只能从新集追起，否则这里没地方改选项，一步都订不了
        followFuture = media.status == "Returning Series" || seasons.isEmpty
        smart = prepared.smart
    }

    /// 「第 1 季、第 2 季」；超过三季写「已选 5 季」；一季都没选写「仅追新集」
    var scope: String {
        if seasons.isEmpty { return String(localized: .subscriptionSubscribeFutureOnly) }
        if seasons.count > 3 { return String(localized: .subscriptionSubscribeSelectedSeasons(seasons.count)) }
        return seasons.map(SubsFormat.seasonName).formatted(.list(type: .and, width: .narrow).locale(AppLanguage.locale))
    }

    var scopeNote: String {
        followFuture ? String(localized: .subscriptionSubscribeFollowDescription) : String(localized: .subscriptionSubscribeSelectedOnly)
    }

    /// 服务端解析好的整句：「优先 4K WEB-DL」「最多等 1 天 · 达标后停止洗版」「英语 · 只下带中文字幕的」
    var quality: [String] {
        guard let smart else { return [] }
        return [smart.qualityLabel, smart.waitLabel, smart.subtitleLine].compactMap { $0 }
    }

    /// 只有管理员能指定入库的库（成员的订阅走服务端路由）：从这部剧所在的库订，新集就进这个库
    func payload(libraryId: Int?) -> API.SubscriptionCreatePayload {
        let choice = smart.map { SmartChoice().payload(for: $0) }
        return API.SubscriptionCreatePayload(
            titleRef: "tmdb:\(media.kind):\(media.tmdbId)",
            selectedSeasons: seasons,
            followFuture: followFuture,
            libraryId: libraryId,
            selectionMode: smart == nil ? "rules" : "smart",
            smartProfileRevision: smart?.profileRevision,
            smartLanguageAnswer: choice?.language,
            smartResolution: choice?.resolution,
            smartSource: choice?.source,
            smartScope: choice?.scope,
            smartMemoryRevision: choice?.memoryRevision
        )
    }
}

/// 播出日历面板上的两个动作（Mac、Apple TV）：「补缺集」让缺口重新排队搜索、「订阅追更」确认默认值后建订阅。
/// 这两端没有全局提示，结果写在面板里（iPhone 走全局提示和订阅弹层，不用它）
@Observable
final class AirScheduleActions {
    enum Stage: Equatable {
        case idle, preparing
        case confirming(QuickSubscribe)
        case submitting(QuickSubscribe)
    }

    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    private(set) var stage = Stage.idle
    private(set) var searching = false
    private(set) var message: Message?

    /// 补缺集：返回有没有发出去（发出去了页面要重读日历）
    func findMissing(api: APIClient, schedule: API.SeasonAirScheduleView) async -> Bool {
        guard let id = schedule.subscriptionId, !searching else { return false }
        searching = true
        defer { searching = false }
        do {
            let result = try await api.subscriptionsSearchMissingResources(subscriptionId: id)
            message = Message(text: String(localized: .subscriptionInspectorRequeued(result.resetCount)), isError: false)
            return true
        } catch is CancellationError {
            return false
        } catch {
            message = Message(text: error.localizedDescription, isError: true)
            return false
        }
    }

    /// 按下「订阅追更」：先读预检，能订就进确认态，订不了把原因写出来
    func beginSubscribe(api: APIClient, tmdbId: Int) async {
        guard stage == .idle else { return }
        stage = .preparing
        message = nil
        do {
            let prepared = try await api.uiSubscriptionsPreviewTitle(body: .init(titleRef: "tmdb:tv:\(tmdbId)"))
            stage = .idle
            if prepared.existingSubscriptionId != nil {
                message = Message(text: String(localized: .subscriptionSubscribeExistingSeries), isError: false)
            } else if let smart = prepared.smart, !smart.configured {
                message = Message(text: smart.canEdit ? String(localized: .libraryItemAirSubscribeSetup) : String(localized: .subscriptionSmartAdminRequired), isError: true)
            } else if let draft = QuickSubscribe(prepared) {
                stage = .confirming(draft)
            } else {
                message = Message(text: String(localized: .subscriptionSubscribeNotFound), isError: true)
            }
        } catch is CancellationError {
            stage = .idle
        } catch {
            stage = .idle
            message = Message(text: error.localizedDescription.isEmpty ? String(localized: .subscriptionSubscribePrepareFailed) : error.localizedDescription, isError: true)
        }
    }

    func cancelSubscribe() {
        if case .confirming = stage { stage = .idle }
    }

    /// 确认订阅：返回成功与否（成功了页面要重读日历，入口随之消失）
    func confirmSubscribe(api: APIClient, libraryId: Int?) async -> Bool {
        guard case let .confirming(draft) = stage else { return false }
        stage = .submitting(draft)
        message = nil
        do {
            _ = try await api.subscriptionsCreate(body: draft.payload(libraryId: libraryId))
            stage = .idle
            message = Message(text: String(localized: .subscriptionSubscribeExistingSeries), isError: false)
            return true
        } catch is CancellationError {
            stage = .confirming(draft)
            return false
        } catch {
            stage = .confirming(draft)
            message = Message(text: error.localizedDescription.isEmpty ? String(localized: .subscriptionSubscribeCreateFailed) : error.localizedDescription, isError: true)
            return false
        }
    }
}
