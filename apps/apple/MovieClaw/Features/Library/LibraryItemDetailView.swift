import Nuke
import NukeUI
import SwiftUI

/// 媒体库条目详情（Web `library-item-detail-view.tsx`，路由 `/library/{id}/item/{mid}?season=&episode=`）。
///
/// 一屏的阅读动线（与 Web 手机端一致）：剧照 Hero → 片名 / 当前集 / 事实行（年份·片长·评分·画质·HDR）/
/// 类型 / 系列与合集 → 媒体轨道（先挑版本与音轨字幕）→ 播放键（落点）+ 收藏 / 已看 → 简介 →
/// 分集（剧集）→ 章节条 → 演职员 → 文件（管理员可删除 / 恢复 / 立即清理）→ 外部词条。
///
/// - 播放键三态：播放 / 继续 mm:ss（下方进度条 + 剩余 X）/ 重新播放，剧集写明哪一集（「继续 第 1 季第 3 集 · mm:ss」）；续播点来自 `GET /playback/resume`，
///   关掉播放器、服务端收下「停止」后重拉（`.playbackStopReported`），按钮立即跟上刚才看到的位置；
/// - 收藏针对整部作品，已看针对当前单元（电影本身 / 选中的那一集），都走 `POST /playback/marks`；
/// - 刮削进行中每 2 秒、章节图生成中每 3 秒（最多 20 次）重拉详情；
/// - ⋯ 菜单：搜索资源 / 加入合集 / 分享 / 洗版 / 修正识别 / 刷新元数据 / 重新生成章节 / 更换图片 /
///   转移到其他库 / 删除影片 / 清除观看记录——对话框各自是独立的 sheet 组件；
/// - 页面底色取剧照露出部分底边的颜色，剧照底部渐变进去、整页铺满（同 Apple Music 专辑页，见 `HeroEdgeColor`）。
struct LibraryItemDetailView: View {
    let libraryId: Int
    let itemId: Int
    var season: Int?
    var episode: Int?

    @Environment(\.api) private var api
    @Environment(\.permissions) private var permissions
    @Environment(Feedback.self) private var feedback
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL

    @State private var detail: API.LibraryItemDetailView?
    @State private var library: API.LibraryView?
    @State private var failed = false
    @State private var selectedEpisode: SelectedEpisode?
    @State private var selectedTrackFileId: Int?
    @State private var watched: API.PlaybackStateView?
    @State private var favorite: Bool?
    @State private var marking = false
    @State private var episodesVersion = 0
    @State private var kicking = false
    @State private var refreshError: String?
    @State private var chapterPolls = 0
    @State private var sheet: ItemSheet?
    @State private var deleteFile: API.LibraryFileView?
    /// 修正识别结果拍板过：关窗时再重拉（同 Web reidentifyDirty）
    @State private var reidentifyDirty = false

    /// 标题区滚出视野后才在导航栏显示片名、恢复顶部的滚动边缘效果（R-6，同发现详情页）：
    /// Hero 全出血到状态栏，返回 / ⋯ 直接浮在剧照上
    @State private var titleVisible = false
    /// 剧照显示区域的尺寸：底边取色按它算露出的那块
    @State private var heroSize: CGSize = .zero
    /// 页面底色（剧照底边的颜色）；取到之前为 nil，页面是黑底
    @State private var edgeTint: Color?

    /// 分集区当前选中的那一集（及其文件）
    struct SelectedEpisode: Equatable {
        var season: Int
        var episode: API.EpisodeView
        var files: [API.LibraryFileView]
    }

    private enum ItemSheet: Identifiable {
        case addToCollection, share(API.ShareView?), reidentify, artwork, transfer, delete
        var id: String {
            switch self {
            case .addToCollection: "collection"
            case .share: "share"
            case .reidentify: "reidentify"
            case .artwork: "artwork"
            case .transfer: "transfer"
            case .delete: "delete"
            }
        }
    }

