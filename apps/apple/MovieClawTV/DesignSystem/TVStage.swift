import Nuke
import NukeUI
import SwiftUI
import UIKit

// 大图区（docs/design/tvos-app.md §3.4）：首页首屏与条目详情共用这一套，两页的剧照、Logo 框、字号、
// 文字与按钮的位置完全一样（2026-10-03 用户在真机上嫌两页的 Logo、字号比例差太多）——从首页按「详情」进去，
// 大图、片名、按钮原地不动，只是下面那一行从「接下来继续」换成了选季与分集。
// - `TVStageBackdrop`：整屏背景——剧照按原始 16:9 铺满整屏、不裁，下半部分渐隐进剧照的边缘色
//   （`TVStageEdgeColor`），左侧用边缘色压暗托字；首屏底部过渡到电视底色（深炭灰），往下滚时整块跟着滚走；
// - `TVStageBlock`：首屏上半块，左下角的文字 + 一排按钮，固定高度、贴底排；
// - `TVStageInfo`：左下角的文字——片名（有 Logo 画 Logo）、一行加粗小字、一行灰色小字、简介。

/// 大图区所在列表的滚动距离（向下为正）。放在可观察对象里而不是页面的 @State：页面主体不读它，
/// 只有背景层读，滚动动画的每一帧只重算背景，不重算整页
@Observable
final class TVStageScroll {
    var offset: CGFloat = 0
}

/// 大图区背景：剧照按原始 16:9 铺满整屏（不裁），下半部分渐隐进剧照的边缘色，左侧用边缘色压暗托字
/// （2026-10-03 用户在「缩小完整显示、靠右」与「原始比例铺满」两版对比后选定后者）
struct TVStageBackdrop: View {
    /// 列表滚动这么多以内背景不动：首页 460（焦点在首屏底下那一行时的滚动量，实测约 400，大图还跟着焦点换）；
    /// 详情页 0（往下按整页滑到选集，剧照跟着内容一起滚走）
    var pinnedScroll: CGFloat = 460
    /// 超过上面那段之后，再滚这么多剧照淡完
    var fadeDistance: CGFloat = 700
    /// 边缘色在屏幕下沿之外再延伸这么高，在里面渐变到深炭灰
    static let tailHeight: CGFloat = 600
    /// 剧照地址（换一部就交叉淡入），按屏宽像素取（`ImageWidth.screen`：4K → 3840，1080p → 1920）；
    /// nil = 没有剧照（首页没有「接下来继续」、详情还没加载），只铺底色
    let url: URL?
    /// 剧照边缘色；取到之前只有电视底色
    let tint: Color?
    /// 列表滚动距离：边缘色与剧照跟着列表一起往上滚走
    let scroll: TVStageScroll
    /// 原图铺满（详情页）：剧照不渐隐、不混边缘色，只在左下角罩一团中性的黑托字，深浅按那一块的亮度定
    /// （`TVStageCornerScrim`）。混边缘色时左边和下边一圈被换成一块平涂的颜色（褐色剧照就是一片褐），
    /// 和中间的原图看得出色差（2026-10-03 用户在详情页指出）；首页下面要落卡片行，仍渐隐进边缘色。
    /// 这时最底下垫的是同一张剧照的模糊版（`TVBlurredBackdrop`，与海报墙同一套），剧照滚走后露出来
    var fullImage = false
    /// 原图铺满时垫底的模糊剧照：按 `TVMetrics.blurredBackdropWidth` 取的小图就够，模糊之后看不出清晰度
    var ambientURL: URL?
    /// 大图预告（`TVStagePreview`）讲的是哪一部：停留一会儿后剧照原地换成片段；nil = 只有剧照
    var previewKey: Int?

    /// 左下角压暗的深浅（0～1）：量出来之前按中等处理。首页、详情页一样：原先首页左侧是一层边缘色（0.9 → 0.55 → 透明），
    /// 褐色剧照左边就是一片褐、和中间原图看得出色差（用户在详情页指出），2026-10-03 一并换成中性的黑
    @State private var cornerScrim = 0.4

