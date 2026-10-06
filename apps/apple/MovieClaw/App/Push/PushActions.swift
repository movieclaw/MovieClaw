import os
import UserNotifications

/// 长按通知的快捷操作（docs/design/cloud-push.md §5.1、§9）。
///
/// 剧卡（类别 `item`）长按出三个操作：「播放第 N 集」「查看全部剧集」「这部剧不再提醒」。按钮的标题由通知内容扩展
/// 按明文改成具体的（「播放第 4 集」），这里注册的是兜底标题。点了之后 App 重新解密，按明文里这个操作的
/// `open` 打开，或者在后台调服务器静音这部片——推送里密文以外的东西都不信（同 PushTapTarget）。
nonisolated enum PushActions {
    static let itemCategory = "item"
    static let play = "play"
    static let open = "open"
    static let mute = "mute"

    private static let log = Logger(subsystem: "io.movieclaw.push", category: "actions")

    /// App 启动时注册（系统要在用户长按之前就知道有哪些类别）
    static func register() {
        let item = UNNotificationCategory(
            identifier: itemCategory,
            actions: [
                UNNotificationAction(identifier: play, title: "播放", options: [.foreground],
                                     icon: UNNotificationActionIcon(systemImageName: "play.fill")),
                UNNotificationAction(identifier: open, title: "查看全部剧集", options: [.foreground],
                                     icon: UNNotificationActionIcon(systemImageName: "list.bullet")),
                UNNotificationAction(identifier: mute, title: "这部剧不再提醒", options: [.destructive],
                                     icon: UNNotificationActionIcon(systemImageName: "bell.slash")),
            ],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([item])
    }

    /// 「这部剧不再提醒」要静音的片和推这条通知的账号：在 App 里重新解密取（推送里别的键都不信）
    struct MuteRequest: Sendable {
        var item: Int
        var login: PushLoginInfo

        init?(userInfo: [AnyHashable: Any], store: PushKeyStore = .shared) {
            guard let push = DecryptedPush(userInfo: userInfo, store: store), !push.plaintext.isNewer,
                  let item = push.plaintext.actions?.first(where: { $0.id == PushActions.mute })?.item
            else { return nil }
            self.item = item
            login = push.login
        }
    }

    /// 在后台用推这条通知的那个账号调服务器静音（只关推送，订阅照常下载）
    @MainActor
    static func mute(_ request: MuteRequest) async {
        guard let server = request.login.server,
              let token = TokenVault.token(server: server, username: request.login.username)
        else { return }
        do {
            _ = try await APIClient(server: server, token: token).pushMeMutedAdd(itemId: request.item)
        } catch {
            log.info("静音失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
