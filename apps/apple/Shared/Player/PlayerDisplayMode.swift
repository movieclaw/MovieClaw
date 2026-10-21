import AetherCore

typealias PlayerDisplayMode = VideoDisplayMode

extension VideoDisplayMode {
    var label: String {
        switch self {
        case .fit: "完整显示"
        case .fitWidth: "适应宽度"
        case .fill: "铺满裁切"
        case .stretch: "拉伸铺满"
        }
    }

    var hint: String {
        switch self {
        case .fit: "保持比例，显示完整画面"
        case .fitWidth: "保持比例，左右贴边，可能裁去上下"
        case .fill: "保持比例，填满屏幕，可能裁去边缘"
        case .stretch: "填满屏幕，画面比例会改变"
        }
    }

    var symbol: String {
        switch self {
        case .fit: "rectangle"
        case .fitWidth: "arrow.left.and.right"
        case .fill: "crop"
        case .stretch: "arrow.up.left.and.arrow.down.right"
        }
    }

    var next: Self {
        let modes = Self.allCases
        return modes[(modes.firstIndex(of: self)! + 1) % modes.count]
    }
}