    var body: some View {
        Group {
            if failed {
                VStack(spacing: 14) {
                    Text("未能加载该条目").font(.headline).foregroundStyle(Theme.text)
                    Text("条目可能已被删除或重新识别为其他作品，请返回后查看。")
                        .font(.subheadline).foregroundStyle(Theme.textMuted).multilineTextAlignment(.center)
                    Button { router.pop() } label: { Label("返回\(backLabel)", systemImage: "chevron.left") }
                        .buttonStyle(.glass)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let detail {
                content(detail)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取本地刮削信息…").font(.subheadline).foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 氛围页：自带沉浸大图，不铺全站蒙版（Web isHomeRoute）；底色取剧照底边的颜色
        .heroEdgeBackground(edgeTint)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(detail?.title ?? "")
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(titleVisible || detail == nil ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: titleVisible)
            }
            if let detail {
                ToolbarItem(placement: .topBarTrailing) { actionsMenu(detail) }
            }
        }
        .task { await reload() }
        // 进了详情页多半要播：先把起播要用的连接连好（见 PlaybackPreconnect）
        .task { PlaybackPreconnect.warm(api: api) }
        .task(id: playUnitKey) { await loadResume() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopReported)) { note in
            guard note.userInfo?["mediaItemId"] as? Int == itemId else { return }
            Task { await loadResume(keepCurrent: true) }
            episodesVersion += 1
        }
        .task { favorite = (try? await api.playbackMarksGet(mediaItemId: itemId))?.isFavorite }
        .polling(every: detail?.scraping == true || kicking ? 2 : 3) {
            guard let detail else { return }
            let chaptersPolling = detail.chaptersPending && !detail.scraping && chapterPolls < 20
            guard detail.scraping || chaptersPolling else { return }
            if !detail.scraping { chapterPolls += 1 }
            if let next = try? await api.libraryItemsGet(libraryId: libraryId, mediaItemId: itemId) {
                self.detail = next
                // 章节补齐（pending 变 false）就把轮数清零，下次「重新生成章节」还有满 20 轮（同 Web）
                if !next.chaptersPending { chapterPolls = 0 }
            }
        }
        .sheet(item: $sheet, onDismiss: {
            // 条目可能已经不在了（文件全改挂走 / 全标为非独立作品）：关窗再重拉，404 落到兜底态
            if reidentifyDirty {
                reidentifyDirty = false
                Task { await reload() }
            }
        }) { sheet in
            sheetContent(sheet).sheetFeedback()
        }
        .sheet(item: $deleteFile) { file in
            DeleteFileSheet(libraryId: libraryId, mediaItemId: itemId, file: file,
                            onDeleted: { Task { await reload() } },
                            onItemDeleted: leaveToLibrary)
                .sheetFeedback()
        }
    }

    // MARK: 派生

    /// 兜底态返回键的去处名（同 Web navFallback）：从发现详情来 →「发现详情」；从媒体库首页来 →「媒体库」；
    /// 其余按本库名（拿不到库名叫「库存」）。App 用真实返回栈判断来路，等价于 Web 的 returnTo / from=recent
    private var backLabel: String {
        let stack = router.paths[router.selectedTab] ?? []
        switch stack.dropLast().last {
        case .mediaDetail?: return "发现详情"
        case nil where router.selectedTab == .library, .libraryHome?: return "媒体库"
        default: return library?.name ?? "库存"
        }
    }

    private var isMovie: Bool { detail?.kind != "tv" }

    /// 当前播放单元：电影恒为 (0, 0)；剧集跟随分集区选中的那一集
    private var playUnit: (season: Int, episode: Int)? {
        guard let detail else { return nil }
        if detail.kind != "tv" { return (0, 0) }
        guard let selectedEpisode else { return nil }
        return (selectedEpisode.season, selectedEpisode.episode.episodeNumber)
    }

    private var playUnitKey: String { playUnit.map { "\($0.season)/\($0.episode)" } ?? "-" }

    private var trackFiles: [API.LibraryFileView] {
        guard let detail else { return [] }
        return isMovie ? detail.files : (selectedEpisode?.files ?? [])
    }

    private var availableTrackFiles: [API.LibraryFileView] { trackFiles.filter { $0.state == "in_place" } }

    private var selectedTrackFile: API.LibraryFileView? {
        availableTrackFiles.first { $0.id == selectedTrackFileId } ?? availableTrackFiles.first
    }

    // MARK: 页面

    @ViewBuilder
    private func content(_ detail: API.LibraryItemDetailView) -> some View {
        let heroURL = api.image(detail.backdropUrl ?? detail.posterUrl, width: Self.heroImageWidth)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let heroURL {
                    hero(heroURL)
                } else {
                    Color.clear.frame(height: 110)
                }
                header(detail)
                    .padding(.top, heroURL == nil ? 0 : -150)
                    .padding(.horizontal, Theme.pagePadding)
                    .onScrollVisibilityChange(threshold: 0.2) { visible in titleVisible = !visible }
                if let plot = isMovie ? detail.localMeta?.plot : (selectedEpisode?.episode.overview ?? detail.localMeta?.plot), !plot.isEmpty {
                    ExpandablePlot(text: plot)
                        .padding(.horizontal, Theme.pagePadding)
                        .padding(.top, 16)
                }
                VStack(alignment: .leading, spacing: 28) {
                    if !isMovie, !detail.seasons.isEmpty {
                        SeasonEpisodesSection(
                            libraryId: libraryId, detail: detail,
                            initialSeason: season, initialEpisode: episode,
                            refreshKey: episodesVersion
                        ) { selection in
                            if selection?.files.map(\.id) != selectedEpisode?.files.map(\.id) { selectedTrackFileId = nil }
                            selectedEpisode = selection
                        }
                    }
                    if let chapters = selectedTrackFile?.chapters, !chapters.isEmpty {
                        ChapterStripSection(
                            chapters: chapters,
                            onPlayFrom: { seconds in play(start: seconds) },
                            pending: detail.chaptersPending,
                            resumeMs: watched?.positionMs
                        )
                    }
                    castRow(detail)
                    let files = isMovie ? detail.files : (selectedEpisode?.files ?? [])
                    if !files.isEmpty {
                        fileSection(detail, files: files)
                    }
                    externalLinks(detail)
                }
                .padding(.top, 28)
                .padding(.bottom, 48)
            }
        }
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectHidden(heroURL != nil && !titleVisible, for: .top)
        .task(id: edgeKey(heroURL)) {
            guard let heroURL, heroSize.height > 0 else { return }
            if let color = await HeroEdgeColor.color(for: heroURL, containerAspect: heroSize.width / heroSize.height),
               !Task.isCancelled {
                edgeTint = color
            }
        }
        .refreshable { await reload() }
    }

    /// 底边取色的任务标识：剧照地址或显示比例变了才重算
    private func edgeKey(_ url: URL?) -> String {
        guard let url, heroSize.height > 0 else { return "" }
        return "\(url.absoluteString)#\(Int((heroSize.width / heroSize.height * 100).rounded()))"
    }

    /// Hero 的显示高度：屏宽 × 1.15，最高屏高 62%
    private static var heroHeight: CGFloat {
        min(ImageWidth.screenSize.width * 1.15, ImageWidth.screenSize.height * 0.62)
    }

    /// Hero 的取图宽度：屏宽 × `heroHeight` 的竖框（393×452 点）铺满 16:9 背景要按高算——按宽只要 1179 像素，
    /// 按高约 804 点 × 3 ≈ 2411 像素 → 2560 档（docs/design/image-sizing.md §6），不再取 4K 原图
    private static var heroImageWidth: Int {
        ImageWidth.cover(CGSize(width: ImageWidth.screenSize.width, height: heroHeight), aspect: ImageAspect.backdrop)
    }

    /// 手机 Hero：剧照撑满宽度从状态栏底下铺起，顶部一抹暗托住返回键，底部渐变进页面底色
    /// （剧照底边的颜色，见 `HeroEdgeColor`），与下方整页无缝接上
    private func hero(_ url: URL) -> some View {
        let height = Self.heroHeight
        let pageTint = edgeTint ?? Theme.background
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { RemoteImage(url: url) }
            .clipped()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { heroSize = $0 }
            .overlay(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: 112)
            }
            .overlay(alignment: .bottom) {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: pageTint.opacity(0.55), location: 0.5), .init(color: pageTint, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.55)
                    .animation(.easeInOut(duration: 0.5), value: edgeTint?.description)
            }
            // 下拉刷新时整块大图（连同两头的渐变）以底边为锚放大，顶上不露底色（同 Apple Music）
            .stretchesOnPull()
            .accessibilityHidden(true)
    }

    // MARK: 头部信息区

    @ViewBuilder
    private func header(_ detail: API.LibraryItemDetailView) -> some View {
        let meta = detail.localMeta
        VStack(alignment: .leading, spacing: 8) {
            titleArt(detail)
                .accessibilityValue(String(detail.mediaItemId))
                .accessibilityIdentifier("item-title")
            if !isMovie, let selectedEpisode {
                Text("第 \(selectedEpisode.season) 季 第 \(selectedEpisode.episode.episodeNumber) 集\(selectedEpisode.episode.name.map { " - \($0)" } ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
            let facts = factsLine(detail)
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            }
            if let genres = meta?.genres, !genres.isEmpty {
                Text(genres.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            if let seriesName = detail.seriesName {
                metaLinkRow("系列") {
                    if let cid = detail.seriesCollectionId {
                        NavigationLink(seriesName, value: AppRoute.collection(libraryId: libraryId, collectionId: cid))
                    } else {
                        Text(seriesName)
                    }
                }
            }
            if !detail.collections.isEmpty {
                metaLinkRow("合集") {
                    ForEach(Array(detail.collections.prefix(3).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Text(" · ").foregroundStyle(.white.opacity(0.3)) }
                        NavigationLink(row.name, value: AppRoute.collection(libraryId: libraryId, collectionId: row.id))
                    }
                    if detail.collections.count > 3 {
                        Text(" · ").foregroundStyle(.white.opacity(0.3))
                        NavigationLink("还有 \(detail.collections.count - 3) 个", value: AppRoute.library(id: libraryId, view: "collections"))
                    }
                }
            }
            MediaTrackSection(files: trackFiles, selectedFileId: $selectedTrackFileId) { await reload() }
                .padding(.top, 6)
            if !availableTrackFiles.isEmpty, isMovie || selectedEpisode != nil {
                playAction(favoriteLabel: isMovie ? "这部电影" : "这部剧")
                    .padding(.top, 10)
            }
            if detail.scraping || kicking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.info)
                    Text("正在刷新元数据\(detail.scrapingPhase.map { " · \($0)" } ?? "")").lineLimit(1)
                    Spacer(minLength: 4)
                    Text("完成后自动更新本页").font(.caption).foregroundStyle(.white.opacity(0.45))
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.info)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.info.opacity(0.07), in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.info.opacity(0.25)))
                .padding(.top, 8)
            }
            if let refreshError {
                Text(refreshError)
                    .font(.footnote)
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.62))
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(radius: 12)
                    .padding(.top, 8)
            }
        }
    }

    /// 年份 · 片长 · 评分 · 画质 · HDR（电影看全部在位版本，剧集看选中的那个文件）
    private func titleText(_ detail: API.LibraryItemDetailView) -> some View {
        Text(detail.title)
            .font(.system(size: 28, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 8)
    }

    /// 片名：有片名 Logo（透明底 PNG，语言档同订阅首页 Hero）就画 Logo，没有或加载失败回落文字。
    /// Logo 区高度固定，加载前后下面的集名 / 事实行不跳；整块合成一个静态文本读屏元素，
    /// 读屏与 UI 测试（item-title）照旧拿到片名。
    /// 本地 Logo 资产存的是 TMDB 原图（给电视端 clearlogo 用，常见 4000px 宽）：按 Logo 框宽（260 点）取 `w`；
    /// 旧服务器不认 `w` 会回原图，所以仍按显示宽度降采样再解码
    @ViewBuilder
    private func titleArt(_ detail: API.LibraryItemDetailView) -> some View {
        if let raw = detail.logoUrl, let url = api.image(raw, width: ImageWidth.points(260)) {
            LazyImage(request: ImageRequest(url: url, processors: [.resize(width: 260)]),
                      transaction: Transaction(animation: .easeOut(duration: 0.25))) { state in
                if let image = state.image {
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260, maxHeight: 96, alignment: .bottomLeading)
                        .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
                } else if state.error != nil {
                    titleText(detail)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .bottomLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail.title)
            .accessibilityAddTraits(.isStaticText)
        } else {
            titleText(detail)
        }
    }

    private func factsLine(_ detail: API.LibraryItemDetailView) -> [String] {
        let meta = detail.localMeta
        let runtime = meta?.runtimeMinutes ?? detail.files.first(where: { $0.durationSeconds != nil })?.durationSeconds.map { Int((Double($0) / 60).rounded()) }
        var facts = [
            detail.year.map(String.init),
            runtime.map(Self.runtimeText),
            (meta?.rating ?? 0) > 0 ? "★ " + String(format: "%.1f", meta!.rating!) : nil,
        ].compactMap { $0 }
        let sources = isMovie ? detail.files.filter { $0.state == "in_place" } : (selectedTrackFile.map { [$0] } ?? [])
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
        guard minutes > 0 else { return "—" }
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时"
    }

    static func resolutionLabel(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let key = normalized.allSatisfy(\.isNumber) ? normalized + "p" : normalized
        return ["4320p": "8K", "2160p": "4K", "1440p": "2K", "1080p": "1080p", "720p": "720p", "4k": "4K", "2k": "2K"][key] ?? raw
    }

    private func metaLinkRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.footnote).foregroundStyle(Theme.textFaint).frame(width: 34, alignment: .leading)
            TrackFlowLayout(spacing: 0, lineSpacing: 4) { content() }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .tint(.white.opacity(0.85))
        }
    }

    // MARK: 播放键

    /// 播放键上的「第 1 季第 3 集」：选中的那一集；电影没有。特别篇（第 0 季）写「特别篇第 2 集」
    private var unitLabel: String? {
        guard !isMovie, let selectedEpisode else { return nil }
        let season = selectedEpisode.season, episode = selectedEpisode.episode.episodeNumber
        return season == 0 ? "特别篇第 \(episode) 集" : "第 \(season) 季第 \(episode) 集"
    }

    @ViewBuilder
    private func playAction(favoriteLabel: String) -> some View {
        let position = watched?.positionMs ?? 0
        let duration = watched?.durationMs
        let finished = watched?.played ?? false
        // 有续播点就接着播（与服务端起播同一口径）：看完后重看到一半的也算，已看标记保留
        let resumable = position > 0
        let percent: Int? = resumable && (duration ?? 0) > 0 ? min(100, max(2, Int((Double(position) / Double(duration!) * 100).rounded()))) : nil
        let remaining: Int? = resumable && (duration ?? 0) > position ? Int((Double(duration! - position) / 60000).rounded()) : nil
        // 看过一段：按钮直接写从哪里起播（点它就从这里接着放），下方进度条只说还剩多少。
        // 剧集写明是哪一集（同 Apple TV 版「继续 第 1 季第 3 集 · 46:56」）：只写「继续 46:56」看不出续的是第几集
        let verb = resumable ? "继续" : finished ? "重新播放" : "播放"
        let parts = [verb, unitLabel, resumable ? Formatters.clock(Double(position) / 1000) : nil].compactMap { $0 }
        let label = parts.count > 2 ? "\(parts[0]) \(parts[1]) · \(parts[2])" : parts.joined(separator: " ")
        let progressText: String? = resumable
            ? remaining.map { $0 >= 1 ? "剩余 \(Self.runtimeText($0))" : "即将看完" } ?? (duration != nil ? "即将看完" : nil)
            : nil

        VStack(alignment: .leading, spacing: 12) {
            Button { play(start: nil) } label: {
                Label(label, systemImage: "play.fill")
                    .heroActionLabel()
                    .frame(maxWidth: HeroAction.maxWideLabelWidth)
            }
            // 尺寸统一见 HeroActionButton.swift：与下面两颗次键同为系统 regular 档，主次靠白底与通栏区分
            .buttonStyle(.glassProminent)
            .controlSize(.regular)
            .tint(.white)
            .foregroundStyle(.black)
            .accessibilityLabel(progressText.map { "\(label)，\($0)" } ?? label)
            .accessibilityIdentifier("item-play")
            HStack(spacing: 10) {
                Button { Task { await toggleFavorite() } } label: {
                    Label(favorite == true ? "已收藏" : "收藏", systemImage: favorite == true ? "heart.fill" : "heart")
                        .heroActionLabel()
                        .foregroundStyle(favorite == true ? Theme.danger : .white.opacity(0.85))
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .disabled(marking)
                .accessibilityLabel(favorite == true ? "取消收藏\(favoriteLabel)" : "收藏\(favoriteLabel)")
                .accessibilityIdentifier("item-favorite")
                Button { Task { await togglePlayed() } } label: {
                    Label(finished ? "已看完" : "标为已看", systemImage: "checkmark")
                        .heroActionLabel()
                        .foregroundStyle(finished ? Theme.success : .white.opacity(0.85))
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .disabled(marking)
                .accessibilityLabel(finished ? "标记为未看" : "标记为已看")
                .accessibilityIdentifier("item-played")
            }
            if let progressText {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule().fill(.white.opacity(0.85)).frame(width: proxy.size.width * CGFloat(percent ?? 0) / 100)
                        }
                    }
                    .frame(height: 4)
                    Text(progressText).font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                }
                .accessibilityIdentifier("item-progress")
            }
            if finished, !resumable, let watched, watched.playCount > 1 {
                Text("看过 \(watched.playCount) 次").font(.caption).monospacedDigit().foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func play(start: Double?) {
        guard let detail else { return }
        router.play(PlayRequest(
            mediaItemId: detail.mediaItemId,
            season: isMovie ? nil : selectedEpisode?.season,
            episode: isMovie ? nil : selectedEpisode?.episode.episodeNumber,
            startSeconds: start
        ))
    }

    // MARK: 演职员 / 文件 / 外部词条

    @ViewBuilder
    private func castRow(_ detail: API.LibraryItemDetailView) -> some View {
        if let meta = detail.localMeta {
            let directors: [CastPerson] = meta.directorCredits.isEmpty
                ? Array(NSOrderedSet(array: meta.directors)).compactMap { $0 as? String }.map { CastPerson(name: $0, subtitle: "导演", avatar: nil, personId: nil) }
                : meta.directorCredits.map { CastPerson(name: $0.name, subtitle: "导演", avatar: $0.thumbUrl, personId: $0.tmdbPersonId) }
            let cast = directors + meta.actors.map { CastPerson(name: $0.name, subtitle: $0.role.map { "饰 \($0)" }, avatar: $0.thumbUrl, personId: $0.tmdbPersonId) }
            if !cast.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    LibrarySectionHeader(title: "演职员")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(cast.enumerated()), id: \.offset) { _, person in
                                if let id = person.personId {
                                    NavigationLink(value: AppRoute.person(tmdbId: id)) { castCard(person) }
                                        .buttonStyle(.plain)
                                } else {
                                    castCard(person)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                    }
                    .scrollClipDisabled()
                }
            }
        }
    }

    private struct CastPerson {
        var name: String
        var subtitle: String?
        var avatar: String?
        var personId: Int?
    }

    /// 头像占位的首字（同 Web cast-row initialsOf）：中日韩取首字；拉丁名单词取前两个字母、多词取首尾单词首字母，大写
    static func initials(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        if trimmed.unicodeScalars.contains(where: { (0x3400 ... 0x9FFF).contains($0.value) || (0x3040 ... 0x30FF).contains($0.value) || (0xAC00 ... 0xD7AF).contains($0.value) }) {
            return String(first)
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        if words.count == 1 { return String(words[0].prefix(2)).uppercased() }
        return (String(words[0].prefix(1)) + String(words[words.count - 1].prefix(1))).uppercased()
    }

    private func castCard(_ person: CastPerson) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack {
                Theme.surfaceRaised
                Text(Self.initials(of: person.name)).font(.title2.weight(.bold)).foregroundStyle(.white.opacity(0.3))
                if person.avatar != nil {
                    RemoteImage(url: api.image(person.avatar, width: ImageWidth.points(96)), placeholderSymbol: "person.fill")
                }
            }
            .aspectRatio(Theme.posterAspect, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            Text(person.name).font(.footnote.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1).padding(.top, 6)
            if let subtitle = person.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
        }
        .frame(width: 96)
        .contentShape(.rect)
    }

    @ViewBuilder
    private func fileSection(_ detail: API.LibraryItemDetailView, files: [API.LibraryFileView]) -> some View {
        let manage = permissions.canManageLibraries
        let inPlace = detail.files.filter { $0.state == "in_place" }
        let duplicateUnits = Dictionary(grouping: inPlace, by: { "\($0.seasonNumber):\($0.episodeNumber)" }).values.filter { $0.count > 1 }.count
        let duplicateLabel: String? = duplicateUnits == 0 ? nil : detail.kind == "tv" ? "\(duplicateUnits) 集有重复" : "\(inPlace.count) 个版本"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("文件").font(.subheadline.weight(.medium)).foregroundStyle(Theme.textMuted)
                Text("\(files.count)").font(.caption).monospacedDigit().foregroundStyle(Theme.textFaint)
                if manage, let duplicateLabel {
                    Button("\(duplicateLabel) · 处理重复") { router.push(.libraryManage(tab: "duplicates", item: itemId)) }
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
            VStack(spacing: 0) {
                ForEach(files, id: \.id) { file in
                    LibraryFileRow(
                        file: file,
                        onDelete: manage ? { deleteFile = file } : nil,
                        onRestore: manage ? { () -> Void in Task<Void, Never> { await restore(file) } } : nil,
                        onPurge: manage ? { () -> Void in Task<Void, Never> { await purge(file) } } : nil
                    )
                    if file.id != files.last?.id { Divider().overlay(Color.white.opacity(0.035)) }
                }
            }
            .background(.white.opacity(0.015), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.04)))
        }
        .padding(.horizontal, Theme.pagePadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("item-files")
    }

    @ViewBuilder
    private func externalLinks(_ detail: API.LibraryItemDetailView) -> some View {
        let tmdb = detail.tmdbId ?? 0
        if tmdb > 0 || detail.imdbId != nil || detail.doubanId != nil {
            HStack(spacing: 16) {
                Text("相关链接").foregroundStyle(Theme.textFaint)
                if tmdb > 0 { link("TMDB", "https://www.themoviedb.org/\(detail.kind)/\(tmdb)") }
                if let imdb = detail.imdbId { link("IMDb", "https://www.imdb.com/title/\(imdb)/") }
                if let douban = detail.doubanId {
                    // 手机上优先唤起豆瓣 App（Web useDoubanAppHref 同一口径）
                    link("豆瓣", douban.allSatisfy(\.isNumber)
                        ? "https://www.douban.com/doubanapp/dispatch?uri=/movie/\(douban)/&dt_dapp=1"
                        : "https://movie.douban.com/subject/\(douban)/")
                }
            }
            .font(.footnote)
            .padding(.horizontal, Theme.pagePadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("外部词条")
        }
    }

    private func link(_ label: String, _ url: String) -> some View {
        Button("\(label) ↗") { if let url = URL(string: url) { openURL(url) } }
            .foregroundStyle(Theme.textMuted)
    }

    // MARK: ⋯ 菜单

    private func actionsMenu(_ detail: API.LibraryItemDetailView) -> some View {
        let manage = permissions.canManageLibraries
        let scraped = detail.source == "tmdb"
        let identifiable = library?.capabilities.scraped ?? scraped
        let readsNfo = detail.kind == "video"
        let scraping = detail.scraping || kicking
        let tmdb = detail.tmdbId ?? 0
        let canUpgrade = permissions.canSubscribe && tmdb > 0 && detail.kind != "video" && detail.kind != "photo"
        let canShare = permissions.isAdmin && detail.kind != "photo"
        return Menu {
            if permissions.canSearch {
                Button("搜索资源") {
                    router.push(.search(.init(q: detail.title, also: SearchScope.titleSearchAlso(detail.englishTitle, detail.originalTitle), scope: SearchScope.ofMediaKind(detail.kind).encoded)))
                }
            }
            Button("加入合集…") { sheet = .addToCollection }
            if canShare {
                Button("分享…") { Task { await openShare() } }
            }
            if canUpgrade {
                Button("洗版…") { Task { await upgrade(detail) } }
            }
            if manage {
                Divider()
                if identifiable { Button("修正识别结果…") { sheet = .reidentify } }
                Button(scraping
                    ? (scraped ? "正在刷新元数据…" : readsNfo ? "正在读取 NFO…" : "正在生成封面…")
                    : (scraped ? "刷新元数据" : readsNfo ? "重新读取 NFO 与封面" : "重新生成封面")) {
                    Task { await refreshMetadata(detail) }
                }
                .disabled(scraping)
                if library?.extractChapterImages == true {
                    Button(detail.chaptersPending ? "正在生成章节…" : "重新生成章节") { Task { await regenerateChapters() } }
                        .disabled(detail.chaptersPending)
                }
                if scraped { Button("更换图片…") { sheet = .artwork } }
                Button("转移到其他库…") { sheet = .transfer }
                Divider()
                Button("删除影片", role: .destructive) { sheet = .delete }
            }
            if manage || canUpgrade || canShare { Divider() }
            Button("清除观看记录…") { Task { await clearHistory(detail) } }
        } label: {
            Image(systemName: "ellipsis")
                .overlay(alignment: .topTrailing) {
                    if scraping { Circle().fill(Theme.info).frame(width: 6, height: 6).offset(x: 6, y: -4) }
                }
        }
        .accessibilityLabel("更多操作")
        .accessibilityIdentifier("item-actions")
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ItemSheet) -> some View {
        let title = detail?.title ?? ""
        switch sheet {
        case .addToCollection:
            AddToCollectionSheet(libraryId: libraryId, mediaItemId: itemId, title: title)
        case let .share(initial):
            if let detail {
                LibraryShareSheet(
                    target: .item(libraryId: libraryId, mediaItemId: itemId), title: detail.title,
                    kind: detail.kind, year: detail.year, posterUrl: detail.posterUrl,
                    seasonSummary: isMovie ? nil : "已入库 \(Set(detail.files.map(\.seasonNumber)).count) 季 \(Set(detail.files.map { "\($0.seasonNumber)-\($0.episodeNumber)" }).count) 集",
                    initialShare: initial
                )
            }
        case .reidentify:
            ReidentifySheet(libraryId: libraryId, mediaItemId: itemId) { reidentifyDirty = true }
        case .artwork:
            ArtworkPickerSheet(libraryId: libraryId, mediaItemId: itemId) { Task { await reload() } }
        case .transfer:
            TransferItemSheet(libraryId: libraryId, mediaItemId: itemId, title: title)
        case .delete:
            DeleteItemSheet(libraryId: libraryId, mediaItemId: itemId, title: title, onDeleted: leaveToLibrary)
        }
    }

    // MARK: 加载与动作

    private func reload() async {
        do {
            async let item = api.libraryItemsGet(libraryId: libraryId, mediaItemId: itemId)
            async let lib = try? api.libraryGet(libraryId: libraryId)
            let (d, l) = try await (item, lib)
            detail = d
            if let l { library = l }
            failed = false
            if !d.chaptersPending { chapterPolls = 0 }
        } catch is CancellationError {
        } catch let error as APIError where error.status == 404 {
            // 条目已不存在（改挂走了 / 删掉了）：不论页面上有没有旧数据都落到兜底态，别继续显示已不存在的条目
            failed = true
        } catch {
            // 网络抖动：保留已显示的内容，首次加载才落兜底态
            if detail == nil { failed = true }
        }
    }

    /// 删除影片（或删掉最后一个文件连带条目）后离开：落到本库页（同 Web router.replace(/library/{id})）。
    /// 上一屏就是本库页时直接返回；否则把栈顶的条目页换成本库页
    private func leaveToLibrary() {
        var stack = router.paths[router.selectedTab] ?? []
        if !stack.isEmpty { stack.removeLast() }
        if stack.last != .library(id: libraryId) { stack.append(.library(id: libraryId)) }
        router.paths[router.selectedTab] = stack
    }

    /// - Parameter keepCurrent: 播完回来的刷新：旧值先留着、拿到新值再换，播放键不会先闪回「播放」
    private func loadResume(keepCurrent: Bool = false) async {
        guard let unit = playUnit else {
            watched = nil
            return
        }
        if !keepCurrent { watched = nil }
        let fresh = try? await api.playbackResume(mediaItemId: itemId, seasonNumber: unit.season, episodeNumber: unit.episode)
        if fresh != nil || !keepCurrent { watched = fresh }
    }

    private func toggleFavorite() async {
        guard !marking else { return }
        let next = !(favorite ?? false)
        marking = true
        favorite = next
        defer { marking = false }
        do {
            favorite = try await api.librarySetMarks(mediaItemId: itemId, favorite: next).isFavorite
        } catch {
            favorite = !next
            feedback.error(error.localizedDescription.isEmpty ? "收藏失败，请稍后重试" : error.localizedDescription)
        }
    }

    private func togglePlayed() async {
        guard !marking, let unit = playUnit else { return }
        let next = !(watched?.played ?? false)
        marking = true
        defer { marking = false }
        do {
            _ = try await api.librarySetMarks(mediaItemId: itemId, season: unit.season, episode: unit.episode, played: next)
            watched = try await api.playbackResume(mediaItemId: itemId, seasonNumber: unit.season, episodeNumber: unit.episode)
            episodesVersion += 1
        } catch {
            feedback.error(error.localizedDescription.isEmpty ? "标记失败，请稍后重试" : error.localizedDescription)
        }
    }

    private func openShare() async {
        do {
            sheet = .share(try await api.libraryItemsShareGet(libraryId: libraryId, mediaItemId: itemId))
        } catch {
            feedback.error(error)
        }
    }

    /// 洗版：已有订阅直接去订阅详情跑一轮洗版；没有则以洗版模式打开订阅对话框
    private func upgrade(_ detail: API.LibraryItemDetailView) async {
        let tmdb = detail.tmdbId ?? 0
        let kind = detail.kind == "tv" ? "tv" : "movie"
        if let subs = try? await api.subscriptionsList(kind: kind),
           let existing = subs.first(where: { $0.media.tmdbId == tmdb }) {
            router.push(.subscription(id: existing.id, upgradeRun: true))
            return
        }
        router.present(.subscribe(SubscribeRequest(titleRef: "tmdb:\(kind):\(tmdb)", title: detail.title, upgrade: true, libraryItemId: detail.mediaItemId)))
    }

    private func refreshMetadata(_ detail: API.LibraryItemDetailView) async {
        let ok: Bool
        if detail.kind == "video" {
            ok = await feedback.confirm("重新读取《\(detail.title)》的 NFO 与封面？", message: LibraryDetailView.bullets("本次会：", [
                "重新读取视频旁同名的 NFO 文件，标题、简介、系列等以 NFO 为准",
                "重新生成封面",
                "不联网，不会改动你的文件",
            ]), confirmTitle: "读取")
        } else {
            ok = await feedback.confirm("刷新《\(detail.title)》的元数据？", message: LibraryDetailView.bullets("本次刷新会：", [
                "重新获取这部作品的简介、评分和演职员",
                "重新下载海报和背景图（你手动锁定的不动）",
                "同步更新影片文件夹里的海报和 NFO 信息文件",
                "不会改动你的视频文件",
            ]), confirmTitle: "刷新")
        }
        guard ok else { return }
        kicking = true
        defer { kicking = false }
        do {
            _ = try await api.libraryItemsRefreshMetadata(libraryId: libraryId, mediaItemId: itemId)
            await reload()
            try? await Task.sleep(for: .milliseconds(1500))
            await reload()
        } catch {
            refreshError = error.localizedDescription.isEmpty ? "元数据刷新失败，请稍后重试" : error.localizedDescription
        }
    }

    private func regenerateChapters() async {
        do {
            _ = try await api.libraryItemsRegenerateChapterImages(libraryId: libraryId, mediaItemId: itemId)
            feedback.success("已开始重新生成章节")
            await reload()
        } catch {
            feedback.error(error)
        }
    }

    private func clearHistory(_ detail: API.LibraryItemDetailView) async {
        guard await feedback.confirm("清除《\(detail.title)》的观看记录？",
                                     message: "续播进度、已看标记和播放次数都会清除，无法恢复。只影响你自己的记录。",
                                     confirmTitle: "清除", destructive: true) else { return }
        do {
            let (_, message) = try await api.libraryClearHistory(scope: "item", mediaItemId: detail.mediaItemId)
            feedback.success(message)
            await loadResume()
            episodesVersion += 1
        } catch {
            feedback.error(error)
        }
    }

    private func restore(_ file: API.LibraryFileView) async {
        do {
            _ = try await api.libraryItemsRestoreFile(libraryId: libraryId, mediaItemId: itemId, fileId: file.id)
            feedback.success("「\(file.fileName)」已恢复为在位版本")
            await reload()
        } catch {
            feedback.error(error.localizedDescription.isEmpty ? "恢复失败，请稍后重试" : error.localizedDescription)
        }
    }

    private func purge(_ file: API.LibraryFileView) async {
        let seeding = file.purgeAfter == nil
        guard await feedback.confirm(
            "立即清理「\(file.fileName)」？",
            message: seeding
                ? "该文件留在原位置（原盘目录或没能移入回收站），清理会直接从磁盘删除，此操作不可恢复。若它仍被下载器做种，清理会中断做种任务（PT 站请留意保种要求）。"
                : "将立即从回收站删除该文件，不再等待保留期，此操作不可恢复。",
            confirmTitle: "立即清理", destructive: true
        ) else { return }
        do {
            _ = try await api.libraryItemsPurgeFile(libraryId: libraryId, mediaItemId: itemId, fileId: file.id)
            feedback.success("「\(file.fileName)」已清理")
            await reload()
        } catch {
            feedback.error(error.localizedDescription.isEmpty ? "清理失败，请稍后重试" : error.localizedDescription)
        }
    }
}


