import SwiftUI

/// 原生优先级列表：长按列表行拖动排序，菜单保留上下移动与移除，添加时搜索完整候选。
/// 保留类型名供媒体库覆盖编辑器复用。
struct SettingsBScrapeOrderChips: View {
    let options: [SettingsBScrapeChipOption]
    let extraOptions: [SettingsBScrapeChipOption]
    let moreLabel: String
    @Binding var value: [String]
    let max: Int
    let primaryTag: String
    let identifier: String
    @State private var moreOpen = false

    private var allOptions: [SettingsBScrapeChipOption] { options + extraOptions }

    var body: some View {
        ForEach(Array(value.enumerated()), id: \.element) { index, id in
            let option = allOptions.first { $0.id == id }
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option?.name ?? id)
                    if let tip = option?.tip {
                        Text(tip).font(.caption).foregroundStyle(.secondary)
                    } else if index == 0, !primaryTag.isEmpty {
                        Text(primaryTag).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Menu {
                    Button(String(localized: .libraryCollectionsUp), systemImage: "arrow.up") {
                        value.swapAt(index - 1, index)
                    }
                    .disabled(index == 0)
                    .accessibilityIdentifier("\(identifier)-up-\(id)")
                    Button(String(localized: .libraryCollectionsDown), systemImage: "arrow.down") {
                        value.swapAt(index, index + 1)
                    }
                    .disabled(index == value.count - 1)
                    .accessibilityIdentifier("\(identifier)-down-\(id)")
                    Button(String(localized: .settingsDrivesRemove), systemImage: "minus.circle", role: .destructive) {
                        value.removeAll { $0 == id }
                    }
                    .disabled(value.count <= 1)
                    .accessibilityIdentifier("\(identifier)-remove-\(id)")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel(String(localized: .settingsOrderChipsAdjust(option?.name ?? id)))
                .accessibilityIdentifier("\(identifier)-order-\(id)")
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 44)
                    .accessibilityLabel(String(localized: .settingsOrderChipsDrag(option?.name ?? id)))
                    .accessibilityIdentifier("\(identifier)-drag-\(id)")
            }
            .contentShape(.rect)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier)-row-\(id)")
            .accessibilityHint(String(localized: .settingsOrderChipsDragHint))
            .moveDisabled(value.count <= 1)
        }
        .onMove { offsets, destination in
            value.move(fromOffsets: offsets, toOffset: destination)
        }
        Button {
            moreOpen = true
        } label: {
            Label(String(localized: .settingsOrderChipsAdd(moreLabel)), systemImage: "plus")
                .frame(minHeight: 44)
        }
        .disabled(value.count >= max)
        .accessibilityIdentifier("\(identifier)-more")
        Text(String(localized: .settingsOrderChipsLimitHint(max)))
            .font(.caption).foregroundStyle(.secondary)
        .sheet(isPresented: $moreOpen) {
            SettingsBScrapeMoreSheet(moreLabel: moreLabel,
                candidates: allOptions.filter { !value.contains($0.id) }) { id in
                guard value.count < max, !value.contains(id) else { return }
                value.append(id)
            }
            .sheetFeedback()
        }
    }
}

/// 两个固定图片来源只允许重排；调用方持有草稿，保存仍由外层编辑器负责。
struct SettingsBScrapeImageSourceOrder: View {
    @Binding var value: [String]
    var identifier = "scrape-image-source"

    var body: some View {
        ForEach(Array(value.enumerated()), id: \.element) { index, id in
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(id == "fanart" ? "Fanart.tv" : "TMDB")
                    Text(index == 0 ? String(localized: .settingsOrderChipsFirst) : String(localized: .settingsOrderChipsFallback))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(String(localized: .libraryCollectionsUp), systemImage: "arrow.up") { value.swapAt(index - 1, index) }
                        .disabled(index == 0)
                        .accessibilityIdentifier("\(identifier)-up-\(id)")
                    Button(String(localized: .libraryCollectionsDown), systemImage: "arrow.down") { value.swapAt(index, index + 1) }
                        .disabled(index == value.count - 1)
                        .accessibilityIdentifier("\(identifier)-down-\(id)")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17))
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel(String(localized: .settingsOrderChipsAdjust(id == "fanart" ? "Fanart.tv" : "TMDB")))
                .accessibilityIdentifier("\(identifier)-order-\(id)")
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 44)
                    .accessibilityLabel(String(localized: .settingsOrderChipsDrag(id == "fanart" ? "Fanart.tv" : "TMDB")))
                    .accessibilityIdentifier("\(identifier)-drag-\(id)")
            }
            .contentShape(.rect)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier)-row-\(id)")
            .accessibilityHint(String(localized: .settingsOrderChipsDragHint))
        }
        .onMove { offsets, destination in
            value.move(fromOffsets: offsets, toOffset: destination)
        }
        Text(String(localized: .settingsOrderChipsSourcesHint))
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct SettingsBScrapeMoreSheet: View {
    let moreLabel: String
    let candidates: [SettingsBScrapeChipOption]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [SettingsBScrapeChipOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return candidates.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        SubsSheetScaffold(title: String(localized: .settingsOrderChipsAdd(moreLabel)), closeTitle: String(localized: .commonCancel)) {
            SettingsFormSection {
                TextField(String(localized: .settingsOrderChipsSearch(moreLabel)), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("scrape-option-search")
            }
            SettingsFormSection {
                if filtered.isEmpty {
                    Text(String(localized: .settingsScrapeNoMatchingOptions(moreLabel))).foregroundStyle(.secondary)
                }
                ForEach(filtered, id: \.id) { option in
                    Button {
                        onPick(option.id)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(option.name).foregroundStyle(Theme.text)
                                if let tip = option.tip {
                                    Text(tip).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(option.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("scrape-more-option-\(option.id)")
                }
            }
        }
    }
}
