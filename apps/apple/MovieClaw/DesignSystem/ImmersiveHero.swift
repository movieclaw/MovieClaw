import Nuke
import SwiftUI
import UIKit

// 沉浸式大图（Hero）的共用部件：订阅首页与发现页同一套轮播与图片处理机制，只有文字与按钮各自排。
//
// - `ImmersiveHeroBackdrop`：剧照层——慢速推近（Ken Burns）、上滑视差下沉、下半部压暗托字、
//   底部渐隐进页面氛围色、顶部压暗托住状态栏与顶栏；
// - `immersiveHeroRotation`：轮播计时——每张停留固定时长，指示器当前那格按时长填满，
//   手动切换重新计时，退到后台不推进；
// - `ImmersiveHeroIndicator`：指示器——当前格是会填满的长胶囊，其余是可点的小圆点；
// - `ImmersiveHeroAmbient`：页面氛围底色（取色 `ImmersiveHeroAmbientColor` 与 Apple TV 共用，在 Shared/DesignSystem）；
// - `ImmersiveHeroScroll`：页面滚动距离，只给 Hero 与氛围底读，滚动时不重算整页。

/// 页面的连续滚动距离（向上为正）。放在可观察对象里而不是页面的 @State：
/// 页面主体不读它，只有 Hero（视差、淡出）与氛围底（随滚动退淡）读，滚动时只重算这两块。
@Observable
final class ImmersiveHeroScroll {
    var offset: CGFloat = 0
}

// MARK: - 下拉拉伸

extension View {
    /// 下拉时拉伸顶部大图（同 Apple Music 专辑页 / 艺人页）：大图顶边被拉离屏幕顶边多少，
    /// 就以底边为锚点等比放大多少，顶边始终贴住屏幕顶，不露出一截页面底色。
    ///
    /// - 用大图自己的位置算下拉量，而不是 `contentOffset`：刷新转圈期间系统把转圈的高度加进了
    ///   contentInset，按 contentOffset + contentInsets 算是 0，内容却还被往下推着；
    /// - 量的是离屏幕顶边（全局坐标）而不是离滚动视图顶边：各页 ScrollView 的布局框起点不一样
    ///   （发现详情页从导航栏下沿算起，静止时大图在它的坐标里是 -122），屏幕顶边才是统一的基准。
    ///   前提是页面全屏显示——这几页都只在主标签页的导航栈里推入，不会出现在弹层里；
    /// - 用 `visualEffect` 只改渲染不改布局：滚动时不重算页面，布局尺寸（底边取色用的显示比例）也不变；
    ///   等比放大而不是拉高边框，底边露出的画面不变，与下面页面底色的交界处对得上；
    /// - 只处理下拉（大图顶边低于屏幕顶边），上滑时原样不动；
    /// - 系统的刷新转圈画在滚动内容后面，原先露在底色那一截里，现在会被拉伸的大图盖住，
    ///   所以同时把它提到内容上层（见 `RefreshControlAboveContent`）。
    /// 只挂在静止时顶边贴住屏幕物理顶边的全出血大图上。
    func stretchesOnPull() -> some View {
        background { RefreshControlAboveContent().accessibilityHidden(true) }
            .visualEffect { content, proxy in
                let pull = max(0, proxy.frame(in: .global).minY)
                return content.scaleEffect(1 + pull / max(1, proxy.size.height), anchor: .bottom)
            }
    }
}

extension View {
    /// 轮播首尾两张被拉过头时横向拉伸剧照（同下拉拉伸的思路），边缘不露出页面底色。
    ///
    /// 分页轮播在第一张再往右拖、最后一张再往左拖时会橡皮筋回弹，整页被拉离屏幕边缘，
    /// 空出来的那条原先露着页面氛围底色。静止时每页左边缘贴住屏幕左边缘（轮播铺满整屏宽），
    /// 所以第一张的 minX > 0、最后一张的 minX < 0 就是拉过头的距离；中间几张左右滑时两侧都有相邻页盖着，不处理。
    /// 以另一侧的底角为锚点等比放大：底边不动（与下面的渐隐、页面底色对得上），多出来的高度往屏幕顶边之外长。
    func stretchesOnEdgeOverscroll(first: Bool, last: Bool) -> some View {
        visualEffect { content, proxy in
            let minX = proxy.frame(in: .global).minX
            let width = max(1, proxy.size.width)
            let overscroll = first && minX > 0 ? minX : (last && minX < 0 ? -minX : 0)
            return content.scaleEffect(1 + overscroll / width, anchor: minX > 0 ? .bottomTrailing : .bottomLeading)
        }
    }
}