    private var scrollOffset: CGFloat { max(0, scroll.offset) }
    /// 剧照还在原位（列表没滚得让它跟着走开）：预告只在这时放，滚走就暂停
    private var stageInPlace: Bool { scrollOffset <= pinnedScroll + 120 }

    var body: some View {
        ZStack {
            if fullImage {
                // 原先垫的是边缘色往下渐暗，往下滑看分集、演职员时整页一块平涂的颜色，显得素；
                // 2026-10-04 用户觉得海报墙的模糊背景精致，要求详情页往下也这样
                TVBlurredBackdrop(url: ambientURL)
            } else {
                Color.tvPage
            }
            // 剧照贴着屏幕顶：压栈的详情页整体往下错了 48.5 点、背景铺到屏幕外，居中摆的话顶上会露出一条底色
            ZStack(alignment: .top) {
                if !fullImage, let tint {
                    // 边缘色垫在剧照下面，整个首屏保持同一个颜色：首屏里只有「剧照渐隐进边缘色」这一段过渡。
                    // 原先在屏高 80%～100% 再渐变到深炭灰，两段过渡之间夹着一截亮度不变的平台，平台两端
                    // 变化快慢突变，真机上看得出一条横线（2026-10-03 用户反馈、截图逐行量亮度确认）。
                    // 往深炭灰的过渡挪到屏幕下沿之外的 600 点里：只有往下看别的行、背景跟着上移时才看得到
                    tint
                        .overlay(alignment: .bottom) {
                            LinearGradient(stops: TVEasedFade.stops(color: tint, from: 0, to: 1), startPoint: .top, endPoint: .bottom)
                                .frame(height: Self.tailHeight)
                                .offset(y: Self.tailHeight)
                        }
                        .id(tint.description)
                        .transition(.opacity)
                }
                if let url, fullImage {
                    // 静止时原图不渐隐；往下滑、剧照跟着往上走时下沿慢慢渐隐进底色，不在屏幕中间露出一道硬边
                    TVStageImage(url: url, fadeFrom: 1 - min(1, scrollOffset / 500) * 0.4, scrim: cornerScrim, scrimShape: .corner,
                                 previewKey: previewKey, previewVisible: stageInPlace)
                        .id(url)
                        .transition(.opacity)
                } else if let url {
                    TVStageImage(url: url, fadeFrom: 0.4, scrim: cornerScrim, scrimShape: .leading,
                                 previewKey: previewKey, previewVisible: stageInPlace)
                        .id(url)
                        .transition(.opacity)
                }
            }
            // 先拍平成一层再整体淡出：透明度直接加在这一组上会分别套到每一层，左侧压暗那层（只有剧照那么高）
            // 叠在边缘色上就比下面单独的边缘色深一截，往下滚、背景开始变淡时剧照下沿显出一道横线（2026-10-03 截图量出 7 级亮度差）
            .compositingGroup()
            // 焦点从按钮进下面那一行时列表上滚约 400 点：这段之内背景不动（首页的大图还跟着焦点换）；
            // 再往下看别的行才跟着滚走、淡掉
            // 这一层撑满整个背景区域、剧照贴顶：二级页的背景区域比屏幕高一截，原图铺满时没有边缘色那层撑开，
            // 这一层只有剧照那么高、被居中摆放，上下各露出 24 点底色（2026-10-03 实测）
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .offset(y: -max(0, scrollOffset - pinnedScroll))
            .opacity(Double(max(0, 1 - max(0, scrollOffset - pinnedScroll) / fadeDistance)))
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .animation(.easeInOut(duration: 0.8), value: tint?.description)
        .animation(.easeInOut(duration: 0.4), value: cornerScrim)
        .ignoresSafeArea()
        .task(id: url) {
            guard let url, let strength = await TVStageCornerScrim.strength(for: url, shape: fullImage ? .corner : .leading),
                  !Task.isCancelled else { return }
            cornerScrim = strength
        }
        .accessibilityHidden(true)
    }
}

/// 一张铺满整屏的剧照：出现后 40 秒慢慢推近到 1.06 倍（Ken Burns，裁在屏幕框里），下半部分渐隐进边缘色。
/// 每换一部是一个新视图（外面 `.id(url)`），推近从头开始，不会和上一部没走完的动画叠在一起。
private struct TVStageImage: View {
    let url: URL
    /// 从屏高的哪儿开始渐隐到下沿：首页 0.4（露出底下的边缘色，卡片行落在上面）；详情页静止时 1（原图不渐隐），
    /// 往下滑时逐渐提到 0.6
    let fadeFrom: CGFloat
    /// 左下角压暗的深浅（`TVStageCornerScrim`）：同系统 Apple TV App 的详情页，只在文字和按钮所在的左下角罩一团黑、
    /// 往右上散开，不是左边整条的暗带；黑色只压暗不改色相，本来就暗的剧照几乎不加。画在渐隐之内，首页随剧照一起淡进边缘色
    let scrim: Double
    let scrimShape: TVStageScrimShape
    /// 大图预告：片段盖在剧照上（不跟着推近）、压在托字的黑之下
    var previewKey: Int?
    var previewVisible = true
    @State private var zoom: CGFloat = 1

