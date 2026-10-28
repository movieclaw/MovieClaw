import SwiftUI

/// 媒体库首页的「下拉二楼」：用力往下拉，松手进片段（2026-10-28 用户要求，取代顶栏的片段按钮）。
///
/// 交互同淘宝二楼、微信下拉小程序，排在系统下拉刷新（首页的 `.refreshable`）后面：
/// - 照常下拉，转圈转起来就是刷新了；
/// - 刷新触发后继续往下拉，内容上方从左侧送进一条胶片（「走片」，见 `ReelsFilmStrip`），跟着手指一格一格走；
/// - 再拉过 `armBeyond`：片门合拢、正中一格亮起并重震一下，这时松手就进片段；推回线内再松手只是刷新。
///
/// 线不写死，跟在这一次拖动里刷新实际触发的位置后面：刷新的触发距离随机型变（模拟器实测 iPhone 17 Pro
/// 拉下约 183 点、13 寸 iPad 约 274 点），写死的线在 iPad 上会先于刷新，只想刷新的人就误进了片段。
/// 只认手指拖着的那段越界（`ScrollPhase.interacting`），甩到顶的回弹不会误进。
/// 拉下来多少只在页面外的可观察对象里变（同 `ImmersiveHeroScroll`）：首页主体不读它，拖动时只重算提示。
@Observable
final class ReelsFloor {
    /// 顶端被拉下来多少（点）
    private(set) var pull: CGFloat = 0
    /// 拉过线了，松手就进。只在拖动中更新：松手后回弹的那一下保持原样，提示不会先跳回「继续下拉」
    private(set) var armed = false
    /// 这一次拖动里刷新在拉下多少时触发；还没触发为空，这时既不出提示也不会过线
    private(set) var refreshedAt: CGFloat?
    @ObservationIgnored private var dragging = false
    /// 静止时内容顶边离滚动视图顶边多远（导航栏下沿；刷新转圈期间再加上转圈那一截）。拖动中不跟着变：
    /// 刷新在手指还拖着时触发，系统会把转圈高度加进内边距、下一帧又撤掉，跟着变下拉量会跳 60 点
    @ObservationIgnored private var restTop: CGFloat?

    /// 刷新触发后再拉多少，胶片从无到完全入画
    static let revealSpan: CGFloat = 20
    /// 刷新触发后再拉多少算过线（2026-10-28 真机试过 50 嫌远，改 35：刷新本身的距离改不了，只能缩这一截）
    static let armBeyond: CGFloat = 35

    var reveal: Double {
        guard let refreshedAt else { return 0 }
        return Double(min(1, max(0, (pull - refreshedAt) / Self.revealSpan)))
    }

    /// 从刷新触发到过线走了多少（0～1）：放映灯随它变亮、首页随它变暗
    var progress: Double {
        guard let refreshedAt else { return 0 }
        return Double(min(1, max(0, (pull - refreshedAt) / Self.armBeyond)))
    }

    private var pastLine: Bool {
        guard let refreshedAt else { return false }
        return pull >= refreshedAt + Self.armBeyond
    }

    /// `top`：内容顶边离滚动视图顶边多远（往上滚走时按静止位置算）；`inset`：系统给的顶部内边距
    func scrolled(top: CGFloat, inset: CGFloat) {
        let rest = dragging ? restTop ?? inset : inset
        restTop = rest
        let now = max(0, top - rest)
        if now != pull { pull = now }
        if dragging, armed != pastLine { armed.toggle() }
    }

    /// 首页开始下拉刷新时调。只记手指拖着时触发的那次：读屏等别的方式触发的刷新不算
    func refreshTriggered() {
        if dragging { refreshedAt = pull }
    }

    /// 首页被盖住时（进了片段）清掉这一次：不然返回时胶片还挂在那儿，等回弹的几何回调才消失
    func reset() {
        armed = false
        refreshedAt = nil
    }

    /// 滚动阶段变了；返回 true 表示这一下是拉过线后松手
    func phaseChanged(from old: ScrollPhase, to new: ScrollPhase) -> Bool {
        let released = old == .interacting && new != .interacting && armed
        if new == .interacting, old != .interacting { refreshedAt = nil }
        dragging = new == .interacting
        // 新一次拖动从头判断：不然上次松手时留下的「过线」会让下一次普通滑动松手也进二楼
        if dragging, armed != pastLine { armed.toggle() }
        return released
    }
}

