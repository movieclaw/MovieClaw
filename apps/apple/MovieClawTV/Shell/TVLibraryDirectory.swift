import SwiftUI

/// 侧边栏上的媒体库清单：当前账号能看到的库，按服务端顺序。
///
/// 侧边栏最多直接放 `sidebarLimit` 个库，多出来的收进「全部媒体库」一页（docs/design/tvos-app.md §3.3），
/// 免得把底部的「更多」分组挤出屏幕。照片类媒体库首版不做（§3.1），不出现在侧边栏。
@Observable
final class TVLibraryDirectory {
    static let sidebarLimit = 6

    private(set) var libraries: [API.LibraryView] = []
    private(set) var loaded = false

    /// 能在电视上浏览的库（排除照片库与没有访问权限的）
    var browsable: [API.LibraryView] {
        libraries.filter { $0.viewerAccess && $0.kind != "photo" }
    }

    /// 直接放进侧边栏的库
    var sidebar: [API.LibraryView] {
        Array(browsable.prefix(Self.sidebarLimit))
    }

    /// 是否有放不下的库（侧边栏多一项「全部媒体库」）
    var overflow: Bool {
        browsable.count > Self.sidebarLimit
    }

    func load(api: APIClient) async {
        do {
            let fresh = try await api.libraryList(scope: "all")
            if fresh != libraries { libraries = fresh }
        } catch {
            // 拿不到就保持原样（首页会挂自己的错误提示）；侧边栏只是少了库这几项
        }
        loaded = true
    }

    func library(_ id: Int) -> API.LibraryView? {
        libraries.first { $0.id == id }
    }

    /// 侧边栏图标：按库的类型
    static func symbol(for kind: API.MediaKind) -> String {
        switch kind {
        case "movie": "film"
        case "tv": "tv"
        case "photo": "photo.on.rectangle"
        default: "play.rectangle.on.rectangle"
        }
    }
}
