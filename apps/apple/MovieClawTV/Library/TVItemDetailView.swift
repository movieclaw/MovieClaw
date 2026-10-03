import SwiftUI

/// 条目详情（docs/design/tvos-app.md §3.4），两截，照系统 Apple TV App 的详情页：
/// - **首屏**沿用首页大图区的组件（`TVStageBackdrop` + `TVStageBlock` + `TVStageInfo`）：剧照原图铺满，
///   片名 Logo 比首页大、整块更靠上，下面不露任何一行——这一部就是主体（2026-10-03 用户要求与首页拉开差别）。
///   剧集讲接着看的那一集；从「接下来继续」进来（首页大图的「详情」、卡片的长按菜单）直接是那一季那一集。
/// - **往下按整页滑到下半截**：顶部居中的片名 → 季（焦点移到哪一季，下面就换成哪一季）→ 分集横排（剧照 + 第几集、集名、
///   简介、日期）→ 演职员 → 所属合集。剧照跟着滚走，露出由剧照边缘色往下渐暗的底色。
///   2026-10-03 先试过 Netflix 式的单独「更多集」页，用户改定为往下滑——更合我们整体「上下翻行」的交互习惯。
///
/// 与 iPhone 版同一套数据：`libraryItemsGet` 拿详情（含演职员）、`playbackResume` 拿续播点（主按钮三态：播放 / 继续 mm:ss /
/// 重新播放）、`librarySetMarks` 收藏与标记已看。电视上不做任何管理操作（修正识别、换图、删除……都在手机和网页上）。
/// 播放器关掉、服务端收下「停止」后（`.playbackStopReported`）重拉续播点与分集进度，按钮立刻跟上刚才看到的位置。
struct TVItemDetailView: View {
    let libraryId: Int
    let itemId: Int

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @Environment(\.resetFocus) private var resetFocus
    /// 页面的焦点范围：回首屏交焦点时，赋值不灵就请焦点引擎在这里面重挑一次（落到声明了首选的主按钮上）
    @Namespace private var focusScope

    @State private var detail: API.LibraryItemDetailView?
    @State private var failed = false
    /// 首屏讲的那一季、那一集（接着看的）
    @State private var season: Int?
    @State private var episodes: [API.EpisodeView] = []
    @State private var selectedEpisode: API.EpisodeView?
    /// 下半截正在看的那一季（换季只换下面的分集横排，首屏还讲接着看的那一集）
    @State private var browseSeason: Int?
    @State private var browseEpisodes: [API.EpisodeView] = []
    @State private var watched: API.PlaybackStateView?
    /// 电影所属的作品系列（《哈利·波特》这种）：整个系列按上映顺序，库里没有的也在（置灰）。没有系列为 nil
    @State private var series: API.CollectionSeriesView?
    @State private var favorite: Bool?
    @State private var marking = false
    /// 列表滚动距离：只给背景层读
    @State private var scroll = TVStageScroll()
    /// 这一刻允许滚回首屏（只有「回首屏」那段代码打开）
    @State private var snapGate = TVDetailSnapGate()
    /// 正在回首屏：首屏的按钮提前放出来接焦点（见 `backToStage`）
    @State private var returningToStage = false
    /// 列表的滚动位置：焦点进下半截时滑到下半截的顶，回到按钮时滚回顶部
    @State private var position = ScrollPosition(edge: .top)
    /// 分集横排的滚动位置：行是惰性的，屏幕外的卡还没建出来，焦点要落过去得先滚到它
    @State private var episodeScroll = ScrollPosition(idType: Int.self)
    /// 列表内容的上沿离屏幕顶多远（压栈页面实测 48.5）：首屏上半块按它定高
    @State private var topInset: CGFloat = 48.5
    @FocusState private var actionFocus: DetailAction?
    /// 回首屏的接应点拿到了焦点（见 `stageReturnCatcher`）
    @FocusState private var catcherFocused: Bool
    @FocusState private var lowerFocus: LowerFocus?
    /// 在下半截点播的那一集：播完退回详情时首屏改讲它，而不是进来时那一集
    @State private var playedElsewhere: (season: Int, episode: Int)?

    private enum DetailAction { case play, restart, favorite, played }
    private enum LowerFocus: Hashable {
        case season(Int)
        case episode(Int)
        case person(Int)
        case collection(Int)
        /// 系列里的一部（按 TMDB id，库里没有的也能停焦点）
        case seriesPart(Int)
    }

    private var isMovie: Bool { detail?.kind != "tv" }

