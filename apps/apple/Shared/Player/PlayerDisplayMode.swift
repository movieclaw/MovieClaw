import AetherCore
import Foundation

typealias PlayerDisplayMode = VideoDisplayMode

extension VideoDisplayMode {
    var label: String {
        switch self {
        case .fit: "完整显示"
        case .fill: "铺满裁切"
        case .stretch: "拉伸铺满"
        }
    }

    var hint: String {
        switch self {
        case .fit: "保持比例，显示完整画面"
        case .fill: "保持比例，填满屏幕，可能裁去边缘"
        case .stretch: "填满屏幕，画面比例会改变"
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
