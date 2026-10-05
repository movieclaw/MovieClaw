import SwiftUI

/// 欢迎页的整屏背景：写实、克制的深空。一片真实感的星空，画面下方一道行星的地平线，偶尔划过一颗流星。
///
/// 写实靠的是「少」和「按物理来」，彩色星云光团、卡通天体、星星闪烁一概不画：
/// - 太空里没有闪烁（那是大气抖动造成的），星光是稳定的；
/// - 流星（`MeteorShower`）隔十几秒才划过一颗、一秒左右就熄灭，细而淡，像真的偶然看见；
/// - 星星亮度按星等分布：绝大多数暗到几乎看不见，只有极少数亮星，亮星带一圈很淡的光晕；
///   颜色按恒星色温只带一点点蓝白或暖黄，不是彩色圆点；
/// - 银河不是一团光斑，而是成千上万颗暗星挤出的星带，中间被尘埃带切开（见 `StarfieldRenderer`）。
///
/// 其余的动都很慢：整片星空绕屏幕中心缓缓转动（约 40 分钟一圈，像飞船在轨道上慢慢翻转）；
/// 片头时地平线的大气辉光像轨道日出一样慢慢亮起。系统开启「减弱动态效果」时星空不转、也没有流星。
struct CosmosBackdrop: View {
    /// 片头：星空从黑暗中浮现、地平线随后亮起
    let lit: Bool
    /// 表单展开时整体压暗一些，把视线让给输入框
    let dimmed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    /// 星空位图：进入页面后在后台渲染（约 0.1~0.5 秒），好了再淡入
    @State private var starfield: CGImage?

    /// 转一圈的秒数
    private static let revolution: TimeInterval = 2400
    /// UI 自动化测试时星空不转：无限动画让 App 永远不「空闲」，XCUITest 每步操作都要干等空闲超时
    private static let spins = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // 星空位图边长取屏幕对角线：旋转到任何角度都铺得满四角
            let side = (size.width * size.width + size.height * size.height).squareRoot().rounded(.up)
            // 位图最多按 2 倍渲染：3 倍屏上一颗星会柔一点点，正好像真实星点的弥散；省下一半多内存
            let scale = min(displayScale, 2)
            ZStack {
                if let starfield {
                    RotatingStarfield(image: starfield, scale: scale, revolution: reduceMotion || !Self.spins ? nil : Self.revolution)
                        .transition(.opacity.animation(.easeIn(duration: 2)))
                }

                // 画在星空之上、行星之下：划到地平线以下的部分被行星挡住
                MeteorShower()

                PlanetHorizon(sunrise: lit)
            }
            .opacity(lit ? 1 : 0)
            .task(id: side) {
                guard starfield == nil else { return }
                let image = await Task.detached(priority: .userInitiated) {
                    StarfieldRenderer.render(side: side, scale: scale)
                }.value
                withAnimation(.easeIn(duration: 2)) { starfield = image }
            }
        }
        .overlay(Color.black.opacity(dimmed ? 0.25 : 0).allowsHitTesting(false))
        .background(Color.black)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 星空位图 + 它的缓慢转动，交给 Core Animation：图层上挂一个无限旋转动画，由渲染服务逐帧插值，
/// App 主线程每帧零开销，位图也只上传一次。
///
/// 不用 SwiftUI 的 `rotationEffect` + `repeatForever`：那是 SwiftUI 在主线程逐帧推进动画，
/// 实测首页因此多吃约 45% 的 CPU（模拟器上从 26% 涨到 71%）。
#if canImport(UIKit)
private struct RotatingStarfield: UIViewRepresentable {
    let image: CGImage
    let scale: CGFloat
    /// 转一圈的秒数；nil = 不转（减弱动态效果、UI 自动化测试）
    let revolution: TimeInterval?

    func makeUIView(context: Context) -> StarfieldView {
        StarfieldView(image: image, scale: scale, revolution: revolution)
    }