    var body: some View {
        ZStack {
            // 剧照原图按 16:9 铺满整屏，只在左下角罩一团中性的黑托字（见 TVStageBackdrop.fullImage）；
            // 往下滑时剧照跟着内容滚走，露出同一张剧照的模糊版（与海报墙同一套背景）
            TVStageBackdrop(pinnedScroll: 0, fadeDistance: 900, url: backdropURL, tint: nil, scroll: scroll, fullImage: true,
                            ambientURL: api.image(detail?.backdropUrl ?? detail?.posterUrl, .tvLandscape))
            if failed {
                TVStateView(symbol: "questionmark.folder", title: "未能加载该条目",
                            message: "条目可能已被删除或重新识别为其他作品。", actionTitle: "返回") { router.pop() }
            } else if let detail {
                content(detail)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await reload() }
        .task { favorite = (try? await api.playbackMarksGet(mediaItemId: itemId))?.isFavorite }
        // 进了详情页多半要播：先把起播要用的连接连好（同 iPhone 版）
        .task { PlaybackPreconnect.warm(api: api) }
        .task(id: unitKey) { await loadResume() }
        // 内容加载出来时焦点还在页面外面（冷启动直接落在详情、焦点停在标签栏上）：放到主按钮上。
        // 已经在页面里（从卡片点进来，系统已放在主按钮上）就不动
        .task(id: detail != nil) {
            guard detail != nil else { return }
            try? await Task.sleep(for: .milliseconds(200))
            if actionFocus == nil, lowerFocus == nil { actionFocus = canPlay ? .play : .favorite }
        }
        // 焦点停在哪一季，下面就换成哪一季（停稳 0.25 秒再换，一路划过去不逐季加载）
        .task(id: lowerFocus) {
            guard case let .season(number) = lowerFocus, number != browseSeason else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await loadBrowse(number)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopReported)) { note in
            guard note.userInfo?["mediaItemId"] as? Int == itemId else { return }
            Task {
                await refreshBrowse()
                // 在下半截播了别的集：首屏改讲刚看的那一集（续播点随 unitKey 重拉）
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-item-\(itemId)")
    }

    // MARK: 页面

    /// 整页背景：条目的背景图原图（与首页大图同一个地址，从首页进来直接从缓存出图），没有用海报
    private var backdropURL: URL? { api.image(detail?.backdropUrl ?? detail?.posterUrl) }

    private func content(_ detail: API.LibraryItemDetailView) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // 首屏：Logo 放大到最高 200，文字与按钮贴底排，下沿与首页一样在 y=918。剧集底下露出分集剧照的上沿——
                // 整屏都是大图的话，用户不知道往下还有东西（2026-10-03 用户指出，同 Apple TV）；电影不露（见 lowerGap）
                TVScrollGate(scroll: scroll, showsWhenLower: false, threshold: lowerScroll) {
                TVStageBlock(topInset: topInset, bottom: 918) {
                    TVStageInfo(
                        title: detail.title,
                        logoURL: api.image(detail.logoUrl),
                        headline: episodeHeadline,
                        meta: metaLine(detail),
                        badges: Self.mediaBadges(detail),
                        overview: isMovie ? detail.localMeta?.plot : (selectedEpisode?.overview ?? detail.localMeta?.plot),
                        overviewLines: 3,
                        logoSize: CGSize(width: 860, height: 200)
                    )
                    .accessibilityIdentifier("tv-item-stage")
                } actions: {
                    actions(detail)
                }
                // 右下角浮一段演职员（同系统 Apple TV App 详情页右下的「主演 …」）：导演一行、主演两位一行，
                // 下沿与按钮一排对齐；想看全部往下滑到「演职员」（2026-10-03 用户要求）
                .overlay(alignment: .bottomTrailing) {
                    stageCredits(detail)
                        .padding(.trailing, TVMetrics.edge)
                        .padding(.bottom, 34)
                }
                }
                lowerSection(detail)
                    // 下半截按内容本身的高度排（横滑行是可伸缩的，不定死会把多出来的高度吃掉、把下面的行挤到屏幕底），
                    // 再至少占满滑上来之后的一屏：电影只有演职员、合集，不够高的话滚不到吸附点，上面会露出半截首屏
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 1080 - lowerScreenTop, alignment: .top)
                    // 片名与选季挂在下半截的顶上、跟着内容一起滚（往下看演职员时自然滚走）；但不占排版的位置——
                    // 占了的话首屏底下露出来的就成了片名，而不是分集 / 演职员。首屏时它们藏着、不接焦点，
                    // 滑下来才淡入：先露分集，片名、季数滑下来再出场（2026-10-03 用户要求）
                    .overlay(alignment: .top) {
                        VStack(spacing: 34) {
                            // 接应点单独一层：回首屏的路上它一直能接焦点（片名那层随滚动淡出、不接焦点）
                            TVScrollGate(scroll: scroll, showsWhenLower: true, threshold: lowerScroll,
                                         forceEnabled: returningToStage, fades: false) {
                                stageReturnCatcher
                            }
                            TVScrollGate(scroll: scroll, showsWhenLower: true, threshold: lowerScroll) {
                                lowerHeader(detail)
                            }
                        }
                        .alignmentGuide(.top) { $0[.bottom] + 36 }
                    }
                    .padding(.top, lowerGap)
            }
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .scrollPosition($position)
        // 两截之间不停在半中间：往下按整页滑到下半截的顶（片名在最上面），往上回到首屏
        .scrollTargetBehavior(TVDetailSnap(scroll: scroll, gate: snapGate, lowerTop: lowerScroll))
        .focusScope(focusScope)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scroll.offset = offset
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, inset in
            topInset = inset
        }
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        // 焦点从下半截回到按钮：滚回顶部恢复首屏——系统只滚到按钮刚好露出为止
        .onChange(of: actionFocus) { old, new in
            guard old == nil, new != nil else { return }
            withAnimation(.easeInOut(duration: 0.4)) { position.scrollTo(edge: .top) }
        }
    }

    /// 「第 2 季 第 6 集 · 集名」（剧集：接着看的那一集）
    private var episodeHeadline: String? {
        guard !isMovie, let selectedEpisode, let season else { return nil }
        return TVStageInfo.episodeLine(season: season, episode: selectedEpisode.episodeNumber, name: selectedEpisode.name)
    }

    // MARK: 首屏的按钮

    private var canPlay: Bool {
        guard let detail else { return false }
        if isMovie { return detail.files.contains { $0.state == "in_place" } }
        return selectedEpisode?.owned == true
    }

    /// 主按钮上的「第 1 季第 3 集」：首屏讲的那一集；电影没有。特别篇（第 0 季）写「特别篇第 2 集」
    private var unitLabel: String? {
        guard !isMovie, let season, let episode = selectedEpisode?.episodeNumber else { return nil }
        return season == 0 ? "特别篇第 \(episode) 集" : "第 \(season) 季第 \(episode) 集"
    }

    /// 一排按钮，照系统 Apple TV App 的详情页：跟播放有关的是宽按钮（播放 / 从头播放），
    /// 收藏、标为已看折成只有图标的圆按钮跟在后面（2026-10-03 用户要求）
    private func actions(_ detail: API.LibraryItemDetailView) -> some View {
        let position = watched?.positionMs ?? 0
        let finished = watched?.played ?? false
        let resumable = canPlay && !finished && position > 0
        let verb = finished ? "重新播放" : resumable ? "继续" : "播放"
        // 剧集在按钮上写明是哪一集（同 Netflix、系统 Apple TV App 的「继续 第 1 季第 3 集」）：只写「继续 46:56」
        // 看不出续的是第几集（2026-10-04 用户要求）。时间点跟在后面
        let parts = [verb, unitLabel, resumable ? Formatters.clock(Double(position) / 1000) : nil].compactMap { $0 }
        let label = parts.count > 2 ? "\(parts[0]) \(parts[1]) · \(parts[2])" : parts.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 18) {
            // 不另画进度条和剩余时间：主按钮上已经写着「继续 第 1 季第 3 集 · mm:ss」（2026-10-03 用户要求去掉）
            if !canPlay, !isMovie, detail.seasons.isEmpty || episodes.allSatisfy({ !$0.owned }) {
                Text(detail.seasons.isEmpty ? "这部剧还没有可播放的分集" : "这一集还没有片源，往下挑别的集")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 28) {
                if canPlay {
                    Button { play(start: finished ? 0 : nil) } label: {
                        Label(label, systemImage: "play.fill")
                            .padding(.horizontal, 16)
                    }
                    .focused($actionFocus, equals: .play)
                    .prefersDefaultFocus(returningToStage, in: focusScope)
                    .accessibilityIdentifier("tv-item-play")
                }
                if resumable {
                    Button { play(start: 0) } label: {
                        Label("从头播放", systemImage: "backward.end.fill")
                    }
                    .focused($actionFocus, equals: .restart)
                    .accessibilityIdentifier("tv-item-restart")
                }
                // 收藏与单集无关，一直在：整部剧都还没有片源时，首屏也得有个能接焦点的按钮——否则焦点一进页面就落到
                // 下半截露出的那一行上，往上回首屏时没有落点，原地弹一下又回去（2026-10-03 用户在《中餐厅》上发现）
                Button { Task { await toggleFavorite() } } label: {
                    Image(systemName: favorite == true ? "heart.fill" : "heart")
                }
                .buttonBorderShape(.circle)
                .disabled(marking)
                .focused($actionFocus, equals: .favorite)
                .prefersDefaultFocus(returningToStage && !canPlay, in: focusScope)
                .accessibilityLabel(favorite == true ? "已收藏" : "收藏")
                .accessibilityIdentifier("tv-item-favorite")
                if canPlay {
                    Button { Task { await togglePlayed() } } label: {
                        Image(systemName: finished ? "checkmark.circle.fill" : "checkmark")
                    }
                    .buttonBorderShape(.circle)
                    .disabled(marking)
                    .focused($actionFocus, equals: .played)
                    .accessibilityLabel(finished ? "已看完" : "标为已看")
                    .accessibilityIdentifier("tv-item-played")
                }
            }
            // 按钮这一行横贯整屏做成焦点区：从下半截往上先落到这里，进来时落在主按钮上（同首页）
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
            .defaultFocus($actionFocus, canPlay ? .play : .favorite, priority: .userInitiated)
        }
    }

    // MARK: 下半截

    /// 片名（居中）→ 季 → 分集 → 演职员 → 所属合集；电影没有季与分集
    /// 下半截滑上来之后，第一行在屏幕上的 y：上面留给居中的片名（和选季，有多季时）——只有一季就不给选季留空，
    /// 否则片名和分集之间空出一大块（2026-10-03 用户在真机上指出）
    private var lowerScreenTop: CGFloat { hasSeasonTabs ? 330 : 250 }
    /// 首屏下沿（918）到下半截的距离，决定首屏底下露出多少（2026-10-04 用户改定）：
    /// - 剧集露分集剧照的上沿约 60 点，与首页「接下来继续」露出的一样多（此前露 120 多点，嫌太高）；
    /// - 电影有系列时露系列一行：行标题「哈利·波特（系列） 已有 7 / 共 8」加海报上沿约 60 点，与首页「接下来继续」露法一样
    ///   （海报是方角卡片，露一角好看，也一眼看出这部有前传续集）；
    /// - 没有系列的电影什么都不露：下半截第一行是演职员，露出半截圆头像不好看。整块排到屏幕外（「演职员」标题从约 1100 起），
    ///   往下按照样滑到下半截
    private var lowerGap: CGFloat {
        guard isMovie else { return 82 }
        return series == nil ? 164 : 20
    }
    /// 滑到下半截的滚动量：下半截静止时从屏幕 y=918 + `lowerGap` 排起，滚到它落在 `lowerScreenTop`
    private var lowerScroll: CGFloat { 918 + lowerGap - lowerScreenTop }
    private var hasSeasonTabs: Bool { !isMovie && (detail?.seasons.count ?? 0) > 1 }

    private func lowerSection(_ detail: API.LibraryItemDetailView) -> some View {
        let hasEpisodes = !isMovie && !detail.seasons.isEmpty
        return VStack(alignment: .leading, spacing: 44) {
            if hasEpisodes {
                // 有选季时它浮在上面，往上先到选季；没有选季时这一行就是下半截的顶，往上回首屏
                episodeRow
            }
            if let series {
                seriesRow(series)
            }
            let people = Self.castPeople(detail)
            if !people.isEmpty {
                TVShelf(title: "演职员") {
                    ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                        TVPersonCard(name: person.name, role: person.role, avatarURL: api.image(person.avatar)) {
                            // 没有 TMDB 影人 id 的（NFO 里只有姓名的导演）没有影人页，按确认不跳转
                            guard let id = person.personId else { return }
                            router.push(.person(tmdbId: id, name: person.name, avatar: person.avatar, fromItem: itemId))
                        }
                        .focused($lowerFocus, equals: .person(index))
                        .accessibilityIdentifier(person.personId.map { "tv-cast-\($0)" } ?? "tv-cast-none")
                    }
                }
                // 电影（没有系列一行时）从按钮往下直接进这一行：落在第一位（导演）。这一行在首屏外，系统按几何就近挑会落到中间某一位
                .defaultFocus($lowerFocus, .person(0), priority: .userInitiated)
            }
            if !otherCollections(detail).isEmpty {
                collectionsRow(detail)
            }
        }
    }

    /// 下半截顶上：居中的片名，下面一排选季（只有一季就不画）
    private func lowerHeader(_ detail: API.LibraryItemDetailView) -> some View {
        VStack(spacing: 36) {
            TVTitleArt(title: detail.title, logoURL: api.image(detail.logoUrl), size: CGSize(width: 620, height: 110),
                       alignment: .bottom, textSize: 52)
                .frame(maxWidth: .infinity)
            if hasSeasonTabs {
                seasonTabs(detail)
            }
        }
    }

    /// 回首屏的接应点：下半截最上面那一行（选季，单季剧是分集、电影是演职员）再往上，焦点落到这条看不见的横条上，
    /// 一落上就把整页送回首屏、焦点交给主按钮（`backToStage`）。
    ///
    /// 不能用 `onMoveCommand` 接「上」：它只响应按方向键 / 点遥控器边缘，在触控板上**滑**不会触发——真机上往上滑时
    /// 焦点找不到去处，原地弹一下就停住（2026-10-03 用户在真机上发现，模拟器里一直是「按」所以没测出来）。
    /// 落焦点是系统焦点引擎做的，按和滑走的是同一条路。横贯整屏，从哪一列往上都找得到它；跟着片名一起只在下半截能接焦点
    private var stageReturnCatcher: some View {
        Button {} label: {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 2)
                .contentShape(.rect)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($catcherFocused)
        .onChange(of: catcherFocused) { _, focused in
            if focused { backToStage() }
        }
        .accessibilityHidden(true)
    }

    /// 从下半截回首屏（焦点落到 `stageReturnCatcher` 时）：整页滚回首屏，焦点回到主按钮。首屏的按钮在下半截时
    /// 不接焦点（它们还剩一截留在屏幕顶上，会和选季抢焦点），所以系统自己找不到往上的去处，这里接手
    private func backToStage() {
        // 接应点在回首屏的路上一直能接焦点（`returningToStage`），焦点先留在它身上；整页滚回首屏、首屏的按钮恢复成
        // 正常可用的样子之后，再把焦点交给主按钮。反过来先交焦点不行：页面还停在下半截时首屏按钮是锁着的，
        // 临时放开去赋焦点、请焦点引擎重挑都常被系统忽略，页面回去了焦点却哪儿也没落（2026-10-03 实测）
        returningToStage = true
        snapGate.allowsTop = true
        Task {
            // 焦点落到接应点的同一刻，系统也在为露出它而滚动（电影页从演职员那一行的 768 滚到 688）：同一刻发出的滚动
            // 会被它盖掉，页面停在半路（实测）。先让它起步再滚回顶部，没到顶就再滚一次，到顶了才交焦点
            for _ in 0 ..< 4 {
                try? await Task.sleep(for: .milliseconds(80))
                guard scroll.offset > 1 else { break }
                withAnimation(.easeInOut(duration: 0.4)) { position.scrollTo(edge: .top) }
                try? await Task.sleep(for: .milliseconds(420))
            }
            let target: DetailAction = canPlay ? .play : .favorite
            for i in 0 ..< 10 where actionFocus != target {
                // 先直接赋值；不灵就请焦点引擎重挑（主按钮这时声明了首选），交替着来。整页包在 focusScope 里之后
                // 实测 20 次都是第一下赋值就成，重挑是兜底
                if i.isMultiple(of: 2) {
                    actionFocus = target
                } else {
                    resetFocus(in: focusScope)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            returningToStage = false
            snapGate.allowsTop = false
        }
    }

    /// 季：一排胶囊，选中的那一季垫一层浅底；焦点移到哪一季，下面就换成哪一季
    private func seasonTabs(_ detail: API.LibraryItemDetailView) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(detail.seasons, id: \.self) { number in
                    Button(number == 0 ? "特别篇" : "第 \(number) 季") {
                        Task { await loadBrowse(number) }
                    }
                    .buttonStyle(TVSeasonTabStyle(selected: number == browseSeason))
                    .focused($lowerFocus, equals: .season(number))
                    .accessibilityIdentifier("tv-season-\(number)")
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .focusSection()
        // 从按钮往下进来落在正在看的这一季上，不按位置挑第一季
        .defaultFocus($lowerFocus, browseSeason.map(LowerFocus.season), priority: .userInitiated)
    }

    /// 分集横排：剧照（片长或剩多久、进度）+ 第几集、集名、四行简介、首播日期（同系统 Apple TV App）
    private var episodeRow: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: TVMetrics.cardSpacing) {
                ForEach(browseEpisodes, id: \.episodeNumber) { episode in
                    TVEpisodeCard(
                        episode: episode,
                        imageURL: api.image(episode.stillUrl, .tvLandscape),
                        runtimeMinutes: detail?.localMeta?.runtimeMinutes
                    ) {
                        guard episode.owned, let browseSeason else { return }
                        router.play(PlayRequest(mediaItemId: itemId, season: browseSeason, episode: episode.episodeNumber))
                    }
                    .contextMenu {
                        if episode.owned {
                            Button(episode.played ? "标为未看" : "标为已看") {
                                Task { await markEpisode(episode, played: !episode.played) }
                            }
                        }
                    }
                    .focused($lowerFocus, equals: .episode(episode.episodeNumber))
                    .accessibilityIdentifier("tv-episode-\(episode.episodeNumber)")
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .scrollPosition($episodeScroll)
        .focusSection()
        // 往下进分集落在接着看的那一集（换了季就是那一季接着看的），不按位置挑第一集
        .defaultFocus($lowerFocus, entryEpisode.map(LowerFocus.episode), priority: .userInitiated)
        .onAppear { scrollEpisodesToEntry() }
    }

    /// 「所属合集」：一排文字按钮，按下进那个合集的海报墙。试过做成与库卡片同样的封面卡（2026-10-04），
    /// 用户嫌太重：一部片通常只在一两个合集里，一张孤零零的大卡不好看、各部之间也差不多，入口用文字就够
    private func collectionsRow(_ detail: API.LibraryItemDetailView) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("所属合集")
                .font(.system(size: 32, weight: .semibold))
            HStack(spacing: 24) {
                ForEach(otherCollections(detail), id: \.id) { row in
                    Button(row.name) { router.push(.collection(id: row.id, name: row.name)) }
                        .focused($lowerFocus, equals: .collection(row.id))
                }
            }
        }
        .padding(.horizontal, TVMetrics.edge)
        .focusSection()
    }

    /// 作品系列一行（2026-10-04 用户要求）：电影往下滑的第一行，整个系列按上映顺序排，标题旁写「已有 7 / 共 8」。
    /// 这一部标「本片」，按下回首屏（播放按钮就在那）；库里没有的置灰标「未入库」，按下不做事——
    /// 电视上订阅暂时收起（TVMainView.showsDiscoverAndSubscriptions），以后可改成去订阅。
    /// 往下进这一行落在「本片」上，看得出这一部排第几
    private func seriesRow(_ series: API.CollectionSeriesView) -> some View {
        TVShelf(title: series.seriesName ?? "系列", detail: "已有 \(series.ownedCount) / 共 \(series.total)") {
            ForEach(series.parts, id: \.tmdbId) { part in
                let current = part.mediaItemId == itemId
                let missing = part.mediaItemId == nil
                TVPosterCard(
                    title: part.title,
                    subtitle: part.releaseDate.map { String($0.prefix(4)) },
                    imageURL: api.image(part.posterUrl, .tvPoster),
                    badge: current ? "本片" : missing ? "未入库" : nil
                ) {
                    if current {
                        backToStage()
                    } else if let id = part.mediaItemId {
                        router.push(.item(libraryId: libraryId, itemId: id))
                    }
                }
                .opacity(missing ? 0.45 : 1)
                .focused($lowerFocus, equals: .seriesPart(part.tmdbId))
            }
        }
        .defaultFocus($lowerFocus, series.parts.first { $0.mediaItemId == itemId }.map { .seriesPart($0.tmdbId) },
                      priority: .userInitiated)
    }

    /// 「所属合集」里不再列系列本身：上面已经有系列一行了
    private func otherCollections(_ detail: API.LibraryItemDetailView) -> [API.ItemCollectionRef] {
        guard series != nil, let seriesId = detail.seriesCollectionId else { return detail.collections }
        return detail.collections.filter { $0.id != seriesId }
    }

    /// 读电影所属系列的整份清单（TMDB 档案 + 库里有哪几部）。只有一部、或拉不到上游档案（没配 TMDB、网络不通）
    /// 时不出这一行——只剩自己一部的「系列」没有可看的
    private func loadSeries(_ detail: API.LibraryItemDetailView) async {
        guard detail.kind != "tv", let id = detail.seriesCollectionId,
              let fresh = try? await api.collectionSeriesGet(collectionId: id),
              fresh.available, fresh.parts.count > 1 else {
            series = nil
            return
        }
        series = fresh
    }

    /// 下半截分集横排进来时落在哪一集：首屏讲的那一季是首屏那一集，别的季是那一季接着看的那一集
    private var entryEpisode: Int? {
        if browseSeason == season, let selectedEpisode { return selectedEpisode.episodeNumber }
        return Self.resumeEpisode(in: browseEpisodes)?.episodeNumber
    }

    /// 分集横排滚到要落焦点的那一集，排在行首边距处。打开页面时行还没建出来，出现时再滚一次
    private func scrollEpisodesToEntry() {
        guard let number = entryEpisode else { return }
        episodeScroll.scrollTo(id: number, anchor: Self.firstCardAnchor)
    }

    /// 让一张分集卡停在行首边距处的锚点：卡上这一点与可见区同一点对齐，
    /// x 满足「卡的左边 = 可见区左边 + 边距」（卡 416 宽、屏 1920 宽）
    private static let firstCardAnchor = UnitPoint(x: TVMetrics.edge / (1920 - TVMetrics.landscapeWidth), y: 0.5)

    /// 首屏右下角的演职员：「导演 某某」「主演 某某、某某」，标签灰、人名白；没有就不画
    @ViewBuilder
    private func stageCredits(_ detail: API.LibraryItemDetailView) -> some View {
        let meta = detail.localMeta
        let directors = (meta?.directorCredits.map(\.name)).flatMap { $0.isEmpty ? nil : $0 } ?? meta?.directors ?? []
        let actors = (meta?.actors ?? []).prefix(2).map(\.name)
        if !directors.isEmpty || !actors.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let director = directors.first {
                    creditLine("导演", [director])
                }
                if !actors.isEmpty {
                    creditLine("主演", Array(actors))
                }
            }
            // 按内容收缩、右边贴页面边线（同 Apple TV：一块左对齐的字整体靠右）；只有三个名字，不会长到压住左边的文字
            .fixedSize()
            .shadow(color: .black.opacity(0.55), radius: 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("tv-item-credits")
        }
    }

    private func creditLine(_ label: String, _ names: [String]) -> some View {
        (Text(label + "  ").foregroundStyle(.white.opacity(0.6))
            + Text(names.joined(separator: "、")).foregroundStyle(.white))
            .font(.system(size: 24, weight: .medium))
            .lineLimit(1)
    }

    typealias CastPerson = (name: String, role: String?, avatar: String?, personId: Int?)

    /// 演职员：导演在前（结构化的优先，没有就退回姓名），演员跟着，同 iPhone 版。带 TMDB 影人 id 的能进影人页
    static func castPeople(_ detail: API.LibraryItemDetailView) -> [CastPerson] {
        guard let meta = detail.localMeta else { return [] }
        let directors: [CastPerson] = meta.directorCredits.isEmpty
            ? Array(NSOrderedSet(array: meta.directors)).compactMap { $0 as? String }.map { ($0, "导演", nil, nil) }
            : meta.directorCredits.map { ($0.name, "导演", $0.thumbUrl, $0.tmdbPersonId) }
        return directors + meta.actors.map { ($0.name, $0.role.map { "饰 \($0)" }, $0.thumbUrl, $0.tmdbPersonId) }
    }

    // MARK: 派生

    private var unitKey: String {
        if isMovie { return detail == nil ? "-" : "movie" }
        guard let season, let selectedEpisode else { return "-" }
        return "\(season)/\(selectedEpisode.episodeNumber)"
    }

    /// 片名正下方的第一行（2026-10-03 用户定：第一眼要看到的）：年份 · 类型（前两个） · 电影写片长、剧集两季以上写「共 X 季」，
    /// 后面跟画质、HDR、音频小标签（`mediaBadges`）。评分先不放（还没想好放哪）
    private func metaLine(_ detail: API.LibraryItemDetailView) -> String {
        let meta = detail.localMeta
        var facts = [detail.year.map(String.init)].compactMap { $0 } + (meta?.genres ?? []).prefix(2)
        if isMovie {
            let runtime = meta?.runtimeMinutes ?? detail.files.first(where: { $0.durationSeconds != nil })?.durationSeconds.map { Int((Double($0) / 60).rounded()) }
            if let runtime, runtime > 0 { facts.append(Self.runtimeText(runtime)) }
        } else {
            let seasons = detail.seasons.filter { $0 > 0 }.count
            if seasons >= 2 { facts.append("共 \(seasons) 季") }
        }
        return facts.joined(separator: " · ")
    }

    /// 画质、HDR、音频小标签：在位的文件里各挑最好的那一档（多个版本、多集取最高的）。
    /// 分辨率 4K / HD（1080p、720p）；HDR 杜比视界 > HDR10+ > HDR10 > HLG > HDR；音频杜比全景声 > DTS:X > 7.1 > 5.1
    static func mediaBadges(_ detail: API.LibraryItemDetailView) -> [TVMediaBadge] {
        let sources = detail.files.filter { $0.state == "in_place" }
        var badges: [TVMediaBadge] = []
        let heights = sources.compactMap { $0.resolution.flatMap(Self.resolutionHeight) }
        if let best = heights.max() {
            switch best {
            case 4320...: badges.append(.init(text: "8K", style: .filled))
            case 2160...: badges.append(.init(text: "4K", style: .filled))
            case 720...: badges.append(.init(text: "HD", style: .filled))
            default: break
            }
        }
        let hdrPriority = ["Dolby Vision", "HDR10+", "HDR10", "HLG", "HDR"]
        if let hdr = sources.compactMap(\.hdr).min(by: { (hdrPriority.firstIndex(of: $0) ?? 99) < (hdrPriority.firstIndex(of: $1) ?? 99) }) {
            badges.append(.init(text: hdr == "Dolby Vision" ? "DOLBY VISION" : hdr.uppercased(), style: .outlined))
        }
        let audio = sources.flatMap { $0.audioStreams ?? [] }
        let described = audio.map { [$0.profile, $0.title, $0.codec].compactMap { $0 }.joined(separator: " ").lowercased() }
        if described.contains(where: { $0.contains("atmos") }) {
            badges.append(.init(text: "DOLBY ATMOS", style: .outlined))
        } else if described.contains(where: { $0.contains("dts:x") || $0.contains("dts-x") }) {
            badges.append(.init(text: "DTS:X", style: .outlined))
        } else if let channels = audio.compactMap(\.channels).max(), channels >= 6 {
            badges.append(.init(text: channels >= 8 ? "7.1" : "5.1", style: .outlined))
        }
        return badges
    }

    /// 「2160p」「4k」「1080」→ 画面高度
    static func resolutionHeight(_ raw: String) -> Int? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "8k": return 4320
        case "4k", "uhd": return 2160
        case "2k": return 1440
        default: return Int(normalized.filter(\.isNumber))
        }
    }

    static func runtimeText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时"
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
                // 在「接下来继续」里的剧打开接着看的那一季那一集（首页大图正讲第 2 季第 6 集，按「详情」进来还是它）；
                // 别的打开第一个有片源的季——综艺常只收了最新一季（《中餐厅》只有第 10 季），打开第 1 季就是一排缺集、
                // 首屏没有能播的；一季都没有片源才从第一季开始。
                // 分集读完再出页面：先出页面的话这一刻还没有分集，会闪一下「还没有可播放的分集」
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
            // 系列读完再出页面：首屏要按有没有系列决定底下露不露
            await loadSeries(fresh)
            detail = fresh
            failed = false
        } catch is CancellationError {
        } catch {
            if detail == nil { failed = true }
        }
    }

    /// 读首屏那一季的分集；不保留选择时选「接着看的那一集」：指定的那一集（「接下来继续」给的）→ 看了一半的 →
    /// 第一集没看过的 → 第一集
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

    /// 下半截换一季：分集横排换成那一季，滚到那一季接着看的那一集
    private func loadBrowse(_ number: Int) async {
        guard let result = try? await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: itemId, seasonNumber: number) else { return }
        browseSeason = number
        browseEpisodes = result.episodes
        scrollEpisodesToEntry()
    }

    /// 只换下半截的进度，不动滚动位置（从播放器退回来、标记已看之后）
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

