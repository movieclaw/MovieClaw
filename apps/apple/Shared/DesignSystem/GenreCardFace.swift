import NukeUI
import SwiftUI

/// TMDB 类型墙标题，与网页 genre-labels.ts 同表。
enum GenreLabels {
    static let names: [Int: String] = [
        28: "动作",
        12: "冒险",
        16: "动画",
        35: "喜剧",
        80: "犯罪",
        99: "纪录",
        18: "剧情",
        10751: "家庭",
        14: "奇幻",
        36: "历史",
        27: "恐怖",
        10402: "音乐",
        9648: "悬疑",
        10749: "爱情",
        878: "科幻",
        10770: "电视电影",
        53: "惊悚",
        10752: "战争",
        37: "西部",
        10759: "动作冒险",
        10762: "儿童",
        10763: "新闻",
        10764: "真人秀",
        10765: "科幻奇幻",
        10766: "肥皂剧",
        10767: "脱口秀",
        10768: "战争政治",
    ]
}

/// 全幅剧照类型卡：各端共用自然通透的剧照、文字保护与分类语义。
struct GenreCardFace: View {
    let label: String
    let count: Int
    let mediaKind: String
    let coverURL: URL?
    let width: CGFloat
    var imageSaturation: Double = 1
    /// 剧照在卡片里的缩放（Mac 悬停时 1.045，同网页；卡片外框不动）
    var imageScale: CGFloat = 1

    #if os(tvOS)
    private var scale: CGFloat { width / 416 }
    private var height: CGFloat { width * 9 / 16 }
    private var corner: CGFloat { 20 * scale }
    private var titleSize: CGFloat { 40 * scale }
    private var countSize: CGFloat { 24 * scale }
    private var titleLeft: CGFloat { 30 * scale }
    private var titleBottom: CGFloat { 66 * scale }
    private var countLeft: CGFloat { 30 * scale }
    private var countBottom: CGFloat { 29 * scale }
    #else
    private var scale: CGFloat { width / 236 }
    private var height: CGFloat { 150 * scale }
    private var corner: CGFloat { 12 * scale }
    private var titleSize: CGFloat { 24 * scale }
    // 部数保持 11 pt，缩小卡片后仍易读。
    private let countSize: CGFloat = 11
    private var titleLeft: CGFloat { 18 * scale }
    private var titleBottom: CGFloat { 38 * scale }
    private var countLeft: CGFloat { 18 * scale }
    private var countBottom: CGFloat { 17 * scale }
    #endif

    private var countLabel: String { "\(count) 部\(mediaKind == "tv" ? "剧集" : "电影")" }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LazyImage(url: coverURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { state in
                if let image = state.image {
                    image.resizable().scaledToFill().saturation(imageSaturation)
                        .overlay {
                            // 压暗区提饱和：黑色渐变压低的那一截颜色更浓，读起来是「暗」而不是「灰」
                            image.resizable().scaledToFill()
                                .saturation(imageSaturation * 1.2)
                                .mask(LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.25),
                                    .init(color: .clear, location: 0.6),
                                ], startPoint: .bottom, endPoint: .top))
                        }
                        .scaleEffect(imageScale)
                } else {
                    RadialGradient(colors: [Color(white: 0.28), Color(white: 0.12)],
                                   center: .topTrailing, startRadius: 0, endRadius: width * 0.85)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "film")
                                .font(.system(size: titleSize * 1.875, weight: .ultraLight))
                                .foregroundStyle(.white.opacity(0.13))
                                .padding(titleLeft)
                        }
                }
            }
            .frame(width: width, height: height)
            .clipped()

            // 文字保护只压该压的地方：全宽一层很轻的底，再在文字所在的左下叠一团椭圆暗区；
            // 两层都走缓动曲线，没有可见的渐变边界，右上角保持剧照原本的亮度
            LinearGradient(stops: Self.easedStops(maxOpacity: 0.28, span: 0.54), startPoint: .bottom, endPoint: .top)
            EllipticalGradient(stops: Self.easedStops(maxOpacity: 0.5, span: 1), center: .center)
                .frame(width: width * 1.56, height: height * 1.44)
                .position(x: width * 0.12, y: height)

            Text(label)
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.32), radius: 4, y: 1)
                .padding(.leading, titleLeft)
                .padding(.trailing, titleLeft * 2)
                .padding(.bottom, titleBottom)
            Text(countLabel)
                .font(.system(size: countSize).monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, countLeft)
                .padding(.bottom, countBottom)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                // 顶边一道内高光往下淡出，卡片有厚度、不像贴在黑底上的平图
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.12), .white.opacity(0.025)],
                                             startPoint: .top, endPoint: .center), lineWidth: 0.5)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("浏览\(label)，\(countLabel)")
    }

    /// smoothstep 缓动的黑色渐变：从 0 处的 maxOpacity 平滑落到 span 处的全透明
    private static func easedStops(maxOpacity: Double, span: Double) -> [Gradient.Stop] {
        (0...8).map { i in
            let t = Double(i) / 8
            return .init(color: .black.opacity(maxOpacity * (1 - t * t * (3 - 2 * t))), location: t * span)
        }
    }
}