    var body: some View {
        // 固定成屏幕大小的透明底 + 叠层画剧照，再按底的边界裁：直接对图片裁的话推近放大的部分会溢出屏幕
        Color.clear
            .frame(width: 1920, height: 1080)
            .overlay {
                LazyImage(url: url) { state in
                    if let image = state.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        // 加载中不画占位色块：上一部正在淡出，露出的是边缘色
                        Color.clear
                    }
                }
                .scaleEffect(zoom)
            }
            .overlay {
                if let previewKey {
                    TVStagePreviewLayer(key: previewKey, visible: previewVisible)
                }
            }
            .overlay {
                switch scrimShape {
                case .corner:
                    RadialGradient(stops: TVEasedFade.stops(color: .black.opacity(scrim), from: 0, to: 1),
                                   center: .bottomLeading, startRadius: 0, endRadius: 1500)
                case .leading:
                    LinearGradient(stops: TVEasedFade.stops(color: .black.opacity(scrim), from: 0.1, to: 0.65),
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .clipped()
            // 下半部分渐隐进边缘色：屏高 40% 以上保持原样，一路平滑淡到屏幕下沿，卡片行落在渐隐的部分上
            .mask {
                LinearGradient(stops: TVEasedFade.stops(color: .black, from: fadeFrom, to: 1), startPoint: .top, endPoint: .bottom)
            }
            .onAppear {
                withAnimation(.linear(duration: 40)) { zoom = TVMetrics.stageZoom }
            }
    }
}

/// 剧照上托字的那层黑的形状：
/// - `corner`：详情页，文字和按钮一直在左下角，只罩左下一团、往右上散开（同系统 Apple TV App 的详情页）；
/// - `leading`：首页，焦点进卡片行时文字块跟着滚到左上角，左下一团就托不住了（2026-10-03 亮剧照上看不清），
///   改成从左边缘往右渐隐的一整条（左 10% 满强度，屏宽 65% 处淡完）
enum TVStageScrimShape {
    case corner
    case leading
}

/// 托字那层黑的深浅：量剧照上文字会落的那一块的亮度，取偏亮的那一档（第 80 百分位）——
/// 窗户、白墙这类亮斑才是压字的，平均值会被大片暗部拉低。暗的（≤0.3）只罩 0.15 的一层，越亮罩得越深，封顶 0.65。
/// 同系统 Apple TV App：它的海报图左下本来就是留给文字的暗区，几乎看不出压暗；我们的剧照是刮来的，按图来定。结果按地址缓存。
/// 量的是同一张图的 240 宽小图（`ImageWidth.analysis`）：最后只缩成 24×24 求亮度，用不着解码整张 4K 图
@MainActor
enum TVStageCornerScrim {
    private static var cache: [String: Double] = [:]

    /// 量的是文字会落的那一块：`corner` 左 55%、下 65%；`leading` 左 55% 整列
    static func strength(for url: URL, shape: TVStageScrimShape) async -> Double? {
        let key = "\(shape)|\(url.absoluteString)"
        if let hit = cache[key] { return hit }
        guard let image = try? await ImagePipeline.shared.image(for: url.imageWidth(ImageWidth.analysis)) else { return nil }
        let top: CGFloat = shape == .corner ? 0.35 : 0
        guard let luma = await Task.detached(priority: .utility, operation: { regionLuma(of: image, top: top) }).value else { return nil }
        // 首页的文字会落在剧照不同的高度上（焦点进卡片行时滚到左上角），起码罩 0.3；详情页只在左下角，暗图几乎不加
        let floor = shape == .leading ? 0.3 : 0.15
        let strength = min(0.65, max(floor, 0.15 + (luma - 0.3) / 0.45 * 0.5))
        cache[key] = strength
        return strength
    }

    nonisolated static func regionLuma(of image: UIImage, top: CGFloat) -> Double? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        let rect = CGRect(x: 0, y: height * top, width: width * 0.55, height: height * (1 - top)).integral
        let side = 24
        guard let corner = cgImage.cropping(to: rect),
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

/// 剧照边缘色：取剧照**左边缘与下边缘**一圈的平均色——剧照渐隐进的正是这两条边，接得上才不显出边界
/// （同 iPhone 详情页的底边铺色 HeroEdgeColor 的思路，这里多一条左边）。
/// 亮度封顶 0.3：左侧压着白字，底色再亮字就读不清；本来就暗的边（夜景、黑边）保持原样。结果按地址缓存
@MainActor
enum TVStageEdgeColor {
    private static var cache: [URL: Color] = [:]

    static func color(for url: URL) async -> Color? {
        if let hit = cache[url] { return hit }
        // 取同一张图的 240 宽小图：边缘色只是缩到 16×16 求平均，不必解码整张 4K 图；与亮度分析同一个地址，只下载一次
        guard let image = try? await ImagePipeline.shared.image(for: url.imageWidth(ImageWidth.analysis)) else { return nil }
        guard let color = await Task.detached(priority: .utility, operation: { edgeColor(of: image) }).value
        else { return nil }
        cache[url] = color
        return color
    }

    /// 左边 6% 宽的竖条 + 下边 8% 高的横条，各自缩到小图求平均，再合起来
    nonisolated static func edgeColor(of image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        let strips = [
            CGRect(x: 0, y: 0, width: max(1, width * 0.06), height: height),
            CGRect(x: 0, y: height * 0.92, width: width, height: max(1, height * 0.08)),
        ]
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for rect in strips {
            guard let strip = cgImage.cropping(to: rect.integral),
                  let context = CGContext(
                      data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16 * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
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
        let edge = UIColor(red: r / count / 255, green: g / count / 255, blue: b / count / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        edge.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(1, saturation * 1.1), brightness: min(0.3, brightness))
    }
}

/// 首屏上半块：左下角的文字 + 一排按钮，贴底排（首页首屏与条目详情共用）。
/// - 首页整块的下沿固定在屏幕 y=918：按钮下沿落在 y≈888，下面那一行只露出顶上一截（卡片露出约四分之一）——
///   同 Disney+ / Netflix 首屏（2026-10-03 用户要求：视线聚焦在当前这部，往下按一下才看到整行）；
/// - 按钮离屏幕底边留足一百六十来点，焦点在按钮上时系统不会自己滚动列表；
/// - 文字贴底排：有没有 Logo、简介几行都只影响文字往上长多少，按钮与下面那一行纹丝不动
struct TVStageBlock<Info: View, Actions: View>: View {
    /// 列表内容的上沿离屏幕顶多远（列表的 `contentInsets.top`）。系统给两页的不一样：页签根页面从标签栏下方
    /// 排起（157），压栈的详情页只有 48.5——按它算整块的高度，两页的按钮才落在同一个位置
    let topInset: CGFloat
    /// 整块下沿在屏幕上的 y：首页 918（下面露卡片行）；详情页 860（下面不露行，整块靠上、顶上留白小）
    var bottom: CGFloat = 918
    @ViewBuilder let info: () -> Info
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        // 文字与按钮之间 36：文字段之间拉开了，按钮跟着拉开一档（同 Apple TV 详情页）
        VStack(alignment: .leading, spacing: 36) {
            info()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            actions()
        }
        .padding(.bottom, 30)
        .frame(height: bottom - topInset, alignment: .bottomLeading)
        .padding(.horizontal, TVMetrics.edge)
    }
}

/// 首屏左下角的文字。密度照 Disney+ / 系统 Apple TV App 的首屏（2026-10-03 用户嫌文字占比太大、海报显得小）：
/// 片名 Logo → 一行加粗小字（第几集）→ 一行灰色小字（类型年份、画质）→ 小号简介；下面是按钮。
/// 整块只占屏宽三分之一出头，剧照露得多，海报才显得大
struct TVStageInfo: View {
    let title: String
    /// 片名 Logo（原图地址）；没有或加载失败画文字
    let logoURL: URL?
    /// 第几集（排在年份类型那一行下面，降一级）
    var headline: String?
    /// 片名下的第一行（加粗主文字）：年份、类型、片长……
    var meta: String?
    /// 跟在第一行后面的画质、音频小标签（4K、DOLBY VISION、DOLBY ATMOS……，详情页用；首页的数据里没有规格）
    var badges: [TVMediaBadge] = []
    var overview: String?
    /// 简介最多几行：首页两行（下面还压着一行卡片），详情页三行
    var overviewLines = 2
    /// 片名 Logo 的最大宽高：首页与详情页一致 860×200（2026-10-04 用户要求统一成详情页的大小——
    /// 从首页点进详情，同一个 Logo 不再突然变大一圈）
    var logoSize = CGSize(width: 860, height: 200)

    // 排法（首页、详情页同一套，2026-10-03 用户定）：片名 → 年份、类型、片长（加粗主文字，后面跟规格小标签）
    // → 第几集（降一级）→ 简介。段距照系统 Apple TV App 详情页量出来的节奏：组内紧、组间松约 2～3 倍——
    // Logo ↓28 年份规格 ↓14 第几集（这两行一组）↓20 简介（行距 +7：中文字面满，比 Apple 的英文再松一点）

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 片名 Logo 是首屏的视觉主角之一（同 Disney+ / Apple TV App），给足尺寸：最高 200、最宽 860（`logoSize`）。
            // 64 点高时横长的中文字标只剩一条细线（2026-10-03 用户在真机上嫌小）
            TVTitleArt(title: title, logoURL: logoURL, size: logoSize)
                .padding(.bottom, 28)
            metaRow
                .padding(.bottom, headline == nil ? 20 : 14)
            if let headline {
                Text(headline)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .padding(.bottom, 20)
            }
            if let overview = overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty {
                TVInfoText.overview(overview, lines: overviewLines)
            }
        }
        // 剧照的左侧压暗减弱了，靠字自己的阴影托住
        .shadow(color: .black.opacity(0.55), radius: 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// 年份、类型、片长 + 画质、音频小标签
    @ViewBuilder
    private var metaRow: some View {
            if (meta?.isEmpty == false) || !badges.isEmpty {
                HStack(spacing: 12) {
                    if let meta, !meta.isEmpty {
                        TVInfoText.meta(meta)
                            .padding(.trailing, 4)
                    }
                    ForEach(badges, id: \.self) { badge in
                        TVMediaBadgeView(badge: badge)
                    }
                }
            }
    }

    /// 「第 2 季 第 6 集 · 集名」：TMDB 没起名字的集（集名就是「第 6 集」「Episode 6」）不重复写
    static func episodeLine(season: Int, episode: Int, name: String?) -> String {
        let number = "第 \(season) 季 第 \(episode) 集"
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              name.range(of: #"^(第\s*\d+\s*集|Episode\s*\d+)$"#, options: [.regularExpression, .caseInsensitive]) == nil
        else { return number }
        return "\(number) · \(name)"
    }
}

/// 年份类型那一行与简介的字：大图区（首页首屏、详情页）和首页海报行下方的说明共用这一套。
/// 海报行原先另写了一套（65% 亮度的灰字、铺 1100 宽、行距更紧），和详情页放在一起看不是一套字
/// （2026-10-04 用户要求统一成详情页的大字）；以后调字号只改这里
enum TVInfoText {
    /// 年份、类型、片长那一行：27 号半粗白字
    static func meta(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 27, weight: .semibold))
            .lineLimit(1)
    }

    /// 简介：25 号，行距 +7（中文字面满，比 Apple 的英文再松一点），82% 亮度，最宽 720
    static func overview(_ text: String, lines: Int) -> some View {
        Text(text)
            .font(.system(size: 25))
            .lineSpacing(7)
            .foregroundStyle(.white.opacity(0.82))
            .lineLimit(lines)
            .frame(maxWidth: 720, alignment: .leading)
    }
}

/// 画质、音频小标签（照系统 Apple TV App 详情页那排小图：分辨率实心，HDR、音频描边）。
/// 都是自己画的文字标签：Apple 的「4K」「CC」本来就是文字标签；「Dolby Vision」「Dolby Atmos」的双 D 标志是杜比商标、
/// 要签授权才能用，这里只写字（2026-10-03 与用户确认）
struct TVMediaBadge: Hashable {
    enum Style: Hashable {
        /// 实心浅底黑字：分辨率（4K、HD）
        case filled
        /// 描边白字：HDR、音频
        case outlined
    }

    let text: String
    let style: Style
}

struct TVMediaBadgeView: View {
    let badge: TVMediaBadge

    var body: some View {
        Text(badge.text)
            .font(.system(size: 18, weight: .bold))
            .fontWidth(.condensed)
            .tracking(0.6)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 30)
            .foregroundStyle(badge.style == .filled ? Color.black : Color.white.opacity(0.92))
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(badge.style == .filled ? Color.white.opacity(0.9) : Color.clear)
            }
            .overlay {
                if badge.style == .outlined {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.8), lineWidth: 2)
                }
            }
            .accessibilityLabel(badge.text)
    }
}