    func updateUIView(_ view: StarfieldView, context: Context) {}
}
#else
private struct RotatingStarfield: NSViewRepresentable {
    let image: CGImage
    let scale: CGFloat
    let revolution: TimeInterval?

    func makeNSView(context: Context) -> StarfieldView {
        StarfieldView(image: image, scale: scale, revolution: revolution)
    }

    func updateNSView(_ view: StarfieldView, context: Context) {}
}
#endif

/// 承载星空图层的 UIView：图层居中摆放（位图边长是屏幕对角线，转到任何角度都铺满四角）
final class StarfieldView: NativeView {
    private let starLayer = CALayer()

    init(image: CGImage, scale: CGFloat, revolution: TimeInterval?) {
        super.init(frame: .zero)
        starLayer.contents = image
        starLayer.contentsScale = scale
        starLayer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        layer.addSublayer(starLayer)
        #else
        wantsLayer = true
        layer?.addSublayer(starLayer)
        #endif
        if let revolution {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = Double.pi * 2
            spin.duration = revolution
            spin.repeatCount = .infinity
            // 切到后台再回来，动画不被系统移除
            spin.isRemovedOnCompletion = false
            starLayer.add(spin, forKey: "spin")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        centerStars()
    }
    #else
    override func layout() {
        super.layout()
        centerStars()
    }

    /// 星空只是背景，不接鼠标
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    private func centerStars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        starLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
}

/// 流星：页面出现后 4～9 秒来第一颗，之后每隔 7～18 秒随机划过一颗，同一时间最多一颗。
///
/// 真实流星的样子：一道很细的亮线，头部最亮、尾迹渐隐，点燃后迅速变亮、烧到后段熄灭，整个过程不到一两秒；
/// 方向斜向下（左下或右下随机），多数暗淡，偶尔有一颗亮的带一点光晕。
///
/// 性能：平时什么都不画；一颗流星在飞的那一秒里，只有它自己的时间线逐帧重算这一小块（一条线段和一个亮点，
/// 见 `MeteorStreak`），星空位图和其余视图都不跟着重算。「减弱动态效果」与 UI 自动化测试时不出现。
private struct MeteorShower: View {
    struct Meteor: Equatable {
        let id: Int
        /// 起点（占屏幕宽高的比例）
        let start: CGPoint
        /// 飞行方向（度；屏幕坐标，0 向右、90 向下）
        let angle: Double
        /// 飞过的距离（占屏宽的比例）
        let travel: CGFloat
        /// 最长时的尾迹长度（点）
        let length: CGFloat
        let duration: Double
        /// 亮度 0~1：多数在 0.5~0.8，偶尔一颗很亮
        let brightness: Double

        static func random(id: Int) -> Meteor {
            let towardRight = Bool.random()
            let bright = Double.random(in: 0 ..< 1) < 0.15
            return Meteor(
                id: id,
                start: CGPoint(
                    x: towardRight ? .random(in: 0.05 ... 0.5) : .random(in: 0.5 ... 0.95),
                    y: .random(in: 0.04 ... 0.38)
                ),
                angle: towardRight ? .random(in: 22 ... 40) : .random(in: 140 ... 158),
                travel: .random(in: 0.28 ... 0.48),
                length: .random(in: 70 ... 140),
                duration: .random(in: 0.7 ... 1.2),
                brightness: bright ? 1 : .random(in: 0.5 ... 0.8)
            )
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var meteor: Meteor?

    /// UI 自动化测试时不放流星：画面里一直有动画，XCUITest 每步都要干等 App 空闲
    private static let enabled = !ProcessInfo.processInfo.arguments.contains("--ui-testing")

    var body: some View {
        GeometryReader { proxy in
            if let meteor {
                MeteorStreak(meteor: meteor, size: proxy.size)
                    .id(meteor.id)
            }
        }
        .allowsHitTesting(false)
        .task {
            guard Self.enabled, !reduceMotion else { return }
            var count = 0
            var wait = Double.random(in: 4 ... 9)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                count += 1
                let next = Meteor.random(id: count)
                meteor = next
                // 飞完就移除，它的时间线随之停掉：两颗之间屏幕上什么都不画
                try? await Task.sleep(for: .seconds(next.duration))
                meteor = nil
                wait = .random(in: 7 ... 18)
            }
        }
    }
}

/// 一颗流星：只在它飞的这一秒里挂一个 `TimelineView`，按「出现后过了多久」算进度，逐帧画出这一小块；
/// 飞完 `MeteorShower` 就把它移除，时间线随之停掉。
///
/// 不用「onAppear 里 withAnimation 推进度 + 自定义 Animatable 修饰器」：工程默认主线程隔离，自定义的
/// Animatable 遵循会被推断成隔离遵循，SwiftUI 运行时认不出来、不做插值，进度从 0 直接跳到 1——
/// 两端亮度都是 0，流星一颗也看不见（实测如此）
private struct MeteorStreak: View {
    let meteor: MeteorShower.Meteor
    let size: CGSize
    @State private var appeared = Date.now

