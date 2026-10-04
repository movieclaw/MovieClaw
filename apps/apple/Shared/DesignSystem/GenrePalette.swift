import CoreImage
import SwiftUI
import UIKit

/// 首页「按类型找电影 / 剧集」色块的配色：TMDB genre id → 一块网格渐变。
///
/// 逐项移植自网页 `apps/web/lib/genre-palette.ts`（同一张表、同一套公式；那边的
/// test/genre-palette.test.mjs 会解析本文件比对，两边改一处测试就红）。
///
/// 每个类型手调一组三色相（主色 a、渐变偏移色 b、高光色 c）与明度 l、彩度 k，全部在
/// OKLCH 里定义——同样的 l 在人眼里一样亮，渐变中段也不发灰。整体彩度再乘 `chromaScale`。
/// 一块色块 = 主色→偏移色的斜向底 + 三团羽化色团（高光团、偏移团、小亮斑）+ 胶片颗粒 + 左下压暗。
enum GenrePalette {
    struct Tone {
        var name: String
        var a: Double
        var b: Double
        var c: Double
        var l: Double
        var k: Double
    }

    /// 整体彩度倍率：设计稿 v6 的「80%」档
    static let chromaScale = 0.8
    /// 色块宽高比（16:10.5），色团的纵向位置按它换算
    static let tileAspect = 16.0 / 10.5

    // 与 genre-palette.ts 的 GENRE_TONES 逐行对应（改这里也要改那里）
    static let tones: [Int: Tone] = [
        // 电影
        28: Tone(name: "动作", a: 33, b: 58, c: 12, l: 0.62, k: 0.2),
        12: Tone(name: "冒险", a: 190, b: 165, c: 225, l: 0.6, k: 0.13),
        16: Tone(name: "动画", a: 140, b: 115, c: 168, l: 0.68, k: 0.19),
        35: Tone(name: "喜剧", a: 75, b: 52, c: 95, l: 0.72, k: 0.17),
        80: Tone(name: "犯罪", a: 268, b: 290, c: 245, l: 0.4, k: 0.13),
        99: Tone(name: "纪录", a: 160, b: 135, c: 195, l: 0.52, k: 0.11),
        18: Tone(name: "剧情", a: 292, b: 318, c: 265, l: 0.52, k: 0.2),
        10751: Tone(name: "家庭", a: 48, b: 28, c: 72, l: 0.72, k: 0.15),
        14: Tone(name: "奇幻", a: 310, b: 340, c: 280, l: 0.55, k: 0.2),
        36: Tone(name: "历史", a: 62, b: 45, c: 82, l: 0.56, k: 0.1),
        27: Tone(name: "恐怖", a: 22, b: 4, c: 38, l: 0.4, k: 0.16),
        10402: Tone(name: "音乐", a: 345, b: 318, c: 12, l: 0.62, k: 0.21),
        9648: Tone(name: "悬疑", a: 205, b: 230, c: 180, l: 0.46, k: 0.1),
        10749: Tone(name: "爱情", a: 2, b: 345, c: 30, l: 0.68, k: 0.18),
        878: Tone(name: "科幻", a: 252, b: 225, c: 285, l: 0.58, k: 0.19),
        10770: Tone(name: "电视电影", a: 278, b: 255, c: 305, l: 0.62, k: 0.13),
        53: Tone(name: "惊悚", a: 340, b: 12, c: 312, l: 0.42, k: 0.16),
        10752: Tone(name: "战争", a: 125, b: 150, c: 105, l: 0.54, k: 0.1),
        37: Tone(name: "西部", a: 58, b: 72, c: 38, l: 0.66, k: 0.15),
        // 剧集独有
        10759: Tone(name: "动作冒险", a: 42, b: 68, c: 20, l: 0.64, k: 0.19),
        10762: Tone(name: "儿童", a: 210, b: 185, c: 95, l: 0.7, k: 0.13),
        10763: Tone(name: "新闻", a: 240, b: 255, c: 220, l: 0.58, k: 0.07),
        10764: Tone(name: "真人秀", a: 355, b: 40, c: 322, l: 0.66, k: 0.2),
        10765: Tone(name: "科幻奇幻", a: 272, b: 305, c: 232, l: 0.55, k: 0.19),
        10766: Tone(name: "肥皂剧", a: 322, b: 352, c: 296, l: 0.65, k: 0.16),
        10767: Tone(name: "脱口秀", a: 68, b: 45, c: 88, l: 0.7, k: 0.16),
        10768: Tone(name: "战争政治", a: 140, b: 165, c: 115, l: 0.5, k: 0.09),
    ]

