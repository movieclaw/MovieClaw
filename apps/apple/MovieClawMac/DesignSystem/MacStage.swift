import AppKit
import Nuke
import NukeUI
import SwiftUI

// 大图区（docs/design/macos-app.md §4.2）：首页首屏与条目详情共用。思路同 Apple TV 版（docs/design/tvos-app.md §3.4），
// 尺寸按 Mac 窗口重排：
// - `MacStageBackdrop`：剧照铺满大图区（窗口多宽铺多宽，按 16:9 顶对齐裁剪），往下渐隐进剧照的边缘色、
//   左下角罩一团中性的黑托字；剧照延伸到侧边栏底下（`backgroundExtensionEffect`，同 Apple Music 的专辑页头图）；
// - `MacStageInfo`：左下角的文字——片名（有 Logo 画 Logo）、年份类型片长 + 画质小标签、第几集、简介；
// - `MacTitleArt`、`MacMediaBadge`、`MacBlurredBackdrop`：共用的小件。

/// 大图区的高度：随窗口宽度走，16:9 剧照露出上面约 3/4，太矮的窗口也至少 420、太高也不超过 760
enum MacStageLayout {
    static func height(for width: CGFloat, windowHeight: CGFloat) -> CGFloat {
        min(max(width * 9 / 16 * 0.78, 420), min(760, max(420, windowHeight * 0.82)))
    }
}

/// 大图区背景：剧照（换一部交叉淡入、40 秒慢推近）→ 下沿渐隐进边缘色 → 左下角托字的黑
struct MacStageBackdrop: View {
    let url: URL?
    /// 剧照边缘色；取到之前用深炭灰
    let tint: Color?
    /// 渐隐从大图区高度的哪儿开始：首页 0.6（下面接卡片行）；详情页 0.62
    var fadeFrom: CGFloat = 0.55
    /// 剧照下面垫不垫底色：首页垫边缘色；详情页不垫，剧照直接淡进页面底下那层模糊剧照
    var showsBase = true

    @State private var scrim = 0.45

