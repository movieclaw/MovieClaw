import Foundation

// 生成模型的协议补充集中放在这里（Generated/ 勿手改）。
// 各模块需要给 API.* 模型加 Identifiable 等一致性时，先 grep 本文件，没有再加到这里，
// 不要在模块目录里各加一份——同一类型重复声明一致性会编译失败。
//
// 一律写 nonisolated：工程默认隔离在主线程，不写的话一致性会被推断为主线程隔离，
// Xcode 26（Swift 6.2）不许它满足 Sendable 泛型参数（如 LibraryWallPager<Item>）而编译失败；
// Xcode 27 能自行推断出不隔离，所以本机编得过、CI 的 Xcode 26 编不过（2026-09-29）。

nonisolated extension API.LibraryFileView: Identifiable {}

nonisolated extension API.LibraryItemView: Identifiable {
    var id: Int { mediaItemId }
}

nonisolated extension API.FavoriteItemView: Identifiable {
    var id: Int { mediaItemId }
}

// 活动模块：删除确认弹层按种子任务弹出、列表按 Job id 区分
nonisolated extension API.DownloadTaskView: Identifiable {}

nonisolated extension API.JobView: Identifiable {}

// 设置（成员）
nonisolated extension API.MemberView: Identifiable {}
