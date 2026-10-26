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
                editRow(.profile, value: String(localized: .settingsMemberDetailProfile))
            }
            SettingsFormSection(String(localized: .settingsMemberDetailPermissions)) {
                // 共用一个行背景，避免原生相邻行在小数像素边界露出黑色接缝。
                VStack(spacing: 0) {
                    editRow(.permissions, value: permissionSummary).padding(.vertical, 12)
                    SettingsRowSeparator().padding(.horizontal, -16)
                    editRow(.content, value: MemberPresentation.age(member)).padding(.vertical, 12)
                    SettingsRowSeparator().padding(.horizontal, -16)
                    editRow(.libraries, value: MemberPresentation.libraries(member)).padding(.vertical, 12)
                    if member.allowSearch {
                        SettingsRowSeparator().padding(.horizontal, -16)
                        editRow(.sites, value: member.allSites ? String(localized: .settingsMembersAccessAllSites) : String(localized: .settingsMemberDetailSiteCount(member.siteIds.count)))
                            .padding(.vertical, 12)
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
            }
            SettingsFormSection(String(localized: .settingsMemberDetailSecurity)) {
                LabeledContent(String(localized: .settingsMemberDetailDevices), value: String(localized: .settingsPushChannelsCoveredCount(member.deviceCount)))
                LabeledContent(String(localized: .settingsMemberDetailLastSignIn), value: member.lastLoginAt.map { Formatters.relative($0) } ?? String(localized: .settingsMembersUiNeverSignedIn))
                Button(String(localized: .settingsMembersActionsReset), systemImage: "key") { Task { await resetPassword() } }
                    .accessibilityIdentifier("member-reset-password")
            }
        }
        .appBackground()
        .disabled(busy)
        .navigationTitle(String(localized: .settingsMemberDetailTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(String(localized: .settingsMemberDetailTitle)).font(.headline)
                    Image(systemName: member.status == "active" ? "checkmark.circle.fill" : "pause.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(member.status == "active" ? Theme.success : Color.red)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: .settingsMemberDetailAria(member.status == "active" ? String(localized: .settingsMemberDetailEnabled) : String(localized: .settingsMemberDetailDisabled))))
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
                Button(String(localized: .settingsMemberDetailSignOutAll), systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await signOut() }
                }.accessibilityIdentifier("member-signout")
            }
            if member.status == "active" {
                Button(String(localized: .settingsMembersActionsDisable), systemImage: "pause.circle.fill", role: .destructive) { Task { await toggleStatus() } }
                    .accessibilityIdentifier("member-disable")
            } else {
                Button(String(localized: .settingsMembersActionsEnable), systemImage: "checkmark.circle.fill") { Task { await toggleStatus() } }
                    .accessibilityIdentifier("member-enable")
            }
            Divider()
            Button(String(localized: .settingsMembersActionsDelete), systemImage: "trash", role: .destructive) { Task { await remove() } }
                .accessibilityIdentifier("member-delete")
        } label: { Label(String(localized: .settingsMemberDetailActions), systemImage: "ellipsis") }
        .accessibilityIdentifier("member-actions")
    }

    private var permissionSummary: String {
        let enabled = [member.allowSubscribe ? String(localized: .settingsMembersUiSubscribe) : nil, member.allowSearch ? String(localized: .commonSearch) : nil,
                       member.allowDirectDownload ? String(localized: .settingsMembersUiDownload) : nil].compactMap { $0 }
        return enabled.isEmpty ? String(localized: .settingsMembersUiBrowseOnly) : enabled.joined(separator: "、")
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
        guard await feedback.confirm(String(localized: .settingsMembersActionsResetTitle(member.nickname)),
            message: String(localized: .settingsMemberDetailResetHint),
            confirmTitle: String(localized: .settingsMembersActionsReset), destructive: true) else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await api.membersPasswordReset(memberId: member.id)
            password = .init(title: String(localized: .settingsMembersCredentialsReset), username: result.username, password: result.password)
            if let next = try? await api.membersList().first(where: { $0.id == member.id }) { onUpdated(next) }
        } catch { feedback.error(error) }
    }

    private func signOut() async {
        guard !busy else { return }
        guard await feedback.confirm(String(localized: .settingsMemberDetailSignOutTitle(member.nickname)),
            message: String(localized: .settingsMemberDetailSignOutHint),
            confirmTitle: String(localized: .settingsMembersActionsSignOut), destructive: true) else { return }
        busy = true
        defer { busy = false }
        do { onUpdated(try await api.membersSignOut(memberId: member.id)); feedback.success(String(localized: .settingsMemberDetailSignedOut)) }
        catch { feedback.error(error) }
    }

    private func toggleStatus() async {
        guard !busy else { return }
        let enabled = member.status != "active"
        if !enabled {
            guard await feedback.confirm(String(localized: .settingsMembersActionsDisableTitle(member.nickname)),
                message: String(localized: .settingsMemberDetailDisableHint),
                confirmTitle: String(localized: .settingsMembersActionsDisable), destructive: true) else { return }
        }
        busy = true
        defer { busy = false }
        do { onUpdated(try await api.membersStatusSet(memberId: member.id, body: .init(enabled: enabled))) }
        catch { feedback.error(error) }
    }

    private func remove() async {
        guard !busy else { return }
        guard await feedback.confirm(String(localized: .settingsMembersActionsDeleteTitle(member.nickname)),
            message: String(localized: .settingsMembersActionsDeleteHint),
            confirmTitle: String(localized: .settingsMembersActionsDelete), destructive: true) else { return }
        busy = true
        defer { busy = false }
        do { try await api.membersDelete(memberId: member.id); onDeleted() }
        catch { feedback.error(error) }
    }
}
