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
    var imageSaturation: Double = 0.76

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

            LinearGradient(stops: [
                .init(color: Color(red: 7 / 255, green: 9 / 255, blue: 13 / 255).opacity(239 / 255), location: 0),
                .init(color: Color(red: 8 / 255, green: 10 / 255, blue: 12 / 255).opacity(119 / 255), location: 0.44),
                .init(color: Color(red: 9 / 255, green: 11 / 255, blue: 16 / 255).opacity(16 / 255), location: 1),
            ], startPoint: .bottom, endPoint: .top)

            Text(label)
                .font(.system(size: titleSize, weight: .semibold))
                .tracking(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 8, y: 1)
                .padding(.leading, titleLeft)
                .padding(.trailing, titleLeft * 2)
                .padding(.bottom, titleBottom)
            Text(countLabel)
                .font(.system(size: countSize))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.leading, countLeft)
                .padding(.bottom, countBottom)
            Image(systemName: "chevron.right")
                .font(.system(size: countSize * 0.85, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, countBottom)
                .padding(.bottom, countBottom + 2)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("浏览\(label)，\(countLabel)")
    }
}