// MARK: - 简介

/// 可展开的简介：默认 4 行，超出才给「展开全文 / 收起」
struct ExpandablePlot: View {
    let text: String
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.body)
                .lineSpacing(4)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(expanded ? nil : 4)
                .background {
                    // 量一下完整高度，判断 4 行是否装得下
                    ViewThatFits(in: .vertical) {
                        Text(text).font(.body).lineSpacing(4).hidden().onAppear { truncated = false }
                        Color.clear.onAppear { truncated = true }
                    }
                }
            if truncated || expanded {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "收起" : "展开全文")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .expandedHitArea(vertical: 12)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: text) {
            expanded = false
        }
    }
}

// MARK: - 分集

/// 剧集分集区（Web `SeasonEpisodesSection`）：季选择 + 分集横滚卡；缺集置灰、看完绿勾、看了一半底部进度条。
/// 默认落在接着看的那一集（同 Apple TV 版）：路由带了 season/episode 时是那一集；首页「接下来继续」里有这部剧时是它给的
/// 那一季那一集；否则第一个在库的正片季里看了一半的 → 第一集没看过的 → 第一集。落点不在第一集时滚到可见处。
struct SeasonEpisodesSection: View {
    let libraryId: Int
    let detail: API.LibraryItemDetailView
    var initialSeason: Int?
    var initialEpisode: Int?
    var refreshKey = 0
    var onEpisodeChange: (LibraryItemDetailView.SelectedEpisode?) -> Void