private struct PullEdge: Equatable {
    var top: CGFloat
    var inset: CGFloat
}

extension View {
    /// 挂在首页的纵向滚动视图上：量顶端拉下来多少、认「过线后松手」。提示画在内容里（`ReelsFloorHint`）
    func reelsFloor(_ floor: ReelsFloor, enabled: Bool, onEnter: @escaping () -> Void) -> some View {
        onScrollGeometryChange(for: PullEdge.self) { geometry in
            // 往上滚走时顶边按静止位置算：平常滑动时这个值不变，不会每帧都回调
            PullEdge(top: max(-geometry.contentOffset.y, geometry.contentInsets.top), inset: geometry.contentInsets.top)
        } action: { _, edge in
            floor.scrolled(top: edge.top, inset: edge.inset)
        }
        .onScrollPhaseChange { old, new in
            if floor.phaseChanged(from: old, to: new), enabled { onEnter() }
        }
    }
}

/// 二楼的「走片」（2026-10-28 用户在原型里选定）：一条 35 毫米胶片随手指穿过片门。
///
/// - 胶片绕着看不见的过片轮：中间拱起、两头沉下并略微转开，两头隐进黑里；
/// - 冷银配色（2026-10-28 用户在原型里从冷银 / 夜蓝 / 琥珀中选定，琥珀是 App 里唯一的暖色、显得突兀）：石墨片基、
///   冷白放映灯，光透过齿孔；片门里那格全彩，两侧褪成黑白；
/// - 胶片位置只由下拉量决定（往回推就倒片），每过一格轻轻一下「咔」；
/// - 过线时两块拉丝钢压片板合拢、胶片对齐到最近一格，那一格闪一下白光，重震一下。
/// 画格是首页已经拿到的条目剧照，不另发请求；没有剧照就是空画格。
/// 贴在内容顶边上方，裁在下拉露出的那一截里，不伸到导航栏底下。
struct ReelsFilmStrip: View {
    let floor: ReelsFloor
    let stills: [URL]

    @State private var flash = 0.0

    private static let frame = CGSize(width: 112, height: 70)
    /// 相邻两格的间距、整条胶片的宽（含上下齿孔带）
    private static let step: CGFloat = 124
    private static let band: CGFloat = 104
    /// 手指拉一点，胶片走几点
    private static let travel: CGFloat = 2.6
    /// 两侧各画几格
    private static let side = 3
    /// 放映灯：冷白
    private static let lamp = Color(red: 0.8, green: 0.86, blue: 1)