    var body: some View {
        TimelineView(.animation) { context in
            let linear = min(max(context.date.timeIntervalSince(appeared) / meteor.duration, 0), 1)
            // 先慢后快：流星冲进大气层时越烧越快
            MeteorFrame(progress: linear * linear, meteor: meteor, size: size)
        }
    }
}

/// 按飞行进度画出这一帧的流星：一条头亮尾暗的线段 + 头部亮点（亮的那颗再加一圈柔光）
private struct MeteorFrame: View {
    let progress: Double
    let meteor: MeteorShower.Meteor
    let size: CGSize

    var body: some View {
        let radians = meteor.angle * .pi / 180
        let direction = CGVector(dx: cos(radians), dy: sin(radians))
        let distance = meteor.travel * size.width * progress
        let head = CGPoint(x: meteor.start.x * size.width + direction.dx * distance,
                           y: meteor.start.y * size.height + direction.dy * distance)
        // 亮度：点燃后迅速变亮，后段慢慢熄灭；尾迹跟着先拉长再收短
        let glow = sin(.pi * pow(progress, 0.7))
        let tailLength = meteor.length * (0.3 + 0.7 * glow)
        let tail = CGPoint(x: head.x - direction.dx * tailLength, y: head.y - direction.dy * tailLength)
        let alpha = meteor.brightness * glow

        ZStack {
            Path { path in
                path.move(to: tail)
                path.addLine(to: head)
            }
            .stroke(
                LinearGradient(
                    colors: [.white.opacity(0), Color(red: 0.9, green: 0.94, blue: 1).opacity(0.85 * alpha)],
                    startPoint: UnitPoint(x: tail.x / size.width, y: tail.y / size.height),
                    endPoint: UnitPoint(x: head.x / size.width, y: head.y / size.height)
                ),
                style: StrokeStyle(lineWidth: meteor.brightness > 0.9 ? 1.6 : 1.1, lineCap: .round)
            )
            Circle()
                .fill(.white.opacity(alpha))
                .frame(width: 2.2, height: 2.2)
                .position(head)
            if meteor.brightness > 0.9 {
                Circle()
                    .fill(Color(red: 0.85, green: 0.92, blue: 1).opacity(0.35 * alpha))
                    .frame(width: 10, height: 10)
                    .blur(radius: 3)
                    .position(head)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// 画面下方的行星地平线（夜面朝向我们，太阳正要从右侧升起）。
///
/// 一颗半径约 2.4 倍屏宽的巨大球体，只露出顶部一段弧；弧上是一线大气层：
/// 细亮线是大气边缘，外面两层模糊的辉光是大气散射，左侧冷蓝、越往右越亮，近太阳处转暖。
///
/// 用两张屏幕大小的 Canvas 画、只画看得见的部分，而不是 SwiftUI 的整圆 Circle：
/// 整圆直径两千多点，SwiftUI 按整圆尺寸给模糊分配离屏缓冲，3 倍屏上一层就一百多 MB，
/// 实测首页常驻内存上 G、CPU 居高不下。Canvas 的缓冲只有屏幕大小，内容静态只画一次；
/// 日出效果靠大气层那张 Canvas 整体渐显，不重画。
private struct PlanetHorizon: View {
    let sunrise: Bool

    /// 大气层沿弧线的颜色：可见的弧大约是 -102° 到 -78°（正上方是 -90°），颜色铺在 -104° 到 -70° 这 34° 里。
    /// Canvas 的锥形渐变按整圈 0~1 计位置，所以把各色标压缩到 34/360 以内，起点转到 -104°
    private static let rim: Gradient = {
        let span = 34.0 / 360
        return Gradient(stops: [
            .init(color: Color(red: 0.3, green: 0.48, blue: 0.85).opacity(0.2), location: 0),
            .init(color: Color(red: 0.42, green: 0.64, blue: 1).opacity(0.6), location: 0.45 * span),
            .init(color: Color(red: 0.72, green: 0.85, blue: 1), location: 0.8 * span),
            .init(color: Color(red: 1, green: 0.84, blue: 0.64), location: 0.93 * span),
            .init(color: Color(red: 1, green: 0.95, blue: 0.86), location: span),
        ])
    }()

    var body: some View {
        ZStack {
            // 行星夜面：不是纯黑，带一点极暗的蓝，和深空分得开
            Canvas { context, size in
                let planet = Self.planet(in: size, context: &context)
                context.fill(planet.path, with: .color(Color(red: 0.012, green: 0.016, blue: 0.026)))
            }
            // 大气层：辉光 + 边缘亮线 + 太阳那侧的暖光，日出时整体渐显
            Canvas { context, size in
                let planet = Self.planet(in: size, context: &context)
                let shading = GraphicsContext.Shading.conicGradient(Self.rim, center: planet.center, angle: .degrees(-104))
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: 38))
                    glow.opacity = 0.22
                    glow.stroke(planet.path, with: shading, lineWidth: 56)
                }
                context.drawLayer { glow in
                    glow.addFilter(.blur(radius: 7))
                    glow.opacity = 0.45
                    glow.stroke(planet.path, with: shading, lineWidth: 10)
                }
                // 抹掉落在行星本体上的那半边辉光（行星挡住了身后的大气）
                context.blendMode = .destinationOut
                context.fill(planet.path, with: .color(.black))
                context.blendMode = .normal
                context.drawLayer { edge in
                    edge.addFilter(.blur(radius: 0.5))
                    edge.stroke(planet.path, with: shading, lineWidth: 1.2)
                }
                // 可见弧右端：太阳就在它后面，叠一团很淡的暖光
                let dawn = Angle.degrees(-79).radians
                let point = CGPoint(x: planet.center.x + planet.radius * cos(dawn), y: planet.center.y + planet.radius * sin(dawn))
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 110, y: point.y - 110, width: 220, height: 220)),
                    with: .radialGradient(
                        Gradient(colors: [Color(red: 1, green: 0.86, blue: 0.7).opacity(0.16), .clear]),
                        center: point, startRadius: 0, endRadius: 110
                    )
                )
            }
            .opacity(sunrise ? 1 : 0)
            .animation(.easeInOut(duration: 4.5).delay(sunrise ? 1.2 : 0), value: sunrise)
        }
        .allowsHitTesting(false)
    }

