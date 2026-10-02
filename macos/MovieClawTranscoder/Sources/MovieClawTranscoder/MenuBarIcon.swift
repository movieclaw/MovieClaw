import AppKit

/// 菜单栏图标：品牌标志（``BrandMark``，与网页 logo 同一个极光播放三角）的单色剪影。
///
/// 菜单栏只认模板图（只用 alpha、由系统着色），所以不画渐变，只填满字形；字形用细笔画版，
/// 并收在 16pt 的格子里——与 SF Symbols 及常见菜单栏图标（约 15～16pt 高、1.5～2pt 线宽）同一视觉分量。
/// 用代码画而不是打包图片资源：任意倍率都清晰，也省掉一套 asset catalog 与
/// bundle 查找的失败模式（`swift run` 不在 .app 里时尤其）。
enum MenuBarIcon {
    /// 菜单栏可用高度约 22pt。图片画布 18pt（右下角标要用这块地方），字形本身收在中间 16pt 里，
    /// 画满 18pt 时比旁边的图标显大一号（实测其他菜单栏图标多为 15～16pt 高）。
    private static let side: CGFloat = 18
    private static let glyphSide: CGFloat = 16

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
    /// 否则 18pt 下角标会和叶子粘成一团。
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
        let inset = (side - glyphSide) / 2
        BrandMark.draw(in: rect.insetBy(dx: inset, dy: inset), template: true)
    }
}