    @Environment(\.api) private var api
    @State private var season: Int?
    @State private var data: API.SeasonEpisodesView?
    @State private var failed = false
    @State private var selected: Int?

    private var ownedSeasons: Set<Int> { Set(detail.files.map(\.seasonNumber)) }
    /// 打开时落在哪一季哪一集：路由指定的 → 首页「接下来继续」里这部剧接着看的那一集
    private var entry: (season: Int, episode: Int?)? {
        if let initialSeason, ownedSeasons.contains(initialSeason) { return (initialSeason, initialEpisode) }
        guard let next = LibraryHomeStore.shared.upNext?.first(where: { $0.mediaItemId == detail.mediaItemId && $0.kind == "tv" }),
              ownedSeasons.contains(next.seasonNumber) else { return nil }
        return (next.seasonNumber, next.episodeNumber)
    }
    /// 没有落点时打开第一个有片源的正片季（特别篇排在最前，但不该先开它）
    private var currentSeason: Int {
        season ?? entry?.season
            ?? detail.seasons.first { $0 > 0 && ownedSeasons.contains($0) }
            ?? detail.seasons.first { ownedSeasons.contains($0) }
            ?? detail.seasons.first { $0 > 0 } ?? detail.seasons.first ?? 1
    }

    private func seasonLabel(_ s: Int) -> String {
        let name = s == 0 ? "特别篇" : "第 \(s) 季"
        return ownedSeasons.contains(s) ? name : "\(name) · 未入库"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("分集").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                if detail.seasons.count > 1 {
                    Menu {
                        Picker("季", selection: Binding(mcGet: { currentSeason }, set: { season = $0 })) {
                            ForEach(detail.seasons, id: \.self) { Text(seasonLabel($0)).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(seasonLabel(currentSeason))
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .accessibilityIdentifier("season-picker")
                } else {
                    Text(seasonLabel(currentSeason)).font(.subheadline).foregroundStyle(Theme.textMuted)
                }
                if let data {
                    Text("在库 \(data.episodes.filter(\.owned).count) / \(data.episodes.count) 集")
                        .font(.subheadline).monospacedDigit().foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, Theme.pagePadding)
            if failed {
                Text("分集信息加载失败，请稍后重试。").font(.subheadline).foregroundStyle(Theme.textMuted)
                    .padding(.horizontal, Theme.pagePadding)
            } else if let data {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(data.episodes, id: \.episodeNumber) { episode in
                                EpisodeCard(episode: episode, selected: episode.episodeNumber == selected) {
                                    selected = episode.episodeNumber
                                    report()
                                }
                                .id(episode.episodeNumber)
                            }
                        }
                        .padding(.horizontal, Theme.pagePadding)
                    }
                    .scrollClipDisabled()
                    .task(id: data.seasonNumber) {
                        if let target = selected, target != data.episodes.first?.episodeNumber {
                            try? await Task.sleep(for: .milliseconds(200))
                            withAnimation { proxy.scrollTo(target, anchor: .center) }
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取分集信息…")
                }
                .font(.subheadline).foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.pagePadding).padding(.vertical, 20)
            }
        }
        .task(id: "\(currentSeason)|\(detail.fileCount)") { await load(reset: true) }
        .onChange(of: refreshKey) { Task { await load(reset: false) } }
        .accessibilityIdentifier("season-episodes")
    }

