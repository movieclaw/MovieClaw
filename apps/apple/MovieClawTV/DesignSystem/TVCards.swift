import SwiftUI

/// Apple TV 的尺寸令牌（三米观看距离，docs/design/tvos-app.md §2）。
/// 画布固定 1920×1080 点；系统已经留出安全边距（上下 60、左右 80），横滑行要贴满屏宽时自己补回左边距。
///
/// 间距是一套黄金比例的阶梯：20（图与片名）→ 32（卡片之间）→ 52（行与行）→ 84（≈ 安全边距 80），
/// 每级约 ×1.618，层级之间拉得开又不跳。卡片宽度按 Apple HIG 的 tvOS 网格思路倒推：整数张卡加间距
/// 刚好铺满安全区内的 1760 点（HIG 固定间距 40，我们收到 32，卡片相应放大），下一张从右边缘露出约 50 点，
/// 提示还能往右划（2026-10-03 用户嫌间距过大后调整）
enum TVMetrics {
    /// 页面左右边距（与系统安全边距一致）
    static let edge: CGFloat = 80
    /// 海报卡宽（2:3）：6 张 + 5 个间距 = 1760
    static let posterWidth: CGFloat = 266
    /// 横版剧照卡宽（16:9）：4 张 + 3 个间距 = 1760
    static let landscapeWidth: CGFloat = 416
    /// 行与行之间
    static let rowSpacing: CGFloat = 52
    /// 同一行卡片之间
    static let cardSpacing: CGFloat = 32
    /// 卡片图与下面片名之间：阶梯里是 20，放宽到 24——海报 400 高，获得焦点放大约 1.1 倍时下沿往下长 20 点，
    /// 20 会正好贴住片名（实测）
    static let captionSpacing: CGFloat = 24
    /// 卡片圆角（与系统 Apple TV App 的海报 / 横卡一致的大圆角）
    static let cardCorner: CGFloat = 20
}

extension Color {
    /// 大图区（首页首屏、条目详情）以下的底色：偏冷的深炭灰 #16171C（色相约 230°、饱和 0.12、亮度 10%，量自系统 Apple TV App）。
    /// 不用纯黑：海报的暗部在纯黑上会糊成一片、边缘生硬；略带冷调的近黑把偏暖的海报衬得更鲜亮（2026-10-03 用户要求，
    /// 只换大图渐变之后的那片底色，大图本身与其他页面不动）
    static let tvPage = Color(red: 22 / 255, green: 23 / 255, blue: 28 / 255)
}

/// 卡片下面的说明文字（片名 / 副标题）什么时候出现。
/// 卡片下面挂字，一行卡片的底边就参差不齐、显得碎；参照系统 Apple TV App，能靠图认出来的地方尽量不挂字。
enum TVCardCaption {
    /// 一直显示：剧照（横版）上认不出是哪一部 / 哪一集，「接下来继续」、分集、刚入库都用它
    case always
    /// 只有焦点所在的那张显示（位置预留，出现时不挤动排版）：海报自带片名，平时不必再写一遍
    case focused
    /// 不显示
    case hidden
}

/// 海报卡（竖版 2:3）：海报自带片名，片名与年份只在获得焦点时出现在下面。
/// 用系统的 `.borderless` 样式——获得焦点时图放大抬起、带光泽，与系统 Apple TV App 的海报一致。
struct TVPosterCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    var width: CGFloat = TVMetrics.posterWidth
    /// 0～1 的观看进度（有才画进度条）
    var progress: Double?
    /// 图上角标（「已入库」「已订阅」「在追」）
    var badge: String?
    var caption: TVCardCaption = .focused
    /// 只在获得焦点时浮现在海报底部暗带里的一行（影人页的「饰 某某」）：不占排版位置，海报墙的网格不变
    var focusDetail: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVCardLabel(title: title, subtitle: subtitle, width: width, caption: caption, badge: badge, focusDetail: focusDetail) {
                RemoteImage(url: imageURL, placeholderText: title)
                    .frame(width: width, height: width * 1.5)
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0 {
                            TVProgressStrip(value: progress)
                                .padding(12)
                        }
                    }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }
}

/// 横版剧照卡（16:9）：「接下来继续」、分集、刚入库。
/// 给了 `detail`（「第 2 季 第 6 集 · 剩 18 分钟」）时，进度条与这行字收进图片底部的暗带里，
/// 不再挂在卡片下面；没给时进度条贴图片底边，片名、副标题照旧写在下面
struct TVLandscapeCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    var width: CGFloat = TVMetrics.landscapeWidth
    var progress: Double?
    /// 图上角标（如「下一集」「已看」）
    var badge: String?
    /// 压在图片底部暗带里的一行说明
    var detail: String?
    var caption: TVCardCaption = .always
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVCardLabel(title: title, subtitle: subtitle, width: width, caption: caption, badge: badge) {
                RemoteImage(url: imageURL, placeholderText: title)
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottom) {
                        if let detail {
                            detailBand(detail)
                        } else if let progress, progress > 0 {
                            TVProgressStrip(value: progress)
                                .padding(14)
                        }
                    }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }

    /// 图片底部的暗带：▶ 进度条 第几集 · 剩多久（同系统 Apple TV App 的「继续观看」卡）
    private func detailBand(_ detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.fill")
                .font(.system(size: 18))
            if let progress, progress > 0 {
                // 暗带本身是黑的，轨道用浅色才看得见
                TVProgressStrip(value: progress, track: .white.opacity(0.3))
                    .frame(width: 64)
            }
            Text(detail)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 36)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 一行末尾的「查看全部」（同 Infuse、Plex 电视版）：与这一行的海报同样大小的一块，往右滑到底就看到，按确认进完整的海报墙。
