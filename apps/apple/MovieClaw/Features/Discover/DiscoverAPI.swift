import UIKit

/// 发现模块手写的接口（生成器跳过的 multipart 上传、不可达提示）。
nonisolated extension APIClient {
    /// 长边限制到 maxEdge 并编码为 JPEG（质量 0.9）；小图不放大
    static func compressedJPEG(_ data: Data, maxEdge: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.9)
    }
}
