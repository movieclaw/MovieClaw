import Nuke
import NukeUI
import SwiftUI

// Mac 版的卡片与行（docs/design/macos-app.md §4）。版式参照 macOS 上的 Apple Music：
// - 卡片平时安静：圆角图 + 一圈很细的亮边，片名、副标题写在图下面（鼠标不像遥控器那样有「焦点」，
//   认不出是哪一部的东西不能只在悬停时才出现）；
// - 鼠标移上去：图微微压暗，左下角浮出一枚玻璃播放键（能播的才有），右下角浮出「⋯」菜单——同 Apple Music 专辑封面；
// - 横滑行：标题可点（「最近添加的电影 ›」进完整的海报墙），鼠标移到行上时左右两端浮出翻页键，一次翻一屏；
// - 右键菜单与悬停的「⋯」是同一份菜单。

/// 尺寸与间距（点）。按 Apple Music 的 Mac 版量的节奏：页边 32，卡片间 18，行与行 40
enum MacMetrics {
    /// 页面左右边距
    static let edge: CGFloat = 32
    /// 海报（竖版 2:3）宽
    static let posterWidth: CGFloat = 168
    /// 剧照（横版 16:9）宽：「接下来继续」、分集
    static let landscapeWidth: CGFloat = 296
    /// 「我的媒体库」库卡宽（16:9）
    static let libraryWidth: CGFloat = 296
    /// 「按类型找电影 / 剧集」类型卡：同网页 236 × 150（docs/design/genre-cinematic-cards.md）
    static let genreWidth: CGFloat = 236
    static let genreHeight: CGFloat = 150
    /// 卡片之间
    static let cardSpacing: CGFloat = 18
    /// 行与行之间
    static let rowSpacing: CGFloat = 40
    /// 卡片圆角（同 Apple Music 的封面，macOS 26 的圆角更圆）
    static let cardCorner: CGFloat = 10
    /// 模糊垫底的剧照按这么宽取：模糊之后看不出清晰度
    static let blurredBackdropWidth: CGFloat = 480
    /// 演职员圆头像
    static let avatarSize: CGFloat = 92
}

extension ImageWidth {
    /// 卡片的取图宽度：按屏幕倍率换成像素（视网膜屏 2 倍）。悬停不放大，不加余量
    static func macCard(_ points: CGFloat) -> Int {
        ImageWidth.points(points)
    }
}

extension Color {
    /// 大图区以下的底色：偏冷的深炭灰（同 Apple TV 版的 `tvPage`，量自系统 Apple TV App），把偏暖的海报衬得更鲜亮
    static let macPage = Color(red: 22 / 255, green: 23 / 255, blue: 28 / 255)
}

// MARK: - 卡片

/// 卡片右下角「⋯」与右键菜单里的一项
struct MacCardAction: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var role: ButtonRole?
    let perform: () -> Void
}

/// 海报卡（竖版 2:3）：图 + 片名 + 副标题（年份）。悬停时浮出播放键与菜单（同 Apple Music 的专辑封面）
struct MacPosterCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    var width: CGFloat = MacMetrics.posterWidth
    /// 0～1 的观看进度（有才画进度条）
    var progress: Double?
    /// 图上角标（「本片」「未入库」）
    var badge: String?
    /// 悬停时左下角的播放键（能直接播的才给）
    var play: (() -> Void)?
    /// 悬停「⋯」与右键菜单
    var menu: [MacCardAction] = []
    /// 片名下面挂不挂字：影人页等需要
    var showsCaption = true
    let action: () -> Void

    var body: some View {
        MacCardLabel(title: title, subtitle: subtitle, width: width, artHeight: width * 1.5, showsCaption: showsCaption, play: play,
                     menu: menu, badge: badge) {
            RemoteImage(url: imageURL, placeholderText: title)
                .frame(width: width, height: width * 1.5)
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0 {
                        MacProgressStrip(value: progress)
                            .padding(8)
                    }
                }
        }
        .macCardTap(title, action: action)
        .contextMenu { MacCardMenu(actions: menu) }
    }
}

