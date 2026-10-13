import SwiftUI

/// 详情页「文件」区里本机副本那一行（docs/design/offline-download.md §8）：与服务器上的文件行同一个样子，
/// 文件名后标「本机」；展开的信息与源文件一致，只是保存位置写本机、时间写下载时间、尺寸写本机这份的大小。
/// 转码档是另一份文件：只列确定知道的（档位、大小），不把源文件的码率、编码冒充成本机的。
/// 右边垃圾桶立即删除（不进回收站），确认里说明删除后没网就不能播了；长按可改下其他画质。
///
/// 自己读本机目录：详情页只按「下完的文件」这个派生集合决定放不放这一行，下载进度刷新不会重算整页
struct OfflineLocalFileRow: View {
    let fileId: Int
    /// 服务器上的源文件（同一个文件号）：展开时借它的规格
    let source: API.LibraryFileView?
    /// 改下其他画质时选档面板的标题
    let title: String

    @Environment(\.permissions) private var permissions
    @State private var store = OfflineStore.shared
    @State private var reachability = ServerReachability.shared
    @State private var expanded = false
    @State private var confirmDelete = false
    @State private var picking = false

    var body: some View {
        if let unit = store.units[fileId], unit.playable {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(Theme.textFaint)
                            Text(source?.fileName ?? title)
                                .font(.footnote)
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(expanded ? nil : 1)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("local-file-row-\(fileId)")
                    .accessibilityValue("\(unit.state.rawValue)|\(unit.profile)")
                    .contextMenu {
                        if canChangeProfile {
                            Button("改下其他画质", systemImage: "arrow.triangle.2.circlepath") { picking = true }
                        }
                        Button("从 iPhone 删除", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                    localTag
                    Button { confirmDelete = true } label: { Image(systemName: "trash").font(.footnote) }
                        .foregroundStyle(Theme.textFaint)
                        .accessibilityLabel("从 iPhone 删除")
                        .accessibilityIdentifier("local-file-delete-\(fileId)")
                        // 确认气泡从这个按钮弹出
                        .confirmationDialog("删除 iPhone 上的这份副本？", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("删除（释放 \(Formatters.bytes(Int(unit.receivedBytes)))）", role: .destructive) {
                                OfflineDownloader.shared.delete(fileId: fileId)
                            }
                        } message: {
                            Text("立即删除，不进回收站。删除后没网时就不能播放了，要离线看得重新下载；观看进度会保留。")
                        }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                if expanded { details(unit) }
            }
            .sheet(isPresented: $picking) {
                OfflineProfileSheet(fileId: fileId, title: title)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var canChangeProfile: Bool {
        !reachability.isOffline && permissions.canDownloadVideo && source != nil
    }

    private var localTag: some View {
        Label("本机", systemImage: "iphone")
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.success)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Theme.success.opacity(0.12), in: .capsule)
            .accessibilityIdentifier("local-file-tag")
    }

    private func details(_ unit: OfflineUnit) -> some View {
        let original = unit.profile == "original"
        let iso = unit.completedAt.map { $0.ISO8601Format() }
        let downloaded = iso.map { "\(Formatters.dateTime($0)) · \(libraryFromNow($0))" } ?? "—"
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            row("保存位置", "本机（iPhone · MovieClaw 下载）")
            row("下载时间", downloaded)
            row("来源", original ? "从服务器下载 · 原画" : "服务器转码 · \(unit.profileLabel)")
            row("文件尺寸", libraryBytes(Int(unit.receivedBytes)))
            if original, let source {
                // 原画就是源文件的字节：规格照抄
                ForEach(LibraryFileRow.specRows(source), id: \.self) { item in row(item.label, item.value) }
            } else {
                row("画面规格", unit.profileLabel)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(Theme.textFaint)
            Text(value).font(.footnote).foregroundStyle(Theme.textMuted).textSelection(.enabled)
        }
    }
}
