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
}

/// 海报卡（竖版 2:3）：图在上、片名与年份在下。用系统的 `.borderless` 样式——获得焦点时只有图放大抬起、
/// 带光泽，文字跟着下移，与系统 Apple TV App 的海报一致。
struct TVPosterCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    var width: CGFloat = TVMetrics.posterWidth
    /// 0～1 的观看进度（有才画进度条）
    var progress: Double?
    /// 图上角标（「已入库」「已订阅」「在追」）
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(url: imageURL, placeholderText: title)
                    .frame(width: width, height: width * 1.5)
                    .overlay(alignment: .bottom) { progressBar }
                    .overlay(alignment: .topLeading) {
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.65), in: .capsule)
                                .padding(10)
                        }
                    }
                    .clipShape(.rect(cornerRadius: 14))
                    // 焦点效果要点名套在图上：图是 Nuke 的 LazyImage 包出来的，`.borderless` 自己找不到它，
                    // 获得焦点时卡片纹丝不动、看不出焦点在哪
                    .hoverEffect(.highlight)
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
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let progress, progress > 0 {
            TVProgressStrip(value: progress)
                .padding(12)
        }
    }
}

/// 横版剧照卡（16:9）：「接下来继续」、分集。图在上，下面两行字（片名 / 第几集 · 剩多久）
struct TVLandscapeCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    var width: CGFloat = TVMetrics.landscapeWidth
    var progress: Double?
    /// 图上角标（如「下一集」「已看」）
    var badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                RemoteImage(url: imageURL, placeholderText: title)
                    .frame(width: width, height: width * 9 / 16)
                    .overlay(alignment: .bottom) {
                        if let progress, progress > 0 {
                            TVProgressStrip(value: progress)
                                .padding(14)
                        }
                    }
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
                    .clipShape(.rect(cornerRadius: 14))
                    // 焦点效果要点名套在图上：图是 Nuke 的 LazyImage 包出来的，`.borderless` 自己找不到它，
                    // 获得焦点时卡片纹丝不动、看不出焦点在哪
                    .hoverEffect(.highlight)
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
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
    }
}

/// 图片底部的观看进度条
struct TVProgressStrip: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.black.opacity(0.45))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title)
                    .font(.title3.weight(.semibold))
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
