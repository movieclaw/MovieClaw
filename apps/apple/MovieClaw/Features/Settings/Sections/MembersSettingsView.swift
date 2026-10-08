import SwiftUI

/// 成员列表只呈现身份与账号状态，权限和管理操作在详情页逐项展开。
struct MembersSettingsView: View {
    @Environment(\.api) private var api
    @State private var members: Loadable<[API.MemberView]> = .loading
    @State private var search = ""
    @State private var creating = false
    @State private var selectedID: Int?
    @State private var error: String?

    var body: some View {
        List {
            switch members {
            case .loading: SettingsLoadingRow()
            case let .failed(message): retry(message)
            case let .loaded(rows):
                if let error { SettingsFormSection { retry(error) } }
                let matches = MemberPresentation.matching(rows, search: search)
                ForEach([true, false], id: \.self) { active in
                    let group = matches.filter { ($0.status == "active") == active }
                    if !group.isEmpty {
                        SettingsFormSection("\(active ? "已启用" : "已停用") · \(group.count)") {
                            ForEach(group) { member in
                                Button { selectedID = member.id } label: { MemberListRow(member: member) }
                                    .accessibilityIdentifier("member-row-\(member.username)")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .appBackground()
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if let rows = members.value, MemberPresentation.matching(rows, search: search).isEmpty {
                if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView {
                        Label("还没有成员", systemImage: "person.2")
                    } description: {
                        Text("为家人或朋友创建独立账号，分别管理权限和可见内容。")
                    } actions: {
                        Button("添加成员") { creating = true }.buttonStyle(.borderedProminent)
                    }
                } else { ContentUnavailableView.search(text: search) }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索昵称或用户名")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加成员", systemImage: "plus") { creating = true }
                    .accessibilityIdentifier("member-add")
            }
        }
        .navigationDestination(item: $selectedID) { id in
            if let member = members.value?.first(where: { $0.id == id }) {
                MemberDetailView(member: member, onUpdated: replace) {
                    selectedID = nil
                    if let rows = members.value { members = .loaded(rows.filter { $0.id != id }) }
                }
            }
        }
        .sheet(isPresented: $creating) {
            CreateMemberSheet { member in
                members = .loaded((members.value ?? []) + [member])
            }.sheetFeedback()
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func retry(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(.secondary)
            Button("重试") { Task { await load() } }
        }
    }

    private func load() async {
        do { members = .loaded(try await api.membersList()); error = nil }
        catch {
            if members.value == nil { members = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    private func replace(_ member: API.MemberView) {
        guard var rows = members.value, let index = rows.firstIndex(where: { $0.id == member.id }) else { return }
        rows[index] = member
        members = .loaded(rows)
    }
}

enum MemberPresentation {
    static func matching(_ members: [API.MemberView], search: String) -> [API.MemberView] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return members.filter { query.isEmpty || $0.nickname.localizedStandardContains(query) || $0.username.localizedStandardContains(query) }
    }

    static func libraries(_ member: API.MemberView) -> String {
        if member.allLibraries { return member.libraryIds.isEmpty ? "全部共享库" : "全部共享库及单独授权" }
        return member.libraryIds.isEmpty ? "未分配" : "\(member.libraryIds.count) 个媒体库"
    }

    static func age(_ member: API.MemberView) -> String {
        member.contentAgeLimit.map { "\($0) 岁以下" } ?? "不限"
    }
}

private struct MemberListRow: View {
    let member: API.MemberView
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarBadge(session: nil, avatarUrl: member.avatarUrl, nickname: member.nickname, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                if member.nickname.caseInsensitiveCompare(member.username) == .orderedSame {
                    Text(member.nickname).font(.body).foregroundStyle(.primary).lineLimit(1)
                } else {
                    Text("\(member.nickname) \(Text("· @\(member.username)").foregroundStyle(.secondary))")
                        .font(.body).foregroundStyle(.primary).lineLimit(1)
                }
                Text(member.deviceCount == 0 ? "暂无登录设备" : "\(member.deviceCount) 台登录设备")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// 设置弹层的统一外壳：导航栏左「取消」、右主操作（带忙碌态），内容是分组表单
struct SettingsSheetScaffold<Content: View>: View {
    let title: String
    var confirmTitle: String?
    var confirmDisabled = false
    var busy = false
    var cancelTitle = "取消"
    var confirmIdentifier = "sheet-confirm"
    var onConfirm: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content() }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(cancelTitle) { dismiss() }
                            .accessibilityIdentifier("sheet-cancel")
                    }
                    if let confirmTitle, let onConfirm {
                        ToolbarItem(placement: .confirmationAction) {
                            if busy {
                                ProgressView()
                            } else {
                                Button(confirmTitle, action: onConfirm)
                                    .disabled(confirmDisabled)
                                    .accessibilityIdentifier(confirmIdentifier)
                            }
                        }
                    }
                }
        }
        .presentationBackground(Theme.background)
    }
}