    var body: some View {
        ZStack(alignment: .top) {
            if showsBase {
                (tint ?? Color.macPage)
                    .animation(.easeInOut(duration: 0.8), value: tint?.description)
            }
            if let url {
                MacStageImage(url: url, fadeFrom: fadeFrom, scrim: scrim)
                    .id(url)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .animation(.easeInOut(duration: 0.4), value: scrim)
        .task(id: url) {
            guard let url, let strength = await MacStageScrim.strength(for: url), !Task.isCancelled else { return }
            scrim = strength
        }
        .accessibilityHidden(true)
    }
}

/// 一张铺满大图区的剧照：出现后 40 秒慢慢推近到 1.05 倍，下半部分渐隐、左下角罩一团黑托字
private struct MacStageImage: View {
    let url: URL
    let fadeFrom: CGFloat
    let scrim: Double
    @State private var zoom: CGFloat = 1

    var body: some View {
        Color.clear
            .overlay {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.clear
                    }
                }
                .scaleEffect(zoom, anchor: .top)
            }
            .overlay {
                // 托字：左下一团中性的黑往右上散开（同系统 Apple TV App 的详情页），再从左往右压一条，文字块高的时候也托得住
                ZStack {
                    RadialGradient(stops: MacEasedFade.stops(color: .black.opacity(scrim), from: 0, to: 1),
                                   center: .bottomLeading, startRadius: 0, endRadius: 1100)
                    LinearGradient(stops: MacEasedFade.stops(color: .black.opacity(scrim * 0.6), from: 0.05, to: 0.6),
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .clipped()
            .mask {
                LinearGradient(stops: MacEasedFade.stops(color: .black, from: fadeFrom, to: 1), startPoint: .top, endPoint: .bottom)
            }
            .onAppear {
                withAnimation(.linear(duration: 40)) { zoom = 1.05 }
            }
    }
}

/// 托字那层黑的深浅：量剧照左下那块的亮度（第 80 百分位），暗图只罩一层薄的，越亮越深，封顶 0.7。结果按地址缓存
@MainActor
enum MacStageScrim {
    private static var cache: [URL: Double] = [:]

    static func strength(for url: URL) async -> Double? {
        if let hit = cache[url] { return hit }
        guard let image = try? await ImagePipeline.shared.image(for: url.imageWidth(ImageWidth.analysis)),
              let cg = image.cgImage else { return nil }
        guard let luma = await Task.detached(priority: .utility, operation: { regionLuma(of: cg) }).value else { return nil }
        let strength = min(0.7, max(0.3, 0.2 + (luma - 0.3) / 0.45 * 0.5))
        cache[url] = strength
        return strength
    }

    /// 左 55%、下 65% 那一块缩到 24×24 求亮度，取第 80 百分位（亮斑才是压字的）
    nonisolated static func regionLuma(of image: CGImage) -> Double? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rect = CGRect(x: 0, y: height * 0.35, width: width * 0.55, height: height * 0.65).integral
        let side = 24
        guard let corner = image.cropping(to: rect),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(corner, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.bindMemory(to: UInt8.self, capacity: side * side * 4) else { return nil }
        var lumas: [Double] = []
        for index in 0 ..< side * side {
            let r = Double(data[index * 4]), g = Double(data[index * 4 + 1]), b = Double(data[index * 4 + 2])
            lumas.append((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255)
        }
        lumas.sort()
        return lumas[Int(Double(lumas.count - 1) * 0.8)]
    }
}

/// 剧照边缘色：左边缘与下边缘一圈的平均色（剧照渐隐进的正是这两条边，接得上才不显出边界），亮度封顶 0.3 保证白字可读。
/// 同 Apple TV 版 `TVStageEdgeColor`。结果按地址缓存
@MainActor
enum MacStageEdgeColor {
    private static var cache: [URL: Color] = [:]

    static func color(for url: URL) async -> Color? {
        if let hit = cache[url] { return hit }
        guard let image = try? await ImagePipeline.shared.image(for: url.imageWidth(ImageWidth.analysis)),
              let cg = image.cgImage else { return nil }
        guard let rgb = await Task.detached(priority: .utility, operation: { edgeRGB(of: cg) }).value else { return nil }
        let edge = NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        edge.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let color = Color(hue: hue, saturation: min(1, saturation * 1.1), brightness: min(0.3, brightness))
        cache[url] = color
        return color
    }

    nonisolated static func edgeRGB(of image: CGImage) -> (CGFloat, CGFloat, CGFloat)? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let strips = [
            CGRect(x: 0, y: 0, width: max(1, width * 0.06), height: height),
            CGRect(x: 0, y: height * 0.92, width: width, height: max(1, height * 0.08)),
        ]
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for rect in strips {
            guard let strip = image.cropping(to: rect.integral),
                  let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16 * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            context.interpolationQuality = .medium
            context.draw(strip, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            guard let data = context.data?.bindMemory(to: UInt8.self, capacity: 16 * 16 * 4) else { continue }
            for index in 0 ..< 16 * 16 {
                r += Double(data[index * 4]); g += Double(data[index * 4 + 1]); b += Double(data[index * 4 + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (r / count / 255, g / count / 255, b / count / 255)
    }
}

/// 大图区左下角的文字：片名 Logo → 年份 · 类型 · 片长 + 画质小标签 → 第几集 → 简介。
/// 段距照 Apple TV 版（组内紧、组间松）：Logo ↓18 年份规格 ↓8 第几集 ↓12 简介
struct MacStageInfo: View {
    let title: String
    let logoURL: URL?
    var headline: String?
    var meta: String?
    var badges: [MacMediaBadge] = []
    var overview: String?
    var overviewLines = 3
    var logoSize = CGSize(width: 460, height: 120)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacTitleArt(title: title, logoURL: logoURL, size: logoSize)
                .padding(.bottom, 18)
            if (meta?.isEmpty == false) || !badges.isEmpty {
                HStack(spacing: 8) {
                    if let meta, !meta.isEmpty {
                        Text(meta)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .padding(.trailing, 2)
                    }
                    ForEach(badges, id: \.self) { MacMediaBadgeView(badge: $0) }
                }
                .padding(.bottom, headline == nil ? 12 : 8)
            }
            if let headline {
                Text(headline)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.bottom, 12)
            }
            if let overview = overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(overviewLines)
                    .frame(maxWidth: 560, alignment: .leading)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 「第 2 季 第 6 集 · 集名」：TMDB 没起名字的集（集名就是「第 6 集」「Episode 6」）不重复写
    static func episodeLine(season: Int, episode: Int, name: String?) -> String {
        let number = season == 0 ? "特别篇 第 \(episode) 集" : "第 \(season) 季 第 \(episode) 集"
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name.range(of: #"^(第\s*\d+\s*集|Episode\s*\d+)$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return number }
        return "\(number) · \(name)"
    }
}

/// 画质、音频小标签（同 Apple TV 版）：分辨率实心，HDR、音频描边。只写字——杜比的双 D 标志要授权
struct MacMediaBadge: Hashable {
    enum Style: Hashable { case filled, outlined }
    let text: String
    let style: Style

    /// 在位文件里各挑最好的一档：分辨率 8K / 4K / HD；HDR 杜比视界 > HDR10+ > HDR10 > HLG > HDR；
    /// 音频杜比全景声 > DTS:X > 7.1 > 5.1
    static func best(for detail: API.LibraryItemDetailView) -> [MacMediaBadge] {
        let sources = detail.files.filter { $0.state == "in_place" }
        var badges: [MacMediaBadge] = []
        if let best = sources.compactMap({ $0.resolution.flatMap(resolutionHeight) }).max() {
            switch best {
            case 4320...: badges.append(.init(text: "8K", style: .filled))
            case 2160...: badges.append(.init(text: "4K", style: .filled))
            case 720...: badges.append(.init(text: "HD", style: .filled))
            default: break
            }
        }
        let hdrPriority = ["Dolby Vision", "HDR10+", "HDR10", "HLG", "HDR"]
        if let hdr = sources.compactMap(\.hdr).min(by: { (hdrPriority.firstIndex(of: $0) ?? 99) < (hdrPriority.firstIndex(of: $1) ?? 99) }) {
            badges.append(.init(text: hdr == "Dolby Vision" ? "DOLBY VISION" : hdr.uppercased(), style: .outlined))
        }
        let audio = sources.flatMap { $0.audioStreams ?? [] }
        let described = audio.map { [$0.profile, $0.title, $0.codec].compactMap { $0 }.joined(separator: " ").lowercased() }
        if described.contains(where: { $0.contains("atmos") }) {
            badges.append(.init(text: "DOLBY ATMOS", style: .outlined))
        } else if described.contains(where: { $0.contains("dts:x") || $0.contains("dts-x") }) {
            badges.append(.init(text: "DTS:X", style: .outlined))
        } else if let channels = audio.compactMap(\.channels).max(), channels >= 6 {
            badges.append(.init(text: channels >= 8 ? "7.1" : "5.1", style: .outlined))
        }
        return badges
    }

    /// 「2160p」「4k」「1080」→ 画面高度
    static func resolutionHeight(_ raw: String) -> Int? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "8k": return 4320
        case "4k", "uhd": return 2160
        case "2k": return 1440
        default: return Int(normalized.filter(\.isNumber))
        }
    }
}

struct MacMediaBadgeView: View {
    let badge: MacMediaBadge

    var body: some View {
        Text(badge.text)
            .font(.system(size: 10, weight: .bold))
            .fontWidth(.condensed)
            .tracking(0.4)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .foregroundStyle(badge.style == .filled ? Color.black : Color.white.opacity(0.92))
            .background {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(badge.style == .filled ? Color.white.opacity(0.9) : Color.clear)
            }
            .overlay {
                if badge.style == .outlined {
                    RoundedRectangle(cornerRadius: 3.5).strokeBorder(.white.opacity(0.8), lineWidth: 1.2)
                }
            }
            .accessibilityLabel(badge.text)
    }
}

/// 片名：有片名 Logo 就画 Logo（按框宽取图、降采样解码），没有或加载失败回落文字
struct MacTitleArt: View {
    let title: String
    let logoURL: URL?
    let size: CGSize
    var alignment: Alignment = .bottomLeading
    var textSize: CGFloat = 40

    var body: some View {
        if let logoURL {
            LazyImage(request: ImageRequest(url: logoURL.imageWidth(ImageWidth.points(size.width)),
                                            processors: [.resize(width: size.width * 2)])) { state in
                if let image = state.image {
                    image.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: size.width, maxHeight: size.height, alignment: alignment)
                        .accessibilityLabel(title)
                } else if state.error != nil {
                    titleText
                } else {
                    Color.clear
                }
            }
            .frame(height: size.height, alignment: alignment)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: textSize, weight: .bold))
            .lineLimit(2)
            .minimumScaleFactor(0.6)
    }
}

/// 平滑的渐隐：在 from～to 之间按 S 形曲线（smootherstep）过渡，两端斜率为零，看不出起止（避免马赫带）
enum MacEasedFade {
    static func stops(color: Color, from: CGFloat, to: CGFloat, steps: Int = 12) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = [.init(color: color, location: 0)]
        for index in 0 ... steps {
            let t = CGFloat(index) / CGFloat(steps)
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            stops.append(.init(color: color.opacity(1 - eased), location: from + (to - from) * t))
        }
        if to < 1 { stops.append(.init(color: color.opacity(0), location: 1)) }
        return stops
    }
}

/// 模糊剧照背景：放大模糊、压到 45%，再从上往下压暗；换图时交叉淡入。海报墙、影人页、详情页下半截共用
struct MacBlurredBackdrop: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.macPage
            if let url {
                Color.clear
                    .overlay {
                        RemoteImage(url: url, placeholderText: "")
                            .blur(radius: 60)
                            .opacity(0.45)
                    }
                    .clipped()
                    .id(url)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .accessibilityHidden(true)
    }
}
