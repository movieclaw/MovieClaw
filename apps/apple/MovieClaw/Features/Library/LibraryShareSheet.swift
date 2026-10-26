import SwiftUI
import UIKit

/// 影片 / 合集分享弹层（Web `components/share-dialog.tsx`，设计见 docs/design/media-share.md §1.1）。
///
/// 一个弹层两种形态，与 Web 相同：
/// - (a) 还没分享 → 表单：有效期四档（默认 7 天）+ 密码开关（自动生成 6 位访问码，可改可换）；
/// - (b) 已有有效分享 → 链接 / 密码 / 到期 / 打开次数，可复制，可「取消分享」。
///
/// 「生成链接」成功后原地切到 (b)，不关弹层；「取消分享」二次确认后回到 (a)，
/// 可以马上再生成一条新链接（slug 换新）。条目分享与合集分享要填的东西逐字相同，
/// 只是落到的接口不同，所以共用一个弹层，由 `Target` 二选一。
///
/// 分享链接：后端在未配置「外部访问地址」时只给相对路径 `/s/{slug}`，Web 用当前页面
/// origin 补全；App 里的等价物是当前连接的服务器根地址 `api.server.origin`。
struct LibraryShareSheet: View {
    enum Target: Hashable {
        case item(libraryId: Int, mediaItemId: Int)
        case collection(id: Int)
    }

    let target: Target
    let title: String
    var kind: String? = nil
    var year: Int? = nil
    var posterUrl: String? = nil
    /// 剧集的范围提醒（如「已入库 3 季 24 集」）；合集传「12 部 · 会自动收录新片」这类；电影不传
    var seasonSummary: String? = nil
    /// 调用方已 GET 过现有分享时传入；不传则弹层自己查一次
    var initialShare: API.ShareView? = nil

    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(\.dismiss) private var dismiss

    @State private var share: API.ShareView?
    /// 是否已确定「现在有没有分享」（调用方没传现状时要先查一次，避免先闪出创建表单）
    @State private var resolved = false
    @State private var days = shareDefaultDays
    @State private var passwordOn = false
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingRevoke = false
    @State private var copiedRow: String?