    /// 表外的 id（TMDB 将来新增的类型）：中性的石板蓝
    private static let fallback = Tone(name: "", a: 250, b: 270, c: 230, l: 0.5, k: 0.06)

    static func tone(_ id: Int) -> Tone { tones[id] ?? fallback }

    // MARK: OKLCH

    struct Oklch: Equatable {
        var l: Double
        var c: Double
        var h: Double
        var alpha: Double
    }

    /// 彩度在这里统一乘 chromaScale，明度钳在 0-1
    static func oklch(_ l: Double, _ k: Double, _ h: Double, _ alpha: Double = 1) -> Oklch {
        Oklch(l: min(1, max(0, l)), c: k * chromaScale, h: (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360), alpha: alpha)
    }

    /// 两个色相沿短弧的中点（345° 与 12° 的中点是 358.5°，不是 178.5°）
    static func midHue(_ x: Double, _ y: Double) -> Double {
        let d = (y - x + 540).truncatingRemainder(dividingBy: 360) - 180
        return (x + d / 2 + 360).truncatingRemainder(dividingBy: 360)
    }

    /// OKLCH → Display P3（Apple 屏幕都是 P3：与网页在 Safari / Chrome 上画出来的一致）。
    /// OKLab → LMS → 线性 sRGB → 线性 P3，再套 sRGB 同款传递曲线；出 P3 色域的分量钳回 0-1
    static func color(_ value: Oklch) -> Color {
        let hr = value.h * .pi / 180
        let a = value.c * cos(hr), b = value.c * sin(hr)
        let l_ = value.l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = value.l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = value.l - 0.0894841775 * a - 1.2914855480 * b
        let l3 = l_ * l_ * l_, m3 = m_ * m_ * m_, s3 = s_ * s_ * s_
        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3
        let pr = 0.8224621 * r + 0.1775380 * g
        let pg = 0.0331941 * r + 0.9668058 * g
        let pb = 0.0170827 * r + 0.0723974 * g + 0.9105199 * bl
        func encode(_ x: Double) -> Double {
            let v = min(1, max(0, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return Color(.displayP3, red: encode(pr), green: encode(pg), blue: encode(pb), opacity: value.alpha)
    }

    // MARK: 构图

    struct Blob {
        /// 圆心框左上角：left 占宽、top 占高
        var left: Double
        var top: Double
        /// 直径占宽
        var size: Double
        var color: Oklch
    }

    struct Art {
        var from: Oklch
        var to: Oklch
        var blobs: [Blob]
        /// 左下角文字区的局部压暗：类型墙页头的字在左下，亮色块上白字也要够清楚
        var scrim: Double
        /// 外发光投影的颜色：主色与偏移色之间的同色系，让卡片像在发光
        var glow: Oklch
    }

    /// 羽化：按缓动曲线逐级降透明度，边缘像颜料晕开而没有硬边（位置 0-1, 透明度倍率）
    static let featherStops: [(Double, Double)] = [(0, 1), (0.22, 0.82), (0.45, 0.55), (0.68, 0.26), (0.86, 0.08), (1, 0)]

    private enum Role { case c, b, c2 }

    /// 三种构图：色团圆心框的左上角（x 占宽、y 占高）与直径（占宽），以及用哪种颜色
    private static let compositions: [[(x: Double, y: Double, d: Double, role: Role)]] = [
        [(-0.15, -0.35, 0.85, .c), (0.55, 0.25, 0.95, .b), (0.65, -0.45, 0.6, .c2)],
        [(0.45, -0.4, 0.9, .c), (-0.25, 0.3, 0.9, .b), (0.8, 0.35, 0.55, .c2)],
        [(-0.1, 0.25, 0.8, .b), (0.5, -0.5, 1.0, .c), (0.2, -0.3, 0.45, .c2)],
    ]

    /// 羽化后色团画得比构图里的直径大 35%，圆心不动
    private static let featherGrow = 1.35

    /// 构图按 id 各位数字之和轮换：稳定（同一类型永远同一构图），且相邻 id 大多不同
    static func compositionIndex(_ id: Int) -> Int {
        String(abs(id)).compactMap(\.wholeNumberValue).reduce(0, +) % 3
    }

    static func art(_ id: Int) -> Art {
        let t = tone(id)
        func colorFor(_ role: Role) -> Oklch {
            switch role {
            case .c: oklch(t.l + 0.12, t.k + 0.02, t.c, 0.95)
            case .b: oklch(t.l - 0.06, t.k + 0.01, t.b, 0.95)
            case .c2: oklch(t.l + 0.2, t.k * 0.7, midHue(t.a, t.c), 0.7)
            }
        }
        let blobs = compositions[compositionIndex(id)].map { p in
            let size = p.d * featherGrow
            let grow = (size - p.d) / 2
            return Blob(left: p.x - grow, top: p.y - grow * tileAspect, size: size, color: colorFor(p.role))
        }
        return Art(
            from: oklch(t.l + 0.03, t.k, t.a),
            to: oklch(t.l - 0.1, t.k, t.b),
            blobs: blobs,
            scrim: max(0.06, (t.l - 0.5) * 0.9),
            glow: oklch(t.l - 0.02, t.k, midHue(t.a, t.b), 0.55)
        )
    }

    /// 斜向底的色标：在 OKLCH 里预先插出几档（色相走短弧），SwiftUI 在相邻档之间按 sRGB 插值也不会发灰
    static func baseStops(_ art: Art, count: Int = 6) -> [Gradient.Stop] {
        let dh = (art.to.h - art.from.h + 540).truncatingRemainder(dividingBy: 360) - 180
        return (0 ..< count).map { i in
            let t = Double(i) / Double(count - 1)
            let value = Oklch(
                l: art.from.l + (art.to.l - art.from.l) * t,
                c: art.from.c + (art.to.c - art.from.c) * t,
                h: (art.from.h + dh * t + 360).truncatingRemainder(dividingBy: 360),
                alpha: 1
            )
            return Gradient.Stop(color: color(value), location: t)
        }
    }

    static func blobStops(_ value: Oklch) -> [Gradient.Stop] {
        featherStops.map { at, alpha in
            Gradient.Stop(color: color(Oklch(l: value.l, c: value.c, h: value.h, alpha: value.alpha * alpha)), location: at)
        }
    }

    /// 胶片颗粒：一张 160×160 的灰度噪点，平铺后以柔光叠在最上层，只为消掉渐变色带
    @MainActor static let grain: UIImage? = {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return nil }
        let gray = noise.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let rect = CGRect(x: 0, y: 0, width: 160, height: 160)
        guard let cg = CIContext().createCGImage(gray.cropped(to: rect), from: rect) else { return nil }
        return UIImage(cgImage: cg)
    }()
}

/// 一个类型的网格渐变底（色块与类型墙页头共用）：只画底，尺寸与圆角由外层决定（外层负责裁切）。
/// `drift`：获得焦点 / 按下时三团色团各自缓慢漂一点（同网页悬停）。
/// `scrim`：左下角压暗，给写在左下的字托底（类型墙页头）；色块的字居中，不要它
struct GenreArtwork: View {
    let genreId: Int
    var drift = false
    var scrim = true

    private static let driftOffsets: [(CGFloat, CGFloat, CGFloat)] = [(0.08, 0.06, 1.08), (-0.10, -0.04, 1.1), (0.06, -0.08, 1)]

    var body: some View {
        let art = GenrePalette.art(genreId)
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(stops: GenrePalette.baseStops(art), startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(art.blobs.indices, id: \.self) { index in
                    let blob = art.blobs[index]
                    let size = blob.size * width
                    let move = Self.driftOffsets[index]
                    Circle()
                        .fill(RadialGradient(stops: GenrePalette.blobStops(blob.color), center: .center, startRadius: 0, endRadius: size / 2))
                        .frame(width: size, height: size)
                        .scaleEffect(drift ? move.2 : 1)
                        .offset(
                            x: blob.left * width + (drift ? move.0 * size : 0),
                            y: blob.top * height + (drift ? move.1 * size : 0)
                        )
                }
                if let grain = GenrePalette.grain {
                    Image(uiImage: grain)
                        .resizable(resizingMode: .tile)
                        .blendMode(.softLight)
                        .opacity(0.09)
                }
                if scrim {
                    EllipticalGradient(
                        colors: [.black.opacity(art.scrim), .clear],
                        center: .bottomLeading, startRadiusFraction: 0, endRadiusFraction: 0.53
                    )
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 1.6), value: drift)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 色块本体：网格渐变底，类型名居中、部数在它下面，16:10.5，字号、圆角、投影随宽度等比缩放。
///
/// 边缘四层（同网页 `GenreTile`，设计稿 v7）：内晕影（四周往里压暗、中间透亮）、顶部镜面光带、
/// 上亮下暗的渐变描边、同色系的外发光投影（外加一层贴地的暗影）。外发光会溢出卡片，所在的横滑行不能裁切。
/// 交互（点按 / 焦点）由外层包
struct GenreTileFace: View {
    let genreId: Int
    let label: String
    let count: Int?
    let width: CGFloat
    var drift = false
    /// 字号上限：手机 28、电视更大
    var maxFont: CGFloat = 28
    /// 圆角；空 = 随宽度等比（宽的 10%，同网页）。电视与其他卡片统一用 `TVMetrics.cardCorner`
    var corner: CGFloat?
    /// 外发光投影画不画：电视的焦点效果（`.hoverEffect`）会按卡片形状裁切，投影要由外层加在焦点效果外面
    var shadows = true
    /// 部数写在卡片里（名字下面）还是交给外层写在卡片下方：手机写在下方，与海报片名、媒体库卡片名对齐
    var countInside = true

    var body: some View {
        let height = width / GenrePalette.tileAspect
        let font = min(maxFont, max(15, width * 0.13))
        let shape = RoundedRectangle(cornerRadius: corner ?? width * 0.1, style: .continuous)
        ZStack {
            GenreArtwork(genreId: genreId, drift: drift, scrim: false)
            // 内晕影：中心略偏上，字落在亮处
            EllipticalGradient(
                stops: [.init(color: .clear, location: 0.52), .init(color: .black.opacity(0.3), location: 1)],
                center: UnitPoint(x: 0.5, y: 0.42), startRadiusFraction: 0, endRadiusFraction: 1.2
            )
            // 顶部镜面光带
            LinearGradient(
                stops: [.init(color: .white.opacity(0.16), location: 0), .init(color: .white.opacity(0.04), location: 0.3),
                        .init(color: .clear, location: 0.46)],
                startPoint: .top, endPoint: .bottom
            )
            // 间距同网页：片数字号的半个字高（≈ 名字字号的 1/4）
            VStack(spacing: max(11, font * 0.5) * 0.5) {
                Text(label)
                    .font(.system(size: font, weight: .semibold))
                    .tracking(font * 0.12)
                    // 字距加在每个字后面，最后一个字也有：往右挪半个字距才真正居中
                    .offset(x: font * 0.06)
                if let count, countInside {
                    Text("\(count) 部")
                        .font(.system(size: max(11, font * 0.5), weight: .medium).monospacedDigit())
                        .tracking(max(11, font * 0.5) * 0.08)
                        .opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.28), radius: width * 0.03, y: 1)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay {
            // 渐变描边：上沿亮、往下几乎消失
            shape.strokeBorder(
                LinearGradient(
                    stops: [.init(color: .white.opacity(0.42), location: 0), .init(color: .white.opacity(0.08), location: 0.45),
                            .init(color: .white.opacity(0.02), location: 1)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 1
            )
        }
        .modifier(GenreTileShadow(genreId: genreId, width: width, enabled: shadows))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count.map { "\(label)，\($0) 部" } ?? label)
    }
}

/// 色块的投影：同色系外发光 + 一层贴地的暗影（卡片像在发光）
struct GenreTileShadow: ViewModifier {
    let genreId: Int
    let width: CGFloat
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content
                .shadow(color: GenrePalette.color(GenrePalette.art(genreId).glow), radius: width * 0.07, y: width * 0.07)
                .shadow(color: .black.opacity(0.45), radius: 3, y: 2)
        } else {
            content
        }
    }
}
