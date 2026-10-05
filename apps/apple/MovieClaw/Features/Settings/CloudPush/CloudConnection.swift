import SwiftUI

/// MovieClaw Cloud 的连接状态与动作（docs/design/cloud-push.md §7.1）：「MovieClaw Cloud」页与「通知」页的「开启手机通知」共用。
///
/// 连接（§2.2）：实例去云端要配对码，App 在系统网页框里打开官网的批准页，管理员登录官网、核对配对码、点「批准」。
/// 批准结果由实例自己轮询云端拿到，App 只每 2 秒问一次实例（网页框关掉后也照样问），变成「已连接」就收起网页框。
/// App 不碰任何云端凭证，官网的登录也留在网页框里。每个动作都返回最新的连接状态，界面拿它整页重画。
@Observable
final class CloudConnection {
    private(set) var status: Loadable<API.CloudStatusView> = .loading
    /// 在网页框里打开的官网批准页
    var approvalPage: WebLink?

    @ObservationIgnored private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    var value: API.CloudStatusView? { status.value }
    var isConnected: Bool { value?.state == "connected" }

    /// 进行中的配对（还没批准）：要轮询
    var pendingPairing: API.CloudPairingView? {
        guard let value, value.state != "connected", let pairing = value.pairing, pairing.status == "pending" else { return nil }
        return pairing
    }

    /// 没成的配对（被拒绝、过期、出错）：显示原因，给「重新获取配对码」
    var endedPairing: API.CloudPairingView? {
        guard let value, value.state != "connected", let pairing = value.pairing, pairing.status != "pending" else { return nil }
        return pairing
    }

    func load() async {
        do {
            apply(try await api.cloudStatus())
        } catch is CancellationError {
        } catch {
            if status.value == nil { status = .failed(error.localizedDescription) }
        }
    }

    /// 开始连接：拿到配对码就在网页框里打开批准页
    func connect(instanceName: String?) async throws {
        let name = instanceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(try await api.cloudPairingStart(body: .init(instanceName: name?.isEmpty == false ? name : nil)))
        openApprovalPage()
    }

    func openApprovalPage() {
        if let pairing = pendingPairing { approvalPage = WebLink(pairing.verificationUriComplete) }
    }

    func cancelPairing() async throws {
        approvalPage = nil
        apply(try await api.cloudPairingCancel())
    }

    func renew() async throws {
        apply(try await api.cloudRenew())
    }

    /// 云端连不上且没带 force 时返回 409 `CLOUD_UNREACHABLE`（见 `APIError.isCloudUnreachable`）
    func disconnect(force: Bool) async throws {
        apply(try await api.cloudDisconnect(body: .init(force: force ? true : nil)))
    }

    func dismiss(_ notice: API.CloudNoticeView) async throws {
        apply(try await api.cloudNoticesDismiss(noticeId: notice.id))
    }

    /// 统计开关：乐观更新，失败回滚
    func setReportStats(_ value: Bool) async throws {
        guard var next = status.value else { return }
        let previous = next
        next.reportStats = value
        status = .loaded(next)
        do {
            apply(try await api.cloudSettingsSet(body: .init(reportStats: value)))
        } catch {
            status = .loaded(previous)
            throw error
        }
    }

    private func apply(_ value: API.CloudStatusView) {
        status = .loaded(value)
        // 批准了：网页框不用再开着（官网批准页最后也会说「可以回到 App 了」）
        if value.state == "connected" { approvalPage = nil }
    }
}

extension APIError {
    /// 断开时云端连不上（409 `CLOUD_UNREACHABLE`）：要再问一次是否只删本地凭证
    var isCloudUnreachable: Bool {
        if case let .http(_, _, code) = self { return code == "CLOUD_UNREACHABLE" }
        return false
    }
}
