import SwiftUI

/// 整季片源标注（对应 Web `components/media-source-annotation-dialog.tsx`，
/// docs/design/media-source-annotation.md §5.2）。
///
/// 挂在「失败反馈的原地」：洗版报告的「无法确认」季与追踪明细的「无法确认档位」季（管理员）。
/// 三段式：待标注文件名列表（扫一眼确认来源）→ 档位单选（每项写明后果，标注必须是知情选择）→ 确认。
/// 只动片源未知与既有人工标注的文件，已从文件名解析出片源的不被批量覆盖。
struct MediaSourceAnnotationSheet: View {
    let mediaItemId: Int
    /// 电影传 0（后端的电影单元哨兵）
    let seasonNumber: Int
    let isMovie: Bool
    /// 标注成功后回调（父页面负责重跑体检 / 刷新与提示），参数为结果句
    let onApplied: (String) async -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [API.MediaSourceAnnotationCandidateView]?
    @State private var picked: String?
    @State private var busy = false
    @State private var error: String?

    /// 与后端片源档阶梯同源；user-lowest 是「不确定，按最低档」的显式哨兵
    static let options: [(value: String, label: String, consequence: String, destructive: Bool)] = [
        ("Remux", "Remux", String(localized: .librarySourceAnnotationRemuxHint), false),
        ("Blu-ray", String(localized: .librarySourceAnnotationBlurayLabel), String(localized: .librarySourceAnnotationBlurayHint), false),
        ("WEB-DL", "WEB-DL", String(localized: .librarySourceAnnotationWebDlHint), false),
        ("WEBRip", "WEBRip", String(localized: .librarySourceAnnotationWebRipHint), false),
        ("HDTV", String(localized: .librarySourceAnnotationHdtvLabel), String(localized: .librarySourceAnnotationHdtvHint), false),
        ("user-lowest", String(localized: .librarySourceAnnotationLowestLabel), String(localized: .librarySourceAnnotationLowestHint), true),
    ]

    private var scopeLabel: String { isMovie ? String(localized: .subscriptionInspectorFeature) : SubsFormat.seasonName(seasonNumber) }

    private static func sourceDisplay(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value == "user-lowest" { return String(localized: .mediaSourcesLowestManual) }
        if value == "Disc" { return String(localized: .subscriptionSmartStatusSourceDisc) }
        return value
    }

    var body: some View {
        SubsSheetScaffold(
            title: String(localized: .librarySourceAnnotationTitle(scopeLabel)),
            subtitle: String(localized: .subscriptionAnnotateHint),
            confirm: SubsSheetConfirm(
                title: String(localized: .librarySourceAnnotationConfirm),
                enabled: picked != nil && !(candidates?.isEmpty ?? true),
                busy: busy,
                identifier: "annotation-confirm"
            ) { Task { await apply() } },
            ready: candidates != nil || error != nil
        ) {
            if let error {
                Section { SubsNoticeRow(text: error, tone: .error) }
            }
            if let candidates {
                if candidates.isEmpty {
                    Section { SubsNoticeRow(text: String(localized: .librarySourceAnnotationEmpty(scopeLabel)), tone: .neutral) }
                } else {
                    Section {
                        ForEach(candidates, id: \.fileId) { file in
                            HStack(spacing: 8) {
                                Text(file.fileName).font(.subheadline).foregroundStyle(Theme.text.opacity(0.9)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if file.mediaSourceManual, let current = Self.sourceDisplay(file.mediaSource) {
                                    DiscoverTag(text: String(localized: .librarySourceAnnotationCurrent(String(current))))
                                }
                                Text(SubsFormat.bytes(file.sizeBytes)).font(.footnote).monospacedDigit().foregroundStyle(Theme.textMuted)
                            }
                        }
                    } header: {
                        Text(String(localized: .subscriptionAnnotateFiles))
                    } footer: {
                        Text(String(localized: .librarySourceAnnotationCount(candidates.count)))
                    }
                }
            } else {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(String(localized: .librarySourceAnnotationLoading)).foregroundStyle(Theme.textMuted)
                    }
                }
            }

            Section {
                ForEach(Self.options, id: \.value) { option in
                    SubsChoiceRow(
                        title: option.label,
                        subtitle: option.consequence,
                        selected: picked == option.value,
                        tint: option.destructive ? SubsColor.warn : SubsColor.upgrade
                    ) {
                        picked = option.value
                    }
                    .disabled(busy || (candidates?.isEmpty ?? true))
                }
            } header: {
                Text(String(localized: .subscriptionAnnotateSourceTier))
            }
        }
        .accessibilityIdentifier("annotation-sheet")
        .task {
            do {
                candidates = try await api.libraryItemsListMediaSourceAnnotationCandidates(mediaItemId: mediaItemId, seasonNumber: seasonNumber)
            } catch is CancellationError {
            } catch {
                self.error = String(localized: .librarySourceAnnotationLoadFailed)
            }
        }
    }

    private func apply() async {
        guard let picked, let option = Self.options.first(where: { $0.value == picked }) else { return }
        busy = true
        error = nil
        do {
            let result = try await api.libraryItemsAnnotateMediaSource(
                body: .init(mediaItemId: mediaItemId, seasonNumber: seasonNumber, mediaSource: option.value)
            )
            let files = result["files"]?.intValue ?? (candidates?.count ?? 0)
            await onApplied(String(localized: .librarySourceAnnotationApplied(scopeLabel, files, option.label)))
            dismiss()
        } catch {
            self.error = error.localizedDescription.isEmpty ? String(localized: .librarySourceAnnotationApplyFailed) : error.localizedDescription
            busy = false
        }
    }
}
