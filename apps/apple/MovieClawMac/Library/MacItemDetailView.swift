import SwiftUI

/// 条目详情（docs/design/macos-app.md §4.4）。版式取 Apple TV App 的 Mac 版 + Apple Music 的专辑页：
/// - **头图**：剧照铺满（延伸到工具栏与侧边栏底下），左下角是片名 Logo、年份类型片长与画质小标签、第几集、三行简介，
///   下面一排按钮：主按钮写明播哪一集、从哪儿接着播（「继续 第 1 季第 3 集 · 12:34」），「从头播放」，
///   收藏、标为已看折成圆形玻璃钮；右下角浮「导演 / 主演」两行（同 Apple TV App）；
/// - **往下**（垫着同一张剧照的模糊版）：选季（一排胶囊）→ 分集横排（剧照、第几集、集名、简介、首播日期，点一下就播）
///   → 电影的作品系列 → 演职员（圆头像，点进影人页）→ 所属合集 → 信息（原名、类型、评分、文件版本），
///   相当于 Apple Music 专辑页的曲目表与底部的发行信息。
///
/// 数据与 iPhone、Apple TV 版同一套：`libraryItemsGet` 拿详情（含演职员）、`playbackResume` 拿续播点、
/// `librarySetMarks` 收藏与标记已看；剧集默认讲「接下来继续」里那一集，否则第一个有片源的季里接着看的那一集。
/// 播放器关掉、服务端收下「停止」后（`.playbackStopReported`）重拉续播点与分集进度，按钮立刻跟上。
/// Mac 上同样不做任何管理操作（修正识别、换图、删除……都在网页上）。
struct MacItemDetailView: View {
    let libraryId: Int
    let itemId: Int

    @Environment(\.api) private var api
    @Environment(MacRouter.self) private var router

    @State private var detail: API.LibraryItemDetailView?
    @State private var failed: String?
    /// 头图讲的那一季、那一集（接着看的）
    @State private var season: Int?
    @State private var episodes: [API.EpisodeView] = []
    @State private var selectedEpisode: API.EpisodeView?
    /// 下面正在看的那一季（换季只换分集横排，头图还讲接着看的那一集）
    @State private var browseSeason: Int?
    @State private var browseEpisodes: [API.EpisodeView] = []
    @State private var watched: API.PlaybackStateView?
    @State private var series: API.CollectionSeriesView?
    @State private var favorite: Bool?
    @State private var marking = false
    /// 在下面点播的那一集：播完回来头图改讲它
    @State private var playedElsewhere: (season: Int, episode: Int)?

    private var isMovie: Bool { detail?.kind != "tv" }

    var body: some View {
        Group {
            if let failed {
                MacStateView(symbol: "questionmark.folder", title: "未能加载该条目", message: failed, actionTitle: "返回") { router.pop() }
            } else if let detail {
                content(detail)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            MacBlurredBackdrop(url: api.image(detail?.backdropUrl ?? detail?.posterUrl, width: ImageWidth.points(MacMetrics.blurredBackdropWidth)))
                .ignoresSafeArea()
        }
        .navigationTitle(detail?.title ?? "")
        .toolbar(removing: .title)
        .task { await reload() }
        .task { favorite = (try? await api.playbackMarksGet(mediaItemId: itemId))?.isFavorite }
        // 进了详情页多半要播：先把起播要用的连接连好（同 iPhone 版）
        .task { PlaybackPreconnect.warm(api: api) }
        .task(id: unitKey) { await loadResume() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopReported)) { note in
            guard note.userInfo?["mediaItemId"] as? Int == itemId else { return }
            Task {
                await refreshBrowse()
                if let unit = playedElsewhere, unit.season != season || unit.episode != selectedEpisode?.episodeNumber {
                    playedElsewhere = nil
                    await loadEpisodes(unit.season, keepSelection: false, preferred: unit.episode)
                    return
                }
                playedElsewhere = nil
                await loadResume(keepCurrent: true)
                if let season { await loadEpisodes(season, keepSelection: true) }
            }
        }
        .onChange(of: router.player?.id) {
            guard let request = router.player, request.mediaItemId == itemId,
                  let season = request.season, let episode = request.episode else { return }
            playedElsewhere = (season, episode)
        }
        .accessibilityIdentifier("mac-item-\(itemId)")
    }

