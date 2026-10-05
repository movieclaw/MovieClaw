import CryptoKit
import Foundation
import UserNotifications

/// 系统通知权限，登记推送时原样上报（`permission`）
nonisolated enum PushPermission: String, Sendable {
    case authorized, provisional, ephemeral, denied
    case notDetermined = "not_determined"

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        case .denied: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }

    /// 「通知」页上的说法
    var label: String {
        switch self {
        case .authorized: "已允许"
        case .provisional: "已允许（静默送达）"
        case .ephemeral: "临时允许"
        case .denied: "已关闭"
        case .notDetermined: "还没有设置"
        }
    }
}

nonisolated extension API.PushRegistrationRequest {
    /// 本期只发提醒类推送（tvOS 以后只报 background，见 docs/design/cloud-push.md §11）
    static let supportedTypes = ["alert"]

    /// 拼一个登录的推送登记（`PUT /push/me/registration`，docs/design/cloud-push.md §7.3）。`token`、`key_id`、`key`
    /// 三个要么都有，要么都没有：用户关掉了通知、或拿不到 APNs 令牌（模拟器、没有推送权限的侧载包）时只报权限，
    /// 不带令牌，也不为它生成密钥。`key` 只在要带令牌时才取（取的时候可能要生成一把新的）。
    /// `clientVersion` 顺带刷新服务端记的 App 版本——登录时记下的版本，升级后不重新登录就一直是旧的
    static func make(permission: PushPermission, apnsToken: String?, topic: String, environment: String,
                     clientVersion: String?, key: () -> PushKeyStore.Key?) -> API.PushRegistrationRequest {
        var body = API.PushRegistrationRequest(topic: topic, environment: environment, types: supportedTypes, permission: permission.rawValue,
                                               clientVersion: clientVersion)
        if let apnsToken, permission != .denied, let key = key() {
            body.token = apnsToken
            body.keyId = key.keyID
            body.key = key.key.base64URL
        }
        return body
    }
}

nonisolated extension PushLogin {
    init(server: ServerAddress, username: String) {
        self.init(origin: server.origin.absoluteString, username: username)
    }
}

extension PushLoginInfo {
    var server: ServerAddress? { URL(string: origin).map(ServerAddress.init(origin:)) }
}