    /// 行星的几何，顺带把画布绕屏幕中心转 -4°：地平线微微倾斜，真实的轨道照片很少是水平的
    private static func planet(in size: CGSize, context: inout GraphicsContext) -> (path: Path, center: CGPoint, radius: CGFloat) {
        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: .degrees(-4))
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        let radius = size.width * 2.4
        let center = CGPoint(x: size.width / 2, y: size.height * 0.8 + radius)
        let path = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        return (path, center, radius)
    }
}

/// 把整片星空一次性画进一张位图（后台线程执行）。
///
/// 星空是固定的：随机数用固定种子，每次打开看到的都是同一片天。分三步画：
/// 1. 银河的弥散光：沿星带铺几百团极淡的柔光，亮度由分形噪声调制成一块块星云，再被尘埃带挖暗；
/// 2. 银河的星点：几万颗极暗的小星，同样按噪声与尘埃带取舍——远看就是一条有纹理、有暗缝的光带；
/// 3. 前景恒星：一千多颗，亮度按幂律分布（暗星极多、亮星极少），颜色按色温取，亮星加一圈光晕。
nonisolated enum StarfieldRenderer {
    static func render(side: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int(side * scale)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)

        var rng = SeededRandom(seed: 0x4D6F_7669_6543_6C61) // "MovieCla"
        let band = Band(side: side)
        drawGalacticGlow(context, band: band, rng: &rng)
        drawGalacticStars(context, band: band, rng: &rng)
        drawFieldStars(context, side: side, band: band, rng: &rng)
        return context.makeImage()
    }

    /// 银河星带的几何：一条斜穿画面的直线，星带宽度按高斯分布衰减；一端是更亮的银心方向
    private struct Band {
        let origin: CGPoint
        let along: CGVector
        let normal: CGVector
        /// 星带的半宽（高斯分布的 σ）
        let sigma: Double
        let side: Double

        init(side: CGFloat) {
            self.side = side
            origin = CGPoint(x: side * 0.5, y: side * 0.44)
            let angle = 58.0 * .pi / 180
            along = CGVector(dx: cos(angle), dy: sin(angle))
            normal = CGVector(dx: -sin(angle), dy: cos(angle))
            sigma = side * 0.085
        }

        func point(along t: Double, offset: Double) -> CGPoint {
            CGPoint(x: origin.x + along.dx * t + normal.dx * offset, y: origin.y + along.dy * t + normal.dy * offset)
        }

        /// 某点的银河亮度（0~1）：星带高斯衰减 × 银心方向渐强 × 星云纹理 × 尘埃带
        func density(at p: CGPoint) -> Double {
            let dx = p.x - origin.x, dy = p.y - origin.y
            let across = (dx * normal.dx + dy * normal.dy) / sigma
            let lengthwise = (dx * along.dx + dy * along.dy) / side
            let profile = exp(-across * across)
            let core = 0.45 + 0.55 * exp(-pow((lengthwise + 0.18) / 0.32, 2))
            let clouds = Noise.smoothstep(0.32, 0.78, Noise.fbm(p.x / 95, p.y / 95, seed: 11))
            // 尘埃带：星带中线附近被一条条暗缝切开
            let dust = Noise.smoothstep(0.5, 0.66, Noise.fbm(p.x / 42, p.y / 42, seed: 29)) * exp(-pow(across / 0.55, 2))
            return profile * core * clouds * (1 - 0.85 * dust)
        }
    }

    private static func drawGalacticGlow(_ context: CGContext, band: Band, rng: inout SeededRandom) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for _ in 0 ..< 360 {
            let p = band.point(along: (rng.next() - 0.5) * band.side * 1.5, offset: rng.gaussian() * band.sigma)
            let strength = band.density(at: p)
            guard strength > 0.02 else { continue }
            let radius = 16 + 34 * rng.next()
            let alpha = 0.045 * strength
            let colors = [
                CGColor(colorSpace: space, components: [0.93, 0.92, 0.9, alpha])!,
                CGColor(colorSpace: space, components: [0.93, 0.92, 0.9, 0])!,
            ] as CFArray
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else { continue }
            context.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: radius, options: [])
        }
    }

    private static func drawGalacticStars(_ context: CGContext, band: Band, rng: inout SeededRandom) {
        for _ in 0 ..< 70000 {
            let p = band.point(along: (rng.next() - 0.5) * band.side * 1.5, offset: rng.gaussian() * band.sigma * 1.2)
            guard rng.next() < band.density(at: p) else { continue }
            let alpha = 0.05 + 0.3 * pow(rng.next(), 2)
            let radius = 0.28 + 0.25 * rng.next()
            // 银心附近偏暖，外侧偏冷
            let warm = rng.next() < 0.5
            context.setFillColor(red: warm ? 1 : 0.88, green: warm ? 0.95 : 0.92, blue: warm ? 0.88 : 1, alpha: alpha)
            context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private static func drawFieldStars(_ context: CGContext, side: Double, band: Band, rng: inout SeededRandom) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for index in 0 ..< 1700 {
            // 前 1100 颗均匀撒满全天，后 600 颗沿星带加密（银河方向本来星就多）
            let p = index < 1100
                ? CGPoint(x: rng.next() * side, y: rng.next() * side)
                : band.point(along: (rng.next() - 0.5) * side * 1.5, offset: rng.gaussian() * band.sigma * 1.6)
            // 亮度按幂律：u⁷ 让绝大多数星都很暗，显眼的亮星只有几十颗（与肉眼看到的星空比例相当）
            let brightness = pow(rng.next(), index < 1100 ? 7 : 9)
            let radius = 0.26 + 0.75 * pow(brightness, 0.8)
            let alpha = 0.16 + 0.84 * pow(brightness, 0.55)
            let color = temperatureColor(rng.next())

            if brightness > 0.55 {
                // 只有最亮的几十颗带光晕：光学系统里的弥散，很淡、很小，不是卡通的光圈
                let glow = radius * 2.6 + 3 * brightness
                let colors = [
                    CGColor(colorSpace: space, components: [color.r, color.g, color.b, 0.16 * brightness])!,
                    CGColor(colorSpace: space, components: [color.r, color.g, color.b, 0])!,
                ] as CFArray
                if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
                    context.drawRadialGradient(gradient, startCenter: p, startRadius: 0, endCenter: p, endRadius: glow, options: [])
                }
            }
            context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: alpha)
            context.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    /// 恒星颜色按色温抽样：蓝白（O/B/A 型）、白、淡黄（G 型，像太阳）、橙（K/M 型），都压得很淡
    private static func temperatureColor(_ u: Double) -> (r: Double, g: Double, b: Double) {
        switch u {
        case ..<0.22: (0.8, 0.87, 1)
        case ..<0.68: (1, 1, 1)
        case ..<0.9: (1, 0.95, 0.85)
        default: (1, 0.84, 0.66)
        }
    }
}

