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
/// `librarySetMarks` 收藏与标记已看；剧集默认讲「接下来继续」里那一季（否则第一个有片源的季）接着看的那一集
/// （`anchorEpisode`：服务端给的锚点，没给退回客户端规则）。
/// 播放器关掉、服务端收下「停止」后（`.playbackStopReported`）重拉续播点与分集进度，按钮立刻跟上。
/// 一季超过 50 集分段（docs/design/long-season-episode-ranges.md）：季胶囊下面一排段胶囊 + 右侧「全部 N 集 ›」（弹出段 + 10 列宫格），
/// 横排只放当前段的集、首尾各一张「上一段 / 下一段」；锚点的段带橙点。≤50 集不出段胶囊与面板入口。
/// 这一季有观看记录（任一集看过或看了一半）时锚点那张卡标「接着看」，短季同样标。
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
    /// 下面那一季的锚点（接着看的那一集）
    @State private var browseAnchor: Int?
    /// 分段时下面横排正在显示的段（`EpisodeRange.index`）与要滚到的那一集；不分段时不用
    @State private var browseRange: Int?
    @State private var browseFocus: Int?
    @State private var showsAllEpisodes = false
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
                // 播放回来锚点变了（看完 1050 → 1051）：头图改讲新锚点，分段时段跟过去；没变走原来的逻辑
                if let anchor = await refreshBrowse(), let browseSeason {
                    playedElsewhere = nil
                    await loadEpisodes(browseSeason, keepSelection: false, preferred: anchor)
                    return
                }
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
                    hero(detail, height: heroHeight, width: window.size.width)
                    lower(detail)
                }
                .padding(.bottom, 56)
            }
            .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: 头图

    private func hero(_ detail: API.LibraryItemDetailView, height: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            MacStageBackdrop(url: api.image(detail.backdropUrl ?? detail.posterUrl, width: ImageWidth.screen), tint: nil,
                             fadeFrom: 0.62, showsBase: false)
                .frame(height: height)
            HStack(alignment: .bottom, spacing: 32) {
                VStack(alignment: .leading, spacing: 20) {
                    MacStageInfo(
                        title: detail.title,
                        logoURL: api.image(detail.logoUrl),
                        headline: episodeHeadline,
                        meta: metaLine(detail),
                        badges: MacMediaBadge.best(for: detail),
                        overview: isMovie ? detail.localMeta?.plot : (selectedEpisode?.overview ?? detail.localMeta?.plot),
                        overviewLines: 3,
                        logoSize: MacStageLayout.logoSize(for: width)
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
        // 有续播点就接着播（与服务端起播同一口径）：看完后重看到一半的也算，已看标记保留
        let resumable = canPlay && position > 0
        let verb = resumable ? "继续" : finished ? "重新播放" : "播放"
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
                    Button { play(start: nil) } label: {
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
                if !browseRanges.isEmpty { rangeBar }
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
        let ranges = browseRanges
        let current = ranges.first { $0.index == browseRange } ?? ranges.first
        // 分段时横排只放当前段的集，首尾各一张「上一段 / 下一段」
        let shown = current.map { r in browseEpisodes.filter { r.contains($0.episodeNumber) } } ?? browseEpisodes
        let position = current.flatMap { r in ranges.firstIndex(of: r) }
        let previous = position.flatMap { $0 > 0 ? ranges[$0 - 1] : nil }
        let next = position.flatMap { $0 + 1 < ranges.count ? ranges[$0 + 1] : nil }
        // 「接着看」只在这一季有观看记录时标：一集没碰过的季，锚点只是第一集，不标
        let watchedAny = browseEpisodes.contains { $0.played || $0.positionMs > 0 }
        return MacShelf(title: browseSeason.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "分集",
                        detail: Self.seasonSummary(browseEpisodes),
                        artHeight: MacMetrics.landscapeWidth * 9 / 16,
                        scrollTo: entryEpisode) {
            if let previous {
                MacRangeEdgeCard(title: "上一段", symbol: "chevron.backward", range: previous) { switchRange(previous) }
                    .accessibilityIdentifier("episode-range-prev")
            }
            ForEach(shown, id: \.episodeNumber) { episode in
                MacEpisodeCard(
                    episode: episode,
                    imageURL: api.image(episode.stillUrl, width: ImageWidth.macCard(MacMetrics.landscapeWidth)),
                    runtimeMinutes: detail.localMeta?.runtimeMinutes,
                    isStage: browseSeason == season && episode.episodeNumber == selectedEpisode?.episodeNumber,
                    isResume: watchedAny && episode.episodeNumber == browseAnchor,
                    select: { selectEpisode(episode) },
                    play: { playEpisode(episode) },
                    toggleWatched: { Task { await markEpisode(episode, played: !episode.played) } }
                )
                .id(episode.episodeNumber)
                .accessibilityIdentifier("mac-episode-\(episode.episodeNumber)")
            }
            if let next {
                MacRangeEdgeCard(title: "下一段", symbol: "chevron.forward", range: next) { switchRange(next) }
                    .accessibilityIdentifier("episode-range-next")
            }
        }
    }

    /// 分集横排一打开滚到哪一集：分段时是锁定的那一集（换段、宫格里点的、锚点）；
    /// 否则头图讲的那一季是头图那一集，别的季是那一季接着看的那一集
    private var entryEpisode: Int? {
        if !browseRanges.isEmpty, let browseFocus { return browseFocus }
        if browseSeason == season, let selectedEpisode { return selectedEpisode.episodeNumber }
        return browseAnchor
    }

    /// 下面那一季的段：不分段时为空
    private var browseRanges: [EpisodeRange] { EpisodeRanges.ranges(browseEpisodes) }

    /// 段胶囊（选中的白底黑字，锚点的段右上角橙点）+ 右侧「全部 N 集 ›」，点开弹出段 + 宫格
    private var rangeBar: some View {
        let ranges = browseRanges
        let current = ranges.first { $0.index == browseRange } ?? ranges.first
        return HStack(spacing: 12) {
            MacRangeChips(ranges: ranges, current: current?.index, anchor: browseAnchor) { switchRange($0) }
            Button { showsAllEpisodes = true } label: {
                HStack(spacing: 3) {
                    Text("全部 \(browseEpisodes.count) 集")
                    Image(systemName: "chevron.forward").font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("全部分集")
            .accessibilityIdentifier("episode-ranges-all")
            .popover(isPresented: $showsAllEpisodes, arrowEdge: .bottom) {
                MacEpisodeGridPanel(episodes: browseEpisodes, ranges: ranges, anchor: browseAnchor,
                                    selected: browseSeason == season ? selectedEpisode?.episodeNumber : nil) { number in
                    showsAllEpisodes = false
                    pickEpisode(number)
                }
            }
        }
        .padding(.trailing, MacMetrics.edge)
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

    // MARK: 加载与动作

    private func reload() async {
        do {
            let fresh = try await api.libraryItemsGet(libraryId: libraryId, mediaItemId: itemId)
            if fresh.kind == "tv", season == nil {
                // 在「接下来继续」里的剧打开那一季；别的打开第一个有片源的季（综艺常只收了最新一季）。集取这一季的锚点。
                // 分集读完再出页面，不闪「还没有可播放的分集」
                let next = LibraryHomeStore.shared.upNext?.first { $0.mediaItemId == itemId && $0.kind == "tv" }
                let owned = Set(fresh.files.filter { $0.state == "in_place" }.map(\.seasonNumber))
                let start = next.map(\.seasonNumber).flatMap { fresh.seasons.contains($0) ? $0 : nil }
                    ?? fresh.seasons.first(where: { $0 > 0 && owned.contains($0) })
                    ?? fresh.seasons.first(where: { owned.contains($0) })
                    ?? fresh.seasons.first(where: { $0 > 0 }) ?? fresh.seasons.first
                if let start {
                    let result = await loadEpisodes(start, keepSelection: false)
                    browseSeason = start
                    browseEpisodes = episodes
                    browseAnchor = result?.anchorEpisode?.episodeNumber
                    lockBrowse(selectedEpisode?.episodeNumber)
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

    @discardableResult
    private func loadEpisodes(_ number: Int, keepSelection: Bool, preferred: Int? = nil) async -> API.SeasonEpisodesView? {
        guard let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: number) else { return nil }
        season = number
        episodes = result.episodes
        if keepSelection, let current = selectedEpisode, let fresh = result.episodes.first(where: { $0.episodeNumber == current.episodeNumber }) {
            selectedEpisode = fresh
            return result
        }
        selectedEpisode = preferred.flatMap { number in result.episodes.first { $0.episodeNumber == number } }
            ?? result.anchorEpisode
        return result
    }

    private func loadBrowse(_ number: Int) async {
        guard let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: number) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            browseSeason = number
            browseEpisodes = result.episodes
            browseAnchor = result.anchorEpisode?.episodeNumber
            // 换季：段落在头图那一集（同一季）或那一季锚点所在的段
            lockBrowse(number == season ? selectedEpisode?.episodeNumber ?? browseAnchor : browseAnchor)
        }
    }

    /// 重拉下面那一季；锚点变了（看完 1050 → 1051）把段锁到新锚点并返回它，没变不动（保留在别的段的浏览）
    @discardableResult
    private func refreshBrowse() async -> Int? {
        guard let browseSeason,
              let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: browseSeason)
        else { return nil }
        let previous = browseAnchor
        browseEpisodes = result.episodes
        browseAnchor = result.anchorEpisode?.episodeNumber
        guard let anchor = browseAnchor, anchor != previous else { return nil }
        lockBrowse(anchor)
        return anchor
    }

    /// 把下面横排的段锁到某一集所在的段、滚到它
    private func lockBrowse(_ number: Int?) {
        browseRange = number.map(EpisodeRanges.index(of:))
        browseFocus = number
    }

    /// 手动换段：滚到段里的锚点，没有就段首（同换季，只换横排，头图不动）
    private func switchRange(_ range: EpisodeRange) {
        withAnimation(.easeInOut(duration: 0.2)) {
            lockBrowse(EpisodeRanges.entry(of: range, anchor: browseAnchor))
        }
    }

    /// 宫格里点了一集：头图改讲它（同点卡片），段与横排跟过去
    private func pickEpisode(_ number: Int) {
        guard let episode = browseEpisodes.first(where: { $0.episodeNumber == number }) else { return }
        selectEpisode(episode)
        lockBrowse(number)
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

    /// 点分集卡片：头图改讲这一集（续播点随 `unitKey` 重新取），不起播；起播走卡片上的播放键或头图的「播放」
    private func selectEpisode(_ episode: API.EpisodeView) {
        guard let browseSeason else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            season = browseSeason
            episodes = browseEpisodes
            selectedEpisode = episode
        }
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
    /// 这一季有观看记录时，锚点那张卡左上角标「接着看」
    var isResume = false
    /// 点卡片：选中这一集（头图改讲它）
    let select: () -> Void
    /// 点悬停浮出的播放键：起播
    let play: () -> Void
    let toggleWatched: () -> Void

    private let width = MacMetrics.landscapeWidth
    @State private var hovering = MacCardDebug.forceHover

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                RemoteImage(url: imageURL, placeholderText: "第 \(episode.episodeNumber) 集")
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottomLeading) { stillBand }
                    .overlay(alignment: .topLeading) {
                        HStack(spacing: 5) {
                            if isResume {
                                Text("接着看")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.orange, in: .capsule)
                            }
                            if episode.played {
                                Label("已看", systemImage: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.62), in: .capsule)
                            }
                        }
                        .padding(7)
                    }
                    .overlay {
                        if hovering, episode.owned {
                            ZStack {
                                Color.black.opacity(0.2)
                                    .allowsHitTesting(false)
                                Button(action: play) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 44, height: 44)
                                        .contentShape(.circle)
                                }
                                .buttonStyle(.plain)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .help("播放")
                                .accessibilityLabel("播放第 \(episode.episodeNumber) 集")
                                .accessibilityIdentifier("mac-episode-play-\(episode.episodeNumber)")
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
        .help(episode.owned ? "第 \(episode.episodeNumber) 集" : "这一集还没有片源")
        .accessibilityLabel("第 \(episode.episodeNumber) 集 \(episode.name ?? "")")
        .accessibilityValue(isResume ? "接着看" : "")
        .accessibilityAddTraits(isStage ? .isSelected : [])
    }

    /// 剧照左下：▶ 片长（看了一半的写看到哪、压进度条）
    @ViewBuilder
    private var stillBand: some View {
        let inProgress = episode.positionMs > 0  // 含看完后重看到一半的
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

/// 横排首尾的「上一段 / 下一段」小卡：和剧照一样高，点了换到那一段
private struct MacRangeEdgeCard: View {
    let title: String
    let symbol: String
    let range: EpisodeRange
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(range.label).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            }
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
            .frame(width: 120, height: MacMetrics.landscapeWidth * 9 / 16)
            .background(.white.opacity(hovering ? 0.12 : 0.06), in: .rect(cornerRadius: MacMetrics.cardCorner))
            .overlay { RoundedRectangle(cornerRadius: MacMetrics.cardCorner).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
            .contentShape(.rect)
        }
        .buttonStyle(MacCardButtonStyle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
        .help("\(title)：第 \(range.label) 集")
    }
}

/// 一排段胶囊（下面横排与「全部分集」弹窗共用）：选中的段白底黑字（同季胶囊），锚点所在的段右上角橙点；选中段滚到中间
private struct MacRangeChips: View {
    let ranges: [EpisodeRange]
    let current: Int?
    let anchor: Int?
    var idPrefix = "episode-range"
    var edge = MacMetrics.edge
    let select: (EpisodeRange) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ranges) { range in
                        let resume = anchor.map(range.contains) ?? false
                        Button(range.label) { select(range) }
                            .buttonStyle(MacSeasonTabStyle(selected: range.index == current))
                            .monospacedDigit()
                            .overlay(alignment: .topTrailing) {
                                if resume {
                                    Circle().fill(Color.orange).frame(width: 6, height: 6).padding(.top, 3).padding(.trailing, 6)
                                        .allowsHitTesting(false)
                                }
                            }
                            .accessibilityAddTraits(range.index == current ? .isSelected : [])
                            .accessibilityValue(resume ? "接着看" : "")
                            .accessibilityIdentifier("\(idPrefix)-\(range.index)")
                            .id(range.index)
                    }
                }
                .padding(.horizontal, edge)
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .task(id: current) {
                guard let current else { return }
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation { proxy.scrollTo(current, anchor: .center) }
            }
        }
    }
}

/// 「全部分集」弹窗：标题 + 在库数、段胶囊（打开时落在锚点的段）、10 列数字宫格（一段最多 50 集，五行放得下）。
/// 格子：已看 ✓、进度条、缺集虚线（不可点，同缺集卡）、锚点橙边、头图正讲的那一集白底
private struct MacEpisodeGridPanel: View {
    let episodes: [API.EpisodeView]
    let ranges: [EpisodeRange]
    let anchor: Int?
    let selected: Int?
    let pick: (Int) -> Void
    @State private var range: Int

    init(episodes: [API.EpisodeView], ranges: [EpisodeRange], anchor: Int?, selected: Int?, pick: @escaping (Int) -> Void) {
        self.episodes = episodes
        self.ranges = ranges
        self.anchor = anchor
        self.selected = selected
        self.pick = pick
        let start = (anchor ?? selected).flatMap { EpisodeRanges.range(containing: $0, in: ranges) } ?? ranges.first
        _range = State(initialValue: start?.index ?? 0)
    }

    var body: some View {
        let current = ranges.first { $0.index == range }
        let shown = current.map { r in episodes.filter { r.contains($0.episodeNumber) } } ?? episodes
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("全部分集").font(.system(size: 17, weight: .bold))
                Text("在库 \(episodes.filter(\.owned).count) / \(episodes.count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            MacRangeChips(ranges: ranges, current: range, anchor: anchor, idPrefix: "episode-grid-range", edge: 18) { range = $0.index }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 10), alignment: .leading, spacing: 6) {
                ForEach(shown, id: \.episodeNumber) { episode in
                    MacEpisodeGridCell(episode: episode, anchor: episode.episodeNumber == anchor,
                                       selected: episode.episodeNumber == selected) { pick(episode.episodeNumber) }
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 5 * 40 + 4 * 6, alignment: .top)
        }
        .padding(.vertical, 18)
        .frame(width: 10 * 48 + 9 * 6 + 36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("episode-grid")
    }
}

private struct MacEpisodeGridCell: View {
    let episode: API.EpisodeView
    let anchor: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let progress = episode.positionMs > 0 ? episode.progressPercent : nil
        let states: [String?] = [anchor ? "接着看" : nil, episode.owned ? nil : "缺集", episode.played ? "已看" : nil,
                                 progress.map { "看到 \($0)%" }]
        let fill: Color = selected ? .white.opacity(0.92) : !episode.owned ? .clear
            : .white.opacity(hovering ? 0.16 : episode.played ? 0.04 : 0.08)
        let ink: Color = selected ? .black : !episode.owned ? .white.opacity(0.35) : episode.played ? .white.opacity(0.6) : .white
        Button(action: action) {
            Text("\(episode.episodeNumber)")
                .font(.system(size: 13, weight: selected ? .bold : .medium))
                .monospacedDigit()
                .foregroundStyle(ink)
                .frame(width: 48, height: 40)
                .background(fill, in: .rect(cornerRadius: 8))
                .overlay {
                    if !episode.owned {
                        RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if episode.played {
                        // 已看由 accessibilityValue 说；勾号本身不进无障碍树
                        Image(systemName: "checkmark").font(.system(size: 7, weight: .black)).foregroundStyle(.green).padding(4)
                            .accessibilityHidden(true)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let progress {
                        Rectangle().fill(selected ? Color.black.opacity(0.4) : Color.orange)
                            .frame(width: 48 * CGFloat(progress) / 100, height: 3)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    if anchor { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange, lineWidth: 2) }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!episode.owned)
        .onHover { inside in hovering = inside && episode.owned }
        .help(episode.owned ? (episode.name ?? "第 \(episode.episodeNumber) 集") : "这一集还没有片源")
        .accessibilityLabel("第 \(episode.episodeNumber) 集")
        .accessibilityValue(states.compactMap { $0 }.joined(separator: "，"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("episode-grid-\(episode.episodeNumber)")
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
