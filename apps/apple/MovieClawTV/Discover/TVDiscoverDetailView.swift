import SwiftUI

/// 发现里一部作品的详情（docs/design/tvos-app.md §3.1 / §3.2）：大剧照、片名、事实行、简介、主创，
/// 在库就「播放」/「查看」，不在库就**一键订阅**（电视上唯一的写操作，规则与入库库都用服务端默认），
/// 下面是相似推荐。
///
/// 先用列表带过来的字段（`DiscoverMediaSeed`）画出标题区，详情接口回来后整页替换（同 iPhone 版）。
struct TVDiscoverDetailView: View {
    let titleRef: String

    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(AppModel.self) private var model
    @Environment(TVRouter.self) private var router
    @State private var detail: API.DiscoveredTitleDetailsView?
    @State private var failed: String?
    @State private var subscribe = TVSubscribeAction()

    var body: some View {
        ZStack {
            backdrop
            if let detail {
                content(detail)
            } else if let failed {
                TVStateView(symbol: "exclamationmark.triangle", title: "加载失败", message: failed, actionTitle: "返回") { router.pop() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-discover-detail")
    }

    private var backdrop: some View {
        let raw = detail?.backdropOriginalUrl ?? DiscoverHeroImage.fullResolution(detail?.title.backdropUrl) ?? detail?.title.posterUrl
        return RemoteImage(url: api.image(raw))
            .overlay { LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing) }
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.4), .black], startPoint: .top, endPoint: .bottom) }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private func content(_ detail: API.DiscoveredTitleDetailsView) -> some View {
        let title = detail.title
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 50) {
                VStack(alignment: .leading, spacing: 22) {
                    Text(title.title)
                        .font(.system(size: 72, weight: .bold))
                        .lineLimit(2)
                        .shadow(radius: 12)
                        .accessibilityIdentifier("tv-discover-title")
                    if !title.originalTitle.isEmpty, title.originalTitle != title.title {
                        Text(title.originalTitle).font(.title3).foregroundStyle(.secondary)
                    }
                    Text(facts(detail).joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                    if !title.overview.isEmpty {
                        Text(title.overview)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(4)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }
                    let credits = (detail.metadata.directors.prefix(2).map { "导演 \($0)" } + [detail.metadata.cast.prefix(4).map(\.name).joined(separator: " · ")])
                        .filter { !$0.isEmpty }
                    if !credits.isEmpty {
                        Text(credits.joined(separator: "　"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    actions(detail)
                        .padding(.top, 10)
                    if let note = subscribe.note {
                        Label(note.text, systemImage: note.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(note.failed ? Theme.danger : Theme.success)
                            .accessibilityIdentifier("tv-discover-subscribe-note")
                    }
                }
                .padding(.horizontal, TVMetrics.edge)
                .frame(maxWidth: .infinity, minHeight: 820, alignment: .bottomLeading)
                .focusSection()

                if !detail.recommendations.isEmpty {
                    TVShelf(title: "相似推荐") {
                        ForEach(detail.recommendations, id: \.titleRef) { dto in
                            let item = DiscoverPosterItem(dto)
                            TVPosterCard(title: item.title, subtitle: item.year.map(String.init),
                                         imageURL: api.image(item.posterUrl, .posterCard),
                                         badge: item.libraryStatus != nil ? "已入库" : nil) {
                                DiscoverMediaSeed.remember(item)
                                router.push(.discoverTitle(item.resolvedTitleRef))
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
    }

    @ViewBuilder
    private func actions(_ detail: API.DiscoveredTitleDetailsView) -> some View {
        let link = detail.libraryLinks.first
        let isMovie = (detail.title.mediaType ?? TitleRefParts(titleRef).mediaType) == "movie"
        let existing = permissions.canSubscribe ? SubscriptionIndex.shared.subscription(
            source: detail.title.provider, externalId: detail.title.externalId,
            mediaType: detail.title.mediaType ?? TitleRefParts(titleRef).mediaType) : nil
        HStack(spacing: 28) {
            if let link {
                if isMovie {
                    Button { router.play(PlayRequest(mediaItemId: link.mediaItemId)) } label: {
                        Label("播放", systemImage: "play.fill").padding(.horizontal, 16)
                    }
                    .accessibilityIdentifier("tv-discover-play")
                }
                Button { router.push(.item(libraryId: link.libraryId, itemId: link.mediaItemId)) } label: {
                    Label(isMovie ? "在媒体库中查看" : "去看这部剧", systemImage: "play.rectangle.on.rectangle")
                }
                .accessibilityIdentifier("tv-discover-open-library")
            }
            // 电影已入库就不用再订（同 iPhone 版）；剧集在库也可能还在追新集
            if permissions.canSubscribe, !(isMovie && link != nil) || existing != nil {
                if let existing {
                    Button {} label: {
                        Label("已订阅 · \(SubscriptionStatusMeta.label(existing.status))", systemImage: "bookmark.fill")
                    }
                    .accessibilityIdentifier("tv-discover-subscribed")
                } else {
                    Button {
                        Task { await subscribe.run(titleRef: detail.title.titleRef, api: api, username: model.session?.username) }
                    } label: {
                        Label(subscribe.busy ? "正在订阅…" : "订阅", systemImage: "bookmark")
                    }
                    .disabled(subscribe.busy)
                    .accessibilityIdentifier("tv-discover-subscribe")
                }
            }
        }
    }

    private func facts(_ detail: API.DiscoveredTitleDetailsView) -> [String] {
        let title = detail.title
        let kind = (title.mediaType ?? TitleRefParts(titleRef).mediaType).map { $0 == "tv" ? "剧集" : "电影" }
        return [
            kind,
            title.releaseYear.map(String.init),
            title.providerRating > 0 ? "★ " + String(format: "%.1f", title.providerRating) : nil,
            title.extentLabel.isEmpty ? nil : title.extentLabel,
            title.genres.isEmpty ? nil : title.genres.prefix(3).joined(separator: " · "),
        ].compactMap { $0 }
    }

    private func load() async {
        if detail == nil, let seed = DiscoverMediaSeed.item(for: titleRef) {
            detail = API.DiscoveredTitleDetailsView(seed: seed)
        }
        if permissions.canSubscribe {
            await SubscriptionIndex.shared.ensureLoaded(api: api, owner: model.session?.username)
        }
        do {
            detail = try await api.discoverGetTitleDetails(titleRef: titleRef)
            failed = nil
        } catch {
            // 有预存的标题区时不打断页面
            if detail == nil { failed = error.localizedDescription }
        }
    }
}

/// 一键订阅（docs/design/tvos-app.md §3.2）：规则组与入库库交给服务端默认（成员的这两项服务端本来就忽略）；
/// 剧集要先问一次预览拿季信息——订已经播出的正片季，在播的剧顺便打开自动续订。
@Observable
final class TVSubscribeAction {
    struct Note: Equatable {
        var text: String
        var failed: Bool
    }

    private(set) var busy = false
    private(set) var note: Note?

    func run(titleRef: String, api: APIClient, username: String?) async {
        guard !busy else { return }
        busy = true
        note = nil
        defer { busy = false }
        do {
            let prep = try await api.uiSubscriptionsPreviewTitle(body: .init(titleRef: titleRef))
            if prep.existingSubscriptionId != nil {
                note = Note(text: "已经订阅过了", failed: false)
                await SubscriptionIndex.shared.refresh(api: api, owner: username)
                return
            }
            guard prep.status == "ready", let media = prep.media else {
                note = Note(text: prep.status == "ambiguous" ? "TMDB 上有多部同名作品，请在手机或网页上选择后订阅" : "TMDB 未收录该条目，暂时无法订阅",
                            failed: true)
                return
            }
            var seasons: [Int]?
            var follow: Bool?
            if media.kind == "tv" {
                let aired = !prep.suggestedSeasons.isEmpty ? prep.suggestedSeasons
                    : prep.seasons.filter { $0.seasonNumber > 0 && $0.airedCount > 0 }.map(\.seasonNumber)
                seasons = aired.sorted()
                // 还在播的剧追新集；一季都还没播出的剧也只能追新集（同 iPhone 订阅弹层的默认）
                follow = media.status == "Returning Series" || aired.isEmpty
            }
            _ = try await api.subscriptionsCreate(body: .init(
                titleRef: "tmdb:\(media.kind):\(media.tmdbId)",
                sourceTitleRef: titleRef.hasPrefix("douban:") ? titleRef : nil,
                selectedSeasons: seasons,
                followFuture: follow
            ))
            await SubscriptionIndex.shared.refresh(api: api, owner: username)
            note = Note(text: media.kind == "tv" ? "已订阅，新集会自动下载入库" : "已订阅，找到资源后会自动下载入库", failed: false)
        } catch {
            note = Note(text: error.localizedDescription, failed: true)
        }
    }
}
