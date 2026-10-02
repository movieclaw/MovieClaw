import SwiftUI

/// 当前账号能看到的媒体库清单，按服务端顺序（海报墙取库名、首页「我的媒体库」列库用）。
///
/// 照片类媒体库首版不做（docs/design/tvos-app.md §3.1），不在电视上出现。
@Observable
final class TVLibraryDirectory {
    private(set) var libraries: [API.LibraryView] = []
    private(set) var loaded = false

    /// 能在电视上浏览的库（排除照片库与没有访问权限的）
    var browsable: [API.LibraryView] {
        libraries.filter { $0.viewerAccess && $0.kind != "photo" }
    }

    func load(api: APIClient) async {
        do {
            let fresh = try await api.libraryList(scope: "all")
            if fresh != libraries { libraries = fresh }
        } catch {
            // 拿不到就保持原样（首页会挂自己的错误提示）
        }
        loaded = true
    }

    func library(_ id: Int) -> API.LibraryView? {
        libraries.first { $0.id == id }
    }
}
