import CoreImage.CIFilterBuiltins
import SwiftUI

/// 扫码登录（docs/design/tvos-app.md §5.1，Apple TV 的默认登录方式）：电视上显示配对码与二维码，
/// 人用手机扫码打开网页批准页、或在 iPhone App「设置 → 设备」里输入配对码批准，谁批准电视就登录成谁。
///
/// 协议同命令行与转码器（docs/design/device-auth.md §2）：`authorize` 拿到配对码与只有本机知道的 device_code，
/// 按服务端给的间隔轮询 `token`——202 继续等、429 退避、批准后拿到令牌（只交付这一次）、拒绝或过期就停下、
/// 让人重新发起（不静默重试）。配对码 5 分钟有效，过期后按一下「换一个码」。
struct TVPairingLogin: View {
    let server: ServerAddress
    let onUsePassword: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(TVProfileGate.self) private var gate
    @State private var challenge: API.DeviceAuthorizeView?
    @State private var status: Status = .requesting
    /// 加一就重新发起一次（「换一个码」）
    @State private var attempt = 0

    enum Status: Equatable {
        case requesting
        case waiting
        case signingIn
        case failed(String)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            VStack(alignment: .leading, spacing: 30) {
                Text("用手机扫码登录")
                    .font(.welcomeSerif(size: 52))
                Text("用手机相机扫右边的二维码，在打开的网页上批准。不方便扫码的话，在任何已登录的电脑或手机浏览器里打开下面的地址，输入配对码。谁批准，这台 Apple TV 就登录成谁。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let challenge {
                    // 同 Netflix 的「访问 netflix.com/tv8」：批准页地址直接写在屏幕上，不扫码也找得到
                    Text(Self.displayAddress(challenge.verificationUri))
                        .font(.title3.weight(.medium))
                        .accessibilityIdentifier("tv-pairing-address")
                    Text(challenge.userCode)
                        .font(.system(size: 72, weight: .semibold, design: .monospaced))
                        .tracking(6)
                        .accessibilityIdentifier("tv-pairing-code")
                }
                statusLine
                HStack(spacing: 24) {
                    if case .failed = status {
                        Button("换一个码") { attempt += 1 }
                            .accessibilityIdentifier("tv-pairing-retry")
                    }
                    Button("改用账号密码登录", action: onUsePassword)
                        .accessibilityIdentifier("tv-pairing-use-password")
                }
                .padding(.top, 10)
            }
            .frame(width: 820, alignment: .leading)
            qrCode
        }
        .padding(60)
        .glassEffect(.regular, in: .rect(cornerRadius: 48))
        .focusSection()
        .task(id: attempt) { await run() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-pairing")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .requesting:
            HStack(spacing: 16) { ProgressView(); Text("正在向服务器申请配对码…").foregroundStyle(.secondary) }
        case .waiting:
            HStack(spacing: 16) { ProgressView(); Text("等待批准…（配对码 5 分钟内有效）").foregroundStyle(.secondary) }
        case .signingIn:
            HStack(spacing: 16) { ProgressView(); Text("已批准，正在登录…").foregroundStyle(.secondary) }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
                .accessibilityIdentifier("tv-pairing-error")
        }
    }

    private var qrCode: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(.white)
            if let image = challenge.flatMap({ Self.qrImage($0.verificationUriComplete) }) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .padding(28)
            } else {
                ProgressView().tint(.black)
            }
        }
        .frame(width: 440, height: 440)
        .accessibilityHidden(true)
    }

    /// 发起 → 轮询，直到批准（登录）、被拒、过期或出错
    private func run() async {
        status = .requesting
        challenge = nil
        let api = APIClient(server: server)
        let started: API.DeviceAuthorizeView
        do {
            started = try await api.authDeviceAuthorize(body: .init(
                clientType: ClientPlatform.kind, clientName: DeviceInfo.name,
                installationId: InstallationID.value, platform: DeviceInfo.platform, clientVersion: DeviceInfo.appVersion
            ))
        } catch let error as APIError where error.status == 400 || error.status == 404 || error.status == 405 {
            // 老服务器不认 tvos 这种配对（或没有配对接口）：只能用账号密码
            status = .failed("这台服务器还不支持扫码登录，请先把服务器升级到最新版，或改用账号密码登录")
            return
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        challenge = started
        status = .waiting
        var interval = max(1, started.interval)
        let deadline = Date.now.addingTimeInterval(TimeInterval(started.expiresIn))
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            if Date.now > deadline {
                status = .failed("配对码已过期，请换一个码重新扫")
                return
            }
            do {
                guard let granted = try await api.authDeviceToken(body: .init(deviceCode: started.deviceCode)) else { continue }
                status = .signingIn
                try await model.signIn(to: server, pairedToken: granted.token)
                gate.pickedProfile()
                return
            } catch let error as APIError where error.status == 429 {
                // 轮询过快：退避，不重置配对
                interval += 2
            } catch let error as APIError where error.status == 400 {
                if case let .http(_, _, code) = error, code == "AUTHORIZATION_DENIED" {
                    status = .failed("在手机上点了拒绝。要登录的话请换一个码重新扫")
                } else {
                    status = .failed("配对码已过期，请换一个码重新扫")
                }
                return
            } catch {
                // 网络抖动：下一轮接着等
            }
        }
    }

    /// 二维码：内容是带码的批准页地址（手机扫了直接打开、批准页预填好这个码）
    /// 批准页地址给人看的写法：去掉 `http://`、末尾斜杠（「192.168.1.10:3000/activate」）
    static func displayAddress(_ uri: String) -> String {
        var text = uri
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    private static func qrImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
