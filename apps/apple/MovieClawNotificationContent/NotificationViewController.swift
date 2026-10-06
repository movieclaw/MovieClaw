import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

/// 通知内容扩展（docs/design/cloud-push.md §9）：长按剧卡时的展开界面。
///
/// 从上到下：配图大图（角上标出「播放」会到哪一集）、标题正文、这一季的集数格子（看过 / 已入库 / 下载中 / 没找到）。
/// 标题正文、配图是通知扩展已经换好的；格子和快捷操作在密文里，按 key_id 从共享钥匙串取密钥自己解开——
/// 通知扩展不往 userInfo 里写东西（同 App 点开时重新解密）。解不开（已退出那个账号）就只画标题正文。
///
/// 快捷操作的标题按明文换成具体的（「播放第 4 集」）；点了之后由 App 处理（PushActions）。
final class NotificationViewController: UIViewController, UNNotificationContentExtension {
    private let model = CardModel()
    private var host: UIHostingController<CardView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: CardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host
    }

    func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        let push = DecryptedPush(userInfo: content.userInfo, store: .shared)
        let plaintext = push.flatMap { $0.plaintext.isNewer ? nil : $0.plaintext }
        model.title = content.title
        model.body = content.body
        model.image = Self.image(content.attachments.first)
        model.grid = plaintext?.grid
        let actions = plaintext?.actions ?? []
        model.playing = actions.first { $0.id == "play" }.flatMap { Self.unitLabel(fromPlayTitle: $0.title) }
        if !actions.isEmpty {
            extensionContext?.notificationActions = actions.map(Self.action)
        }
        resize()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        resize()
    }

    /// 按内容定高度：宽度是系统给的，高度随格子行数变
    private func resize() {
        guard let host, view.bounds.width > 0 else { return }
        let size = host.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
        let height = ceil(size.height)
        if abs(preferredContentSize.height - height) > 0.5 {
            preferredContentSize = CGSize(width: view.bounds.width, height: height)
        }
    }

    /// 通知扩展附上的配图（系统给的是要「申请访问」的地址）
    private static func image(_ attachment: UNNotificationAttachment?) -> UIImage? {
        guard let url = attachment?.url, url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return UIImage(contentsOfFile: url.path)
    }

    /// 「播放第 4 集」→「第 4 集」（标在大图角上）；电影的「播放」不标
    static func unitLabel(fromPlayTitle title: String) -> String? {
        let label = title.hasPrefix("播放") ? String(title.dropFirst(2)) : title
        return label.isEmpty ? nil : label
    }

    private static func action(_ action: PushPlaintext.Action) -> UNNotificationAction {
        switch action.id {
        case "play":
            UNNotificationAction(identifier: action.id, title: action.title, options: [.foreground],
                                 icon: UNNotificationActionIcon(systemImageName: "play.fill"))
        case "mute":
            UNNotificationAction(identifier: action.id, title: action.title, options: [.destructive],
                                 icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        default:
            UNNotificationAction(identifier: action.id, title: action.title, options: [.foreground],
                                 icon: UNNotificationActionIcon(systemImageName: "list.bullet"))
        }
    }
}

@Observable
final class CardModel {
    var title = ""
    var body = ""
    var image: UIImage?
    var grid: PushPlaintext.Grid?
    /// 「播放」会到哪一集（标在大图角上）
    var playing: String?
}