    // MARK: 页面

    private func content(_ detail: API.LibraryItemDetailView) -> some View {
        GeometryReader { window in
            let heroHeight = MacStageLayout.height(for: window.size.width, windowHeight: window.size.height + window.safeAreaInsets.top) + 40
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: MacMetrics.rowSpacing) {
                    hero(detail, height: heroHeight)
                    lower(detail)
                }
                .padding(.bottom, 56)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: 头图

    private func hero(_ detail: API.LibraryItemDetailView, height: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            MacStageBackdrop(url: api.image(detail.backdropUrl ?? detail.posterUrl, width: ImageWidth.screen), tint: nil,
                             fadeFrom: 0.62, showsBase: false)
                .frame(height: height)
                .backgroundExtensionEffect()
            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 20) {
                    MacStageInfo(
                        title: detail.title,
                        logoURL: api.image(detail.logoUrl),
                        headline: episodeHeadline,
                        meta: metaLine(detail),
                        badges: MacMediaBadge.best(for: detail),
                        overview: isMovie ? detail.localMeta?.plot : (selectedEpisode?.overview ?? detail.localMeta?.plot),
                        overviewLines: 3
                    )
                    .accessibilityIdentifier("mac-item-stage")
                    actions(detail)
                }
                .frame(maxWidth: 640, alignment: .leading)
                Spacer(minLength: 0)
                stageCredits(detail)
            }
            .padding(.horizontal, MacMetrics.edge + 8)
            .padding(.bottom, 36)
        }
        .frame(height: height)
        .clipped()
    }

    /// 「第 2 季 第 6 集 · 集名」（剧集：接着看的那一集）
    private var episodeHeadline: String? {
        guard !isMovie, let selectedEpisode, let season else { return nil }
        return MacStageInfo.episodeLine(season: season, episode: selectedEpisode.episodeNumber, name: selectedEpisode.name)
    }

    private var canPlay: Bool {
        guard let detail else { return false }
        if isMovie { return detail.files.contains { $0.state == "in_place" } }
        return selectedEpisode?.owned == true
    }

    /// 主按钮上的「第 1 季第 3 集」；特别篇写「特别篇第 2 集」；电影没有
    private var unitLabel: String? {
        guard !isMovie, let season, let episode = selectedEpisode?.episodeNumber else { return nil }
        return season == 0 ? "特别篇第 \(episode) 集" : "第 \(season) 季第 \(episode) 集"
    }

    /// 一排按钮：主按钮（醒目玻璃）写明播哪一集、从哪儿接着播；「从头播放」；收藏、标为已看是圆形玻璃钮
    private func actions(_ detail: API.LibraryItemDetailView) -> some View {
        let position = watched?.positionMs ?? 0
        let finished = watched?.played ?? false
        let resumable = canPlay && !finished && position > 0
        let verb = finished ? "重新播放" : resumable ? "继续" : "播放"
        let parts = [verb, unitLabel, resumable ? Formatters.clock(Double(position) / 1000) : nil].compactMap { $0 }
        let label = parts.count > 2 ? "\(parts[0]) \(parts[1]) · \(parts[2])" : parts.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 10) {
            if !canPlay, !isMovie, detail.seasons.isEmpty || episodes.allSatisfy({ !$0.owned }) {
                Text(detail.seasons.isEmpty ? "这部剧还没有可播放的分集" : "这一集还没有片源，在下面挑别的集")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            } else if isMovie, !canPlay {
                Text("片源已移除，暂时不能播放")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 10) {
                if canPlay {
                    Button { play(start: finished ? 0 : nil) } label: {
                        Label(label, systemImage: "play.fill")
                            .padding(.horizontal, 6)
                            .monospacedDigit()
                    }
                    .buttonStyle(MacPrimaryButtonStyle())
                    .accessibilityIdentifier("mac-item-play")
                    if resumable {
                        Button { play(start: 0) } label: {
                            Label("从头播放", systemImage: "backward.end.fill")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                        .accessibilityIdentifier("mac-item-restart")
                    }
                }
                circleButton(favorite == true ? "heart.fill" : "heart", help: favorite == true ? "取消收藏" : "收藏") {
                    Task { await toggleFavorite() }
                }
                .accessibilityIdentifier("mac-item-favorite")
                if canPlay {
                    circleButton(finished ? "checkmark.circle.fill" : "checkmark", help: finished ? "标为未看" : "标为已看") {
                        Task { await togglePlayed() }
                    }
                    .accessibilityIdentifier("mac-item-played")
                }
            }
            .disabled(marking)
        }
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .help(help)
        .accessibilityLabel(help)
    }

    /// 头图右下角的演职员：「导演 某某」「主演 某某、某某」，标签灰、人名白；窗口太窄时不显示
    @ViewBuilder
    private func stageCredits(_ detail: API.LibraryItemDetailView) -> some View {
        let meta = detail.localMeta
        let directors = (meta?.directorCredits.map(\.name)).flatMap { $0.isEmpty ? nil : $0 } ?? meta?.directors ?? []
        let actors = (meta?.actors ?? []).prefix(3).map(\.name)
        if !directors.isEmpty || !actors.isEmpty {
            ViewThatFits(in: .horizontal) {
                VStack(alignment: .leading, spacing: 6) {
                    if let director = directors.first { creditLine("导演", [director]) }
                    if !actors.isEmpty { creditLine("主演", Array(actors)) }
                }
                .fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
            .shadow(color: .black.opacity(0.5), radius: 8)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private func creditLine(_ label: String, _ names: [String]) -> some View {
        (Text(label + "  ").foregroundStyle(.white.opacity(0.6)) + Text(names.joined(separator: "、")).foregroundStyle(.white))
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
    }

    // MARK: 下面

    @ViewBuilder
    private func lower(_ detail: API.LibraryItemDetailView) -> some View {
        if !isMovie, !detail.seasons.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if detail.seasons.count > 1 { seasonTabs(detail) }
                episodeShelf(detail)
            }
        }
        if let series { seriesShelf(series) }
        let people = Self.castPeople(detail)
        if !people.isEmpty {
            MacShelf(title: "演职员", artHeight: MacMetrics.avatarSize) {
                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                    MacPersonCard(name: person.name, role: person.role,
                                  avatarURL: api.image(person.avatar, width: ImageWidth.points(MacMetrics.avatarSize)),
                                  linked: person.personId != nil) {
                        guard let id = person.personId else { return }
                        router.push(.person(tmdbId: id, name: person.name, avatar: person.avatar, fromItem: itemId))
                    }
                    .accessibilityIdentifier(person.personId.map { "mac-cast-\($0)" } ?? "mac-cast-none")
                }
            }
        }
        if !otherCollections(detail).isEmpty { collectionsRow(detail) }
        infoSection(detail)
    }

    /// 季：一排胶囊，选中的那一季白底黑字
    private func seasonTabs(_ detail: API.LibraryItemDetailView) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(detail.seasons, id: \.self) { number in
                    Button(number == 0 ? "特别篇" : "第 \(number) 季") {
                        Task { await loadBrowse(number) }
                    }
                    .buttonStyle(MacSeasonTabStyle(selected: number == browseSeason))
                    .accessibilityIdentifier("mac-season-\(number)")
                }
            }
            .padding(.horizontal, MacMetrics.edge)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func episodeShelf(_ detail: API.LibraryItemDetailView) -> some View {
        MacShelf(title: browseSeason.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "分集",
                 detail: Self.seasonSummary(browseEpisodes),
                 artHeight: MacMetrics.landscapeWidth * 9 / 16,
                 scrollTo: entryEpisode) {
            ForEach(browseEpisodes, id: \.episodeNumber) { episode in
                MacEpisodeCard(
                    episode: episode,
                    imageURL: api.image(episode.stillUrl, width: ImageWidth.macCard(MacMetrics.landscapeWidth)),
                    runtimeMinutes: detail.localMeta?.runtimeMinutes,
                    isStage: browseSeason == season && episode.episodeNumber == selectedEpisode?.episodeNumber,
                    play: { playEpisode(episode) },
                    toggleWatched: { Task { await markEpisode(episode, played: !episode.played) } }
                )
                .id(episode.episodeNumber)
                .accessibilityIdentifier("mac-episode-\(episode.episodeNumber)")
            }
        }
    }

    /// 分集横排一打开滚到哪一集：头图讲的那一季是头图那一集，别的季是那一季接着看的那一集
    private var entryEpisode: Int? {
        if browseSeason == season, let selectedEpisode { return selectedEpisode.episodeNumber }
        return Self.resumeEpisode(in: browseEpisodes)?.episodeNumber
    }

    /// 分集横排标题旁的小字：「共 10 集 · 已看 3 集 · 缺 2 集」
    private static func seasonSummary(_ episodes: [API.EpisodeView]) -> String? {
        guard !episodes.isEmpty else { return nil }
        var parts = ["共 \(episodes.count) 集"]
        let played = episodes.filter(\.played).count
        if played > 0 { parts.append("已看 \(played) 集") }
        let missing = episodes.filter { !$0.owned }.count
        if missing > 0 { parts.append("缺 \(missing) 集") }
        return parts.joined(separator: " · ")
    }

    /// 电影的作品系列：整个系列按上映顺序，库里没有的置灰标「未入库」，这一部标「本片」
    private func seriesShelf(_ series: API.CollectionSeriesView) -> some View {
        MacShelf(title: series.seriesName ?? "系列", detail: "已有 \(series.ownedCount) / 共 \(series.total)",
                 artHeight: MacMetrics.posterWidth * 1.5) {
            ForEach(series.parts, id: \.tmdbId) { part in
                let current = part.mediaItemId == itemId
                let missing = part.mediaItemId == nil
                MacPosterCard(
                    title: part.title,
                    subtitle: part.releaseDate.map { String($0.prefix(4)) },
                    imageURL: api.image(part.posterUrl, width: ImageWidth.macCard(MacMetrics.posterWidth)),
                    badge: current ? "本片" : missing ? "未入库" : nil,
                    play: missing || current ? nil : { if let id = part.mediaItemId { router.play(PlayRequest(mediaItemId: id)) } }
                ) {
                    if !current, let id = part.mediaItemId {
                        router.push(.item(libraryId: libraryId, itemId: id))
                    }
                }
                .opacity(missing ? 0.45 : 1)
                .disabled(missing)
            }
        }
    }

    /// 「所属合集」：一排玻璃胶囊，点进合集的海报墙（一部片通常只在一两个合集里，入口用文字就够，同 Apple TV 版）
    private func collectionsRow(_ detail: API.LibraryItemDetailView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("所属合集").font(.system(size: 20, weight: .bold))
            HStack(spacing: 8) {
                ForEach(otherCollections(detail), id: \.id) { row in
                    Button { router.push(.collection(id: row.id, name: row.name)) } label: {
                        Label(row.name, systemImage: "rectangle.stack")
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .padding(.horizontal, MacMetrics.edge)
    }

    /// 页底的信息（同 Apple Music 专辑页底部的发行信息）：原名、类型、评分、片长 / 季数、文件；电影列出在位的各个版本
    private func infoSection(_ detail: API.LibraryItemDetailView) -> some View {
        let meta = detail.localMeta
        var facts: [(String, String)] = []
        if !detail.originalTitle.isEmpty, detail.originalTitle != detail.title { facts.append(("原名", detail.originalTitle)) }
        if let year = detail.year { facts.append(("年份", String(year))) }
        if let genres = meta?.genres, !genres.isEmpty { facts.append(("类型", genres.joined(separator: " / "))) }
        if let rating = meta?.rating, rating > 0 { facts.append(("评分", String(format: "%.1f", rating))) }
        if isMovie, let runtime = meta?.runtimeMinutes, runtime > 0 { facts.append(("片长", Formatters.runtime(runtime))) }
        if !isMovie {
            let seasons = detail.seasons.filter { $0 > 0 }.count
            if seasons > 0 { facts.append(("季数", "\(seasons) 季")) }
        }
        let inPlace = detail.files.filter { $0.state == "in_place" }
        facts.append(("文件", inPlace.isEmpty ? "没有在位的文件" : "\(inPlace.count) 个 · \(Formatters.bytes(inPlace.reduce(0) { $0 + $1.sizeBytes }))"))
        let versions = isMovie ? inPlace : []
        return VStack(alignment: .leading, spacing: 12) {
            Text("信息").font(.system(size: 20, weight: .bold))
            HStack(alignment: .top, spacing: 56) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                    ForEach(facts, id: \.0) { fact in
                        GridRow {
                            Text(fact.0).foregroundStyle(.secondary)
                            Text(fact.1).textSelection(.enabled)
                        }
                    }
                }
                if !versions.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("版本").foregroundStyle(.secondary)
                        ForEach(versions, id: \.id) { file in
                            Text(Self.versionLine(file))
                                .lineLimit(1)
                                .help(file.fileName)
                        }
                    }
                }
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, MacMetrics.edge)
        .accessibilityIdentifier("mac-item-info")
    }

    /// 「2160p · HEVC · Dolby Vision · 58.3 GB」
    private static func versionLine(_ file: API.LibraryFileView) -> String {
        [file.resolution, file.videoCodec?.uppercased(), file.hdr, Formatters.bytes(file.sizeBytes)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// 「所属合集」里不再列系列本身：上面已经有系列一行了
    private func otherCollections(_ detail: API.LibraryItemDetailView) -> [API.ItemCollectionRef] {
        guard series != nil, let seriesId = detail.seriesCollectionId else { return detail.collections }
        return detail.collections.filter { $0.id != seriesId }
    }

    typealias CastPerson = (name: String, role: String?, avatar: String?, personId: Int?)

    /// 演职员：导演在前（结构化的优先，没有就退回姓名），演员跟着
    static func castPeople(_ detail: API.LibraryItemDetailView) -> [CastPerson] {
        guard let meta = detail.localMeta else { return [] }
        let directors: [CastPerson] = meta.directorCredits.isEmpty
            ? Array(NSOrderedSet(array: meta.directors)).compactMap { $0 as? String }.map { ($0, "导演", nil, nil) }
            : meta.directorCredits.map { ($0.name, "导演", $0.thumbUrl, $0.tmdbPersonId) }
        return directors + meta.actors.map { ($0.name, $0.role.flatMap { $0.isEmpty ? nil : "饰 \($0)" }, $0.thumbUrl, $0.tmdbPersonId) }
    }

    // MARK: 派生

    private var unitKey: String {
        if isMovie { return detail == nil ? "-" : "movie" }
        guard let season, let selectedEpisode else { return "-" }
        return "\(season)/\(selectedEpisode.episodeNumber)"
    }

    /// 年份 · 类型（前两个） · 电影片长 / 剧集两季以上「共 X 季」
    private func metaLine(_ detail: API.LibraryItemDetailView) -> String {
        let meta = detail.localMeta
        var facts = [detail.year.map(String.init)].compactMap { $0 } + (meta?.genres ?? []).prefix(2)
        if isMovie {
            let runtime = meta?.runtimeMinutes ?? detail.files.first(where: { $0.durationSeconds != nil })?.durationSeconds.map { Int((Double($0) / 60).rounded()) }
            if let runtime, runtime > 0 { facts.append(Formatters.runtime(runtime)) }
        } else {
            let seasons = detail.seasons.filter { $0 > 0 }.count
            if seasons >= 2 { facts.append("共 \(seasons) 季") }
        }
        return facts.joined(separator: " · ")
    }

    /// 一季里「接着看的那一集」：看了一半的 → 第一集没看过的 → 第一集（有片源的优先）
    static func resumeEpisode(in episodes: [API.EpisodeView]) -> API.EpisodeView? {
        let owned = episodes.filter(\.owned)
        return owned.first { $0.positionMs > 0 && !$0.played }
            ?? owned.first { !$0.played }
            ?? owned.first
            ?? episodes.first
    }

    // MARK: 加载与动作

    private func reload() async {
        do {
            let fresh = try await api.libraryItemsGet(libraryId: libraryId, mediaItemId: itemId)
            if fresh.kind == "tv", season == nil {
                // 在「接下来继续」里的剧打开接着看的那一季那一集；别的打开第一个有片源的季（综艺常只收了最新一季）。
                // 分集读完再出页面，不闪「还没有可播放的分集」
                let next = LibraryHomeStore.shared.upNext?.first { $0.mediaItemId == itemId && $0.kind == "tv" }
                let owned = Set(fresh.files.filter { $0.state == "in_place" }.map(\.seasonNumber))
                let start = next.map(\.seasonNumber).flatMap { fresh.seasons.contains($0) ? $0 : nil }
                    ?? fresh.seasons.first(where: { $0 > 0 && owned.contains($0) })
                    ?? fresh.seasons.first(where: { owned.contains($0) })
                    ?? fresh.seasons.first(where: { $0 > 0 }) ?? fresh.seasons.first
                if let start {
                    await loadEpisodes(start, keepSelection: false, preferred: next?.episodeNumber)
                    browseSeason = start
                    browseEpisodes = episodes
                }
            }
            await loadSeries(fresh)
            detail = fresh
            failed = nil
        } catch is CancellationError {
        } catch {
            if detail == nil { failed = "条目可能已被删除或重新识别为其他作品。（\(error.localizedDescription)）" }
        }
    }

    /// 电影所属的作品系列：只有一部、或拉不到上游档案时不出这一行
    private func loadSeries(_ detail: API.LibraryItemDetailView) async {
        guard detail.kind != "tv", let id = detail.seriesCollectionId,
              let fresh = try? await api.collectionSeriesGet(collectionId: id),
              fresh.available, fresh.parts.count > 1 else {
            series = nil
            return
        }
        series = fresh
    }

    private func loadEpisodes(_ number: Int, keepSelection: Bool, preferred: Int? = nil) async {
        guard let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: number) else { return }
        season = number
        episodes = result.episodes
        if keepSelection, let current = selectedEpisode, let fresh = result.episodes.first(where: { $0.episodeNumber == current.episodeNumber }) {
            selectedEpisode = fresh
            return
        }
        selectedEpisode = preferred.flatMap { number in result.episodes.first { $0.episodeNumber == number } }
            ?? Self.resumeEpisode(in: result.episodes)
    }

    private func loadBrowse(_ number: Int) async {
        guard let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: number) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            browseSeason = number
            browseEpisodes = result.episodes
        }
    }

    private func refreshBrowse() async {
        guard let browseSeason,
              let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: browseSeason)
        else { return }
        browseEpisodes = result.episodes
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
        router.play(PlayRequest(mediaItemId: itemId, season: isMovie ? nil : season,
                                episode: isMovie ? nil : selectedEpisode?.episodeNumber, startSeconds: start))
    }

    private func playEpisode(_ episode: API.EpisodeView) {
        guard episode.owned, let browseSeason else { return }
        router.play(PlayRequest(mediaItemId: itemId, season: browseSeason, episode: episode.episodeNumber))
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
        await refreshBrowse()
    }

    private func markEpisode(_ episode: API.EpisodeView, played: Bool) async {
        guard let browseSeason else { return }
        _ = try? await api.librarySetMarks(mediaItemId: itemId, season: browseSeason, episode: episode.episodeNumber, played: played)
        await refreshBrowse()
        if browseSeason == season {
            await loadEpisodes(browseSeason, keepSelection: true)
            await loadResume(keepCurrent: true)
        }
    }
}