/// 片名：有片名 Logo 就画 Logo（按 Logo 框宽取 `w`；本地 Logo 常见 4000px 宽，旧服务器不认 `w` 会回原图，
/// 所以仍按显示宽度降采样再解码），没有或加载失败回落文字。
/// 大图区左下角（贴左下对齐）与详情页往下滑到选集时的顶部（居中）共用
struct TVTitleArt: View {
    let title: String
    let logoURL: URL?
    /// Logo 的最大宽高
    let size: CGSize
    var alignment: Alignment = .bottomLeading
    /// 没有 Logo 时文字片名的字号
    var textSize: CGFloat = 64

    var body: some View {
        if let logoURL {
            // Logo 等比装进框里，有效宽最多就是框宽
            LazyImage(request: ImageRequest(url: logoURL.imageWidth(ImageWidth.points(size.width)),
                                            processors: [.resize(width: size.width * 1.8)])) { state in
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
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// 平滑的渐隐：在 `from`～`to` 之间按 S 形曲线（smootherstep）从不透明过渡到透明，前后都是平的。
///
/// 只给两三个点的线性渐变，每个折点处亮度变化的快慢会突变，人眼会在那里看出一道横线（马赫带）；
/// 大图底边是浅色剧照渐隐进深色底，尤其明显（2026-10-03 用户在真机上看出来）。这里在区间里取 12 个点，
/// 两端斜率为零，看不出起止
enum TVEasedFade {
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

/// 模糊剧照背景：剧照放大模糊、压到 45%，再从上到下压一层渐暗的黑（上 20% → 下 75%），换图时交叉淡入。
/// 海报墙（焦点那一部）与详情页往下滑之后（这一部自己）共用：同一个底色语言，往哪页走都是一个调子
struct TVBlurredBackdrop: View {
    /// 剧照地址（按 `TVMetrics.blurredBackdropWidth` 取的小图）；nil 只铺电视底色与渐暗
    let url: URL?

    var body: some View {
        ZStack {
            Color.tvPage
            if let url {
                // 图片铺在占满给定区域的底板上、不参与排版：直接放进 ZStack 时按「填满」铺开的图会按自己的比例撑大，
                // 竖版海报（影人页）铺满宽度后比屏幕高一大截，把整个 ZStack 撑大、内容被挤到屏幕外
                // （2026-10-04 真机：影人页左边、顶上各露一条底下的页面）
                Color.clear
                    .overlay {
                        RemoteImage(url: url, placeholderText: "")
                            .blur(radius: 50)
                            .opacity(0.45)
                    }
                    .id(url)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .accessibilityHidden(true)
    }
}
