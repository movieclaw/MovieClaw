import SwiftUI

/// 「我的」页：标签栏最右的头像页签（Web `/my` 与 components/more-page.tsx）。
///
/// iOS 设置式分组列表（2026-09-29 按 iOS 设置 App 的惯例重排：分组不写标题，靠间距区分）：
/// - 账户卡：头像 + 昵称 + 身份小字（和昵称不同时才带 `@用户名`、角色）。不显示服务器（2026-09-29 用户决定）；
///   点进「个人信息」，同 iOS 设置 App 顶部的账户卡；返回直接回到本页，不垫设置列表。
///   切换账号是高频操作，走底部头像页签的长按 / 双击（见 TabBarAccountGestures），不在这里占一行；
///   能看见的兜底入口「切换账号」与「退出登录」一起放在个人信息页最底部（iOS 账户详情页惯例）；
/// - 提醒组（仅管理员、有事才出现，同 iOS 设置 App 账户卡下的「有可用更新」）：待处理（30 秒轮询）/
///   应用更新（文案「新版本 vX」或「新识别模型 X」）；
/// - 服务器设置：标题下面一行小字写当前服务器地址（iOS 副标题行，与账户卡「昵称 / 超级管理员」、服务器设置页
///   各分区的「标题 / 说明」同一写法），回答「这些设置改的是哪台」，也让人一眼看到 App 连的是哪个地址。
///   试过分组下方的说明文字（footer，悬在卡片外没有一体感）和同一行右侧灰字，用户选了副标题（2026-09-29）。
///   「关于 MovieClaw」不占这里的位置（低频，用户认为太重），放在服务器设置页最底部；
/// - 最近会话（管理员）：首行「新会话」（加号，顶栏的「+」已去掉，这里是发起新会话的入口），下面是 AI 会话，
///   每页 20 条、滑到末尾自动加载下一页（用户决定不要「显示全部 / 收起」，与 Web 的差异）；
///   操作走 iOS 列表惯例：左滑出续接 / 重命名 / 删除三个图标按钮，长按出完整菜单（与会话页右上角同图标、同顺序）。
///
/// 原先是点左上角头像弹出的 sheet（右上「完成」关闭），2026-09-26 头像挪进标签栏后改为标签根页；
/// 站内链接 `/my` 也切到这个标签（Router.tabRoot）。
struct MorePage: View {
    @Environment(AppModel.self) private var model
    @Environment(Router.self) private var router
    @Environment(Feedback.self) private var feedback
    @Environment(ShellBadges.self) private var badges
    @Environment(\.permissions) private var permissions
    @Environment(\.api) private var api

    @State private var sessions: [API.SessionSummary] = []
    @State private var notices: [API.NoticeView] = []
    /// 还有更早的会话没取回（上一页取满了一整页）
    @State private var hasMoreSessions = false
    @State private var loadingMoreSessions = false
    /// 会话列表每页条数（Web agent-conversations 的 PAGE_SIZE）
    private static let pageSize = 20