/// 跟着滚动显隐的一层：首屏的文字与按钮滑走时淡出，下半截顶上的片名与选季滑下来时淡入。
/// 越过一半才能接焦点——两层在屏幕顶上会叠在一起（下半截只往上滚了不到一屏，首屏底下要露出它的第一行），
/// 都能接焦点的话会互相抢。淡出的那层不接焦点后，系统从下半截往上找不到去处，由 `backToStage` 接手。
/// 只这一层读滚动距离，滚动时不重算整页
private struct TVScrollGate<Content: View>: View {
    let scroll: TVStageScroll
    /// true：下半截的那层（滑下来淡入）；false：首屏那层（滑走淡出）
    let showsWhenLower: Bool
    /// 滑到下半截的滚动量
    let threshold: CGFloat
    /// 不管滚到哪都接焦点（回首屏的接应点：滚回首屏的路上焦点一直在它身上）
    var forceEnabled = false
    /// 跟着滚动淡入淡出；接应点本身看不见，不淡（透明度为 0 的视图系统不给焦点）
    var fades = true
    @ViewBuilder let content: () -> Content

    private var progress: Double { Double(min(1, max(0, scroll.offset / threshold))) }

    var body: some View {
        let shown = showsWhenLower ? max(0, progress - 0.5) * 2 : max(0, 1 - progress / 0.6)
        content()
            .opacity(fades ? shown : 1)
            .disabled(!forceEnabled && (showsWhenLower ? progress < 0.5 : progress > 0.5))
    }
}

