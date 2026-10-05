import Foundation
import ImageIO
import UniformTypeIdentifiers
import UserNotifications

/// 通知扩展（docs/design/cloud-push.md §9，push-payload.md §6）。
///
/// 推送经中继到达时只带通用文案（「MovieClaw」「你有一条新通知」）和密文 `e`。这里：
/// 1. 按密文里的 `key_id` 从 App Group 共享的钥匙串取这个登录的密钥，解密、校验 `type`；
/// 2. 换上真正的标题、副标题、正文、分组（按服务器分开）、类别、声音；按明文的 `source` 在副标题标出服务器或账号
///    （本机连了多台服务器 / 同一台上登了多个账号时才标，内容类通知不标）；
/// 3. 有配图时从「服务器地址 + 路径」下载（路径带签名，不用登录），5 秒内拿不到就不带图。
///
/// 点开后切哪个账号、跳哪个页面由 App 重新解密决定（PushTapTarget），这里不往 userInfo 里写任何东西。
/// 任何一步失败都保留中继的通用文案，不报错。不碰登录令牌。
final class NotificationService: UNNotificationServiceExtension {
    private var delivery: Delivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let delivery = Delivery(contentHandler, fallback: request.content)
        self.delivery = delivery
        let store = PushKeyStore.shared
        guard let push = DecryptedPush(userInfo: request.content.userInfo, store: store),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else { return delivery.finish() }

        let presentation = PushAlertPresentation(push, logins: Array(store.registry.entries.values))
        presentation.apply(to: content)
        delivery.update(content)
        guard let imageURL = presentation.imageURL else { return delivery.finish() }
        PushImageDownload.attachment(from: imageURL) { attachment in
            delivery.finish(attachment: attachment)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // 系统要收回时间了：交出已经解开的那一版（不带图）
        delivery?.finish()
    }
}

private extension PushAlertPresentation {
    func apply(to content: UNMutableNotificationContent) {
        if let title { content.title = title }
        if let subtitle { content.subtitle = subtitle }
        if let body { content.body = body }
        if let thread { content.threadIdentifier = thread }
        if let category { content.categoryIdentifier = category }
        if let sound {
            content.sound = sound == "default" ? .default : UNNotificationSound(named: UNNotificationSoundName(sound))
        }
    }
}

/// 一条通知只交一次：没有配图、配图下载完、系统喊停，谁先到谁交，之后的都忽略
private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNNotificationContent

    init(_ handler: @escaping (UNNotificationContent) -> Void, fallback: UNNotificationContent) {
        self.handler = handler
        content = fallback
    }

    /// 解开后的内容（还没带图）：之后不管怎么结束，至少交这一版
    func update(_ content: UNNotificationContent) {
        lock.withLock { self.content = content }
    }

    func finish(attachment: UNNotificationAttachment? = nil) {
        let (handler, content) = lock.withLock {
            defer { self.handler = nil }
            return (self.handler, self.content)
        }
        guard let handler else { return }
        if let attachment, let withImage = content.mutableCopy() as? UNMutableNotificationContent {
            withImage.attachments = [attachment]
            handler(withImage)
        } else {
            handler(content)
        }
    }
}

/// 下载配图做成通知附件：前后最多 5 秒，失败就不带图
private enum PushImageDownload {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static let attachable: Set<UTType> = [.jpeg, .png, .gif]

    private struct ConversionFailed: Error {}

    private static func jpeg(from source: URL) throws -> URL {
        let target = source.deletingPathExtension().appendingPathExtension("jpg")
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ConversionFailed() }
        CGImageDestinationAddImageFromSource(destination, image, 0, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionFailed() }
        return target
    }

    static func attachment(from url: URL, completion: @escaping @Sendable (UNNotificationAttachment?) -> Void) {
        session.downloadTask(with: url) { location, response, _ in
            guard let location, let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let type = http.mimeType.flatMap({ UTType(mimeType: $0) }), type.conforms(to: .image)
            else { return completion(nil) }
            // 下载的临时文件在回调返回后就会被删：先挪走，扩展名让系统认出图片格式
            let file = FileManager.default.temporaryDirectory
                .appending(path: "\(UUID().uuidString).\(type.preferredFilenameExtension ?? "jpg")")
            do {
                try FileManager.default.moveItem(at: location, to: file)
                // 通知附件只认 JPEG / PNG / GIF：服务器的图片缓存给的是 WebP，转成 JPEG
                let (url, finalType) = attachable.contains(type) ? (file, type) : (try jpeg(from: file), UTType.jpeg)
                let attachment = try UNNotificationAttachment(
                    identifier: "image", url: url, options: [UNNotificationAttachmentOptionsTypeHintKey: finalType.identifier])
                completion(attachment)
            } catch {
                completion(nil)
            }
        }.resume()
    }
}