/// 固定种子的伪随机数（SplitMix64）：同一个种子永远生成同一片星空
nonisolated private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// 0~1 均匀分布
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// 标准正态分布（Box-Muller）
    mutating func gaussian() -> Double {
        let u = max(next(), 1e-12)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * next())
    }
}

/// 值噪声 + 分形叠加：给银河加上一块块的星云纹理与尘埃暗缝
nonisolated private enum Noise {
    static func fbm(_ x: Double, _ y: Double, seed: Int) -> Double {
        var total = 0.0, amplitude = 0.5, frequency = 1.0, norm = 0.0
        for octave in 0 ..< 5 {
            total += amplitude * value(x * frequency, y * frequency, seed: seed + octave * 131)
            norm += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return total / norm
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func value(_ x: Double, _ y: Double, seed: Int) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let fx = x - floor(x), fy = y - floor(y)
        let ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi, seed), b = hash(xi + 1, yi, seed)
        let c = hash(xi, yi + 1, seed), d = hash(xi + 1, yi + 1, seed)
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
    }

    private static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Double {
        var h = UInt64(bitPattern: Int64(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 1_274_126_177))
        h = (h ^ (h >> 13)) &* 0x5851_F42D_4C95_7F2D
        h ^= h >> 29
        return Double(h & 0xFF_FFFF) / Double(0xFF_FFFF)
    }
}
