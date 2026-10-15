import SwiftUI
import UIKit

/// 小幕的动作来自同一张 4 × 6 透明图集；任务状态仍以会话事件为准。
nonisolated enum AgentCompanionState: Int, CaseIterable {
    case idle, attentive, departing, working, complete, failed

    static func resolve(turn: AgentTurn?, busy: Bool, unavailable: Bool = false) -> Self {
        if unavailable { return .idle }
        if busy { return .working }
        guard let turn else { return .idle }
        if turn.stopped { return .idle }
        if turn.interrupted || turn.status == .error { return .failed }
        return turn.status == .done ? .complete : .idle
    }

    var label: String {
        switch self {
        case .idle: "小幕，安静陪伴"
        case .attentive: "小幕，正在听你说"
        case .departing: "小幕，出发了"
        case .working: "小幕，正在处理任务"
        case .complete: "小幕，任务已完成"
        case .failed: "小幕，任务遇到了问题"
        }
    }

    var frameDuration: Duration { .milliseconds(self == .working ? 300 : 160) }
}

/// 小幕趴在输入框右上角：输入框用 `agentCompanionAnchor()` 标出位置，页面在整页最上层用 `agentCompanion` 画。
///
/// 不能画进输入框所在的底部栏（safeAreaBar）里：栏里多一个独立的可点控件，iOS 26 会在它周围单独生成底部压暗遮罩，
/// 从会话页返回「我的」时转场收尾才拆掉这块遮罩、再淡入「我的」页自己的压暗，底部列表的白字会闪一下
/// （2026-10-15 真机 iOS 26.6 逐项对照查实：小幕改 SwiftUI 绘制、挪进输入框内都照闪，挪出底部栏就不闪）
struct AgentComposerAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// 标出小幕要趴的输入框
    func agentCompanionAnchor() -> some View {
        anchorPreference(key: AgentComposerAnchorKey.self, value: .bounds) { $0 }
    }

    /// 在整页最上层画小幕，位置跟着标出的输入框：右边对齐，身体露出输入框上沿、爪子压住上沿 10pt
    func agentCompanion(_ activity: AgentCompanionState, attentive: Bool) -> some View {
        overlayPreferenceValue(AgentComposerAnchorKey.self) { anchor in
            if let anchor {
                GeometryReader { proxy in
                    let composer = proxy[anchor]
                    AgentCompanion(activity: activity, attentive: attentive)
                        .frame(width: 90, height: 72)
                        .position(x: composer.maxX - 45, y: composer.minY - 26)
                }
            }
        }
    }
}

struct AgentCompanion: View {
    let activity: AgentCompanionState
    let attentive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var pose = AgentCompanionState.idle
    @State private var frame = 0
    @State private var moving = false
    @State private var greeting = 0
    @State private var observedActivity: AgentCompanionState?
    @State private var observedGreeting = 0

    private struct Playback: Equatable {
        var activity: AgentCompanionState
        var attentive: Bool
        var greeting: Int
        var animated: Bool
    }

    var body: some View {
        let playback = Playback(activity: activity, attentive: attentive, greeting: greeting,
                                animated: scenePhase == .active && !reduceMotion)
        HStack {
            Spacer(minLength: 0)
            Button { greeting += 1 } label: {
                AgentCompanionSprite(pose: pose, frame: frame)
                    .frame(width: 72, height: 72)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pose.label)
            .accessibilityHint("轻点和小幕打招呼")
            .accessibilityIdentifier("agent-companion")
            .accessibilityValue(Text(verbatim: "\(pose)-\(playback.animated && moving ? "animated" : "still")"))
            .offset(x: pose == .departing ? CGFloat(frame) * 5 : 0,
                    y: pose == .departing ? -CGFloat(frame % 3) * 4 : 0)
        }
        .padding(.trailing, 14)
        .task(id: playback) {
            let previous = observedActivity
            let previousPose = pose
            let tapped = greeting != observedGreeting
            observedActivity = activity
            observedGreeting = greeting
            frame = 0
            moving = false
            // 重进已结束的历史对话不重复庆祝；只有眼前这轮真的结束才迎接回来。
            var next = activity
            if next == .complete, previous != .working { next = .idle }
            if next == .idle || next == .failed, attentive { next = .attentive }
            pose = next
            guard playback.animated else { return }
            do {
                if next == .working, previous != .working {
                    try await playOnce(.departing)
                    try await playOnce(.working)
                } else if next == .complete {
                    try await playOnce(.complete)
                    try await Task.sleep(for: .seconds(1.2))
                    pose = attentive ? .attentive : .idle
                } else if next == .failed, previous != .failed {
                    try await playOnce(.failed)
                } else if next == .attentive, previousPose != .attentive || tapped {
                    try await playOnce(.attentive)
                } else if tapped, next == .idle {
                    try await playOnce(.attentive)
                    pose = .idle
                }
                frame = 0
                // 等待时抱鱼静坐，只偶尔眨眼；错误和倾听停在静态表情，不再循环。
                while !Task.isCancelled, pose == .working || pose == .idle {
                    let seconds = pose == .working ? Double.random(in: 15 ... 25) : Double.random(in: 8 ... 14)
                    try await Task.sleep(for: .seconds(seconds))
                    moving = true
                    frame = pose == .working ? 2 : 1
                    try await Task.sleep(for: .milliseconds(250))
                    frame = 0
                    moving = false
                }
            } catch is CancellationError {
                // 离开页面、进入后台或状态变更都立刻终止旧动作。
            } catch {}
        }
    }

    private func playOnce(_ state: AgentCompanionState) async throws {
        pose = state
        moving = true
        defer { moving = false }
        for index in 0 ..< 4 {
            frame = index
            try await Task.sleep(for: state.frameDuration)
        }
    }
}

/// 与 Codex 的 background-position 同理：共享一份位图，只切换图层的可见格子。
/// 帧更新只发生在这个小视图里，不让聊天消息列跟着动画重建。
private struct AgentCompanionSprite: UIViewRepresentable {
    let pose: AgentCompanionState
    let frame: Int
    static let artwork = UIImage(named: "AgentMoonCompanion")?.cgImage

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.layer.contents = Self.artwork
        view.layer.contentsGravity = .resize
        view.layer.magnificationFilter = .linear
        view.layer.minificationFilter = .linear
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.contentsRect = CGRect(x: CGFloat(frame) / 4, y: CGFloat(pose.rawValue) / 6,
                                         width: 1.0 / 4, height: 1.0 / 6)
        CATransaction.commit()
    }
}
