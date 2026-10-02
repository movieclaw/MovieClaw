import Nuke
import NukeUI
import SwiftUI

// 首页大图区的两层（docs/design/tvos-app.md §3.1）：
// - `TVHomeBackdrop`：整页背景——焦点那一部的剧照铺满全屏、慢速推近，底部渐隐进氛围色；
//   氛围色取剧照主色（与 iPhone 订阅首页 / 发现页同一套取色），往下滚时剧照淡出、颜色退淡；
// - `TVHomeStageInfo`：首屏左侧的文字——片名（有 Logo 画 Logo）、类型年份、第几集、简介，
//   以及一枚液态玻璃的状态小标签（进度、剩多久 / 下一集）。
// 背景层不随列表滚动、文字层随列表滚动：往下看别的行时文字先走、剧照慢慢淡出，自带一点景深。

/// 首页列表的滚动距离（向下为正）。放在可观察对象里而不是首页的 @State：首页主体不读它，
/// 只有背景层读，滚动动画的每一帧只重算背景，不重算整页的行清单
@Observable
final class TVHomeScroll {
    var offset: CGFloat = 0
}

/// 首页整页背景：氛围色 + 焦点那一部的剧照
struct TVHomeBackdrop: View {
    /// 剧照地址（换一部就交叉淡入）；nil = 没有「接下来继续」，只铺底色
    let url: URL?
    /// 剧照主色；取到之前是纯黑底
    let tint: Color?
    /// 列表滚动距离：往下看别的行时剧照淡出，氛围色退到一半左右
    let scroll: TVHomeScroll

    private var scrollOffset: CGFloat { max(0, scroll.offset) }

    var body: some View {
        ZStack {
            Theme.background
            if let tint {
                // 整屏铺主色、越往下越淡：首屏底部那一行卡片正好落在颜色里，下面各行也被同一种光照着
                LinearGradient(stops: [
                    .init(color: tint.opacity(0.95), location: 0),
                    .init(color: tint.opacity(0.7), location: 0.55),
                    .init(color: tint.opacity(0.4), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .id(tint.description)
                .transition(.opacity)
                .opacity(Double(max(0.5, 1 - scrollOffset / 1400)))
            }
            if let url {
                TVStageImage(url: url)
                    .id(url)
                    .transition(.opacity)
                    .opacity(Double(max(0, 1 - scrollOffset / 700)))
            }
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .animation(.easeInOut(duration: 1.2), value: tint?.description)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// 一张剧照：铺满全屏，出现后 40 秒慢慢推近到 1.08 倍（Ken Burns），左侧压暗托住文字，底部渐隐。
/// 每换一部是一个新视图（外面 `.id(url)`），推近从头开始，不会和上一部没走完的动画叠在一起。
private struct TVStageImage: View {
    let url: URL
    @State private var zoom: CGFloat = 1

    var body: some View {
        LazyImage(url: url) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                // 加载中不画占位色块：上一部正在淡出，露出的是氛围色
                Color.clear
            }
        }
        .scaleEffect(zoom)
        // 左侧压暗：片名、简介落在左半屏，亮画面（雪景、天空）上白字也读得清
        .overlay {
            LinearGradient(stops: [
                .init(color: .black.opacity(0.78), location: 0),
                .init(color: .black.opacity(0.4), location: 0.42),
                .init(color: .clear, location: 0.72),
            ], startPoint: .leading, endPoint: .trailing)
        }
        // 底部渐隐进氛围色，不切出一道硬边
        .mask {
            LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.5),
                .init(color: .black.opacity(0.55), location: 0.76),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        }
        .onAppear {
            withAnimation(.linear(duration: 40)) { zoom = 1.08 }
        }
    }
}

/// 首屏左侧的文字：讲焦点所在的那一部
struct TVHomeStageInfo: View {
    let item: API.UpNextItemView

    @Environment(\.api) private var api

    private var isEpisode: Bool { item.kind == "tv" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleArt
            if let meta = Self.metaLine(item) {
                Text(meta)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.72))
            }
            if isEpisode {
                Text(Self.episodeLine(item))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
                    .frame(maxWidth: 980, alignment: .leading)
            }
            statusCapsule
                .padding(.top, 4)
        }
        .shadow(color: .black.opacity(0.35), radius: 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tv-home-stage")
    }

    /// 片名：有片名 Logo 就画 Logo（本地 Logo 常见 4000px 宽，按显示宽度降采样再解码），没有或加载失败回落文字
    @ViewBuilder
    private var titleArt: some View {
        if let url = api.image(item.logoUrl) {
            LazyImage(request: ImageRequest(url: url, processors: [.resize(width: 1100)])) { state in
                if let image = state.image {
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 560, maxHeight: 100, alignment: .bottomLeading)
                } else if state.error != nil {
                    titleText
                } else {
                    Color.clear
                }
            }
            .frame(height: 100, alignment: .bottomLeading)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(item.title)
            .font(.system(size: 72, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    /// 状态小标签（液态玻璃）：看了一半的给进度条与剩余时间，翻到下一集的写「下一集」与这一集多长
    @ViewBuilder
    private var statusCapsule: some View {
        let durationMinutes = item.durationMs.map { $0 / 60_000 }
        HStack(spacing: 18) {
            if item.advanced {
                Label("下一集", systemImage: "forward.end.fill")
            }
            if item.positionMs > 0, let percent = item.progressPercent {
                TVProgressStrip(value: Double(percent) / 100)
                    .frame(width: 220)
                if let remaining = Formatters.remaining(positionMs: item.positionMs, durationMs: item.durationMs) {
                    Text(remaining)
                }
            } else if let minutes = durationMinutes, minutes > 0 {
                Text(Formatters.duration(minutes: minutes))
            }
        }
        .font(.callout.weight(.semibold))
        .padding(.horizontal, 26)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }

    /// 「剧集 · 2023 · 古装 · 喜剧」：类型只取前两个，再多就挤了
    static func metaLine(_ item: API.UpNextItemView) -> String? {
        var parts: [String] = [item.kind == "tv" ? "剧集" : "电影"]
        if let year = item.year { parts.append(String(year)) }
        parts += (item.genres ?? []).prefix(2)
        return parts.joined(separator: " · ")
    }

    /// 「第 2 季 第 6 集 · 集名」：TMDB 没起名字的集（集名就是「第 6 集」「Episode 6」）不重复写
    static func episodeLine(_ item: API.UpNextItemView) -> String {
        let number = "第 \(item.seasonNumber) 季 第 \(item.episodeNumber) 集"
        guard let name = item.episodeTitle?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name.range(of: #"^(第\s*\d+\s*集|Episode\s*\d+)$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return number }
        return "\(number) · \(name)"
    }
}