/// 滚回首屏的闸门：不参与界面刷新，只给吸附规则读
private final class TVDetailSnapGate {
    var allowsTop = false
}

/// 详情页的滚动吸附：系统按焦点滚动时（只滚到焦点刚好露出为止），目标落在首屏与下半截之间就吸到下半截的顶；
/// 主动发起的滚动拦不住它：焦点一动系统紧接着自己滚，会把主动滚的量盖掉（实测）
private struct TVDetailSnap: ScrollTargetBehavior {
    /// 现在滚到哪了：判断这一下是往下还是往上
    let scroll: TVStageScroll
    let gate: TVDetailSnapGate
    /// 下半截的顶在内容里的位置：从首屏下沿排起，就是一屏高
    let lowerTop: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let y = target.rect.minY
        // 在下半截时系统有时会自己要求滚到最顶上（焦点进片名下面的选季那一刻，实测），首屏的按钮随之重新能接焦点，
        // 焦点就被它抢走。只有「回首屏」那段代码打开闸门时才放行
        if y < lowerTop - 0.5, scroll.offset >= lowerTop - 1, !gate.allowsTop {
            target.rect.origin.y = lowerTop
            return
        }
        // 从首屏往下进来，系统想滚过下半截的顶：第一行是高的海报（系列一行）时，系统为了把焦点那张卡连同下面的字
        // 露全会多滚一截，片名和行标题被顶出屏幕（2026-10-04 实测）。从首屏出发的一律停在下半截的顶
        if y > lowerTop + 0.5, scroll.offset < lowerTop - 1 {
            target.rect.origin.y = lowerTop
            return
        }
        if y > 0.5, y < lowerTop - 0.5 {
            // 落在两截之间的一律吸到下半截的顶：往下是从首屏的按钮进下半截；往上是焦点进选季时系统想多往上挪一段给它留边距。
            // 回首屏不走这里——由页面自己滚到正好 0（`backToStage`、焦点回到按钮时）
            target.rect.origin.y = lowerTop
            return
        }
        // 从下面的行（演职员、合集）往上回到下半截第一行：系统只滚到这一行刚好露全，片名、选季会被顶出屏幕。
        // 落在下半截顶部附近就吸回标准位置
        if y > lowerTop + 0.5, y < scroll.offset, y < lowerTop + 300 {
            target.rect.origin.y = lowerTop
        }
    }
}

