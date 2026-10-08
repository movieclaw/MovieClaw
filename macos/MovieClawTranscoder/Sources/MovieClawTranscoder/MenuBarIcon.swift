import AppKit

/// 菜单栏图标：转码器三角循环标志（``BrandMark``）的单色剪影。
///
/// 菜单栏只认模板图（只用 alpha、由系统着色），所以不画渐变，只填满字形；字形用细笔画版，
/// 18pt 画布内字形约 15pt 高、线宽 1.7pt，保留菜单栏源稿的边距。
/// 用代码画而不是打包图片资源：任意倍率都清晰，也省掉一套 asset catalog 与
/// bundle 查找的失败模式（`swift run` 不在 .app 里时尤其）。
enum MenuBarIcon {
    /// 18pt 图片画布，三角循环轮廓和状态角标保持紧凑。
    private static let side: CGFloat = 18

    /// 右下角的状态角标。不点开面板也能看出 Worker 在干什么。
    enum Badge: Equatable {
        case none
        /// 在转码：实心圆点。
        case busy
        /// 断线重连或出错：圆里挖一个感叹号。
        case attention
    }

    /// 生成模板图。模板图只用 alpha，由系统按浅色/深色菜单栏和高亮态自动着色，
    /// 这是菜单栏图标唯一正确的形态——写死颜色的图在另一种外观下会看不见。
    /// 角标因此也只能靠形状区分（实心点 / 感叹号），不能靠颜色。
    static func statusItemImage(badge: Badge = .none) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            draw(in: rect)
            drawBadge(badge, in: rect)
            return true
        }
        image.isTemplate = true
        switch badge {
        case .none: image.accessibilityDescription = "MovieClaw 转码器"
        case .busy: image.accessibilityDescription = "MovieClaw 转码器：转码中"
        case .attention: image.accessibilityDescription = "MovieClaw 转码器：需要注意"
        }
        return image
    }

    /// 角标压在标志右下角：先挖掉一圈（与图标之间留出缝），再画角标本身，
    /// 否则 18pt 下角标会和循环轮廓粘成一团。
    private static func drawBadge(_ badge: Badge, in rect: NSRect) {
        guard badge != .none, let context = NSGraphicsContext.current else { return }
        let radius: CGFloat = 3.6
        let center = NSPoint(x: rect.maxX - radius - 0.2, y: rect.minY + radius + 0.2)
        let dot = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSBezierPath(ovalIn: dot.insetBy(dx: -1.4, dy: -1.4)).fill()
        context.compositingOperation = .sourceOver
        NSColor.black.setFill()
        NSBezierPath(ovalIn: dot).fill()
        if badge == .attention {
            // 感叹号：竖条 + 圆点，挖空
            context.compositingOperation = .clear
            let width: CGFloat = 1.3
            NSBezierPath(
                roundedRect: NSRect(x: center.x - width / 2, y: center.y - 0.6, width: width, height: 2.9),
                xRadius: width / 2, yRadius: width / 2
            ).fill()
            NSBezierPath(ovalIn: NSRect(x: center.x - width / 2, y: center.y - 2.4, width: width, height: width)).fill()
        }
        context.restoreGraphicsState()
    }

    private static func draw(in rect: NSRect) {
        BrandMark.draw(in: rect, template: true)
    }
}
