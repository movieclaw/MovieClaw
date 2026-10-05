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

/// 设计稿 A：手机 236 × 150、电视 416 × 234。两端共用剧照、遮罩与分类语义。
struct GenreCardFace: View {
    let label: String
    let count: Int
    let mediaKind: String
    let coverURL: URL?
    let width: CGFloat
    var imageSaturation: Double = 1

    #if os(tvOS)
    private let height: CGFloat = 234
    private let corner: CGFloat = 20
    private let titleSize: CGFloat = 40
    private let countSize: CGFloat = 24
    private let titleLeft: CGFloat = 30
    private let titleBottom: CGFloat = 66
    private let countLeft: CGFloat = 32
    private let countBottom: CGFloat = 29
    #else
    private let height: CGFloat = 150
    private let corner: CGFloat = 12
    private let titleSize: CGFloat = 24
    private let countSize: CGFloat = 11
    private let titleLeft: CGFloat = 18
    private let titleBottom: CGFloat = 38
    private let countLeft: CGFloat = 19
    private let countBottom: CGFloat = 17
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
                                .saturation(imageSaturation * 1.45).brightness(-0.03)
                                .mask(LinearGradient(stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: 0.25),
                                    .init(color: .clear, location: 0.6),
                                ], startPoint: .bottom, endPoint: .top))
                        }
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
            LinearGradient(stops: Self.easedStops(maxOpacity: 0.42, span: 0.58), startPoint: .bottom, endPoint: .top)
            EllipticalGradient(stops: Self.easedStops(maxOpacity: 0.55, span: 1), center: .center)
                .frame(width: width * 1.9, height: height * 1.5)
                .position(x: width * 0.12, y: height)

            Text(label)
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 1)
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
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .center), lineWidth: 1)
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