/// 一集：剧照（左下「▶ 片长」或「看到 mm:ss」+ 进度，看完标「已看」）+ 第几集、集名、三行简介、首播日期。
/// 简介固定三行高，一排卡的日期对齐在同一条线上（同 Apple TV App 的分集卡）。点一下就播；悬停浮出播放键；
/// 右键菜单：播放、标为已看 / 未看。缺集的置灰、不可点
private struct MacEpisodeCard: View {
    let episode: API.EpisodeView
    let imageURL: URL?
    let runtimeMinutes: Int?
    /// 头图正讲这一集：描一圈亮边
    let isStage: Bool
    let play: () -> Void
    let toggleWatched: () -> Void

    private let width = MacMetrics.landscapeWidth
    @State private var hovering = false

    var body: some View {
        Button(action: play) {
            VStack(alignment: .leading, spacing: 9) {
                RemoteImage(url: imageURL, placeholderText: "第 \(episode.episodeNumber) 集")
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottomLeading) { stillBand }
                    .overlay(alignment: .topLeading) {
                        if episode.played {
                            Label("已看", systemImage: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.62), in: .capsule)
                                .padding(7)
                        }
                    }
                    .overlay {
                        if hovering, episode.owned {
                            ZStack {
                                Color.black.opacity(0.2)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .frame(width: 44, height: 44)
                                    .glassEffect(.regular, in: .circle)
                            }
                            .transition(.opacity)
                        }
                    }
                    .clipShape(.rect(cornerRadius: MacMetrics.cardCorner))
                    .overlay {
                        RoundedRectangle(cornerRadius: MacMetrics.cardCorner)
                            .strokeBorder(isStage ? .white.opacity(0.7) : .white.opacity(0.12), lineWidth: isStage ? 2 : 0.5)
                    }
                    .shadow(color: .black.opacity(hovering ? 0.35 : 0.2), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("第 \(episode.episodeNumber) 集")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(episode.name ?? "第 \(episode.episodeNumber) 集")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(episode.overview ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .frame(height: 46, alignment: .top)
                    Text(episode.owned ? (episode.airDate.map { String($0.prefix(10)) } ?? "") : "缺集")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: width, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(MacCardButtonStyle())
        .disabled(!episode.owned)
        .opacity(episode.owned ? 1 : 0.45)
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .contextMenu {
            if episode.owned {
                Button("播放", systemImage: "play.fill", action: play)
                Button(episode.played ? "标为未看" : "标为已看", systemImage: episode.played ? "circle" : "checkmark.circle", action: toggleWatched)
            }
        }
        .help(episode.owned ? "播放第 \(episode.episodeNumber) 集" : "这一集还没有片源")
        .accessibilityLabel("第 \(episode.episodeNumber) 集 \(episode.name ?? "")")
    }

    /// 剧照左下：▶ 片长（看了一半的写看到哪、压进度条）
    @ViewBuilder
    private var stillBand: some View {
        let inProgress = !episode.played && episode.positionMs > 0
        let text: String? = inProgress ? "看到 \(Formatters.clock(Double(episode.positionMs) / 1000))"
            : runtimeMinutes.flatMap { $0 > 0 ? Formatters.runtime($0) : nil }
        if text != nil || inProgress {
            VStack(alignment: .leading, spacing: 5) {
                if let text {
                    Label(text, systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                if inProgress, let percent = episode.progressPercent {
                    MacProgressStrip(value: Double(percent) / 100, track: .white.opacity(0.3))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// 演职员一格：圆头像 + 姓名 + 身份（导演 / 饰 X）。有 TMDB 影人 id 的点进影人页；悬停时头像套一圈亮边
struct MacPersonCard: View {
    let name: String
    let role: String?
    let avatarURL: URL?
    var linked = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                MacAvatar(url: avatarURL, name: name, size: MacMetrics.avatarSize)
                    .overlay { Circle().strokeBorder(.white.opacity(hovering && linked ? 0.8 : 0.1), lineWidth: hovering && linked ? 2 : 0.5) }
                    .shadow(color: .black.opacity(0.3), radius: hovering ? 8 : 3, y: 2)
                VStack(spacing: 2) {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(role ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: MacMetrics.avatarSize + 24)
            .contentShape(.rect)
        }
        .buttonStyle(MacCardButtonStyle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .help(linked ? "查看\(name)在库里的作品" : name)
        .accessibilityLabel([name, role].compactMap { $0 }.joined(separator: "，"))
    }
}

/// 季的胶囊：选中的季白底黑字，其余淡玻璃
private struct MacSeasonTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? .black : .white.opacity(0.85))
            .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
            .overlay(Capsule().strokeBorder(.white.opacity(selected ? 0 : 0.14), lineWidth: 0.5))
            .contentShape(.capsule)
            .animation(.easeOut(duration: 0.15), value: selected)
    }
}
