import NukeUI
import SwiftUI

/// 条目详情（docs/design/tvos-app.md §3.1）：大剧照铺满全屏，左侧片名 Logo、事实行、简介与操作；
/// 剧集往下是选季与分集横排。
///
/// 与 iPhone 版同一套数据：`libraryItemsGet` 拿详情、`playbackResume` 拿续播点（主按钮三态：播放 / 继续 mm:ss /
/// 重新播放）、`librarySetMarks` 收藏与标记已看。电视上不做任何管理操作（修正识别、换图、删除……都在手机和网页上）。
/// 播放器关掉、服务端收下「停止」后（`.playbackStopReported`）重拉续播点与分集进度，按钮立刻跟上刚才看到的位置。
struct TVItemDetailView: View {
    let libraryId: Int
    let itemId: Int

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router

    @State private var detail: API.LibraryItemDetailView?
    @State private var failed = false
    @State private var season: Int?
    @State private var episodes: [API.EpisodeView] = []
    @State private var selectedEpisode: API.EpisodeView?
    @State private var watched: API.PlaybackStateView?
    @State private var favorite: Bool?
    @State private var marking = false

    private var isMovie: Bool { detail?.kind != "tv" }

    var body: some View {
        Group {
            if failed {
                TVStateView(symbol: "questionmark.folder", title: "未能加载该条目",
                            message: "条目可能已被删除或重新识别为其他作品。", actionTitle: "返回") { router.pop() }
            } else if let detail {
                content(detail)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background { backdrop }
        .task { await reload() }
        .task { favorite = (try? await api.playbackMarksGet(mediaItemId: itemId))?.isFavorite }
        // 进了详情页多半要播：先把起播要用的连接连好（同 iPhone 版）
        .task { PlaybackPreconnect.warm(api: api) }
        .task(id: unitKey) { await loadResume() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopReported)) { note in
            guard note.userInfo?["mediaItemId"] as? Int == itemId else { return }
            Task {
                await loadResume(keepCurrent: true)
                if let season { await loadEpisodes(season, keepSelection: true) }
            }
        }
        .accessibilityIdentifier("tv-item-\(itemId)")
    }

    // MARK: 页面

    private var backdrop: some View {
        RemoteImage(url: api.image(detail?.backdropUrl ?? detail?.posterUrl))
            .overlay {
                LinearGradient(colors: [.black.opacity(0.9), .black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.4), .black], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    private func content(_ detail: API.LibraryItemDetailView) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 50) {
                header(detail)
                    // 第一屏只有头部：剧照露出大半，往下滑才是分集
                    .frame(minHeight: 820, alignment: .bottomLeading)
                if !isMovie, !detail.seasons.isEmpty {
                    seasonSection(detail)
                }
                if !detail.collections.isEmpty {
                    collectionsRow(detail)
                }
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
    }

    private func header(_ detail: API.LibraryItemDetailView) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            titleArt(detail)
            let facts = factsLine(detail)
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
            }
            if let genres = detail.localMeta?.genres, !genres.isEmpty {
                Text(genres.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !isMovie, let selectedEpisode, let season {
                Text("第 \(season) 季 第 \(selectedEpisode.episodeNumber) 集" + (selectedEpisode.name.map { " · \($0)" } ?? ""))
                    .font(.headline)
            }
            if let plot = isMovie ? detail.localMeta?.plot : (selectedEpisode?.overview ?? detail.localMeta?.plot), !plot.isEmpty {
                Text(plot)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(4)
                    .frame(maxWidth: 980, alignment: .leading)
            }
            if canPlay {
                actions
                    .padding(.top, 10)
            } else if !isMovie, detail.seasons.isEmpty || episodes.allSatisfy({ !$0.owned }) {
                Text("这部剧还没有可播放的分集")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, TVMetrics.edge)
        .focusSection()
    }

    /// 片名：有片名 Logo 就画 Logo（本地 Logo 常见 4000px 宽，按显示宽度降采样再解码），没有回落文字
    @ViewBuilder
    private func titleArt(_ detail: API.LibraryItemDetailView) -> some View {
        if let raw = detail.logoUrl, let url = api.image(raw) {
            LazyImage(request: ImageRequest(url: url, processors: [.resize(width: 1100)])) { state in
                if let image = state.image {
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 640, maxHeight: 220, alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 6)
                } else if state.error != nil {
                    titleText(detail)
                } else {
                    Color.clear.frame(height: 220)
                }
            }
            .frame(height: 220, alignment: .bottomLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail.title)
        } else {
            titleText(detail)
        }
    }

    private func titleText(_ detail: API.LibraryItemDetailView) -> some View {
        Text(detail.title)
            .font(.system(size: 76, weight: .bold))
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 12)
            .accessibilityIdentifier("tv-item-title")
    }

    // MARK: 操作

    private var canPlay: Bool {
        guard let detail else { return false }
        if isMovie { return detail.files.contains { $0.state == "in_place" } }
        return selectedEpisode?.owned == true
    }