    var body: some View {
        NavigationStack {
            Group {
                if !resolved {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        header
                        if let share {
                            readySections(share)
                        } else {
                            createSections
                        }
                    }
                    .subsFormStyle()
                }
            }
            // 高度贴合内容、半透明的液态玻璃弹层（2026-09-30 用户要求：不必拉全屏，同订阅弹层）；上拉仍可到全高
            .modifier(SubsFittedDetents(ready: resolved))
            .navigationTitle(share != nil ? String(localized: .libraryShareSharedTitle(title)) : String(localized: .libraryShareShareTitle(title)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .alert(String(localized: .libraryShareRevokeTitle(title)), isPresented: $confirmingRevoke) {
                Button(String(localized: .libraryItemNotNow), role: .cancel) {}
                Button(String(localized: .libraryShareRevoke), role: .destructive) { Task { await revoke() } }
            } message: {
                Text(String(localized: .libraryShareRevokeDetail))
            }
        }
        .interactiveDismissDisabled(busy)
        .task { await resolveCurrent() }
    }

    // MARK: - 头部（影片身份常驻）

    private var header: some View {
        Section {
            HStack(spacing: 14) {
                RemoteImage(url: api.image(posterUrl, width: ImageWidth.points(48)))
                    .frame(width: 48, height: 72)
                    .clipShape(.rect(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    Text(String(localized: .libraryShareAnyoneHint))
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 副标题：年份 · 形态 · 范围提醒（合集没有形态与年份，只剩调用方给的那一格）
    private var subtitle: String {
        let kindLabel = kind.flatMap { shareKindLabels[$0] }
        let tail: String? = if let seasonSummary {
            [kindLabel, seasonSummary].compactMap { $0 }.joined(separator: " · ")
        } else {
            kindLabel
        }
        return [year.map(String.init), tail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - (a) 创建表单

    @ViewBuilder
    private var createSections: some View {
        Section {
            Picker(String(localized: .libraryShareExpiry), selection: $days) {
                ForEach(shareExpiryOptions, id: \.days) { option in
                    Text(option.label).tag(option.days)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text(String(localized: .libraryShareExpiry))
        } footer: {
            Text(String(localized: .libraryShareExpiresIn(days, Formatters.dateTime(isoString(Date.now.addingTimeInterval(Double(days) * 86_400))))))
        }

        Section {
            Toggle(String(localized: .libraryShareProtection), isOn: Binding(mcGet: { passwordOn }, set: { _ in togglePassword() }))
            if passwordOn {
                HStack(spacing: 10) {
                    TextField(String(localized: .libraryShareAccessPassword), text: Binding(
                        get: { password },
                        set: { password = String($0.prefix(shareMaxPassword)); error = nil }
                    ))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(String(localized: .libraryShareAccessPassword))
                    Button {
                        password = generateSharePassword()
                        error = nil
                    } label: {
                        Label(String(localized: .libraryShareRegenerate), systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textMuted)
                }
            }
        } footer: {
            Text(passwordOn
                ? String(localized: .librarySharePasswordHint)
                : String(localized: .libraryShareNoPasswordHint))
        }

        if let error {
            Section {
                Text(error).font(.subheadline).foregroundStyle(Theme.danger)
            }
        }

        Section {
        } footer: {
            Text(String(localized: .libraryShareActivityHint))
        }
    }

    // MARK: - (b) 已分享

    @ViewBuilder
    private func readySections(_ share: API.ShareView) -> some View {
        let link = absoluteShareURL(share.url)
        Section {
            copyRow(label: String(localized: .libraryShareLink), value: link, mono: false) { copy(link, String(localized: .libraryShareLink)) }
            if let pw = share.password {
                copyRow(label: String(localized: .librarySharePassword), value: pw, mono: true, locked: true) { copy(pw, String(localized: .librarySharePassword)) }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(facts(share)).monospacedDigit()
                if isRelativeShareURL(share.url) {
                    Text(String(localized: .libraryShareServerOriginHint))
                }
            }
        }

        Section {
            Button {
                copy(shareCopyText(title: title, url: link, password: share.password), String(localized: .libraryShareLinkAndPassword))
            } label: {
                Label(share.password != nil ? String(localized: .libraryShareCopyProtected) : String(localized: .libraryShareCopyLink), systemImage: "doc.on.doc")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Button(String(localized: .libraryShareRevoke), role: .destructive) { confirmingRevoke = true }
                .frame(maxWidth: .infinity)
                .disabled(busy)
        }
    }

    private func copyRow(label: String, value: String, mono: Bool, locked: Bool = false, onCopy: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline).foregroundStyle(Theme.textMuted).frame(width: 34, alignment: .leading)
            if locked {
                Image(systemName: "lock.fill").font(.caption).foregroundStyle(Theme.textFaint)
            }
            Text(value)
                .font(mono ? .body.monospaced() : .body)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button {
                onCopy()
                copiedRow = label
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    if copiedRow == label { copiedRow = nil }
                }
            } label: {
                Label(copiedRow == label ? String(localized: .commonCopied) : String(localized: .commonCopy), systemImage: copiedRow == label ? "checkmark" : "doc.on.doc")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.textMuted)
        }
    }

    /// 「N 天后失效（时间）· 已打开 N 次 · 最近 X 前」
    private func facts(_ share: API.ShareView) -> String {
        [
            "\(expiryHint(share.expiresAt))（\(Formatters.dateTime(share.expiresAt))）",
            share.viewCount > 0 ? String(localized: .libraryShareViews(share.viewCount)) : String(localized: .libraryShareNoViews),
            share.lastAccessedAt.map { String(localized: .libraryShareLastAccess(Formatters.relative($0))) },
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if share != nil || !resolved {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: .commonClose)) { dismiss() }
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: .commonCancel)) { dismiss() }.disabled(busy)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? String(localized: .libraryShareGenerating) : String(localized: .libraryShareGenerate)) { Task { await create() } }
                    .disabled(busy)
            }
        }
    }

    // MARK: - 动作

    private var sharePath: String {
        switch target {
        case let .item(libraryId, mediaItemId): "/libraries/\(libraryId)/items/\(mediaItemId)/share"
        case let .collection(id): "/collections/\(id)/share"
        }
    }

    private var isCollection: Bool {
        if case .collection = target { return true }
        return false
    }

    /// 调用方给了现状就直接用；没给就查一次（查失败按「还没分享」处理，生成时后端会返回已有的那条）
    private func resolveCurrent() async {
        guard !resolved else { return }
        if let initialShare {
            share = initialShare
            resolved = true
            return
        }
        share = try? await api.shareSheetFetch(path: sharePath)
        resolved = true
    }

    private func togglePassword() {
        error = nil
        if passwordOn {
            passwordOn = false
            return
        }
        passwordOn = true
        if password.trimmingCharacters(in: .whitespaces).isEmpty { password = generateSharePassword() }
    }

    private func create() async {
        let pw = passwordOn ? password : ""
        if passwordOn, let invalid = validateSharePassword(pw) {
            error = invalid
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        let trimmed = pw.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = API.ShareCreateRequest(expiresInDays: days, password: passwordOn && !trimmed.isEmpty ? trimmed : nil)
        do {
            let result = try await api.shareSheetCreate(path: sharePath, body: body)
            share = result.share
            if result.existed {
                feedback.success(isCollection ? String(localized: .libraryShareExistingCollection) : String(localized: .libraryShareExistingItem))
            } else {
                feedback.success(String(localized: .libraryShareCreated))
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription.isEmpty ? String(localized: .libraryShareCreateFailed) : error.localizedDescription
        }
    }

    private func revoke() async {
        busy = true
        defer { busy = false }
        do {
            switch target {
            case let .item(libraryId, mediaItemId):
                _ = try await api.libraryItemsShareRevoke(libraryId: libraryId, mediaItemId: mediaItemId)
            case let .collection(id):
                _ = try await api.collectionShareRevoke(collectionId: id)
            }
            share = nil
            // 回到创建表单，表单回到默认值（同 Web 每次打开时的重置）
            days = shareDefaultDays
            passwordOn = false
            password = ""
            feedback.success(String(localized: .libraryShareRevoked))
        } catch {
            feedback.error(error)
        }
    }

    private func copy(_ text: String, _ what: String) {
        UIPasteboard.general.string = text
        feedback.success(String(localized: .libraryShareCopiedWhat(what)))
    }

    /// 相对路径 `/s/{slug}` 用当前服务器根地址补全；已是绝对地址的原样返回（同 Web absoluteShareUrl）
    private func absoluteShareURL(_ url: String) -> String {
        if !isRelativeShareURL(url) { return url }
        var base = api.server.origin.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return url.hasPrefix("/") ? base + url : base + "/" + url
    }
}

// MARK: - 纯逻辑（同 Web lib/share.ts）

private let shareExpiryOptions: [(days: Int, label: String)] = [
    (1, String(localized: .libraryShareDays(1))), (3, String(localized: .libraryShareDays(3))),
    (7, String(localized: .libraryShareDays(7))), (30, String(localized: .libraryShareDays(30))),
]
private let shareDefaultDays = 7
/// 访问码字符集：小写字母数字，去掉 0/o/1/l 这种口头转述会混淆的字符
private let sharePasswordAlphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
private let sharePasswordLength = 6
private let shareMinPassword = 4
private let shareMaxPassword = 32
private let shareKindLabels = ["movie": String(localized: .libraryKindMovies), "tv": String(localized: .libraryKindSeries), "video": String(localized: .libraryKindOther), "photo": String(localized: .libraryFormImages)]

private func generateSharePassword() -> String {
    var generator = SystemRandomNumberGenerator()
    return String((0 ..< sharePasswordLength).map { _ in sharePasswordAlphabet.randomElement(using: &generator)! })
}

/// 空 = 不设密码；非空须在 4–32 位之间。返回错误文案，合法为 nil
private func validateSharePassword(_ password: String) -> String? {
    let cleaned = password.trimmingCharacters(in: .whitespacesAndNewlines)
    if cleaned.isEmpty { return nil }
    if cleaned.count < shareMinPassword || cleaned.count > shareMaxPassword {
        return String(localized: .librarySharePasswordLength(shareMinPassword, shareMaxPassword))
    }
    return nil
}

private func isRelativeShareURL(_ url: String) -> Bool {
    let lower = url.lowercased()
    return !(lower.hasPrefix("http://") || lower.hasPrefix("https://"))
}

/// 「复制链接和密码」：一段可以直接粘进聊天框的话
private func shareCopyText(title: String, url: String, password: String?) -> String {
    var parts = [String(localized: .libraryShareCopyTitle(title)), String(localized: .libraryShareCopyLinkLine(url))]
    if let password { parts.append(String(localized: .libraryShareCopyPassword(password))) }
    return parts.joined(separator: " ")
}

/// 到期提示：「N 天后失效」/「N 小时后失效」/「N 分钟后失效」/「已失效」
private func expiryHint(_ expiresAt: String) -> String {
    guard let date = Formatters.date(expiresAt) else { return String(localized: .libraryShareExpired) }
    let remaining = date.timeIntervalSinceNow
    if remaining <= 0 { return String(localized: .libraryShareExpired) }
    let hours = remaining / 3600
    if hours >= 47 { return String(localized: .libraryShareExpiresDays(Int((hours / 24).rounded()))) }
    if hours >= 1 { return String(localized: .libraryShareExpiresHours(Int(hours.rounded(.down)))) }
    return String(localized: .libraryShareExpiresMinutes(max(1, Int((remaining / 60).rounded(.down)))))
}

private func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

// MARK: - 接口

nonisolated extension APIClient {
    /// 生成分享：生成的接口函数只返回 data，而「已有有效分享」要看信封里的 `code == SHARE_EXISTS`，所以手写
    fileprivate func shareSheetCreate(path: String, body: API.ShareCreateRequest) async throws -> (share: API.ShareView, existed: Bool) {
        let envelope: APIEnvelope<API.ShareView> = try await raw("POST", path, body: body)
        return (envelope.data, envelope.code == "SHARE_EXISTS")
    }

    /// 当前有效分享；没有为 nil
    fileprivate func shareSheetFetch(path: String) async throws -> API.ShareView? {
        try await send("GET", path)
    }
}