/// 横版剧照卡（16:9）：「接下来继续」。`detail`（「S2 E6 · 剩 18 分钟」）与进度条收进图片底部的暗带里，
/// 片名、副标题写在下面（剧照上认不出是哪一部）
struct MacLandscapeCard: View {
    let title: String
    let subtitle: String?
    let imageURL: URL?
    var width: CGFloat = MacMetrics.landscapeWidth
    var progress: Double?
    var badge: String?
    var detail: String?
    var play: (() -> Void)?
    var menu: [MacCardAction] = []
    let action: () -> Void

    var body: some View {
        MacCardLabel(title: title, subtitle: subtitle, width: width, artHeight: width * 9 / 16, showsCaption: true, play: play,
                     menu: menu, badge: badge, centeredControls: true) {
            RemoteImage(url: imageURL, placeholderText: title)
                .frame(width: width, height: width * 9 / 16)
                .overlay(alignment: .bottom) {
                    if let detail {
                        detailBand(detail)
                    } else if let progress, progress > 0 {
                        MacProgressStrip(value: progress)
                            .padding(10)
                    }
                }
        }
        .macCardTap(title, action: action)
        .contextMenu { MacCardMenu(actions: menu) }
    }

    /// 图片底部的暗带：进度条 + 第几集 · 剩多久（同系统 Apple TV App 的「继续观看」卡）
    private func detailBand(_ detail: String) -> some View {
        HStack(spacing: 8) {
            if let progress, progress > 0 {
                MacProgressStrip(value: progress, track: .white.opacity(0.3))
                    .frame(width: 44)
            }
            Text(detail)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.top, 26)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 「按类型找电影 / 剧集」的一格：全幅剧照类型卡（三端共用 `GenreCardFace`）。
/// 悬停时剧照恢复饱和、微微放大（同网页的 1.045 倍、Apple TV 的焦点），滚动中不响应悬停
struct MacGenreCard: View {
    let label: String
    let count: Int
    let mediaKind: String
    let coverURL: URL?
    let action: () -> Void

    @State private var hovering = MacCardDebug.forceHover
    @Environment(\.macScrollInProgress) private var scrolling

    private var active: Bool { hovering && !scrolling }

    var body: some View {
        GenreCardFace(label: label, count: count, mediaKind: mediaKind, coverURL: coverURL, width: MacMetrics.genreWidth,
                      imageSaturation: active ? 1 : 0.76, imageScale: active ? 1.045 : 1)
            .shadow(color: .black.opacity(active ? 0.35 : 0.2), radius: active ? 10 : 4, y: active ? 5 : 2)
            .animation(scrolling ? nil : .easeOut(duration: 0.2), value: active)
            .onHover { hovering = $0 || MacCardDebug.forceHover }
            .macCardTap("浏览\(label)，\(count) 部\(mediaKind == "tv" ? "剧集" : "电影")", action: action)
    }
}

/// 「我的媒体库」的库卡 / 合集卡（16:9）：服务端拼好的货架封面（21:10）贴顶完整显示，下面用同一张封面放大模糊延伸
/// （同 Apple TV 版的库卡），库名写在底部暗区里，合集在右侧挂「合集」标签
struct MacLibraryCard: View {
    let name: String
    let count: Int
    var collection = false
    let imageURL: URL?
    var width: CGFloat = MacMetrics.libraryWidth
    let action: () -> Void

    var body: some View {
        MacCardLabel(title: name, subtitle: nil, width: width, artHeight: width * 9 / 16, showsCaption: false, play: nil, menu: [],
                     badge: nil) {
            RemoteImage(url: imageURL, placeholderSymbol: collection ? "rectangle.stack" : "film")
                .frame(width: width, height: width * 10 / 21)
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .frame(width: width, height: width * 9 / 16, alignment: .top)
                .background {
                    if imageURL != nil {
                        RemoteImage(url: imageURL).blur(radius: 30).overlay(Color.black.opacity(0.3))
                    } else {
                        Theme.surfaceRaised
                    }
                }
                .overlay(alignment: .bottomLeading) { nameBand }
        }
        .macCardTap(collection ? "合集「\(name)」，\(count) 部" : "\(name)，\(count) 部", action: action)
    }

    private var nameBand: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(count) 部")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            if collection {
                Spacer(minLength: 0)
                Label("合集", systemImage: "rectangle.stack")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                    .fixedSize()
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// 一行末尾的「查看全部」：与这一行的海报同大，点进完整的海报墙（行里只取前 20 部）
struct MacSeeAllCard: View {
    var total: Int?
    var width: CGFloat = MacMetrics.posterWidth
    var aspect: CGFloat = 1.5
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 26, weight: .regular))
            Text("查看全部")
                .font(.system(size: 14, weight: .semibold))
            if let total {
                Text("\(total) 部")
                    .font(.system(size: 12))
                    .opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .frame(width: width, height: width * aspect)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: MacMetrics.cardCorner))
        .overlay {
            RoundedRectangle(cornerRadius: MacMetrics.cardCorner)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .modifier(MacHoverLift())
        .macCardTap(total.map { "查看全部 \($0) 部" } ?? "查看全部", action: action)
    }
}

