import Foundation
import Observation

// MARK: - 数据

/// 各视角数据的缓存容器：字典本身不参与观察（在 body 里按需创建不会触发状态写入警告），
/// 每个视角的 `DiscoverFeed` 自己是可观察的。
@Observable
final class DiscoverFeedStore {
    @ObservationIgnored private var feeds: [String: DiscoverFeed] = [:]

    func feed(mediaType: String, provider: String) -> DiscoverFeed {
        let key = "\(mediaType):\(provider)"
        if let feed = feeds[key] { return feed }
        let feed = DiscoverFeed(mediaType: mediaType, provider: provider)
        feeds[key] = feed
        return feed
    }

    /// 院线地区变更：其余视角下次进入时重新拉取
    func invalidateAll() {
        for feed in feeds.values { feed.invalidate() }
    }
}

/// 一个视角（类型 × 数据源）的发现页数据：展示清单 + Hero + 各行片单。
///
/// 三态约定（同 Web）：hero = nil 加载中（出骨架）/ [] 无或失败（收起）/ 有值轮播；
/// rows[ref] 缺省 = 加载中，`.failed` = 失败（收起），`.loaded` = 渲染。
@Observable
final class DiscoverFeed {
    enum RowState { case loaded([DiscoverPosterItem]), failed }

    struct Failure {
        var message: String
        var unreachable: Bool
        /// 后端给的下一步提示（不可达时的 `details[0].hint`），异步补上
        var hint: String?
    }

    let mediaType: String
    let provider: String
    private(set) var layout: API.DiscoveryPageView?
    private(set) var hero: [DiscoverPosterItem]?
    private(set) var rows: [String: RowState] = [:]
    private(set) var failure: Failure?
    @ObservationIgnored private var loaded = false

    init(mediaType: String, provider: String) {
        self.mediaType = mediaType
        self.provider = provider
        // 本机快照（DiscoverSnapshots）：先原样画出上次的版面、Hero 与各行，再照常刷新
        if let snapshot = DiscoverSnapshots.snapshot(mediaType: mediaType, provider: provider) {
            layout = snapshot.layout
            hero = snapshot.hero
            rows = snapshot.rows.mapValues { .loaded($0) }
        }
    }

    var declaresHero: Bool { layout?.sections.contains { $0.presentation == "hero" } == true }
    var rowSections: [API.DiscoveryPageSectionView] { layout?.sections.filter { $0.presentation != "hero" } ?? [] }

    /// 整页数据都到了（打点用，见 PerfTrace）：版面、Hero 与每一行都有了结果（成功或失败）
    var perfComplete: Bool {
        guard layout != nil else { return failure != nil }
        return (!declaresHero || hero != nil) && rowSections.allSatisfy { rows[$0.collectionRef] != nil }
    }

    /// 首屏会显示的图（交给 FirstScreenImages 提前解码进内存）：Hero 第一张的剧照、第一行前 4 张海报
    func firstScreenImageURLs(api: APIClient) -> [URL] {
        var urls: [URL?] = []
        if let first = hero?.first { urls.append(DiscoverHeroImage.url(first, api: api)) }
        if let section = rowSections.first, case let .loaded(items) = rows[section.collectionRef] {
            urls += items.prefix(4).map { api.image($0.posterUrl, .card(aspect: Double($0.aspect))) }
        }
        return urls.compactMap { $0 }
    }

    /// 常规行全部失败（且没有任何一行成功）→ 整页错误态
    var allRowsFailed: Bool {
        let sections = rowSections
        guard !sections.isEmpty else { return false }
        return sections.allSatisfy { if case .failed = rows[$0.collectionRef] { true } else { false } }
    }

    /// 首次进入该视角才拉取；已缓存的视角直接恢复
    func loadIfNeeded(api: APIClient) async {
        guard !loaded else { return }
        await reload(api: api)
    }

    func invalidate() {
        loaded = false
    }

