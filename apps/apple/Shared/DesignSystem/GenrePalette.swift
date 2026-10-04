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
            blobs: blobs
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

    // MARK: 贴图卡

    /// 贴图卡（首页色块，设计稿 v10 B）的纯色底与字色：类型主色相的浅色底 + 同色相深色字。
    /// 惊悚、悬疑反过来用深色底 + 浅色字。彩度直接给定，不乘 chromaScale（同网页 genreCardColors）
    static let darkCardGenres: Set<Int> = [53, 9648]

    struct CardColors {
        var background: Oklch
        var ink: Oklch
        var dark: Bool
    }

    static func cardColors(_ id: Int) -> CardColors {
        let t = tone(id)
        let h = (t.a.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if darkCardGenres.contains(id) {
            return CardColors(background: Oklch(l: 0.3, c: t.k * 0.55, h: h, alpha: 1), ink: Oklch(l: 0.93, c: t.k * 0.25, h: h, alpha: 1), dark: true)
        }
        return CardColors(background: Oklch(l: 0.82, c: t.k * 0.42, h: h, alpha: 1), ink: Oklch(l: 0.24, c: t.k * 0.55, h: h, alpha: 1), dark: false)
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

/// 一个类型的网格渐变（斜向底 + 三团羽化色团 + 颗粒）：类型色块里没有可用剧照时，贴在剧照的位置。
/// 只画底，尺寸与圆角由外层决定（外层负责裁切）
struct GenreArtwork: View {
    let genreId: Int

    var body: some View {
        let art = GenrePalette.art(genreId)
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(stops: GenrePalette.baseStops(art), startPoint: .topLeading, endPoint: .bottomTrailing)
                ForEach(art.blobs.indices, id: \.self) { index in
                    let blob = art.blobs[index]
                    let size = blob.size * width
                    Circle()
                        .fill(RadialGradient(stops: GenrePalette.blobStops(blob.color), center: .center, startRadius: 0, endRadius: size / 2))
                        .frame(width: size, height: size)
                        .offset(x: blob.left * width, y: blob.top * height)
                }
                if let grain = GenrePalette.grain {
                    Image(uiImage: grain)
                        .resizable(resizingMode: .tile)
                        .blendMode(.softLight)
                        .opacity(0.09)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// 首页「按类型找电影 / 剧集」的一格（设计稿 v10，同网页 `GenreTile`）：方卡，类型固定色的浅色纯底
/// （惊悚、悬疑是深色底），左上角粗体类型名、右上角部数；下半部贴一张这个类型**最近入库**那部片的
/// 剧照（原色、自带圆角），没有剧照时贴这个类型的网格渐变。字号、圆角、内边距都按宽度等比缩放。
/// 卡片下方的片名、交互（点按 / 焦点）由外层决定
struct GenreCardFace: View {
    let genreId: Int
    let label: String
    let count: Int
    /// 封面剧照（已按显示宽度取好）；空 = 贴渐变
    let coverURL: URL?
    let width: CGFloat

    var body: some View {
        let colors = GenrePalette.cardColors(genreId)
        let pad = width * 0.045
        let title = max(15, width * 0.118)
        let inner = width - pad * 2
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(.system(size: title, weight: .bold))
                    .tracking(title * 0.02)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count) 部")
                    .font(.system(size: max(10, width * 0.052), weight: .semibold).monospacedDigit())
                    .opacity(0.75)
            }
            .foregroundStyle(GenrePalette.color(colors.ink))
            .padding(.top, width * 0.035)
            .padding(.horizontal, width * 0.005)
            Spacer(minLength: 0)
            cover
                .frame(width: inner, height: inner * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: width * 0.03, style: .continuous))
        }
        .padding(pad)
        .frame(width: width, height: width)
        .background(GenrePalette.color(colors.background))
        .clipShape(RoundedRectangle(cornerRadius: width * 0.045, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label)，\(count) 部")
    }

    @ViewBuilder
    private var cover: some View {
        if let coverURL {
            RemoteImage(url: coverURL)
        } else {
            GenreArtwork(genreId: genreId)
        }
    }
}
