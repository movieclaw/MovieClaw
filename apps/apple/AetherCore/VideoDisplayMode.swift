import Foundation

/// 只改变显示布局，不改源文件、解码尺寸或播放会话。
public enum VideoDisplayMode: String, CaseIterable, Sendable {
    case fit, fill, stretch

    public func rect(in bounds: CGRect, videoSize: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              videoSize.width > 0, videoSize.height > 0,
              videoSize.width.isFinite, videoSize.height.isFinite else { return bounds }
        if self == .stretch { return bounds }
        let sx = bounds.width / videoSize.width
        let sy = bounds.height / videoSize.height
        let scale = self == .fill ? max(sx, sy) : min(sx, sy)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