/// 卡片共用的外观：圆角图 + 细亮边 + 左上角标 + 悬停浮层（压暗、播放键、⋯ 菜单）+ 图下的片名。
/// 开着 `macCardFocusEffect`（全产品默认）时悬停不出任何按钮，改成 Apple TV 式的聚焦：放大、随指针微倾、指针处一团高光
private struct MacCardLabel<Art: View>: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    /// 图的高度（各卡片类型的比例固定，直接给出，不逐帧量）
    let artHeight: CGFloat
    let showsCaption: Bool
    let play: (() -> Void)?
    let menu: [MacCardAction]
    let badge: String?
    /// 横版剧照卡：底部暗带里写着第几集、剩多久，悬停的播放键放正中、「⋯」放右上，不压住那行字
    var centeredControls = false
    @ViewBuilder let art: () -> Art

    @State private var hovering = MacCardDebug.forceHover
    @Environment(\.macCardFocusEffect) private var focusEffect
    @Environment(\.macCardSelected) private var selected
    @Environment(\.macCardControlsInFocus) private var controlsInFocus
    @Environment(\.macScrollInProgress) private var scrolling
    /// 聚焦时指针在图上的位置（0～1），图外为 nil
    @State private var pointer: UnitPoint?

    private var hovered: Bool { hovering && !scrolling }
    private var focused: Bool { focusEffect && hovered }
    private var controlsOnHover: Bool { hovered && (!focusEffect || controlsInFocus) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            art()
                .overlay {
                    // 悬停压暗一层：同 Apple Music，告诉人「这张可以点」
                    if !focusEffect { Color.black.opacity(hovered ? 0.18 : 0) }
                }
                .overlay(alignment: .topLeading) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.62), in: .capsule)
                            .padding(7)
                    }
                }
                .overlay(alignment: .bottom) {
                    if controlsOnHover, !centeredControls, play != nil || !menu.isEmpty {
                        hoverControls
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if controlsOnHover, centeredControls, let play {
                        playButton(play, size: 44)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // 「⋯」只在不做聚焦效果的卡片上出；聚焦卡片的更多操作走右键菜单
                    if controlsOnHover, !focusEffect, centeredControls, !menu.isEmpty {
                        menuButton
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    // 聚焦高光：指针处一团柔光，同 Apple TV 海报的镜面反光
                    if focused {
                        RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0.06), .clear],
                                       center: pointer ?? UnitPoint(x: 0.5, y: 0.2),
                                       startRadius: 0, endRadius: max(width, artHeight) * 0.75)
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .clipShape(.rect(cornerRadius: MacMetrics.cardCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: MacMetrics.cardCorner)
                        .strokeBorder(.white.opacity(selected ? 0.75 : focused ? 0.32 : 0.12),
                                      lineWidth: selected ? 2 : focused ? 1 : 0.5)
                }
                // 随指针微倾（最多 4°）：指针在哪一侧，哪一侧往里压
                .rotation3DEffect(.degrees(focused ? tilt.y : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(focused ? tilt.x : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .scaleEffect(focused ? 1.05 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : hovered ? 0.35 : 0.2),
                        radius: focused ? 18 : hovered ? 10 : 4, y: focused ? 12 : hovered ? 5 : 2)
                .animation(scrolling ? nil : .spring(response: 0.34, dampingFraction: 0.72), value: focused)
            if showsCaption {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
                // 字不单独参与命中测试（点字照样落在整张卡的 contentShape 上）：滚动时每帧要重算的响应者少一批
                .allowsHitTesting(false)
                // 封面放大后片名往下让一点
                .offset(y: focused ? 6 : 0)
                .animation(scrolling ? nil : .spring(response: 0.34, dampingFraction: 0.72), value: focused)
            }
        }
        .contentShape(.rect)
        // 悬停进出与指针位置用同一个悬停处理（少一个悬停响应者）。在未变换的卡片区域读坐标：图片的倾斜、缩放不能反过来改变下一次悬停位置
        .onContinuousHover { phase in hover(phase) }
        .onChange(of: scrolling) { _, active in
            if active, pointer != nil { pointer = nil }
        }
    }

    private func hover(_ phase: HoverPhase) {
        let inside: Bool
        switch phase {
        case .active(let location):
            inside = true
            if focusEffect, !scrolling {
                pointer = location.y <= artHeight
                    ? UnitPoint(x: min(1, max(0, location.x / width)), y: min(1, max(0, location.y / artHeight)))
                    : nil
            }
        case .ended:
            inside = false
            if pointer != nil { pointer = nil }
        }
        let value = inside || MacCardDebug.forceHover
        guard hovering != value else { return }
        if scrolling {
            hovering = value
        } else {
            withAnimation(.easeOut(duration: 0.15)) { hovering = value }
        }
    }

    /// 微倾角度（度）：x 绕竖轴、y 绕横轴
    private var tilt: (x: Double, y: Double) {
        guard let pointer else { return (0, 0) }
        return ((pointer.x - 0.5) * 8, (0.5 - pointer.y) * 8)
    }

    /// 左下播放键、右下「⋯」：小号玻璃圆钮，同 Apple Music 封面上的那两枚
    private var hoverControls: some View {
        HStack {
            if let play { playButton(play, size: 32) }
            Spacer(minLength: 0)
            if !menu.isEmpty { menuButton }
        }
        .padding(8)
    }

    private func playButton(_ play: @escaping () -> Void, size: CGFloat) -> some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("播放")
        .accessibilityLabel("播放\(title)")
    }

    private var menuButton: some View {
        Menu {
            MacCardMenu(actions: menu)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(.circle)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.regular.interactive(), in: .circle)
        .help("更多")
    }
}