/// 一集：剧照（左下角片长或剩多久，看了一半的压进度条，看完的标「已看」）+ 第几集、集名、四行简介、首播日期。
/// 简介固定占四行高，一排卡的日期对齐在同一条线上（同系统 Apple TV App 的分集卡）
private struct TVEpisodeCard: View {
    let episode: API.EpisodeView
    let imageURL: URL?
    let runtimeMinutes: Int?
    let action: () -> Void

    private let width = TVMetrics.landscapeWidth

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                RemoteImage(url: imageURL, placeholderText: "第 \(episode.episodeNumber) 集")
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottomLeading) { stillBand }
                    .overlay(alignment: .topLeading) {
                        if episode.played {
                            Text("已看")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.6), in: .capsule)
                                .padding(12)
                        }
                    }
                    .clipShape(.rect(cornerRadius: TVMetrics.cardCorner))
                    // 焦点效果要点名套在图上：图是 LazyImage 包出来的，`.borderless` 自己找不到它
                    .hoverEffect(.highlight)
                VStack(alignment: .leading, spacing: 6) {
                    Text("第 \(episode.episodeNumber) 集")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(episode.name ?? "第 \(episode.episodeNumber) 集")
                        .font(.system(size: 26, weight: .semibold))
                        .lineLimit(1)
                    Text(episode.overview ?? "")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(4)
                        .frame(height: 116, alignment: .top)
                    Text(episode.owned ? (episode.airDate.map { String($0.prefix(10)) } ?? "") : "缺集")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.borderless)
        .opacity(episode.owned ? 1 : 0.45)
    }

    /// 剧照左下：▶ 片长（看了一半的写剩多久、压进度条）
    @ViewBuilder
    private var stillBand: some View {
        let inProgress = !episode.played && episode.positionMs > 0
        let text: String? = inProgress ? "看到 \(Formatters.clock(Double(episode.positionMs) / 1000))"
            : runtimeMinutes.flatMap { $0 > 0 ? TVItemDetailView.runtimeText($0) : nil }
        if text != nil || inProgress {
            VStack(alignment: .leading, spacing: 10) {
                if let text {
                    Label(text, systemImage: "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                }
                if inProgress, let percent = episode.progressPercent {
                    TVProgressStrip(value: Double(percent) / 100, track: .white.opacity(0.3))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 36)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

/// 演职员一格：圆头像 + 姓名 + 身份（导演 / 饰 X），按确认进影人页（`TVPersonView`，2026-10-04）。
/// 获得焦点时只有头像放大、套白边（同「谁在看」）：系统 `.borderless` 的焦点效果不认圆形，头像外面会浮起一块方形底板
private struct TVPersonCard: View {
    let name: String
    let role: String?
    let avatarURL: URL?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                // 头像 210（原 150，2026-10-03 用户嫌小）：一排约七个半，和上面分集卡的高度（234）接近，两行比例协调
                TVProfileAvatarFocus {
                    TVAvatar(url: avatarURL, name: name, size: 210)
                }
                VStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                    if let role {
                        Text(role)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 236)
        }
        .buttonStyle(TVPersonButtonStyle())
        .accessibilityLabel([name, role].compactMap { $0 }.joined(separator: "，"))
    }
}

/// 演职员按钮：把焦点往下传给头像（`TVProfileAvatarFocus` 据此放大、套白边），并报给所在的行让行标题亮起来
private struct TVPersonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .environment(\.tvProfileFocused, focused)
                .preference(key: TVRowFocusKey.self, value: focused)
        }
    }
}

/// 什么都不画的按钮样式：回首屏的接应点用，拿到焦点时没有任何高亮
private struct TVBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// 季的胶囊：选中的季垫一层浅底；获得焦点白底黑字、微微放大
private struct TVSeasonTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, selected: selected)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isFocused) private var focused

        var body: some View {
            configuration.label
                .font(.system(size: 28, weight: .semibold))
                .padding(.horizontal, 30)
                .padding(.vertical, 12)
                .foregroundStyle(focused ? .black : .white.opacity(selected ? 1 : 0.7))
                .background(Capsule().fill(focused ? .white : .white.opacity(selected ? 0.2 : 0)))
                .scaleEffect(focused ? 1.08 : 1)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
    }
}