    var body: some View {
        let reveal = floor.reveal, progress = floor.progress, armed = floor.armed
        let raw = floor.pull * Self.travel
        // 过线后对齐到最近一格，让它卡进片门
        let position = armed ? (raw / Self.step).rounded() * Self.step : raw
        let index = Int((position / Self.step).rounded())
        // 自身零高、贴着内容顶边；胶片挂在它上方，裁在拉开的那一截里
        Color.clear.frame(maxWidth: .infinity).frame(height: 0).overlay(alignment: .bottom) {
            VStack(spacing: 12) {
                Text(armed ? String(localized: .libraryHomeReelsRelease) : String(localized: .libraryHomeReelsPull))
                    .font(.subheadline.weight(.semibold))
                    .tracking(1.5)
                    .foregroundStyle(armed ? Theme.accent : Theme.textMuted)
                    .contentTransition(.opacity)
                film(position: position, progress: progress, armed: armed)
            }
            .padding(.bottom, 16)
            .opacity(reveal)
            .offset(x: -(1 - reveal) * 120)
            .animation(.snappy(duration: 0.25), value: armed)
            .frame(maxWidth: .infinity, minHeight: floor.pull, maxHeight: floor.pull, alignment: .bottom)
            .clipped()
        }
        .sensoryFeedback(.selection, trigger: index) { _, _ in reveal > 0 && !armed }
        .sensoryFeedback(.impact(flexibility: .rigid, intensity: 1), trigger: armed) { _, now in now }
        .onChange(of: armed) { _, now in
            guard now else { return }
            flash = 1
            withAnimation(.easeOut(duration: 0.55)) { flash = 0 }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func film(position: CGFloat, progress: Double, armed: Bool) -> some View {
        let base = Int((position / Self.step).rounded(.down))
        let frac = position - CGFloat(base) * Self.step
        return GeometryReader { geo in
            let half = geo.size.width / 2
            ZStack {
                // 放映灯
                RadialGradient(colors: [Self.lamp.opacity(0.16 + 0.3 * progress + 0.4 * flash), .clear],
                               center: .center, startRadius: 4, endRadius: 150 + 40 * progress)
                // 先画两侧、后画中间：中间那格压在最上面
                ForEach(base - Self.side ... base + Self.side, id: \.self) { k in
                    let x = CGFloat(k - base) * Self.step - frac
                    let c = x / half
                    let near = max(0, 1 - abs(c) * 1.35)
                    FilmCell(url: stills.isEmpty ? nil : stills[((k % stills.count) + stills.count) % stills.count],
                             light: min(1.2, near * (0.35 + 0.65 * progress) + flash * near),
                             color: near * (0.4 + 0.6 * progress))
                        .scaleEffect(1 - 0.16 * c * c)
                        .rotationEffect(.radians(Double(c) * 0.11))
                        .offset(x: x, y: 18 * c * c)
                        .zIndex(-abs(Double(c)))
                }
                gate(closed: armed, progress: progress)
            }
            .frame(width: geo.size.width, height: Self.band)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                         .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
        .frame(height: Self.band + 24)
    }

    /// 片门：两块拉丝钢压片板，过线时合拢
    private func gate(closed: Bool, progress: Double) -> some View {
        let gap = Self.frame.width / 2 + 9 + (closed ? 0 : 14)
        let steel = LinearGradient(colors: [Color(red: 0.19, green: 0.2, blue: 0.23),
                                            Color(red: 0.8 + 0.07 * progress, green: 0.84 + 0.06 * progress, blue: 0.88 + 0.05 * progress),
                                            Color(red: 0.15, green: 0.16, blue: 0.19)],
                                   startPoint: .top, endPoint: .bottom)
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.accent.opacity(closed ? 0.85 : 0.25), lineWidth: 1)
                .frame(width: Self.frame.width + 6, height: Self.frame.height + 6)
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule().fill(steel).frame(width: 6, height: Self.frame.height + 22).offset(x: side * gap)
            }
            RadialGradient(colors: [.white.opacity(0.9 * flash), .clear], center: .center, startRadius: 0, endRadius: 90)
                .blendMode(.plusLighter)
        }
    }
}

/// 一格胶片：片基、上下各一排透光的齿孔、中间的画格
private struct FilmCell: View {
    let url: URL?
    /// 背光多亮（0～1.2）、画格恢复多少原色（0～1）
    let light: Double
    let color: Double

    var body: some View {
        let hole = Color(red: 0.89, green: 0.92, blue: 0.97).opacity(0.1 + 0.78 * min(1, light))
        ZStack {
            Rectangle().fill(Color(red: 0.07 + 0.12 * light, green: 0.08 + 0.13 * light, blue: 0.09 + 0.14 * light).opacity(0.97))
            VStack {
                sprockets(hole)
                Spacer()
                sprockets(hole)
            }
            .padding(.vertical, 4)
            RemoteImage(url: url, placeholderSymbol: "film")
                .frame(width: 112, height: 70)
                .saturation(color)
                .contrast(1.08)
                .brightness(-0.45 + 0.5 * min(1, light))
                .clipShape(.rect(cornerRadius: 3))
        }
        // 两侧多铺一点，绕弧转开时格与格之间不露缝
        .frame(width: 124 + 8, height: 104)
    }

    private func sprockets(_ hole: Color) -> some View {
        HStack(spacing: 20) {
            ForEach(0 ..< 4, id: \.self) { _ in RoundedRectangle(cornerRadius: 2).fill(hole).frame(width: 11, height: 7) }
        }
    }
}

/// 走片时首页跟着暗下去，把注意力让给胶片
struct ReelsFloorDim: View {
    let floor: ReelsFloor

    var body: some View {
        Color.black
            .opacity(floor.reveal * 0.3 + floor.progress * 0.3)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