    private func load(reset: Bool) async {
        let s = currentSeason
        if reset {
            data = nil
            failed = false
        }
        do {
            let result = try await api.libraryItemsListEpisodes(libraryId: libraryId, mediaItemId: detail.mediaItemId, seasonNumber: s)
            guard s == currentSeason else { return }
            data = result
            if reset {
                let target = s == entry?.season ? entry?.episode : nil
                let requested = target.flatMap { t in result.episodes.first { $0.episodeNumber == t && $0.owned } }
                selected = (requested ?? result.episodes.resumeEpisode)?.episodeNumber
                // 定住打开的这一季：「接下来继续」之后刷新（比如刚看完一季）不把分集区跳到别的季
                if season == nil { season = s }
            }
            report()
        } catch is CancellationError {
        } catch {
            if reset { failed = true }
        }
    }

    private func report() {
        guard let data, let episode = data.episodes.first(where: { $0.episodeNumber == selected }) else {
            onEpisodeChange(nil)
            return
        }
        let files = episode.fileIds.compactMap { id in detail.files.first { $0.id == id } }
        onEpisodeChange(.init(season: data.seasonNumber, episode: episode, files: files))
    }
}

private struct EpisodeCard: View {
    let episode: API.EpisodeView
    let selected: Bool
    var onSelect: () -> Void
    @Environment(\.api) private var api

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                LibraryArtwork(url: api.image(episode.stillUrl, width: ImageWidth.points(200)), frameAspect: 16 / 9,
                               fallbackText: episode.stillUrl == nil ? "\(episode.episodeNumber)" : nil)
                    .clipShape(.rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? .white.opacity(0.85) : .white.opacity(0.08), lineWidth: selected ? 2 : 1))
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 4) {
                            if !episode.owned {
                                Text("缺").font(.caption2.weight(.semibold)).foregroundStyle(Theme.warning)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                            }
                            if episode.played {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 18, height: 18).background(Theme.success, in: .circle)
                            }
                        }
                        .padding(6)
                    }
                    .overlay(alignment: .bottom) {
                        // 看完后重看到一半：对勾保留，进度条按这次看到哪画
                        let resuming = episode.positionMs > 0
                        let progress = resuming ? episode.progressPercent : episode.played ? 100 : nil
                        if let progress {
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.25))
                                    Capsule().fill(resuming ? Theme.accent2 : Theme.success).frame(width: proxy.size.width * CGFloat(progress) / 100)
                                }
                            }
                            .frame(height: 3).padding(6)
                        } else if episode.positionMs > 0 {
                            Capsule().fill(Theme.accent2.opacity(0.6)).frame(height: 3).padding(6)
                        }
                    }
                Text("\(episode.episodeNumber). \(episode.name ?? "第 \(episode.episodeNumber) 集")")
                    .font(.footnote.weight(selected ? .semibold : .regular))
                    .monospacedDigit()
                    .foregroundStyle(selected ? .white : Theme.text)
                    .lineLimit(1)
            }
            .frame(width: 200)
            .contentShape(.rect)
            .opacity(episode.owned ? 1 : 0.45)
            .saturation(episode.owned ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("episode-\(episode.episodeNumber)")
    }
}

