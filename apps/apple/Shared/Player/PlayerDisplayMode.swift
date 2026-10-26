import AetherCore
import Foundation

typealias PlayerDisplayMode = VideoDisplayMode

extension VideoDisplayMode {
    var label: String {
        switch self {
        case .fit: String(localized: .playerDisplayFit)
        case .fill: String(localized: .playerDisplayFill)
        case .stretch: String(localized: .playerDisplayStretch)
        }
    }

    var hint: String {
        switch self {
        case .fit: String(localized: .playerDisplayFitHint)
        case .fill: String(localized: .playerDisplayFillHint)
        case .stretch: String(localized: .playerDisplayStretchHint)
        }
    }

    var symbol: String {
        switch self {
        case .fit: "rectangle"
        case .fill: "crop"
        case .stretch: "arrow.up.left.and.arrow.down.right"
        }
    }

    /// 捏合只在完整显示与等比例铺满之间切换，轻微抖动不改变模式。
    func pinched(scale: CGFloat) -> Self {
        if scale > 1.08 { return .fill }
        if scale < 0.92 { return .fit }
        return self
    }
}
