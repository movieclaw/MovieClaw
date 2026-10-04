import SwiftUI

/// 菜单栏（docs/design/macos-app.md §3.3）：Mac 用户习惯从菜单栏与快捷键找功能，侧边栏能做的事在这里都有一份。
/// - 「MovieClaw › 关于 MovieClaw」打开关于窗口（版本、开源许可）；
/// - 「前往」：首页 ⌘1、我的收藏 ⌘2、各个媒体库 ⌘3…、搜索 ⌘F、返回 ⌘[；
/// - 「账号」：切换到本机登录过的其他账号、添加账号、退出登录。
/// 播放器里的快捷键（空格、←→、F……）由播放器自己处理（`MacPlayerScreen`）。
struct MacCommands: Commands {
    let model: AppModel
    @FocusedValue(\.macRouter) private var router
    @FocusedValue(\.macFocusSearch) private var focusSearch
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 MovieClaw") { openWindow(id: "about") }
        }
        // 只有一个主窗口：不要「新建窗口」，避免开出两份播放器、两套导航状态
        CommandGroup(replacing: .newItem) {}
        CommandMenu("前往") {
            Button("首页") { go(.home) }
                .keyboardShortcut("1")
            Button("我的收藏") { go(.favorites) }
                .keyboardShortcut("2")
            if let router {
                let libraries = LibraryHomeStore.shared.libraries?.filter { $0.viewerAccess && $0.kind != "photo" } ?? []
                if !libraries.isEmpty {
                    Divider()
                    ForEach(Array(libraries.prefix(7).enumerated()), id: \.element.id) { index, library in
                        Button(library.name) { go(.library(library.id)) }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 3))))
                    }
                }
                Divider()
                Button("返回") { router.pop() }
                    .keyboardShortcut("[")
                    .disabled(router.path.isEmpty || router.player != nil)
            }
            Divider()
            Button("搜索") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }
        CommandMenu("账号") {
            if case .ready = model.phase {
                let current = MacAccounts.currentID(model)
                ForEach(MacAccounts.all(model)) { saved in
                    Button {
                        guard saved.id != current else { return }
                        Task { try? await model.switchAccount(to: saved.account.username, on: saved.server) }
                    } label: {
                        if saved.id == current {
                            Label("\(saved.account.nickname)（\(saved.server.hostLabel)）", systemImage: "checkmark")
                        } else {
                            Text("\(saved.account.nickname)（\(saved.server.hostLabel)）")
                        }
                    }
                }
                Divider()
                Button("退出登录") { Task { await model.logout() } }
            }
        }
    }

    private func go(_ tab: MainTab) {
        guard let router else { return }
        router.player = nil
        router.searchText = ""
        router.selection = tab
    }
}
