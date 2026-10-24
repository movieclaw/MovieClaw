// 生成 DMG 窗口背景（background.png 与 background@2x.png，已提交到仓库；改了这里再跑一次）：
//   swift apps/apple/scripts/dmg/make-background.swift apps/apple/scripts/dmg
// 画布 600×400 点，与 settings.py 的窗口大小、图标位置一一对应：App 在左（150, 190），「应用程序」在右（450, 190），
// 中间一个箭头，下面一句话。Finder 把图标名字画在图标下方，这里不画字。
import AppKit

let size = CGSize(width: 600, height: 400)
let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // 坐标系翻成左上角为原点，和 settings.py 的图标坐标一致
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)

    // 浅色底（常见安装盘的做法），字和箭头用中灰，图标名字由 Finder 画
    let background = NSGradient(colors: [NSColor(srgbRed: 0.975, green: 0.978, blue: 0.985, alpha: 1),
                                         NSColor(srgbRed: 0.918, green: 0.926, blue: 0.941, alpha: 1)])!
    background.draw(in: CGRect(origin: .zero, size: size), angle: 90)

    // 箭头：两个图标之间，细线 + 实心箭头头
    let silver = NSColor(srgbRed: 0.56, green: 0.60, blue: 0.67, alpha: 1)
    silver.setStroke()
    silver.setFill()
    let shaft = NSBezierPath()
    shaft.move(to: CGPoint(x: 236, y: 190))
    shaft.line(to: CGPoint(x: 352, y: 190))
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: 366, y: 190))
    head.line(to: CGPoint(x: 348, y: 179))
    head.line(to: CGPoint(x: 348, y: 201))
    head.close()
    head.fill()

    // 说明：画在图标名字下方，留出 Finder 画名字的位置
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "把 MovieClaw 拖到「应用程序」文件夹完成安装", attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.30, green: 0.33, blue: 0.38, alpha: 1),
        .paragraphStyle: style,
    ])
    // NSAttributedString 按翻转前的坐标画字，单独切回去
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size.height)
    ctx.scaleBy(x: 1, y: -1)
    text.draw(in: CGRect(x: 0, y: size.height - 318 - 20, width: size.width, height: 22))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try render(scale: 1).write(to: out.appendingPathComponent("background.png"))
try render(scale: 2).write(to: out.appendingPathComponent("background@2x.png"))
print("已生成 \(out.path)/background.png、background@2x.png")