/// 把所在纵向滚动视图的下拉刷新转圈（`.refreshable` 装上的 UIRefreshControl）提到滚动内容上层。
///
/// UIKit 把转圈插在滚动视图最底层，平时靠内容被拉下后露出的空白看见它；顶部大图下拉拉伸后
/// 把这块空白铺满，转圈就被压在图下面，用户看不到「正在刷新」。这里沿父视图往上找到带刷新控件的
/// 滚动视图（跳过轮播自己的横向分页滚动视图），调高转圈图层的 zPosition：只改绘制层级，
/// 不改视图顺序，点击命中与系统的下拉手势都不受影响。
/// 转圈落在剧照上，系统默认的半透明灰在亮画面（浪花、天空）上几乎看不见，改成白色加一圈淡阴影。
private struct RefreshControlAboveContent: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) {}

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            raise()
            // `.refreshable` 的控件可能比这里晚一拍装上，下一轮再补一次
            DispatchQueue.main.async { [weak self] in self?.raise() }
        }

        private func raise() {
            var view = superview
            while let current = view {
                if let control = (current as? UIScrollView)?.refreshControl {
                    control.layer.zPosition = 1
                    control.tintColor = .white
                    control.layer.shadowColor = UIColor.black.cgColor
                    control.layer.shadowOpacity = 0.45
                    control.layer.shadowRadius = 4
                    control.layer.shadowOffset = .zero
                    return
                }
                view = current.superview
            }
        }
    }
}

/// 沉浸 Hero 的剧照层。`active` 为当前正在展示的这张（切到它时从头推近），
/// `scrollOffset` 驱动视差（内容上滑 1 倍，画面只跟 0.6 倍）。
///
/// 下拉拉伸：剧照放大时要往上长出轮播页之外，而分页 TabView 会把页外的部分裁掉，
/// 所以轮播整体向上多占 `pullReserve`（在屏幕顶边之外，平时看不见），剧照只占每页底部
/// `height` 那一截，下拉时往上长进这块预留区（见 `stretchesOnPull`）。
struct ImmersiveHeroBackdrop: View {
    /// 轮播向屏幕顶边之外多占的高度：橡皮筋阻尼下手指拖满整屏也只拉下三百来点，留足余量
    static let pullReserve: CGFloat = 480

    let url: URL?
    let active: Bool
    let scrollOffset: CGFloat
    /// 剧照显示高度（即 Hero 高度）；所在的页比它高出 `pullReserve`，剧照贴页底
    let height: CGFloat
    /// 是不是轮播的第一张 / 最后一张：只有它们会被拉过头，见 `stretchesOnEdgeOverscroll`
    let isFirst: Bool
    let isLast: Bool

    /// 慢速推近：切到这一张时从 1 开始，12 秒推到 1.1
    @State private var zoom: CGFloat = 1
    /// 推近是否已经起过步（页签切回时不从头再来，见下面 onChange）
    @State private var zoomStarted = false

    var body: some View {
        Color.clear
            .overlay {
                RemoteImage(url: url)
                    .modifier(KenBurnsScale(zoom: zoom))
            }
            // 下半部压暗托住文字。必须和剧照一起进下面的渐隐遮罩：压暗层若单独叠在遮罩外，
            // Hero 底边会比下面的氛围色暗一截，切出一道横线
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: UnitPoint(x: 0.5, y: 0.36), endPoint: .bottom)
            }
            .clipped()
            // 视差：内容上滑 1 倍，画面只跟 0.6 倍（相对下沉 0.4），景深感
            .offset(y: max(0, scrollOffset) * 0.4)
            // 底部渐隐进页面氛围色，而不是切一刀黑边
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.56),
                .init(color: .black.opacity(0.6), location: 0.8),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            // 顶部压暗托住状态栏、大标题与工具栏（Hero 顶到屏幕物理顶边，这里没有接缝问题）
            .overlay {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.26))
            }
            .frame(height: height)
            .stretchesOnPull()
            .stretchesOnEdgeOverscroll(first: isFirst, last: isLast)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .onChange(of: active, initial: true) { old, isActive in
                // 页签切走再切回时，initial 这一次会随页面重新出现再调一遍（新旧值相同）。
                // 那不是换张：推近接着走，从 1 重来会让画面猛地缩回去，还会撞上没走完的上一段（见 KenBurnsScale）
                if zoomStarted, old == isActive { return }
                zoomStarted = true
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { zoom = 1 }
                guard isActive else { return }
                withAnimation(.linear(duration: 12)) { zoom = 1.1 }
            }
    }
}

