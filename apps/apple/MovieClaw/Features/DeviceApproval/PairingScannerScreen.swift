import AVFoundation
import SwiftUI
import UIKit

/// 扫码批准设备登录的取景页（全屏）：「我的」页右上角的扫码按钮、批准页里的「扫描二维码」都打开它。
///
/// 只认 MovieClaw 的登录二维码（`PairingQRCode`）：扫到就回调并由调用方关掉本页、进入批准页；
/// 扫到别的二维码只提示一句、继续扫，不把人带去任何地方。批准本身不在这里做——扫到 ≠ 同意，
/// 人必须在批准页上看过审批卡（设备名、类型、将获得的权限）再按批准，这是防钓鱼的那道闸。
///
/// 相机不可用时（拒绝了权限、设备没有相机）给出去设置的入口，或改为手输配对码。
struct PairingScannerScreen: View {
    let onScanned: (PairingQRCode.Scanned) -> Void
    /// 改为手输配对码（相机用不了、或二维码扫不出来时）
    let onManualEntry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var access: CameraAccess = .checking
    @State private var hint: String?
    @State private var handled = false
    /// 上一次提示过的非登录二维码：相机每秒回调十几次，同一张码只提示一次
    @State private var lastRejected: String?

    enum CameraAccess { case checking, granted, denied, unavailable }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch access {
            case .granted:
                QRCameraView(onCode: handle).ignoresSafeArea()
                Viewfinder()
            case .denied:
                unavailableMessage(
                    title: "需要相机权限",
                    message: "扫码登录要用相机读取电视或终端上的二维码。请在系统设置里允许 MovieClaw 使用相机，或者改为手动输入配对码。",
                    showsSettings: true
                )
            case .unavailable:
                unavailableMessage(title: "相机不可用", message: "这台设备上没有可用的相机，请改为手动输入配对码。", showsSettings: false)
            case .checking:
                ProgressView().tint(.white)
            }
            overlay
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await prepare() }
    }

    private var overlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("关闭")
                .accessibilityIdentifier("scanner-close")
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            Spacer()
            VStack(spacing: 14) {
                if let hint {
                    Text(hint)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .transition(.opacity)
                        .accessibilityIdentifier("scanner-hint")
                }
                Text("对准电视或终端上的登录二维码")
                    .font(.headline)
                    .foregroundStyle(.white)
                Button("手动输入配对码", action: onManualEntry)
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("scanner-manual")
            }
            .padding(.bottom, 40)
        }
        .animation(.easeOut(duration: 0.2), value: hint)
    }

    private func unavailableMessage(title: String, message: String, showsSettings: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if showsSettings {
                Button("去设置开启") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal, 40)
    }

    private func prepare() async {
        #if DEBUG
        // 模拟器没有相机：UI 测试用 -mcScanResult 注入「扫到的内容」，走与真相机同一条处理路径
        if let injected = UserDefaults.standard.string(forKey: "mcScanResult") {
            access = .unavailable
            try? await Task.sleep(for: .milliseconds(600))
            handle(injected)
            return
        }
        #endif
        guard AVCaptureDevice.default(for: .video) != nil else { access = .unavailable; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .granted
        case .notDetermined: access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: access = .denied
        }
    }

    private func handle(_ text: String) {
        guard !handled else { return }
        guard let scanned = PairingQRCode.parse(text) else {
            if text != lastRejected {
                lastRejected = text
                hint = "这不是 MovieClaw 的登录二维码"
            }
            return
        }
        handled = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScanned(scanned)
    }
}

/// 取景框：中间留一个圆角方框，四周压暗，告诉人把码放进框里
private struct Viewfinder: View {
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * 0.7, 300)
            let frame = CGRect(x: (proxy.size.width - side) / 2, y: (proxy.size.height - side) / 2 - 40, width: side, height: side)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRoundedRect(in: frame, cornerSize: CGSize(width: 28, height: 28))
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: side, height: side)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// 相机取景 + 二维码识别（AVFoundation）。识别结果在主线程回调，原样交给扫码页判断是不是登录二维码。
private struct QRCameraView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.camera.session
        context.coordinator.camera.configure(delegate: context.coordinator)
        context.coordinator.camera.start()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onCode = onCode
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.camera.stop()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: (String) -> Void
        let camera = QRCameraSession()

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        // 委托队列设的是主队列（见 QRCameraSession.configure），这里可以直接回到主线程隔离
        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard let text = metadataObjects.lazy.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            MainActor.assumeIsolated { onCode(text) }
        }
    }
}

/// 相机会话：startRunning / stopRunning 会阻塞几百毫秒，放在自己的串行队列上，不卡界面
nonisolated private final class QRCameraSession: @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    private let queue = DispatchQueue(label: "movieclaw.pairing-scanner")

    func configure(delegate: AVCaptureMetadataOutputObjectsDelegate) {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output)
        else { return }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        if output.availableMetadataObjectTypes.contains(.qr) { output.metadataObjectTypes = [.qr] }
        session.commitConfiguration()
    }

    func start() {
        queue.async { [self] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }
}
