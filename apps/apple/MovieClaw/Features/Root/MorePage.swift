import SwiftUI

/// 「我的」页：居中个人信息 + 会话 / 下载 / 服务器胶囊切换。
/// 会话保持单行标题、时间、分页、左滑和长按操作；下载管理直接显示在页签中。
/// 入口按权限与在线状态裁剪，更新和待处理提醒归入服务器，并在胶囊上提示。
struct MorePage: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback
    @Environment(ShellBadges.self) private var badges
    @Environment(\.permissions) private var permissions
    @Environment(\.api) private var api
    @Environment(AgentQuickDraft.self) private var quick

    @State private var reachability = ServerReachability.shared
    @State private var offlineStore = OfflineStore.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedSection: MorePageSection = .conversations
    @State private var sessions: [API.SessionSummary] = []
    @State private var notices: [API.NoticeView] = []
    /// 还有更早的会话没取回（上一页取满了一整页）
    @State private var hasMoreSessions = false
    @State private var loadingMoreSessions = false
    /// 会话列表每页条数（Web agent-conversations 的 PAGE_SIZE）
    private static let pageSize = 20

    private var availableSections: [MorePageSection] {
        MorePageSection.available(isAdmin: permissions.isAdmin,
                                  canDownload: permissions.canDownloadVideo,
                                  hasDownloads: !offlineStore.items.isEmpty,
                                  isOffline: reachability.isOffline)
    }

    private var visibleSection: MorePageSection? {
        availableSections.contains(selectedSection) ? selectedSection : availableSections.first
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 26) {
                    if let session = model.session { profile(session) }
                    if availableSections.count > 1 { sectionPicker }
                }
                .padding(.top, 8)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            switch visibleSection {
            case .conversations: conversations
            case .downloads: OfflineStorageSections(embedded: true)
            case .server: server
            case nil: EmptyView()
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(8)
        .contentMargins(.top, 0, for: .scrollContent)
        .contentMargins(.bottom, 24, for: .scrollContent)
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
        .listSectionSeparator(.hidden)
        .environment(\.defaultMinListRowHeight, visibleSection == .conversations ? 44 : 60)
        .appBackground()
        // 保留原有 AI 输入框及跟随键盘的行为。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if permissions.isAdmin, !Self.accessoryAvailable { AgentQuickInput(quick: quick) }
        }
        .navigationTitle("我的")
        .toolbarTitleDisplayMode(.inlineLarge)
        .task { await loadSessions() }
        .polling(every: 30, immediately: true) { await loadNotices() }
        .agentComposerWarmup()
    }

    private func profile(_ session: API.SessionView) -> some View {
        Button {
            // 个人信息直接压栈，返回仍是「我的」，不垫服务器设置页。
            router.push(.settingsSection(.profile))
        } label: {
            VStack(spacing: 8) {
                AvatarBadge(session: session, size: 80)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .circle)
                            .overlay(Circle().stroke(Theme.background, lineWidth: 3))
                            .offset(x: 4, y: 2)
                    }
                    .padding(.bottom, 6)
                Text(session.nickname)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(identityLine(session))
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(session.nickname)，\(identityLine(session))")
        .accessibilityIdentifier("more-profile-card")
        .accessibilityHint("查看和修改个人信息；长按底部头像可以切换账号")
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(availableSections, id: \.self) { section in
                Button { selectedSection = section } label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 7))
                    layout {
                        Image(systemName: section.systemImage)
                            .overlay(alignment: .topTrailing) {
                                if section == .server, permissions.isAdmin,
                                   !notices.isEmpty || badges.updatePending {
                                    Circle()
                                        .fill(notices.isEmpty ? Theme.info : Theme.danger)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 4, y: -3)
                                }
                            }
                            .accessibilityHidden(true)
                        Text(section.title).multilineTextAlignment(.center)
                    }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding(.horizontal, 6)
                    .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
                    .background(visibleSection == section ? Color.white.opacity(0.09) : .clear, in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(visibleSection == section ? Theme.text : Theme.textMuted)
                .accessibilityIdentifier("more-tab-\(section.rawValue)")
                .accessibilityAddTraits(visibleSection == section ? .isSelected : [])
                .accessibilityValue(section == .server && permissions.isAdmin
                    ? [notices.isEmpty ? nil : "\(notices.count) 项待处理", badges.updateLabel].compactMap { $0 }.joined(separator: "，") : "")
            }
        }
        .padding(5)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .capsule)
    }

    private var conversations: some View {
        let now = Date()
        return Group {
            if sessions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有会话").font(.body.weight(.medium)).foregroundStyle(Theme.text)
                        Text("在下方输入框里问点什么吧。")
                            .font(.subheadline).foregroundStyle(Theme.textMuted)
                    }
                    .padding(.vertical, 8)
                }
            }
            ForEach(MoreConversationPeriod.allCases, id: \.self) { period in
                let items = sessions.filter { MoreConversationPeriod.of(Formatters.date($0.updatedAt), now: now) == period }
                if !items.isEmpty {
                    Section {
                        ForEach(items, id: \.id) { item in
                            sessionRow(item)
                                .onAppear {
                                    if item.id == sessions.last?.id { Task { await loadMoreSessions() } }
                                }
                        }
                    } header: {
                        Text(period.rawValue)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textMuted)
                            .textCase(nil)
                            .accessibilityIdentifier("more-conversation-period")
                    }
                }
            }
            if loadingMoreSessions {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var server: some View {
        Section {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("当前服务器").font(.footnote).foregroundStyle(Theme.textMuted)
                    if let server = model.server {
                        Text(server.hostLabel)
                            .font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityLabel("当前服务器 \(server.hostLabel)")
                            .accessibilityIdentifier("more-server-address")
                    }
                    MoreRouteRow(routes: [.settings], tint: Theme.accent) {
                        Text("服务器设置").font(.subheadline.weight(.medium))
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("more-settings")
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceInset, in: .rect(cornerRadius: 16))

                if permissions.isAdmin {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                    layout {
                        if !notices.isEmpty {
                            NavigationLink { NoticeCenterView() } label: {
                                serverTile("待处理", value: "\(notices.count) 项", detail: "查看提醒", tint: Theme.danger)
                            }
                            .buttonStyle(.plain)
                            .navigationLinkIndicatorVisibility(.hidden)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("more-notices")
                        }
                        if let label = badges.updateLabel {
                            MoreRouteRow(routes: [.settingsSection(.app)], showsChevron: false) {
                                serverTile("可用更新", value: label, detail: "查看版本详情", tint: Theme.info)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("more-update")
                        }
                    }
                }
            }
            .padding(.top, 12)
        }
        .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func serverTile(_ title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.footnote).foregroundStyle(Theme.textMuted)
            Text(value).font(.body.weight(.semibold)).foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(.footnote).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .padding(16)
        .background(Theme.surfaceInset, in: .rect(cornerRadius: 16))
    }

    /// 账户卡的身份小字：昵称和用户名不同时带上「@用户名」（相同就不重复），再带角色
    private func identityLine(_ session: API.SessionView) -> String {
        session.nickname != session.username ? "@\(session.username) · \(session.roleLabel)" : session.roleLabel
    }


    /// 会话行按 iOS 列表惯例处理操作（同邮件 / 信息）：行上不放「⋯」，左滑出三个纯图标按钮——
    /// 分支（在新会话中继续）/ 铅笔（重命名）/ 垃圾桶（删除）；续接与删除点了先确认、重命名先弹输入框，
    /// 所以不带文字也不怕误触。长按出同样三项的完整菜单（与会话页右上角同图标、同顺序）。
    /// 删除不允许一滑到底直接触发。
    ///
    /// 行的样子仿「信息」（2026-10-12 用户要求美化）：标题 + 右侧最近活动时间，运行中时右侧换成「进行中」+ 呼吸点。
    /// 试过第二行灰字放最近一次提问，用户觉得多余，只留一行。时间已在右侧，不再要箭头
    private func sessionRow(_ item: API.SessionSummary) -> some View {
        MoreRouteRow(routes: [.session(id: item.id)], showsChevron: false) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            layout {
                Text(title(of: item))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if item.running {
                    HStack(spacing: 5) {
                        MoreRunningDot()
                        Text("进行中")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.info)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.info.opacity(0.1), in: .capsule)
                } else if let updated = Formatters.date(item.updatedAt) {
                    Text(MoreConversationPeriod.of(updated) == .earlier
                         ? AgentTimeline.listTime(updated)
                         : updated.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .accessibilityIdentifier("more-session-row")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { Task { await remove(item) } } label: { Image(systemName: "trash") }
                .tint(.red)
                .accessibilityLabel("删除会话")
            Button { Task { await rename(item) } } label: { Image(systemName: "pencil") }
                .tint(.gray)
                .accessibilityLabel("重命名")
            Button { Task { await fork(item) } } label: { Image(systemName: "arrow.triangle.branch") }
                .tint(.blue)
                .accessibilityLabel("在新会话中继续")
        }
        .contextMenu { sessionActions(item) }
    }

    @ViewBuilder
    private func sessionActions(_ item: API.SessionSummary) -> some View {
        Button("在新会话中继续", systemImage: "arrow.triangle.branch") { Task { await fork(item) } }
        Button("重命名", systemImage: "pencil") { Task { await rename(item) } }
        Divider()
        Button("删除会话", systemImage: "trash", role: .destructive) { Task { await remove(item) } }
    }

    private static var accessoryAvailable: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }

    private func title(of item: API.SessionSummary) -> String {
        if let title = item.title, !title.isEmpty { return title }
        if let prompt = item.lastPrompt, !prompt.isEmpty { return prompt }
        return "未命名会话"
    }

    /// 取第一页（进页、从会话里回来时刷新）；失败保留上次结果
    private func loadSessions() async {
        guard permissions.isAdmin, let first = try? await api.sessionList(limit: Self.pageSize) else { return }
        sessions = first
        hasMoreSessions = first.count == Self.pageSize
    }

    /// 接着取下一页；按 id 去重（翻页期间有新会话插到最前，偏移会错开一条）
    private func loadMoreSessions() async {
        guard hasMoreSessions, !loadingMoreSessions else { return }
        loadingMoreSessions = true
        defer { loadingMoreSessions = false }
        guard let page = try? await api.sessionList(limit: Self.pageSize, offset: sessions.count) else { return }
        let known = Set(sessions.map(\.id))
        sessions += page.filter { !known.contains($0.id) }
        hasMoreSessions = page.count == Self.pageSize
    }

    private func loadNotices() async {
        guard permissions.isAdmin else { return }
        // 拉取失败保留上次结果，下一轮轮询自愈（同 Web）
        if let list = try? await api.noticesList() {
            notices = NoticeCenterView.visible(list)
        }
    }

    private func fork(_ item: API.SessionSummary) async {
        guard await feedback.confirm(
            "在新会话中继续「\(title(of: item))」？",
            message: "会带上这段对话的上下文开一个新会话接着聊，原会话保留不变。",
            confirmTitle: "创建新会话"
        ) else { return }
        do {
            let forked = try await api.sessionFork(sessionId: item.id)
            router.open(.session(id: forked.session.id))
        } catch {
            feedback.error("创建续接会话失败：\(error.localizedDescription)")
        }
    }

    private func rename(_ item: API.SessionSummary) async {
        // 初值是界面上显示的标题；去空白、截 80 字，没变化就不发请求（同 Web）
        let current = title(of: item)
        guard let input = await feedback.prompt("重命名会话", placeholder: "会话标题（最多 80 字）", initial: current, maxLength: 80) else { return }
        let name = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, name != current else { return }
        do {
            let updated = try await api.sessionRename(sessionId: item.id, body: .init(title: name))
            if let index = sessions.firstIndex(where: { $0.id == item.id }) { sessions[index] = updated }
        } catch {
            feedback.error("重命名失败：\(error.localizedDescription)")
        }
    }

    private func remove(_ item: API.SessionSummary) async {
        guard await feedback.confirm(
            "彻底删除会话「\(title(of: item))」？",
            message: "服务器上的完整对话记录将一并删除，此操作不可恢复。",
            confirmTitle: "彻底删除", destructive: true
        ) else { return }
        do {
            _ = try await api.sessionDelete(sessionId: item.id)
            sessions.removeAll { $0.id == item.id }
        } catch {
            feedback.error("删除失败：\(error.localizedDescription)")
        }
    }
}

