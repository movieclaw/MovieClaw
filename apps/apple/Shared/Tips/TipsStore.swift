import Foundation
import Observation

/// 使用提示的 Apple 端引擎（docs/design/tips.md，对标 TipKit）：状态在服务端、每个账号一份，
/// 规则与文案写在用到提示的页面里。不直接用 TipKit——它的存储接不到服务端，换台设备会再提示一遍。
///
/// 判定同 Web：快照拉回来之前不出任何提示；已作废的永不出现。
/// 上报一律先改本地、再以服务端返回的那一行为准；网络失败静默（提示不是关键功能），旧服务器没有接口时提示就不出现。
/// 事件计数规则、展示次数上限、「同屏只出一条」的排队和全局频率节流（Web 现在配置为 0）等 App 里有提示用得上时再加。
///
/// 单例跨账号存活，所以记着属于谁（`LibraryHomePrefs.ownerKey`）：换了账号就作废旧状态重新拉。
@Observable
final class TipsStore {
    static let shared = TipsStore()

    /// 快照到了
    private(set) var loaded = false
    private var records: [String: API.TipRecordView] = [:]
    @ObservationIgnored private var owner: String?
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// 以这个账号的身份拉一次快照（已经拉到就什么都不做；失败下次用到时再拉）
    func ensureLoaded(api: APIClient, owner key: String) async {
        if key != owner {
            owner = key
            loaded = false
            records = [:]
            loading = nil
        }
        guard !loaded else { return }
        if loading == nil {
            loading = Task {
                defer { if owner == key { loading = nil } }
                guard let state = try? await api.tipsStateShow(), owner == key else { return }
                records = Dictionary(state.tips.map { ($0.tipId, $0) }, uniquingKeysWith: { _, new in new })
                loaded = true
            }
        }
        await loading?.value
    }

    /// 这条提示现在能不能出现（页面自己的规则另外判）
    func eligible(_ tip: String) -> Bool {
        loaded && records[tip]?.invalidatedAt == nil
    }

    /// 提示上屏一次
    func recordDisplay(_ tip: String, api: APIClient) {
        var record = records[tip] ?? Self.blank(tip)
        record.displayCount += 1
        records[tip] = record
        Task { if let row = try? await api.tipsDisplaysRecord(tipId: tip) { records[tip] = row } }
    }

    /// 作废：`action_performed` 用过了提示说的功能，`closed` 用户关掉
    func invalidate(_ tip: String, reason: String, api: APIClient) {
        var record = records[tip] ?? Self.blank(tip)
        guard record.invalidatedAt == nil else { return }
        record.invalidatedAt = ISO8601DateFormatter().string(from: .now)
        record.invalidatedReason = reason
        records[tip] = record
        Task { if let row = try? await api.tipsInvalidate(tipId: tip, body: API.InvalidateTipRequest(reason: reason)) { records[tip] = row } }
    }

    private static func blank(_ tip: String) -> API.TipRecordView {
        API.TipRecordView(tipId: tip, displayCount: 0, firstDisplayedAt: nil, lastDisplayedAt: nil, invalidatedAt: nil, invalidatedReason: nil)
    }
}
