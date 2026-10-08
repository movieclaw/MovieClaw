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
                    Button("上移", systemImage: "arrow.up") {
                        value.swapAt(index - 1, index)
                    }
                    .disabled(index == 0)
                    .accessibilityIdentifier("\(identifier)-up-\(id)")
                    Button("下移", systemImage: "arrow.down") {
                        value.swapAt(index, index + 1)
                    }
                    .disabled(index == value.count - 1)
                    .accessibilityIdentifier("\(identifier)-down-\(id)")
                    Button("移除", systemImage: "minus.circle", role: .destructive) {
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
                .accessibilityLabel("调整\(option?.name ?? id)的优先级")
                .accessibilityIdentifier("\(identifier)-order-\(id)")
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 44)
                    .accessibilityLabel("拖动\(option?.name ?? id)调整顺序")
                    .accessibilityIdentifier("\(identifier)-drag-\(id)")
            }
            .contentShape(.rect)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier)-row-\(id)")
            .accessibilityHint("长按并拖动调整优先级，也可使用调整菜单。")
            .moveDisabled(value.count <= 1)
        }
        .onMove { offsets, destination in
            value.move(fromOffsets: offsets, toOffset: destination)
        }
        Button {
            moreOpen = true
        } label: {
            Label("添加\(moreLabel)", systemImage: "plus")
                .frame(minHeight: 44)
        }
        .disabled(value.count >= max)
        .accessibilityIdentifier("\(identifier)-more")
        Text("长按右侧手柄拖动，越靠上越优先。最多 \(max) 项，至少保留一项；保存后生效。")
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
                    Text(index == 0 ? "优先查找" : "缺少图片时补充")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("上移", systemImage: "arrow.up") { value.swapAt(index - 1, index) }
                        .disabled(index == 0)
                        .accessibilityIdentifier("\(identifier)-up-\(id)")
                    Button("下移", systemImage: "arrow.down") { value.swapAt(index, index + 1) }
                        .disabled(index == value.count - 1)
                        .accessibilityIdentifier("\(identifier)-down-\(id)")
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17))
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .accessibilityLabel("调整\(id == "fanart" ? "Fanart.tv" : "TMDB")的优先级")
                .accessibilityIdentifier("\(identifier)-order-\(id)")
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 17))
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 44)
                    .accessibilityLabel("拖动\(id == "fanart" ? "Fanart.tv" : "TMDB")调整顺序")
                    .accessibilityIdentifier("\(identifier)-drag-\(id)")
            }
            .contentShape(.rect)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("\(identifier)-row-\(id)")
            .accessibilityHint("长按并拖动调整优先级，也可使用调整菜单。")
        }
        .onMove { offsets, destination in
            value.move(fromOffsets: offsets, toOffset: destination)
        }
        Text("长按右侧手柄拖动，越靠上越优先。保存后生效。")
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
        SubsSheetScaffold(title: "添加\(moreLabel)", closeTitle: "取消") {
            SettingsFormSection {
                TextField("搜索\(moreLabel)名称或代码", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("scrape-option-search")
            }
            SettingsFormSection {
                if filtered.isEmpty {
                    Text("没有匹配的\(moreLabel)").foregroundStyle(.secondary)
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
