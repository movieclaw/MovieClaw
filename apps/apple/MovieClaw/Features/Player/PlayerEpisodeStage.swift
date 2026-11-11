import SwiftUI

/// 选集面板打开时，画面与面板各占哪里。
///
/// 做法是「画面让位」：面板不盖在画面上，画面缩到一边——横屏缩到左侧成一张圆角卡片、下面写这一集的集名与简介，
/// 面板靠右；竖屏画面挪到顶上，面板接在它下面。画面用缩放与位移挪过去（不改引擎视图的尺寸，引擎不用重新排版），
/// 所以这里算的是「把全屏容器里的画面矩形，变到目标矩形」要的缩放与位移。
///
/// 坐标都在整屏容器里（含安全区，原点在屏幕左上角）。
nonisolated struct EpisodeStageLayout: Equatable, Sendable {
    /// 画面层整体的缩放（锚点左上角）与缩放后的位移
    var scale: CGFloat
    var offset: CGSize
    /// 让位后的画面矩形
    var video: CGRect
    /// 面板矩形
    var drawer: CGRect
    /// 画面下方写集名与简介的位置（只有横屏有）；放不下为 nil
    var caption: CGRect?
    /// 画面挪开了。没挪 = 面板直接浮在画面上：竖屏开着「填满」时画面本来就占满整屏，没处可让
    var yields: Bool

    /// 画面卡片与面板的圆角（屏幕上的点）
    static let videoRadius: CGFloat = 18
    static let drawerRadius: CGFloat = 36
    /// 面板离屏幕边缘
    static let margin: CGFloat = 8
    /// 画面卡片与面板之间
    static let gap: CGFloat = 16
    /// 集名一行 + 简介两行
    static let captionHeight: CGFloat = 62
    static let captionGap: CGFloat = 12

    /// 面板离折痕
    static let creaseGap: CGFloat = 12

    /// - Parameters:
    ///   - picture: 没打开面板时画面在容器里的矩形（适应模式是按片子宽高比居中的那一块，填满 / 拉伸是整个容器）
    ///   - islandTrailing: 横屏时灵动岛在右边（手机朝另一侧横放）：面板要让开它，画面可以更贴左。
    ///     iPhone 横屏左右安全区一样宽，看不出岛在哪边，只能靠界面方向猜；左右不一样宽（iPhone Duo 的竖排系统栏）就照安全区排
    ///   - crease: iPhone Duo 半折时的折痕（整屏容器坐标，见 `PlayerFold.crease`）。竖向（书本）按折痕分页：
    ///     左页画面与集名简介、右页面板；横向（桌面）画面不动，面板占满折痕以下
    static func resolve(container: CGSize, safeArea: EdgeInsets, picture: CGRect, islandTrailing: Bool, crease: CGRect? = nil) -> EpisodeStageLayout {
        let width = container.width, height = container.height
        let aspect = picture.width > 0 && picture.height > 0 ? picture.width / picture.height : 16.0 / 9
        var video = picture
        let drawer: CGRect
        var caption: CGRect?
        var yields = true

        // 横屏两侧各让多少：左右安全区不一样宽时照安全区，一样宽时按灵动岛在哪边
        let asymmetric = abs(safeArea.leading - safeArea.trailing) > 1
        let trailing = asymmetric || islandTrailing ? max(margin, safeArea.trailing) : margin
        let leading = asymmetric ? safeArea.leading + 16 : (islandTrailing ? 20 : safeArea.leading + 16)

        if let crease, crease.height > crease.width {
            // 书本半折：右页整页是面板，左页放画面卡片
            let top = max(margin, safeArea.top)
            let drawerX = crease.maxX + creaseGap
            drawer = CGRect(x: drawerX, y: top, width: width - trailing - drawerX, height: height - margin - top)
            (video, caption) = card(from: leading, to: crease.minX - 16, height: height, safeArea: safeArea, aspect: aspect)
        } else if let crease {
            // 桌面模式：画面本来就在折痕以上，不动；面板占满折痕以下
            let top = crease.maxY + margin
            let left = max(margin, safeArea.leading)
            drawer = CGRect(x: left, y: top, width: width - left - max(margin, safeArea.trailing), height: height - margin - top)
            yields = false
        } else if width > height {
            let drawerWidth = min(380, max(300, (width * 0.365).rounded()))
            let top = max(margin, safeArea.top)
            drawer = CGRect(x: width - trailing - drawerWidth, y: top, width: drawerWidth, height: height - margin - top)
            (video, caption) = card(from: leading, to: drawer.minX - gap, height: height, safeArea: safeArea, aspect: aspect)
        } else {
            // 左右让开竖排的系统栏、灵动岛（iPhone Duo 外屏在右，分屏时可能在左）；普通 iPhone 竖屏两边都是 0
            let left = max(margin, safeArea.leading), right = width - max(margin, safeArea.trailing)
            let drawerWidth = min(right - left, 560)
            let drawerTop: CGFloat
            if picture.height < height * 0.6 {
                // 画面原样挪到顶上（不缩），面板接在下面
                video = CGRect(x: picture.minX, y: safeArea.top + 4, width: picture.width, height: picture.height)
                drawerTop = video.maxY + 12
            } else {
                drawerTop = (height * 0.45).rounded()
                yields = false
            }
            drawer = CGRect(x: left + (right - left - drawerWidth) / 2, y: drawerTop, width: drawerWidth, height: height - margin - drawerTop)
        }

        let scale = picture.width > 0 ? video.width / picture.width : 1
        return EpisodeStageLayout(
            scale: scale,
            offset: CGSize(width: video.minX - picture.minX * scale, height: video.minY - picture.minY * scale),
            video: video, drawer: drawer, caption: caption, yields: yields
        )
    }

    /// 横向一栏里的画面卡片与下面的集名简介：先按「画面 + 集名简介」排，太矮（分屏的小窗）就不要集名简介、全给画面
    private static func card(from minX: CGFloat, to maxX: CGFloat, height: CGFloat, safeArea: EdgeInsets, aspect: CGFloat) -> (CGRect, CGRect?) {
        let available = max(0, maxX - minX)
        let top = max(20, safeArea.top + 12)
        let bottom = height - max(12, safeArea.bottom + 8)
        var budget = bottom - top - captionGap - captionHeight
        let showsCaption = budget >= 120
        if !showsCaption { budget = bottom - top }
        var size = CGSize(width: available, height: available / aspect)
        if size.height > budget { size = CGSize(width: budget * aspect, height: budget) }
        let block = size.height + (showsCaption ? captionGap + captionHeight : 0)
        let video = CGRect(x: minX + (available - size.width) / 2, y: top + (bottom - top - block) / 2,
                           width: size.width, height: size.height)
        let caption = showsCaption ? CGRect(x: video.minX, y: video.maxY + captionGap, width: video.width, height: captionHeight) : nil
        return (video, caption)
    }
}
