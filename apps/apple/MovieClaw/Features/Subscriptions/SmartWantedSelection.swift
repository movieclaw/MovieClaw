import SwiftUI

struct SmartWantedContext {
    let wanted: API.WantedView
    let detail: API.SubscriptionDetailView
    let canManage: Bool
    let onChanged: () async -> Void
}

/// 与网页相同，决策依据只挂在分集履历的搜索节点，不重复另列分集状态。
struct SmartWantedSelection: View {
    let context: SmartWantedContext
    @Environment(\.api) private var api
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        if let state = SmartSelection(context.wanted), state["reason"] == "identity_unconfirmed" {
            VStack(alignment: .leading, spacing: 8) {
                Text("订阅正常进行，无需你处理。")
                if let explanation = state["identity_explanation"] {
                    DisclosureGroup("查看详情") {
                        Text(explanation).textSelection(.enabled).padding(.top, 6)
                    }.accessibilityIdentifier("identity-details")
                }
            }
            .font(.subheadline).foregroundStyle(Theme.textMuted)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("identity-info")
        } else if let state = SmartSelection(context.wanted), state.awaitingSubtitles {
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(SubsColor.danger).accessibilityIdentifier("smart-action-error") }
                if let explanation = state["wait_explanation"] { Text(explanation) }
                if let line = context.detail.smartSubtitle?.line { Text(line).accessibilityIdentifier("smart-subtitle-requirement") }
                if state["reason"] == "awaiting_subtitles", let deadline = state["deadline"] {
                    Text("最晚等待至 \(SubsFormat.dateTime(deadline))").fontWeight(.medium)
                        .accessibilityIdentifier("smart-deadline")
                }
                if let title = state["candidate_title"] {
                    Text("原版：\(title)").textSelection(.enabled).accessibilityIdentifier("smart-candidate")
                }
                if context.canManage, context.detail.status == "active", context.detail.smartStatus == "active",
                   let key = state["candidate_key"] {
                    Button(busy ? "正在处理…" : "这次先下原版") {
                        Task {
                            if await change(.init(version: context.wanted.selectionVersion ?? 0, candidateKey: key)) {
                                NotificationCenter.default.post(name: .smartOriginalRequested, object: context.detail.id)
                            }
                        }
                    }
                    .buttonStyle(.bordered).disabled(busy).accessibilityIdentifier("smart-download-original")
                }
            }
            .font(.subheadline).foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("smart-awaiting-subtitles")
        } else if let state = SmartSelection(context.wanted) {
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(SubsColor.danger).accessibilityIdentifier("smart-action-error") }
                if let deadline = state["deadline"] {
                    Text("最晚等待至 \(SubsFormat.dateTime(deadline))").fontWeight(.medium)
                        .accessibilityIdentifier("smart-deadline")
                }
                if let title = state["candidate_title"] {
                    Text("当前候选：\(title)").textSelection(.enabled).accessibilityIdentifier("smart-candidate")
                }
                if let following = state.followingLabel { Text("跟随版本：\(following)") }
                if let explanation = state["wait_explanation"] { Text(explanation) }
                if let explanation = state["choice_explanation"] { Text(explanation) }
                DisclosureGroup("查看选择依据") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let anchor = state["anchor"] {
                            Text("\(state["anchor_source"] == "published_at" ? "本集最早匹配资源的站点发布时间" : "本系统首次发现合格资源")：\(SubsFormat.dateTime(anchor))")
                        }
                        if case let .object(prediction) = state.values["prediction"],
                           case let .array(episodes) = prediction["episodes"] {
                            Text("根据此前 \(episodes.count) 集的独立发布记录，预计 \(SubsFormat.dateTime(prediction["start"]?.stringValue)) 至 \(SubsFormat.dateTime(prediction["end"]?.stringValue)) 到达。")
                        } else {
                            Text("暂无足够证据支持长时间等待；仅在资源刚发布或发布时间不明时短暂观察。")
                        }
                        if let end = state["observation_end"] {
                            Text("观察窗口于 \(SubsFormat.dateTime(end)) 结束，可能提前选择。下载完成时间取决于资源和网络。")
                        }
                    }.padding(.top, 6)
                }.accessibilityIdentifier("smart-evidence")
                if context.canManage, context.detail.status == "active", context.detail.smartStatus == "active" {
                    VStack(alignment: .leading, spacing: 8) {
                        if let key = state["candidate_key"] {
                            Button(busy ? "正在处理…" : "立即下载当前候选") {
                                Task { await change(.init(version: context.wanted.selectionVersion ?? 0, candidateKey: key)) }
                            }.discoverProminentButton().accessibilityIdentifier("smart-download-now")
                        }
                        Button(context.detail.media.kind == "movie" ? "延长 1 天" : "延长 2 小时") {
                            Task { await change(.init(version: context.wanted.selectionVersion ?? 0, extendSeconds: context.detail.media.kind == "movie" ? 86400 : 7200)) }
                        }.buttonStyle(.bordered).accessibilityIdentifier("smart-extend-wait")
                    }.disabled(busy)
                }
            }
            .font(.subheadline).foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("smart-selection")
        }
    }

    @discardableResult
    private func change(_ payload: SmartWaitPayload) async -> Bool {
        guard !busy else { return false }
        busy = true
        error = nil
        var succeeded = false
        do {
            try await api.changeSmartWait(subscriptionId: context.detail.id, wantedId: context.wanted.id, body: payload)
            succeeded = true
        } catch { self.error = error.localizedDescription }
        // 成功或版本冲突都重新读取，下一次点击使用最新候选与版本。
        await context.onChanged()
        busy = false
        return succeeded
    }
}

extension Notification.Name {
    /// 「这次先下原版」成功：订阅详情据此追问看不看得懂这种语言（object = 订阅 id）
    static let smartOriginalRequested = Notification.Name("movieclaw.smart.original-requested")
}
