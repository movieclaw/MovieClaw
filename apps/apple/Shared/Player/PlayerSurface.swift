import SwiftUI

// iPhone 与 Apple TV 的播放器共用的两块：引擎画面的宿主、进度条缩略图。
// 其余与系统打交道的桥（隔空播放、系统音量、方向锁、屏幕亮度）只有 iPhone 有，留在 MovieClaw/Features/Player。

/// 引擎渲染表面的宿主：把引擎的 UIView 原样塞进 SwiftUI（按引擎实例区分，换引擎即换视图）。
struct EngineSurface: UIViewRepresentable {
    let engineView: UIView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        attach(engineView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if engineView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(engineView, to: container)
        }
    }

    private func attach(_ view: UIView, to container: UIView) {
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
    }
}

/// 进度条缩略图：按需下载雪碧图并裁出目标格子（对应 Web `lib/player/trickplay.ts` 的 tileAt）。
@MainActor
@Observable
final class TrickplayImages {
    private var sheets: [String: UIImage] = [:]
    private var loading: Set<String> = []

    /// 文件时间（毫秒）→ 该显示的格子；雪碧图还没下完返回 nil（并开始下载）
    func tile(_ index: API.TrickplayView?, atMs ms: Int, resolve: (String) -> URL?, session: URLSession) -> UIImage? {
        guard let index, index.ready, index.count > 0, index.intervalMs > 0, index.columns > 0, index.rows > 0, !index.sheets.isEmpty else {
            return nil
        }
        let perSheet = index.columns * index.rows
        // 越界夹到最后一格：拖到片尾时给最后一帧，比忽然没有预览好
        let ordinal = min(max(0, ms) / index.intervalMs, index.count - 1)
        let sheetIndex = min(ordinal / perSheet, index.sheets.count - 1)
        let within = ordinal - sheetIndex * perSheet
        let path = index.sheets[sheetIndex]
        guard let sheet = sheets[path] else {
            load(path, url: resolve(path), session: session)
            return nil
        }
        let scale = sheet.scale
        let rect = CGRect(
            x: CGFloat((within % index.columns) * index.tileWidth) * scale,
            y: CGFloat((within / index.columns) * index.tileHeight) * scale,
            width: CGFloat(index.tileWidth) * scale,
            height: CGFloat(index.tileHeight) * scale
        )
        guard let cropped = sheet.cgImage?.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    private func load(_ path: String, url: URL?, session: URLSession) {
        guard let url, !loading.contains(path) else { return }
        loading.insert(path)
        Task {
            if let (data, _) = try? await session.data(from: url), let image = UIImage(data: data) {
                sheets[path] = image
            }
            loading.remove(path)
        }
    }
}