    private var actions: some View {
        let position = watched?.positionMs ?? 0
        let finished = watched?.played ?? false
        let resumable = !finished && position > 0
        let label = finished ? "重新播放" : resumable ? "继续 \(Formatters.clock(Double(position) / 1000))" : "播放"
        return VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 28) {
                Button { play(start: finished ? 0 : nil) } label: {
                    Label(label, systemImage: "play.fill")
                        .padding(.horizontal, 16)
                }
                .accessibilityIdentifier("tv-item-play")
                if resumable {
                    Button { play(start: 0) } label: {
                        Label("从头播放", systemImage: "backward.end.fill")
                    }
                    .accessibilityIdentifier("tv-item-restart")
                }
                Button { Task { await toggleFavorite() } } label: {
                    Label(favorite == true ? "已收藏" : "收藏", systemImage: favorite == true ? "heart.fill" : "heart")
                }
                .disabled(marking)
                .accessibilityIdentifier("tv-item-favorite")
                Button { Task { await togglePlayed() } } label: {
                    Label(finished ? "已看完" : "标为已看", systemImage: finished ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .disabled(marking)
                .accessibilityIdentifier("tv-item-played")
            }
            if resumable, let remaining = Formatters.remaining(positionMs: position, durationMs: watched?.durationMs) {
                HStack(spacing: 16) {
                    if let duration = watched?.durationMs, duration > 0 {
                        TVProgressStrip(value: Double(position) / Double(duration))
                            .frame(width: 360)
                    }
                    Text(remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: 分集

    private func seasonSection(_ detail: API.LibraryItemDetailView) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            if detail.seasons.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(detail.seasons, id: \.self) { number in
                            Button(number == 0 ? "特别篇" : "第 \(number) 季") {
                                Task { await loadEpisodes(number, keepSelection: false) }
                            }
                            .buttonStyle(TVSeasonTabStyle(selected: number == season))
                            .accessibilityIdentifier("tv-season-\(number)")
                        }
                    }
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.vertical, 12)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            TVShelf(title: detail.seasons.count > 1 ? "分集" : (season.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "分集"),
                    detail: episodes.isEmpty ? nil : "\(episodes.count) 集") {
                ForEach(episodes, id: \.episodeNumber) { episode in
                    episodeCard(episode)
                }
            }
        }
    }

    private func episodeCard(_ episode: API.EpisodeView) -> some View {
        TVLandscapeCard(
            title: "\(episode.episodeNumber). \(episode.name ?? "第 \(episode.episodeNumber) 集")",
            subtitle: episode.owned ? (episode.played ? "已看" : nil) : "缺集",
            imageURL: api.image(episode.stillUrl, .landscapeCard),
            width: 400,
            progress: episode.played ? nil : episode.progressPercent.map { Double($0) / 100 },
            badge: episode.played ? "已看" : nil
        ) {
            guard episode.owned, let season else { return }
            router.play(PlayRequest(mediaItemId: itemId, season: season, episode: episode.episodeNumber))
        }
        .opacity(episode.owned ? 1 : 0.45)
        .contextMenu {
            if episode.owned {
                Button(episode.played ? "标为未看" : "标为已看") {
                    Task { await markEpisode(episode, played: !episode.played) }
                }
            }
        }
        // 焦点停在哪一集，上面的简介和主按钮就说哪一集
        .onFocusChange { focused in
            if focused { selectedEpisode = episode }
        }
        .accessibilityIdentifier("tv-episode-\(episode.episodeNumber)")
    }

    private func collectionsRow(_ detail: API.LibraryItemDetailView) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("所属合集")
                .font(.title3.weight(.semibold))
            HStack(spacing: 24) {
                ForEach(detail.collections, id: \.id) { row in
                    Button(row.name) { router.push(.collection(id: row.id, name: row.name)) }
                }
            }
        }
        .padding(.horizontal, TVMetrics.edge)
        .focusSection()
    }

    // MARK: 派生

    private var unitKey: String {
        if isMovie { return detail == nil ? "-" : "movie" }
        guard let season, let selectedEpisode else { return "-" }
        return "\(season)/\(selectedEpisode.episodeNumber)"
    }

    /// 年份 · 片长 · 评分 · 画质 · HDR（同 iPhone 版）
    private func factsLine(_ detail: API.LibraryItemDetailView) -> [String] {
        let meta = detail.localMeta
        let runtime = meta?.runtimeMinutes ?? detail.files.first(where: { $0.durationSeconds != nil })?.durationSeconds.map { Int((Double($0) / 60).rounded()) }
        var facts = [
            detail.year.map(String.init),
            runtime.flatMap { $0 > 0 ? Self.runtimeText($0) : nil },
            (meta?.rating ?? 0) > 0 ? "★ " + String(format: "%.1f", meta?.rating ?? 0) : nil,
        ].compactMap { $0 }
        let sources = detail.files.filter { $0.state == "in_place" }
        let resolutions = Array(Set(sources.compactMap(\.resolution)))
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map(Self.resolutionLabel)
        if !resolutions.isEmpty { facts.append(resolutions.joined(separator: " / ")) }
        let priority = ["Dolby Vision", "HDR10+", "HDR10", "HLG", "HDR"]
        let hdrs = Array(Set(sources.compactMap(\.hdr))).sorted { (priority.firstIndex(of: $0) ?? 99) < (priority.firstIndex(of: $1) ?? 99) }
        if !hdrs.isEmpty { facts.append(hdrs.joined(separator: " / ")) }
        return facts
    }

    static func runtimeText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时"
    }

    static func resolutionLabel(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let key = normalized.allSatisfy(\.isNumber) ? normalized + "p" : normalized
        return ["4320p": "8K", "2160p": "4K", "1440p": "2K", "1080p": "1080p", "720p": "720p", "4k": "4K", "2k": "2K"][key] ?? raw
    }

    // MARK: 加载与动作

    private func reload() async {
        do {
            let fresh = try await api.libraryItemsGet(libraryId: libraryId, mediaItemId: itemId)
            detail = fresh
            failed = false
            if fresh.kind == "tv", season == nil, let first = fresh.seasons.first(where: { $0 > 0 }) ?? fresh.seasons.first {
                await loadEpisodes(first, keepSelection: false)
            }
        } catch is CancellationError {
        } catch {
            if detail == nil { failed = true }
        }
    }

    /// 读一季的分集；不保留选择时选「接着看的那一集」：看了一半的 → 第一集没看过的 → 第一集
    private func loadEpisodes(_ number: Int, keepSelection: Bool) async {
        guard let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: number) else { return }
        season = number
        episodes = result.episodes
        if keepSelection, let current = selectedEpisode, let fresh = result.episodes.first(where: { $0.episodeNumber == current.episodeNumber }) {
            selectedEpisode = fresh
            return
        }
        let owned = result.episodes.filter(\.owned)
        selectedEpisode = owned.first { $0.positionMs > 0 && !$0.played }
            ?? owned.first { !$0.played }
            ?? owned.first
            ?? result.episodes.first
    }

    private func loadResume(keepCurrent: Bool = false) async {
        guard detail != nil else { return }
        var unit: (Int, Int)?
        if isMovie {
            unit = (0, 0)
        } else if let season, let episode = selectedEpisode?.episodeNumber {
            unit = (season, episode)
        }
        guard let unit else {
            watched = nil
            return
        }
        if !keepCurrent { watched = nil }
        let fresh = try? await api.playbackResume(mediaItemId: itemId, seasonNumber: unit.0, episodeNumber: unit.1)
        if fresh != nil || !keepCurrent { watched = fresh }
    }

    private func play(start: Double?) {
        router.play(PlayRequest(
            mediaItemId: itemId,
            season: isMovie ? nil : season,
            episode: isMovie ? nil : selectedEpisode?.episodeNumber,
            startSeconds: start
        ))
    }

    private func toggleFavorite() async {
        guard !marking else { return }
        let next = !(favorite ?? false)
        marking = true
        favorite = next
        defer { marking = false }
        favorite = (try? await api.librarySetMarks(mediaItemId: itemId, favorite: next).isFavorite) ?? !next
    }

    private func togglePlayed() async {
        guard !marking else { return }
        let next = !(watched?.played ?? false)
        marking = true
        defer { marking = false }
        let unitSeason = isMovie ? 0 : (season ?? 0)
        let unitEpisode = isMovie ? 0 : (selectedEpisode?.episodeNumber ?? 0)
        _ = try? await api.librarySetMarks(mediaItemId: itemId, season: unitSeason, episode: unitEpisode, played: next)
        watched = try? await api.playbackResume(mediaItemId: itemId, seasonNumber: unitSeason, episodeNumber: unitEpisode)
        if let season { await loadEpisodes(season, keepSelection: true) }
    }

    private func markEpisode(_ episode: API.EpisodeView, played: Bool) async {
        guard let season else { return }
        _ = try? await api.librarySetMarks(mediaItemId: itemId, season: season, episode: episode.episodeNumber, played: played)
        await loadEpisodes(season, keepSelection: true)
        await loadResume(keepCurrent: true)
    }
}

/// 选季按钮：选中的季白底黑字
private struct TVSeasonTabStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .foregroundStyle(selected || focused ? .black : .white)
            .background(Capsule().fill(focused ? .white : selected ? .white.opacity(0.85) : .white.opacity(0.12)))
            .scaleEffect(focused ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

extension View {
    /// 焦点进出时回调（tvOS 上焦点就是「用户正看着哪一个」）
    func onFocusChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(TVFocusChangeModifier(action: action))
    }
}

private struct TVFocusChangeModifier: ViewModifier {
    let action: (Bool) -> Void
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, value in action(value) }
    }
}
