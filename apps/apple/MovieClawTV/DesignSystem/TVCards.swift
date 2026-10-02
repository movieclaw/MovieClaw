import SwiftUI

/// Apple TV 的尺寸令牌（三米观看距离，docs/design/tvos-app.md §2）。
/// 画布固定 1920×1080 点；系统已经留出安全边距（上下 60、左右 80），横滑行要贴满屏宽时自己补回左边距。
enum TVMetrics {
    /// 页面左右边距（与系统安全边距一致）
    static let edge: CGFloat = 80
    /// 海报卡宽（2:3）：一屏约 6 张
    static let posterWidth: CGFloat = 240
    /// 横版剧照卡宽（16:9）：一屏约 3.5 张
    static let landscapeWidth: CGFloat = 460
    /// 行与行之间
    static let rowSpacing: CGFloat = 56
    /// 同一行卡片之间
    static let cardSpacing: CGFloat = 40
    /// 卡片圆角（与系统 Apple TV App 的海报 / 横卡一致的大圆角）
    static let cardCorner: CGFloat = 20
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVCardLabel(title: title, subtitle: subtitle, width: width, caption: caption, badge: badge) {
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

/// 两种卡片共用的外观：大圆角 + 一圈很细的半透明亮边（让卡片在深色底上有边界）、焦点抬起、左上角标，
/// 以及下面按 `caption` 决定显不显示的片名 / 副标题。
/// 同时把「我拿到了焦点」报给所在的行（`TVRowFocusKey`），行标题据此变亮
private struct TVCardLabel<Art: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    let caption: TVCardCaption
    let badge: String?
    @ViewBuilder let art: () -> Art

    /// 在按钮的标签里读到的是这张卡（按钮）的焦点
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        // 间距留足：获得焦点时图放大约 1.1 倍，下沿会往下长十几点，太近就压住下面的片名
        VStack(alignment: .leading, spacing: 26) {
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
                Text(title)
                    .font(.title3.weight(.semibold))
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

/// 页面级的空态 / 错误态（大字号、按钮可聚焦）
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