/// 以用户当地的自然日分组，跨午夜与夏令时不按固定 24 小时倒推。
enum MoreConversationPeriod: String, CaseIterable {
    case today = "今天"
    case yesterday = "昨天"
    case earlier = "更早"

    static func of(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> Self {
        guard let date else { return .earlier }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        return .earlier
    }
}

/// 只有当前账号可用的内容才进入切换栏；旧服务器没有下载能力时也不显示空入口。
enum MorePageSection: String {
    case conversations, downloads, server

    var title: String {
        switch self {
        case .conversations: "会话"
        case .downloads: "下载"
        case .server: "服务器"
        }
    }

    var systemImage: String {
        switch self {
        case .conversations: "bubble.left.and.bubble.right"
        case .downloads: "arrow.down.to.line"
        case .server: "server.rack"
        }
    }

    static func available(isAdmin: Bool, canDownload: Bool, hasDownloads: Bool, isOffline: Bool) -> [Self] {
        var sections: [Self] = []
        if isAdmin && !isOffline { sections.append(.conversations) }
        if canDownload || hasDownloads { sections.append(.downloads) }
        if !isOffline { sections.append(.server) }
        return sections
    }
}

/// 运行中会话的提示点：信息蓝 + 呼吸（Web `bg-[var(--info)] animate-pulse`）
private struct MoreRunningDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.info)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel("运行中")
    }
}

/// 「我的」页的跳转行：经 Router 在主导航里打开目标页（设置、会话这类不归属任何标签的页面，
/// 就压在「我的」标签自己的栈里）。
/// `routes` 依次压栈（第一个走 `open` 定标签，其余 `push`），用于还原 Web 的返回链。
private struct MoreRouteRow<Content: View>: View {
    let routes: [AppRoute]
    var tint: Color = Theme.text
    var showsChevron = true
    @ViewBuilder let label: () -> Content
    @Environment(Router.self) private var router

    var body: some View {
        Button {
            guard let first = routes.first else { return }
            router.open(first)
            for route in routes.dropFirst() { router.push(route) }
        } label: {
            HStack {
                label()
                if showsChevron {
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(tint)
    }
}