extension EnvironmentValues {
    /// 卡片悬停时走 Apple TV 式聚焦（不出按钮）：全产品的海报统一这样，起播走详情页或右键菜单
    @Entry var macCardFocusEffect = true
    /// 卡片描一圈亮边表示「选中」（首页大图正讲的那一部）
    @Entry var macCardSelected = false
    /// 聚焦时仍浮出播放键（首页「接下来继续」：点卡片进详情，点播放键才起播）
    @Entry var macCardControlsInFocus = false
    /// 滚动及惯性期间暂停卡片悬停效果，停稳后再恢复。
    @Entry var macScrollInProgress = false
}

/// 开发期出图用：环境变量 MC_FORCE_HOVER=1 让所有卡片一出来就是悬停的样子（合成的鼠标事件触发不了系统的悬停追踪）
enum MacCardDebug {
    #if DEBUG
    static let forceHover = ProcessInfo.processInfo.environment["MC_FORCE_HOVER"] != nil
    #else
    static let forceHover = false
    #endif
}

/// 右键菜单与悬停「⋯」共用的菜单内容
struct MacCardMenu: View {
    let actions: [MacCardAction]

    var body: some View {
        ForEach(actions) { action in
            Button(role: action.role, action: action.perform) {
                Label(action.title, systemImage: action.symbol)
            }
        }
    }
}