/// 行里只有前 20 部，想看全部、更早入库的都从这里进（2026-10-03 用户要求）
struct TVSeeAllCard: View {
    /// 总数（知道才写）
    var total: Int?
    var width: CGFloat = TVMetrics.posterWidth
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SeeAllLabel(total: total, width: width)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(total.map { "查看全部 \($0) 部" } ?? "查看全部")
    }

    private struct SeeAllLabel: View {
        let total: Int?
        let width: CGFloat
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            VStack(spacing: 18) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 48, weight: .regular))
                Text("查看全部")
                    .font(.system(size: 28, weight: .semibold))
                if let total {
                    Text("\(total) 部")
                        .font(.system(size: 22))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .frame(width: width, height: width * 1.5)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: TVMetrics.cardCorner))
            .overlay {
                RoundedRectangle(cornerRadius: TVMetrics.cardCorner)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .contentShape(.hoverEffect, .rect(cornerRadius: TVMetrics.cardCorner))
            .hoverEffect(.highlight)
            // 行标题跟着亮起来
            .preference(key: TVRowFocusKey.self, value: isFocused)
        }
    }
}

/// 两种卡片共用的外观：大圆角 + 一圈很细的半透明亮边（让卡片在深色底上有边界）、焦点抬起、左上角标，
/// 以及下面按 `caption` 决定显不显示的片名 / 副标题。
/// 同时把「我拿到了焦点」报给所在的行（`TVRowFocusKey`），行标题据此变亮
private struct TVCardLabel<Art: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    let caption: TVCardCaption
    let badge: String?
    var focusDetail: String?
    @ViewBuilder let art: () -> Art

    /// 在按钮的标签里读到的是这张卡（按钮）的焦点
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: TVMetrics.captionSpacing) {
            art()
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.6), in: .capsule)
                            .padding(12)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let focusDetail {
                        Text(focusDetail)
                            .font(.system(size: 22, weight: .semibold))
                            .lineLimit(2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.top, 48)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background {
                                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                            }
                            .opacity(isFocused ? 1 : 0)
                            .animation(.easeOut(duration: 0.2), value: isFocused)
                    }
                }
                .clipShape(.rect(cornerRadius: TVMetrics.cardCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: TVMetrics.cardCorner)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                }
                // 焦点效果要点名套在图上：图是 Nuke 的 LazyImage 包出来的，`.borderless` 自己找不到它，
                // 获得焦点时卡片纹丝不动、看不出焦点在哪
                .hoverEffect(.highlight)
            if caption != .hidden {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
                .opacity(caption == .always || isFocused ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: isFocused)
            }
        }
        .preference(key: TVRowFocusKey.self, value: isFocused)
    }
}

/// 一行里有没有卡片拿着焦点（任何一张拿着就是 true）
struct TVRowFocusKey: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// 图片底部的观看进度条
struct TVProgressStrip: View {
    let value: Double
    /// 没看的那段：压在亮画面上用半透明黑，压在暗带里用半透明白
    var track: Color = .black.opacity(0.45)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(.white)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 6)
    }
}

/// 一行横滑内容：标题 + 横向滚动的卡片。整行是一个焦点分区：从上一行按下来时落在这一行离焦点最近的那张，
/// 而不是跳到行首；卡片放大时不被行的边缘裁掉（`scrollClipDisabled`）
struct TVShelf<Content: View>: View {
    let title: String
    /// 标题右侧的说明（如「12 部」）
    var detail: String?
    @ViewBuilder let content: () -> Content

    /// 焦点在不在这一行：在就把行标题点亮，不在就压暗（同系统 Apple TV App：眼睛自然落在当前这一行）
    @State private var rowFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                // 32 点半粗（同系统 Apple TV App 的行标题）：38 点的 title3 压过了首屏大图的文字，显得重
                Text(title)
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(rowFocused ? .primary : .secondary)
                    .animation(.easeOut(duration: 0.2), value: rowFocused)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TVMetrics.cardSpacing) {
                    content()
                }
                .padding(.horizontal, TVMetrics.edge)
                .padding(.vertical, 20)
            }
            .scrollClipDisabled()
            .scrollIndicators(.hidden)
        }
        .onPreferenceChange(TVRowFocusKey.self) { rowFocused = $0 }
        .focusSection()
    }
}

/// 页面级的空态 / 错误态（大字号、按钮可聚焦）。
///
/// 没有按钮时整块本身可聚焦：页签根上的空态（「还没有订阅」「媒体库里还没有内容」）若一个可聚焦的东西都没有，
/// 焦点只能留在侧边栏，侧边栏一收起就无处可去——上下滑没反应、返回键也不起作用（2026-10-03 真机实测）
struct TVStateView: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: symbol)
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(TVMetrics.edge)
        .focusable(actionTitle == nil || action == nil)
    }
}

extension Formatters {
    /// 「剩 23 分钟」「剩 1 小时 5 分」：继续观看卡片的副标题
    static func remaining(positionMs: Int, durationMs: Int?) -> String? {
        guard let durationMs, durationMs > 0 else { return nil }
        let minutes = max(1, (durationMs - positionMs) / 60_000)
        if minutes >= 60 { return "剩 \(minutes / 60) 小时 \(minutes % 60) 分" }
        return "剩 \(minutes) 分钟"
    }
}
