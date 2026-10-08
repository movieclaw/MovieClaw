import AppKit

/// 转码器专用的三角循环标志：沿用 MovieClaw 极光色板，以回转箭头区分主程序。
/// App 图标母版和菜单栏源稿见 `docs/brand/transcoder/`。
/// 菜单栏用细笔画模板图；面板和设置页用较粗的彩色矢量标志。
enum BrandMark {
    static let aurora: [NSColor] = [
        NSColor(srgbRed: 0x36 / 255.0, green: 0xE2 / 255.0, blue: 0xBD / 255.0, alpha: 1),
        NSColor(srgbRed: 0x4C / 255.0, green: 0x9D / 255.0, blue: 0xFF / 255.0, alpha: 1),
        NSColor(srgbRed: 0x9A / 255.0, green: 0x6B / 255.0, blue: 0xFF / 255.0, alpha: 1),
        NSColor(srgbRed: 0xFF / 255.0, green: 0x7F / 255.0, blue: 0xCF / 255.0, alpha: 1),
    ]

    /// 与菜单栏 SVG 相同的 18×18 坐标系（y 向下），箭头是循环轮廓的一部分。
    private static let centerline: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 6, y: 2.55))
        path.addCurve(to: CGPoint(x: 2.6, y: 4.6),
                      control1: CGPoint(x: 4.15, y: 1.7), control2: CGPoint(x: 2.6, y: 2.65))
        path.addLine(to: CGPoint(x: 2.6, y: 13.4))
        path.addCurve(to: CGPoint(x: 6, y: 15.35),
                      control1: CGPoint(x: 2.6, y: 15.45), control2: CGPoint(x: 4.15, y: 16.3))
        path.addLine(to: CGPoint(x: 14.15, y: 10.9))
        path.addCurve(to: CGPoint(x: 14.15, y: 7.15),
                      control1: CGPoint(x: 15.9, y: 9.95), control2: CGPoint(x: 15.9, y: 8.1))
        path.addLine(to: CGPoint(x: 9, y: 4.35))
        path.move(to: CGPoint(x: 9.4, y: 6.7))
        path.addLine(to: CGPoint(x: 9, y: 4.35))
        path.addLine(to: CGPoint(x: 11.6, y: 3.9))
        return path
    }()

    static func draw(in rect: NSRect, template: Bool = false) {
        guard let context = NSGraphicsContext.current else { return }
        let shape = centerline.copy(strokingWithWidth: template ? 1.7 : 2.15,
                                    lineCap: .round, lineJoin: .round, miterLimit: 10)
        // 模板图保留 18pt 源稿的边距；彩色徽标占满目标矩形，沿用原来的图标比例。
        let bounds = template ? CGRect(x: 0, y: 0, width: 18, height: 18) : shape.boundingBoxOfPath
        let scale = min(rect.width, rect.height) / max(bounds.width, bounds.height)
        let origin = CGPoint(x: rect.midX - bounds.width * scale / 2,
                             y: rect.midY - bounds.height * scale / 2)
        let flipped = context.isFlipped
        var transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: flipped ? scale : -scale,
            tx: origin.x - bounds.minX * scale,
            ty: flipped ? origin.y - bounds.minY * scale : origin.y + bounds.maxY * scale
        )
        guard let mapped = shape.copy(using: &transform) else { return }
        let cg = context.cgContext
        cg.saveGState()
        cg.addPath(mapped)
        if template {
            cg.setFillColor(NSColor.black.cgColor)
            cg.fillPath()
        } else {
            cg.clip()
            let locations: [CGFloat] = [0, 0.35, 0.68, 1]
            NSGradient(colors: aurora, atLocations: locations, colorSpace: .sRGB)?
                .draw(in: rect, angle: flipped ? -42 : 42)
        }
        cg.restoreGState()
    }

    /// 面板页眉和设置「关于」页使用的品牌方块。
    static func drawTile(in rect: NSRect, cornerRatio: CGFloat = 0.225) {
        let radius = rect.width * cornerRatio
        let tile = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let gradient = NSGradient(colors: [
            NSColor(srgbRed: 0.05, green: 0.055, blue: 0.075, alpha: 1),
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ])
        gradient?.draw(in: tile, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        NSColor.white.withAlphaComponent(0.10).setStroke()
        tile.lineWidth = max(1, rect.width / 48)
        tile.stroke()
        NSGraphicsContext.restoreGraphicsState()
        draw(in: rect.insetBy(dx: rect.width * 0.18, dy: rect.height * 0.18))
    }
}
