import CoreImage.CIFilterBuiltins
import SwiftUI

/// 扫码登录（同 Apple TV 版 `TVPairingLogin`，docs/design/tvos-app.md §5.1）：Mac 上显示二维码与配对码（MCLW-XXXX），
/// 人用手机相机扫码打开网页批准页、或在 iPhone App「设置 → 设备」里输入配对码批准，谁批准这台 Mac 就登录成谁。
/// 适合手边没有密码、但手机上已登录的时候；服务端从 v0.31.0 起认 `macos` 这种配对设备。
///
/// 协议同命令行与转码器（docs/design/device-auth.md §2）：`authorize` 拿到配对码与只有本机知道的 device_code，
/// 按服务端给的间隔轮询 `token`——202 继续等、429 退避、批准后拿到令牌（只交付这一次）、拒绝或过期就停下、
/// 让人重新发起（不静默重试）。配对码 5 分钟有效，过期后点「换一个码」。
/// 卡片切走（改回账号密码、关掉 sheet）时轮询随视图的 task 一起取消。
struct MacPairingLogin: View {
    let server: ServerAddress
    /// 登录成功之后（添加账号的 sheet 用它关掉自己）
    var onSignedIn: (() -> Void)?

    enum Status: Equatable {
        case requesting
        case waiting
        case signingIn
        case failed(String)
    }

    @Environment(AppModel.self) private var model
    @State private var challenge: API.DeviceAuthorizeView?
    @State private var status: Status = .requesting
    /// 加一就重新发起一次（「换一个码」）
    @State private var attempt = 0

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            qrCode
            VStack(alignment: .leading, spacing: 10) {
                Text("配对码")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                Text(challenge?.userCode ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mac-pairing-code")
                if let challenge {
                    // 同 Netflix 的「访问 netflix.com/tv8」：批准页地址直接写出来，不扫码也找得到
                    VStack(alignment: .leading, spacing: 2) {
                        Text("或在已登录的浏览器里打开")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                        Text(Self.displayAddress(challenge.verificationUri))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("mac-pairing-address")
                    }
                }
                Spacer(minLength: 0)
                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.qrSide)
        .task(id: attempt) { await run() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac-pairing")
    }

    private static let qrSide: CGFloat = 164

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .requesting:
            progress("正在向服务器申请配对码…")
        case .waiting:
            progress("等待在手机上批准…（5 分钟内有效）")
        case .signingIn:
            progress("已批准，正在登录…")
        case let .failed(message):
            VStack(alignment: .leading, spacing: 6) {
                MacWelcomeError(message: message)
                    .accessibilityIdentifier("mac-pairing-error")
                Button("换一个码") { attempt += 1 }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("mac-pairing-retry")
            }
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.textMuted)
    }

    private var qrCode: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.white)
            if let image = challenge.flatMap({ Self.qrImage($0.verificationUriComplete) }) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .padding(12)
            } else if case .failed = status {
                Image(systemName: "qrcode")
                    .font(.system(size: 48))
                    .foregroundStyle(.black.opacity(0.2))
            } else {
                ProgressView().controlSize(.small).tint(.black)
            }
        }
        .frame(width: Self.qrSide, height: Self.qrSide)
        .opacity(status == .requesting || isFailed ? 0.5 : 1)
        .accessibilityHidden(true)
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
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
            // 老服务器不认 macos 这种配对（或没有配对接口）：只能用账号密码
            status = .failed("这台服务器还不支持 Mac 扫码登录：请先在网页「设置 → 更新与维护」里把服务器升级到最新版，或改用账号密码登录。")
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
                status = .failed("配对码已过期，请换一个码重新扫。")
                return
            }
            do {
                guard let granted = try await api.authDeviceToken(body: .init(deviceCode: started.deviceCode)) else { continue }
                status = .signingIn
                try await model.signIn(to: server, pairedToken: granted.token)
                onSignedIn?()
                return
            } catch let error as APIError where error.status == 429 {
                // 轮询过快：退避，不重置配对
                interval += 2
            } catch let error as APIError where error.status == 400 {
                if case let .http(_, _, code) = error, code == "AUTHORIZATION_DENIED" {
                    status = .failed("在手机上点了拒绝。要登录的话请换一个码重新扫。")
                } else {
                    status = .failed("配对码已过期，请换一个码重新扫。")
                }
                return
            } catch {
                // 网络抖动：下一轮接着等
            }
        }
    }

    /// 批准页地址给人看的写法：去掉 `http://`、末尾斜杠（「192.168.1.10:3000/activate」）
    static func displayAddress(_ uri: String) -> String {
        var text = uri
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text.removeFirst(scheme.count)
        }
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// 二维码：内容是带码的批准页地址（手机扫了直接打开、批准页预填好这个码）
    private static func qrImage(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