/// 推近的缩放倍数，逐帧兜底不低于 1。
///
/// iOS 26 上，上面「无动画重置为 1、再 12 秒推到 1.1」若赶上上一段推近还没走完（轮播页码被来回拨一下、
/// 手动快速左右滑、刚启动就切走页签再切回），没走完的那截不会被取消，而是继续叠在新值上：画面实际倍数
/// 跌到 1 以下（真机实测低到约 0.84，几秒后才回升），剧照缩进框里，顶上露出一条氛围底色
/// （底下那截被渐隐遮罩盖住看不出）。iOS 27 模拟器上不叠加、复现不出，别据此删掉兜底。
/// 系统的 scaleEffect 只拿到目标值、管不了中间帧，所以做成可动画修饰器——动画每一帧都带着
/// 插值后的倍数调用 body，在这里截断。
private struct KenBurnsScale: ViewModifier, Animatable {
    var zoom: CGFloat

    nonisolated var animatableData: CGFloat {
        get { zoom }
        set { zoom = newValue }
    }

    func body(content: Content) -> some View {
        content.scaleEffect(max(1, zoom))
    }
}

/// 轮播指示器：当前格是按 `fill`（0...1）填满的长胶囊，看得出「还有多久换下一张」；其余是可点的小圆点
struct ImmersiveHeroIndicator: View {
    let count: Int
    @Binding var index: Int
    let fill: CGFloat
    /// 小圆点的读屏标签（「切换到《片名》」）
    let label: (Int) -> String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { offset in
                if offset == index {
                    Capsule()
                        .fill(Color.white.opacity(0.26))
                        .frame(width: 26, height: 5)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.95)).frame(width: 26 * fill)
                        }
                        .clipShape(.capsule)
                } else {
                    Capsule()
                        .fill(Color.white.opacity(0.34))
                        .frame(width: 5, height: 5)
                        .contentShape(.rect.inset(by: -8))
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.6)) { index = offset } }
                        .accessibilityLabel(label(offset))
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: index)
    }
}

extension View {
    /// 轮播计时：每张停留 `interval` 秒，期间把 `fill` 线性推到 1，然后切下一张；
    /// 手动切换（index 变了）重新计时，退到后台不推进，张数变少时把越界的 index 拉回 0
    func immersiveHeroRotation(index: Binding<Int>, count: Int, fill: Binding<CGFloat>, interval: Double) -> some View {
        modifier(ImmersiveHeroRotation(index: index, count: count, fill: fill, interval: interval))
    }
}

private struct ImmersiveHeroRotation: ViewModifier {
    @Binding var index: Int
    let count: Int
    @Binding var fill: CGFloat
    let interval: Double

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: "\(index)-\(scenePhase == .active)-\(count)") {
                // index 作为任务标识：手动切换即重新计时；先无动画归零、让出一帧，再按轮播周期线性填满
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { fill = 0 }
                guard count > 1, scenePhase == .active else { return }
                await Task.yield()
                withAnimation(.linear(duration: interval)) { fill = 1 }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.8)) { index = (index + 1) % count }
            }
            .onChange(of: count) { _, newCount in
                if index >= newCount { index = 0 }
            }
    }
}

/// 页面底色：纯黑之上叠一层当前 Hero 剧照的主色，从顶部向下渐隐（Apple TV / Apple Music 的做法）。
///
/// 剧照底部渐隐进这层颜色，Hero 与下面的内容之间没有硬边；换下一张时颜色 1.2 秒交叉淡入。
/// 列表往下滚时整体退淡，不让下半页一直泡在颜色里。
struct ImmersiveHeroAmbient: View {
    let tint: Color?
    /// 列表滚动距离：滚得越深颜色越淡
    let scrollOffset: CGFloat

