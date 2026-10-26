import Foundation
import Observation

/// 海报墙的「窗口式」分页器（iPhone 的单库页 / 合集 / 收藏，Apple TV 的各面海报墙共用）。
///
/// 对应 Web 海报墙的 load / loadPrev / jumpTo / reload 四件事：
/// - 墙是整份排序结果上的一个**窗口** `[start, start + items.count)`；
/// - 向下滚到底追加下一页，「A–Z 跳转」「回到上次位置」直接把窗口换成从某个 offset 开始的一页
///   （而不是从头一页页追到那儿），之后向上滚到顶再把上一页补回来；
/// - 轮询 / 从详情页返回时按已加载的页数整窗重拉（`refresh`），在详情页取消收藏的那部会跟着消失，
///   不缩窗口也不动滚动位置。
/// 请求用序号作废：换排序/筛选后，上一轮晚到的响应不会覆盖新窗口。
@MainActor
@Observable
final class LibraryWallPager<Item: Identifiable & Sendable> where Item.ID: Sendable {
    typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async throws -> [Item]

    let pageSize: Int
    private(set) var items: [Item]?
    /// 窗口在整份排序里的起点
    private(set) var start = 0
    private(set) var hasMore = false
    private(set) var failed: String?
    /// 整份结果的总数；接口不给总数时为 nil（按「本页是否满页」判断还有没有下一页）
    var total: Int?
    private var loading = false
    private var loadingPrev = false
    private var generation = 0
    @ObservationIgnored private var fetch: Fetch?

    init(pageSize: Int = 60) {
        self.pageSize = pageSize
    }

    /// 换数据源（排序/筛选变化）：清空并从 offset 起载入第一页
    func reset(_ fetch: @escaping Fetch, from offset: Int = 0, keepItems: Bool = false) async {
        self.fetch = fetch
        generation += 1
        if !keepItems { items = nil }
        await jump(to: offset)
    }

    /// 窗口换成从 offset 开始的一页
    func jump(to offset: Int) async {
        guard let fetch else { return }
        generation += 1
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            let page = try await fetch(offset, pageSize)
            guard gen == generation else { return }
            start = offset
            items = page
            hasMore = page.count >= pageSize && (total.map { offset + page.count < $0 } ?? true)
            failed = nil
        } catch is CancellationError {
        } catch {
            guard gen == generation else { return }
            if items == nil { failed = error.localizedDescription }
        }
    }

    /// 墙尾追加一页
    func loadMore() async {
        guard let fetch, hasMore, !loading, let current = items else { return }
        let gen = generation
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            let page = try await fetch(start + current.count, pageSize)
            guard gen == generation else { return }
            let seen = Set(current.map(\.id))
            items = current + page.filter { !seen.contains($0.id) }
            hasMore = page.count >= pageSize && (total.map { start + (items?.count ?? 0) < $0 } ?? true)
        } catch {
            guard gen == generation else { return }
            hasMore = false
        }
    }

    /// 墙顶还有上文时补上一页（跳转之后仍然能往上滑）
    func loadPrevious() async {
        guard let fetch, start > 0, !loadingPrev, let current = items else { return }
        let gen = generation
        loadingPrev = true
        defer { loadingPrev = false }
        let from = max(0, start - pageSize)
        guard let page = try? await fetch(from, start - from), gen == generation, !page.isEmpty else { return }
        let seen = Set(current.map(\.id))
        start -= page.count
        items = page.filter { !seen.contains($0.id) } + current
    }

    /// 按已加载的条数整窗重拉并整体替换（轮询 / 返回对账），失败保留旧窗口
    func refresh() async {
        guard let fetch, !loading, let current = items else {
            // 墙还没首载：首页请求正在路上时不抢跳——那一跳会作废首载结果、再发一次同样的请求，
            // 进页询问「回到上次位置」因此落空（第三轮复核 N-04b-5）
            if items == nil, self.fetch != nil, !loading { await jump(to: start) }
            return
        }
        let gen = generation
        let count = max(pageSize, current.count)
        let origin = start
        do {
            var rows: [Item] = []
            var offset = origin
            while offset < origin + count {
                let page = try await fetch(offset, pageSize)
                rows += page
                if page.count < pageSize { break }
                offset += pageSize
            }
            guard gen == generation, !loading else { return }
            if rows.isEmpty, origin > 0 {
                await jump(to: 0)
                return
            }
            items = rows
            hasMore = rows.count >= count && (total.map { origin + rows.count < $0 } ?? true)
        } catch {}
    }

    /// 本地改一格（收藏心、已看标记等乐观更新）
    func update(_ id: Item.ID, _ transform: (inout Item) -> Void) {
        guard var list = items, let index = list.firstIndex(where: { $0.id == id }) else { return }
        transform(&list[index])
        items = list
    }

    func offset(of id: Item.ID) -> Int? {
        items?.firstIndex { $0.id == id }.map { start + $0 }
    }
}
