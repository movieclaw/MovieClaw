import TVServices

/// Top Shelf 扩展（docs/design/tvos-app.md §3.1）：把 App 写进 App Group 的「接下来继续」交给系统。
/// 不联网、不碰令牌（理由见 `TopShelfSnapshot`）；没有数据（还没登录、没有在看的）时返回空，系统显示 App 的静态 Top Shelf 图。
final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let snapshot = TopShelfStore.read(), !snapshot.items.isEmpty else { return nil }
        let items = snapshot.items.compactMap { item -> TVTopShelfSectionedItem? in
            guard let play = URL(string: item.playURL), let display = URL(string: item.displayURL) else { return nil }
            let entry = TVTopShelfSectionedItem(identifier: item.id)
            entry.title = item.subtitle.map { "\(item.title) · \($0)" } ?? item.title
            entry.imageShape = .hdtv
            if let image = TopShelfStore.imageURL(item.imageFile) {
                entry.setImageURL(image, for: .screenScale1x)
                entry.setImageURL(image, for: .screenScale2x)
            }
            if let progress = item.progress { entry.playbackProgress = progress }
            entry.playAction = TVTopShelfAction(url: play)
            entry.displayAction = TVTopShelfAction(url: display)
            return entry
        }
        let section = TVTopShelfItemCollection(items: items)
        section.title = "接下来继续"
        return TVTopShelfSectionedContent(sections: [section])
    }
}