    var body: some View {
        ZStack {
            Theme.background
            if let tint {
                LinearGradient(stops: [
                    .init(color: tint.opacity(0.85), location: 0),
                    .init(color: tint.opacity(0.5), location: 0.42),
                    .init(color: tint.opacity(0.14), location: 0.72),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .id(tint.description)
                .transition(.opacity)
                .opacity(Double(max(0.35, 1 - max(0, scrollOffset) / 900)))
            }
        }
        .animation(.easeInOut(duration: 1.2), value: tint?.description)
        .ignoresSafeArea()
    }
}

// MARK: - 单部作品详情页：底边铺色（同 Apple Music 专辑页）

/// 详情页的页面底色：取顶部大图**屏幕上露出部分的底边**那一条的平均色，大图底部渐变进这个颜色，
/// 下面整页铺满（同 Apple Music 专辑页，2026-09-27 用户要求）。单部作品的页面不轮播，整页变色不晃眼；
/// 首页 / 发现页的轮播 Hero 仍用 `ImmersiveHeroAmbient`（主色、只铺上半截）。
///
/// - 按显示方式算露出区域：大图是「等比填满、居中裁切」，横版剧照在竖向大区域里左右被裁，
///   只有海报时上下被裁——取的是裁切后那块画面的底边，而不是原图的底边，交界处才对得上；
/// - 色相取原样、饱和度略提，亮度封顶 0.34：详情页一屏全是白字与浅灰小字（音轨、字幕这些标签），
///   底色再亮小字就读不清（0.42 时底边偏白的剧照铺出来的灰紫已经吃力）；
///   本来就暗的底边（夜景、黑边）保持原样，页面就是近黑；
/// - 结果按「地址 + 显示比例」缓存，返回同一部作品不再计算。
enum HeroEdgeColor {
    @MainActor private static var cache: [String: Color] = [:]

    /// `containerAspect` 为大图显示区域的宽 / 高
    @MainActor
    static func color(for url: URL, containerAspect: CGFloat) async -> Color? {
        guard containerAspect > 0 else { return nil }
        let key = "\(url.absoluteString)#\(Int((containerAspect * 100).rounded()))"
        if let hit = cache[key] { return hit }
        // 与大图显示同一个地址：命中 Nuke 的内存 / 磁盘缓存，不会重复下载
        guard let image = try? await ImagePipeline.shared.image(for: url) else { return nil }
        guard let color = await Task.detached(priority: .utility, operation: { pageColor(of: image, containerAspect: containerAspect) }).value
        else { return nil }
        cache[key] = color
        return color
    }

    /// 露出区域最底下 6% 那一条的平均色，换算成页面底色
    nonisolated static func pageColor(of image: UIImage, containerAspect: CGFloat) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width), height = CGFloat(cgImage.height)
        guard width > 0, height > 0 else { return nil }
        // 等比填满、居中裁切后露出的那块（像素坐标，原点在左上）
        let visible: CGRect
        if width / height > containerAspect {
            let shown = height * containerAspect
            visible = CGRect(x: (width - shown) / 2, y: 0, width: shown, height: height)
        } else {
            let shown = width / containerAspect
            visible = CGRect(x: 0, y: (height - shown) / 2, width: width, height: shown)
        }
        let bandHeight = max(1, visible.height * 0.06)
        let band = CGRect(x: visible.minX, y: visible.maxY - bandHeight, width: visible.width, height: bandHeight)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !band.isEmpty, let strip = cgImage.cropping(to: band) else { return nil }

        let columns = 24, rows = 4
        guard let context = CGContext(
            data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: columns * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(strip, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let data = context.data?.bindMemory(to: UInt8.self, capacity: columns * rows * 4) else { return nil }
        var r = 0.0, g = 0.0, b = 0.0
        for index in 0 ..< columns * rows {
            r += Double(data[index * 4]); g += Double(data[index * 4 + 1]); b += Double(data[index * 4 + 2])
        }
        let count = Double(columns * rows) * 255
        let edge = UIColor(red: r / count, green: g / count, blue: b / count, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        edge.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(1, saturation * 1.1), brightness: min(0.34, brightness))
    }
}

extension View {
    /// 详情页底色：有底边色就整页铺它（取到之前是黑的，取到后 0.5 秒淡入），没有就是黑底
    func heroEdgeBackground(_ tint: Color?) -> some View {
        scrollContentBackground(.hidden)
            .background {
                (tint ?? Theme.background)
                    .animation(.easeInOut(duration: 0.5), value: tint?.description)
                    .ignoresSafeArea()
            }
    }
}
