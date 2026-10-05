import Foundation

/// 这份共享代码此刻跑在哪个 App 里：iPhone 版还是 Apple TV 版。
///
/// 服务端靠这几个值区分客户端：登录设备的类型（`login_device.kind`，「我的设备」里显示「iOS App / Apple TV App」）、
/// User-Agent（活动页显示「MovieClaw iOS / Apple TV」）、播放会话与播放记录的 `client`（质量统计按端分组）。
/// 两个 App 编译同一份 `Shared/` 代码，凡是要报「我是谁」的地方一律从这里取，不写死字面量。
nonisolated enum ClientPlatform {
    #if os(tvOS)
    /// 登录设备类型、播放会话与播放记录的 `client`
    static let kind = "tvos"
    /// User-Agent 的产品名
    static let product = "MovieClaw-tvOS"
    /// 系统名（User-Agent 与「我的设备」的平台说明）
    static let osName = "tvOS"
    #else
    static let kind = "ios"
    static let product = "MovieClaw-iOS"
    static let osName = "iOS"
    #endif

    /// 系统版本号：「26.0」「26.0.1」
    static var osVersion: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return os.patchVersion > 0 ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)" : "\(os.majorVersion).\(os.minorVersion)"
    }
}
