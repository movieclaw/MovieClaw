import SwiftUI

/// 「家里网络 · 192.168.1.10:3300」/「外网 · movie.example.com」：这台服务器现在走的是哪个地址
/// （docs/design/server-addresses.md §1）。只读，不给切换——选哪个由 `ServerRoutes` 自动定。
/// 旧服务器没有地址簿、还没选过时不显示。
struct ServerRouteLabel: View {
    let server: ServerAddress
    var font: Font = .footnote

    var body: some View {
        if let current = ServerRouteStatus.shared.current(for: server), let text = Self.text(current) {
            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("server-route")
        }
    }

    nonisolated static func text(_ current: ServerRoutes.Current) -> String? {
        guard let route = current.route else { return nil }
        let host = ServerAddress(origin: current.origin).hostLabel
        return switch route {
        case .lan: "家里网络 · \(host)"
        case .vpn: "外网（经 VPN）· \(host)"
        case .wan: "外网 · \(host)"
        }
    }
}

/// 让界面跟着换地址刷新：`ServerRoutes` 在任意线程换了地址就发通知，这里记一个版本号，读的视图据此重画
@MainActor
@Observable
final class ServerRouteStatus {
    static let shared = ServerRouteStatus()

    private var revision = 0

    private init() {
        NotificationCenter.default.addObserver(forName: ServerRoutes.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    func current(for server: ServerAddress) -> ServerRoutes.Current? {
        _ = revision
        return ServerRoutes.shared.current(for: server)
    }
}