/// 大图区的主按钮（「继续播放」「播放 第 1 季第 1 集」）：白底黑字的胶囊，同 Apple TV App 的「播放」。
/// 不用系统的 `.glassProminent`：它的强调色在窗口不在前台时被系统画成灰色，压在剧照上看不清是什么按钮
struct MacPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration)
    }

    private struct StyledBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.75 : hovering ? 1 : 0.92)))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(enabled ? 1 : 0.5)
                .contentShape(.capsule)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// 卡片的点击：一个按下手势同时管「按下微微缩小」与点击，不用 `Button`。
///
/// 滚动时每帧要为窗口拖拽区域、光标、悬停遍历整页的响应者；`Button` 自带焦点与手势两套响应者，
/// 一页几十上百张卡片累起来是滚动掉帧的大头（docs/perf/macos-scroll-smoothness.md）。换成一个手势后，
/// 无障碍仍按按钮读出、可执行；代价是全键盘导航（Tab）不再停在卡片上
struct MacCardTap: ViewModifier {
    let label: String
    let action: () -> Void
    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { value in
                        pressed = false
                        // 按下后拖开一段（手滑开了）不算点击
                        if hypot(value.translation.width, value.translation.height) < 10 { action() }
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

extension View {
    func macCardTap(_ label: String, action: @escaping () -> Void) -> some View {
        modifier(MacCardTap(label: label, action: action))
    }
}

/// 卡片按钮：按下时微微缩小，不画系统按钮的底（分集、演职员这类一页只有一排的卡片）
struct MacCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 悬停时提亮一点（「查看全部」这类没有图的块）
struct MacHoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering ? 0.06 : 0)
            .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
    }
}

/// 图片底部的观看进度条
struct MacProgressStrip: View {
    let value: Double
    var track: Color = .black.opacity(0.45)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(.white)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
    }
}

// MARK: - 行