    func reload(api: APIClient) async {
        loaded = true
        failure = nil
        let page: API.DiscoveryPageView
        do {
            page = try await api.uiDiscoveryGet(mediaType: mediaType, provider: provider)
        } catch is CancellationError {
            loaded = false
            return
        } catch {
            failure = Failure(message: error.localizedDescription, unreachable: error.isUpstreamUnreachable)
            loaded = false
            await fillHint(api: api, path: "/ui/discovery/\(mediaType)", query: [URLQueryItem(name: "provider", value: provider)])
            return
        }
        layout = page
        let heroRef = page.sections.first { $0.presentation == "hero" }?.collectionRef
        if heroRef == nil { hero = [] }
        var firstError: (ref: String, limit: Int?, error: Error)?

        await withTaskGroup(of: (String, Result<[DiscoverPosterItem], Error>).self) { group in
            for section in page.sections {
                let ref = section.collectionRef
                let limit = section.previewLimit
                group.addTask {
                    do {
                        let result = try await api.discoverBrowseCollection(collectionRef: ref, limit: limit)
                        return (ref, .success(result.titles.map(DiscoverPosterItem.init)))
                    } catch {
                        return (ref, .failure(error))
                    }
                }
            }
            for await (ref, result) in group {
                if ref == heroRef {
                    // Hero 失败只收起自身；刷新失败保留旧轮播
                    if let items = try? result.get() { hero = items } else if hero == nil { hero = [] }
                    continue
                }
                switch result {
                case let .success(items):
                    rows[ref] = .loaded(items)
                case let .failure(error):
                    if error is CancellationError { continue }
                    if case .loaded = rows[ref] { continue }
                    rows[ref] = .failed
                    if firstError == nil {
                        firstError = (ref, page.sections.first { $0.collectionRef == ref }?.previewLimit, error)
                    }
                }
            }
        }
        if !allRowsFailed, let layout {
            let loaded = rows.compactMapValues { if case let .loaded(items) = $0 { items } else { nil } }
            DiscoverSnapshots.save(DiscoverFeedSnapshot(layout: layout, hero: hero, rows: loaded), mediaType: mediaType, provider: provider)
        }
        if allRowsFailed, let firstError {
            failure = Failure(message: firstError.error.localizedDescription, unreachable: firstError.error.isUpstreamUnreachable)
            loaded = false
            await fillHint(api: api, path: "/discover/collections/\(firstError.ref)/titles",
                           query: firstError.limit.map { [URLQueryItem(name: "limit", value: "\($0)")] } ?? [])
        }
    }

    /// 不可达时补上后端的下一步提示（错误态先出原因，提示随后显示在原因下方）
    private func fillHint(api: APIClient, path: String, query: [URLQueryItem]) async {
        guard failure?.unreachable == true else { return }
        let hint = await api.discoverUnreachableHint(path: path, query: query)
        if let hint, failure?.unreachable == true { failure?.hint = hint }
    }
}

/// 发现页 Hero 的剧照地址（iPhone 与 Apple TV 同一口径）
enum DiscoverHeroImage {
    /// TMDB 剧照换原始尺寸（3840×2160，约 400KB）：发现接口给的是 w1280（1280×720），Hero 要把 16:9 横图
    /// 放大裁切铺满大区域（手机 3 倍屏、4K 电视都要 2400 像素以上），1280 的图被拉伸发糊
    static func fullResolution(_ raw: String?) -> String? {
        raw?.replacingOccurrences(of: "image.tmdb.org/t/p/w1280/", with: "image.tmdb.org/t/p/original/")
    }

    /// Hero 显示与取色、预载共用的剧照地址（剧照原图；没有剧照退回海报）
    static func url(_ item: DiscoverPosterItem, api: APIClient) -> URL? {
        api.image(fullResolution(item.backdropUrl) ?? item.posterUrl)
    }
}