// MARK: - 文件行

/// 文件区的一行（Web `FileRow`）：点开看保存目录、入库时间、来源、多版本、尺寸、片源与画面规格；
/// 待回收的文件带倒计时与「恢复」「立即清理」，在位文件给「删除此文件」。
struct LibraryFileRow: View {
    let file: API.LibraryFileView
    var onDelete: (() -> Void)?
    var onRestore: (() -> Void)?
    var onPurge: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(Theme.textFaint)
                        Text(file.fileName)
                            .font(.footnote)
                            .strikethrough(file.state == "trashed")
                            .foregroundStyle(file.state == "trashed" ? Theme.textFaint : Theme.textMuted)
                            .lineLimit(expanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("file-row-\(file.id)")
                .contextMenu {
                    Button { UIPasteboard.general.string = file.filePath } label: { Label("拷贝路径", systemImage: "doc.on.doc") }
                }
                if file.missing { tag("文件缺失", color: Theme.warning) }
                if file.state == "trashed" {
                    tag("待回收", color: Theme.textFaint)
                    if let onRestore { Button("恢复", action: onRestore).font(.caption.weight(.semibold)) }
                    if let onPurge { Button("立即清理", action: onPurge).font(.caption.weight(.semibold)).foregroundStyle(Theme.danger) }
                } else if let onDelete {
                    Button(action: onDelete) { Image(systemName: "trash").font(.footnote) }
                        .foregroundStyle(Theme.textFaint)
                        .accessibilityLabel("删除此文件")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if file.state == "trashed" {
                Text(Self.purgeCountdown(file.purgeAfter) + (file.trashNote.map { " · \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if expanded { details }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2).foregroundStyle(color.opacity(0.85))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.3)))
    }

    private var details: some View {
        let picture = [file.resolution.map(LibraryItemDetailView.resolutionLabel), file.hdr].compactMap { $0 }.joined(separator: " · ")
        let codecs = ["hevc": "HEVC", "h264": "H.264", "h265": "HEVC", "av1": "AV1", "vc1": "VC-1", "mpeg2video": "MPEG-2", "vp9": "VP9"]
        let codec = file.videoCodec.map { codecs[$0.lowercased()] ?? $0.uppercased() }
        let frameRate = file.frameRate.flatMap { $0 > 0 ? "\(($0 * 1000).rounded() / 1000) fps".replacingOccurrences(of: ".0 fps", with: " fps") : nil }
        let source: String = {
            guard let s = file.mediaSource, !s.isEmpty else { return "未识别" }
            let label = s == "user-lowest" ? "最低档（人工标注）" : s == "Disc" ? "原盘" : s
            return label + (file.mediaSourceManual && s != "user-lowest" ? "（人工标注）" : "")
        }()
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            row("保存目录", Self.directory(file.filePath), mono: true)
            row("入库时间", "\(Formatters.dateTime(file.addedAt)) · \(libraryFromNow(file.addedAt))")
            GridRow {
                Text("来源").foregroundStyle(Theme.textFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.origin.label).foregroundStyle(Theme.text)
                    if let detail = file.origin.detail {
                        Text(detail).font(.caption.monospaced()).foregroundStyle(Theme.textFaint)
                    }
                }
            }
            if let kept = file.keptAt {
                row("多版本", "你留下的 · \(Formatters.dateTime(kept))（不会再列为重复文件）")
            }
            row("文件尺寸", libraryBytes(file.sizeBytes))
            row("片源", source)
            row("画面规格", picture.isEmpty ? "未能探测（文件不可达或尚未扫描）" : picture)
            row("视频编码", codec ?? "尚未探测")
            row("色深", file.bitDepth.map { "\($0)-bit" } ?? "尚未探测")
            row("帧率", frameRate ?? "尚未探测")
            row("色彩空间", file.colorSpace ?? "尚未探测")
            row("视频码率", file.bitRate.map { String(format: "%.1f Mbps", Double($0) / 1_000_000) } ?? "尚未探测")
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.textFaint)
            Text(value)
                .font(mono ? .caption.monospaced() : .footnote)
                .foregroundStyle(Theme.textMuted)
                .textSelection(.enabled)
        }
    }

    static func directory(_ path: String) -> String {
        var normalized = path
        while normalized.hasSuffix("/") || normalized.hasSuffix("\\") { normalized.removeLast() }
        guard let index = normalized.lastIndex(where: { $0 == "/" || $0 == "\\" }) else { return "—" }
        if index == normalized.startIndex { return String(normalized.prefix(1)) }
        return String(normalized[..<index])
    }

    static func purgeCountdown(_ raw: String?) -> String {
        guard let raw else { return "不自动清理" }
        guard let date = Formatters.date(raw) else { return "即将自动清理" }
        let ms = date.timeIntervalSinceNow * 1000
        if ms <= 0 { return "即将自动清理" }
        let days = Int(ms / 86_400_000), hours = Int(ms.truncatingRemainder(dividingBy: 86_400_000) / 3_600_000)
        if days > 0 { return "预计 \(days) 天 \(hours) 小时后自动清理" }
        if hours > 0 { return "预计 \(hours) 小时后自动清理" }
        return "预计 1 小时内自动清理"
    }
}