/// 一行横滑内容（Apple Music 的「架子」）：标题（可点，进完整的海报墙）+ 横向滚动的卡片。
/// 鼠标移到行上时左右两端浮出玻璃翻页键，一次翻约一屏；滚到头那一侧的键自动隐去。触控板横扫照常滚动
struct MacShelf<Content: View>: View {
    let title: String
    /// 标题右侧的说明（如「已有 7 / 共 8」）
    var detail: String?
    /// 点标题进「查看全部」；nil = 标题不可点
    var seeAll: (() -> Void)?
    /// 卡片区的高度（翻页键竖直居中对齐在图上，而不是连同下面的字一起居中）
    var artHeight: CGFloat?
    /// 出现时（以及这个值变了时）滚到哪一张：卡片用 `.id(_:)` 标上同一个整数（分集横排滚到正在看的那一集）
    var scrollTo: Int?
    /// 滚过去时目标卡停在哪：默认停在左边距处；nil = 只滚到刚好整张露出来（已经看得见就不动），带动画
    var scrollAnchor: UnitPoint? = UnitPoint(x: 0.04, y: 0.5)
    var scrollingChanged: ((Bool) -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var position = ScrollPosition(idType: Int.self)
    @State private var scrollMetrics = MacShelfScrollMetrics()
    @State private var canBack = false
    @State private var canForward = false
    @State private var hovering = false
    @State private var scrolling = false
    @Environment(\.macScrollInProgress) private var parentScrolling

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, MacMetrics.edge)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: MacMetrics.cardSpacing) {
                    content()
                        .environment(\.macScrollInProgress, parentScrolling || scrolling)
                }
                .scrollTargetLayout()
                .padding(.horizontal, MacMetrics.edge)
                .padding(.vertical, 6)
                .allowsHitTesting(!scrolling)
            }
            .scrollIndicators(.never)
            .scrollPosition($position)
            .scrollClipDisabled()
            .onScrollPhaseChange { _, phase in
                PerfTrace.record("scroll.phase", ["axis": "horizontal", "shelf": title, "phase": String(describing: phase)])
                if scrolling != phase.isScrolling {
                    scrolling = phase.isScrolling
                    scrollingChanged?(scrolling)
                }
            }
            .onScrollGeometryChange(for: [CGFloat].self) { geometry in
                [geometry.contentOffset.x, geometry.contentSize.width, geometry.containerSize.width]
            } action: { _, values in
                scrollMetrics.offset = values[0]
                scrollMetrics.contentWidth = values[1]
                scrollMetrics.viewport = values[2]
                // 逐像素的位移只供下一次翻页计算；只有箭头可用性变了才更新视图。
                let back = scrollMetrics.offset > 4
                let forward = scrollMetrics.offset + scrollMetrics.viewport < scrollMetrics.contentWidth - 4
                if canBack != back { canBack = back }
                if canForward != forward { canForward = forward }
            }
            .overlay(alignment: artHeight == nil ? .center : .top) {
                // 翻页键（交互式玻璃）只在指针停在这一行上时才建：常驻的话每行两枚，滚动时每帧都要跟着重算
                if hovering {
                    pager
                        .frame(height: artHeight.map { $0 + 12 })
                        .transition(.opacity)
                }
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.18)) { hovering = inside } }
        .task(id: scrollTo) {
            guard let scrollTo else { return }
            // 等横排建好、量出宽度再滚；目标卡停在左边距处，前面露一点上一张，看得出前面还有
            try? await Task.sleep(for: .milliseconds(60))
            if let scrollAnchor {
                position.scrollTo(id: scrollTo, anchor: scrollAnchor)
            } else {
                withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(id: scrollTo) }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let seeAll {
                Button(action: seeAll) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(title)
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("查看全部")
            } else {
                Text(title)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 20, weight: .bold))
    }

    private var pager: some View {
        HStack {
            pageButton("chevron.backward", visible: canBack) { page(-1) }
                .padding(.leading, 8)
            Spacer()
            pageButton("chevron.forward", visible: canForward) { page(1) }
                .padding(.trailing, 8)
        }
    }

    private func pageButton(_ symbol: String, visible: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .opacity(visible ? 1 : 0)
        .disabled(!visible)
        .accessibilityLabel(symbol.hasSuffix("backward") ? "上一页" : "下一页")
    }

    /// 翻一屏：留一张卡的宽度不翻过去，人知道接上的是哪里
    private func page(_ direction: CGFloat) {
        let target = scrollMetrics.target(direction: direction)
        withAnimation(.smooth(duration: 0.45)) { position.scrollTo(x: target) }
    }
}

/// 不参与 SwiftUI 观察的滚动位置，避免每个滚动事件重建整行卡片。
final class MacShelfScrollMetrics {
    var offset: CGFloat = 0
    var contentWidth: CGFloat = 0
    var viewport: CGFloat = 0

    func target(direction: CGFloat) -> CGFloat {
        let step = max(200, viewport - MacMetrics.edge * 2 - 80)
        return min(max(0, offset + direction * step), max(0, contentWidth - viewport))
    }
}

// MARK: - 状态

/// 页面级的空态 / 错误态
struct MacStateView: View {
    let symbol: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 头像

/// 圆头像：有图画图，没图画首字母（中文取第一个字）
struct MacAvatar: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        // 首字母垫底，图片加载成功才盖上、且盖上后不再画首字母：头像图常带透明边，叠着画会透出字（Apple TV 版走查发现）
        LazyImage(url: url) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(white: 0.36), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
                    Text(Self.initials(name))
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    static func initials(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "?" }
        if first.unicodeScalars.first.map({ (0x4E00 ... 0x9FFF).contains($0.value) }) == true {
            return String(first)
        }
        return String(trimmed.prefix(2)).uppercased()
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

    /// 片长：「48 分钟」「2 小时 12 分钟」
    static func runtime(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m > 0 ? "\(h) 小时 \(m) 分钟" : "\(h) 小时"
    }
}
