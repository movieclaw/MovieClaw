import SwiftUI

struct MemberDetailView: View {
    let member: API.MemberView
    let onUpdated: (API.MemberView) -> Void
    let onDeleted: () -> Void
    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var editing: MemberEditSection?
    @State private var password: MemberPasswordResult?
    @State private var busy = false

    var body: some View {
        Form {
            SettingsFormSection {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                layout {
                    AvatarBadge(session: nil, avatarUrl: member.avatarUrl, nickname: member.nickname, size: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(member.nickname).font(.title3.weight(.semibold))
                        Text("@\(member.username)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                editRow(.profile, value: "昵称与账号")
            }
            SettingsFormSection("权限与可见内容") {
                // 共用一个行背景，避免原生相邻行在小数像素边界露出黑色接缝。
                VStack(spacing: 0) {
                    editRow(.permissions, value: permissionSummary).padding(.vertical, 12)
                    SettingsRowSeparator().padding(.horizontal, -16)
                    editRow(.content, value: MemberPresentation.age(member)).padding(.vertical, 12)
                    SettingsRowSeparator().padding(.horizontal, -16)
                    editRow(.libraries, value: MemberPresentation.libraries(member)).padding(.vertical, 12)
                    if member.allowSearch {
                        SettingsRowSeparator().padding(.horizontal, -16)
                        editRow(.sites, value: member.allSites ? "全部启用站点" : "\(member.siteIds.count) 个站点")
                            .padding(.vertical, 12)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
            }
            SettingsFormSection("登录与安全") {
                LabeledContent("登录设备", value: "\(member.deviceCount) 台")
                LabeledContent("最近登录", value: member.lastLoginAt.map { Formatters.relative($0) } ?? "从未登录")
                Button("重置密码", systemImage: "key") { Task { await resetPassword() } }
                    .accessibilityIdentifier("member-reset-password")
            }
        }
        .appBackground()
        .disabled(busy)
        .navigationTitle("成员详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text("成员详情").font(.headline)
                    Image(systemName: member.status == "active" ? "checkmark.circle.fill" : "pause.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(member.status == "active" ? Theme.success : Color.red)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("成员详情，\(member.status == "active" ? "已启用" : "已停用")")
                .accessibilityIdentifier("member-detail-title")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if busy { ProgressView() }
                else { actions }
            }
        }
        .sheet(item: $editing) { section in
            MemberEditSheet(member: member, section: section) { next in
                onUpdated(next)
                editing = nil
            }.sheetFeedback()
        }
        .sheet(item: $password) { result in MemberPasswordSheet(result: result) }
    }

    private var actions: some View {
        Menu {
            if member.deviceCount > 0 {
                Button("全部设备下线", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await signOut() }
                }.accessibilityIdentifier("member-signout")
            }
            if member.status == "active" {
                Button("停用成员", systemImage: "pause.circle.fill", role: .destructive) { Task { await toggleStatus() } }
                    .accessibilityIdentifier("member-disable")
            } else {
                Button("启用成员", systemImage: "checkmark.circle.fill") { Task { await toggleStatus() } }
                    .accessibilityIdentifier("member-enable")
            }
            Divider()
            Button("删除成员", systemImage: "trash", role: .destructive) { Task { await remove() } }
                .accessibilityIdentifier("member-delete")
        } label: { Label("成员操作", systemImage: "ellipsis") }
        .accessibilityIdentifier("member-actions")
    }

    private var permissionSummary: String {
        let enabled = [member.allowSubscribe ? "订阅" : nil, member.allowSearch ? "搜索" : nil,
                       member.allowDirectDownload ? "下载" : nil].compactMap { $0 }
        return enabled.isEmpty ? "仅浏览与播放" : enabled.joined(separator: "、")
    }

    private func editRow(_ section: MemberEditSection, value: String) -> some View {
        Button { editing = section } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).foregroundStyle(.primary)
                    Text(value).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("member-edit-\(section.rawValue)")
    }

    private func resetPassword() async {
        guard !busy else { return }
        guard await feedback.confirm("重置「\(member.nickname)」的密码？",
            message: "旧密码和网页、App、播放器上的登录会立即失效，已配对的命令行保留。新密码只显示一次。",
            confirmTitle: "重置密码", destructive: true) else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await api.membersPasswordReset(memberId: member.id)
            password = .init(title: "密码已重置", username: result.username, password: result.password)
            if let next = try? await api.membersList().first(where: { $0.id == member.id }) { onUpdated(next) }
        } catch { feedback.error(error) }
    }

    private func signOut() async {
        guard !busy else { return }
        guard await feedback.confirm("让「\(member.nickname)」的全部设备下线？",
            message: "网页、App、命令行和播放器上的登录都会失效，正在播放的内容也会停止。账号保留，重新登录即可使用。",
            confirmTitle: "全部下线", destructive: true) else { return }
        busy = true
        defer { busy = false }
        do { onUpdated(try await api.membersSignOut(memberId: member.id)); feedback.success("全部设备已下线") }
        catch { feedback.error(error) }
    }

    private func toggleStatus() async {
        guard !busy else { return }
        let enabled = member.status != "active"
        if !enabled {
            guard await feedback.confirm("停用「\(member.nickname)」？",
                message: "全部设备会立即下线，个人数据和订阅保留，可随时重新启用。",
                confirmTitle: "停用成员", destructive: true) else { return }
        }
        busy = true
        defer { busy = false }
        do { onUpdated(try await api.membersStatusSet(memberId: member.id, body: .init(enabled: enabled))) }
        catch { feedback.error(error) }
    }

    private func remove() async {
        guard !busy else { return }
        guard await feedback.confirm("删除成员「\(member.nickname)」？",
            message: "头像、播放进度等个人数据会被清理；订阅转由管理员接管，已下载内容不受影响。此操作不可恢复。",
            confirmTitle: "删除成员", destructive: true) else { return }
        busy = true
        defer { busy = false }
        do { try await api.membersDelete(memberId: member.id); onDeleted() }
        catch { feedback.error(error) }
    }
}