    var body: some View {
        List {
            if let session = model.session {
                Section {
                    // 用 push 而不是 open：open 会先垫一层设置列表，这里要的是返回直接回「我的」
                    Button {
                        router.push(.settingsSection(.profile))
                    } label: {
                        HStack(spacing: 14) {
                            AvatarBadge(session: session, size: 56)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(session.nickname).font(.title3.weight(.semibold))
                                // 一行小字，不带图标：列表会把行里的 Label 当成这一行的图标 + 正文来排，
                                // 图标被撑到行首图标列、分割线也改对齐到它（2026-09-29 真机截图）
                                Text(identityLine(session))
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.textFaint)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(Theme.text)
                    .accessibilityIdentifier("more-profile-card")
                    .accessibilityHint("查看和修改个人信息；长按底部头像可以切换账号")
                }
            }

            if permissions.isAdmin, !notices.isEmpty || badges.updateLabel != nil {
                Section {
                    if !notices.isEmpty {
                        NavigationLink {
                            NoticeCenterView()
                        } label: {
                            Label {
                                HStack {
                                    Text("待处理").fontWeight(.medium)
                                    Spacer()
                                    Text("\(notices.count)")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Theme.danger, in: .capsule)
                                }
                            } icon: {
                                Image(systemName: "bell")
                            }
                            .foregroundStyle(Theme.danger)
                        }
                        .accessibilityIdentifier("more-notices")
                    }
                    if let label = badges.updateLabel {
                        MoreRouteRow(routes: [.settingsSection(.app)], tint: Theme.info) {
                            Label(label, systemImage: "arrow.down.app")
                        }
                        .accessibilityIdentifier("more-update")
                    }
                }
            }

            Section {
                // 这里改的都是服务器上的配置，与 App 本机偏好区分开；成员进去只看得到自己的设备
                MoreRouteRow(routes: [.settings]) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务器设置")
                            if let server = model.server {
                                // 太长时中间省略：开头认得出是哪台，结尾保住端口
                                Text(server.hostLabel)
                                    .font(.caption)
                                    .foregroundStyle(Theme.textMuted)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityLabel("当前服务器 \(server.hostLabel)")
                            }
                        }
                    } icon: {
                        Image(systemName: "gearshape")
                    }
                }
                .accessibilityIdentifier("more-settings")
            }

            if permissions.isAdmin {
                Section("最近会话") {
                    MoreRouteRow(routes: [.newSession], tint: Theme.accentStrong) {
                        Label("新会话", systemImage: "plus").fontWeight(.medium)
                    }
                    // 这一组只有首行带图标：分割线默认对齐到图标后的文字，比下面会话行的短一截、像没画全，
                    // 对齐到行首与下面一致
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .accessibilityIdentifier("more-new-session")
                    if sessions.isEmpty {
                        Text("还没有会话，点上方的「新会话」开始。")
                            .font(.caption)
                            .foregroundStyle(Theme.textFaint)
                    }
                    ForEach(sessions, id: \.id) { item in
                        sessionRow(item)
                            // 滑到最后一条时接着取下一页，不再要「显示全部」
                            .onAppear {
                                if item.id == sessions.last?.id { Task { await loadMoreSessions() } }
                            }
                    }
                    if loadingMoreSessions {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    }
                }
            }
        }
        .appBackground()
        .navigationTitle("我的")
        // 与媒体库、订阅、活动等标签根页同一种左对齐大标题（和右上角的扫码 · 搜索同一行）
        .toolbarTitleDisplayMode(.inlineLarge)
        .task { await loadSessions() }
        // 待处理事项与 Web NoticeCenter 同频 30 秒轮询（首轮立即拉）
        .polling(every: 30, immediately: true) { await loadNotices() }
        // 最近会话的入口页：空闲时预热一次输入框，点进会话时首屏不再被它拖慢
        .agentComposerWarmup()
    }

    /// 账户卡的身份小字：昵称和用户名不同时带上「@用户名」（相同就不重复），再带角色
    private func identityLine(_ session: API.SessionView) -> String {
        session.nickname != session.username ? "@\(session.username) · \(session.roleLabel)" : session.roleLabel
    }


    /// 会话行按 iOS 列表惯例处理操作（同邮件 / 信息）：行上不放「⋯」，左滑出三个纯图标按钮——
    /// 分支（在新会话中继续）/ 铅笔（重命名）/ 垃圾桶（删除）；续接与删除点了先确认、重命名先弹输入框，
    /// 所以不带文字也不怕误触。长按出同样三项的完整菜单（与会话页右上角同图标、同顺序）。
    /// 删除不允许一滑到底直接触发。
    private func sessionRow(_ item: API.SessionSummary) -> some View {
        MoreRouteRow(routes: [.session(id: item.id)]) {
            HStack(spacing: 10) {
                if item.running {
                    MoreRunningDot()
                }
                Text(title(of: item)).lineLimit(1)
            }
        }
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

/// 运行中会话的提示点：信息蓝 + 呼吸（Web `bg-[var(--info)] animate-pulse`）
private struct MoreRunningDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.info)
            .frame(width: 6, height: 6)
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
                Spacer()
                if showsChevron {
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
