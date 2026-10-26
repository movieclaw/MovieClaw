import SwiftUI

/// 媒体库管理页的「分享」页签（Web `library-shares.tsx`，设计见 docs/design/media-share.md §5.4）。
///
/// 全部有效分享一行一条——海报、片名、有无密码、形态 / 年份 / 有效期、打开次数与最近打开，
/// 行尾「复制」「取消」。分享多了只有这里能一眼管住；过期 / 已取消的后端不列。
/// 30 秒轮询，列表回报条数给页签计数。
struct ManageSharesTab: View {
    @Environment(\.cardMetrics) private var cards
    var onCountChange: (Int) -> Void = { _ in }

    @Environment(\.api) private var api
    @Environment(Feedback.self) private var feedback
    @Environment(Router.self) private var router

    @State private var shares: [API.ShareView]?
    @State private var failed = false
    @State private var busyId: Int?
    /// 待确认取消的分享：确认框按钮是「取消分享 / 先不」（同 Web），全局确认框的取消键固定叫「取消」会与之混淆
    @State private var revoking: API.ShareView?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let shares {
                if shares.isEmpty {
                    EmptyState(
                        systemImage: "link",
                        title: String(localized: .libraryShareEmpty),
                        message: String(localized: .libraryShareEmptyHint)
                    )
                    .padding(.top, 30)
                } else {
                    if failed {
                        ManageBanner(text: String(localized: .libraryHomeStale))
                    }
                    ForEach(shares, id: \.id) { share in
                        row(share)
                    }
                }
            } else if failed {
                ErrorState(message: String(localized: .librarySharesLoadFailed)) { await reload() }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(String(localized: .libraryShareLoading)).font(.subheadline).foregroundStyle(Theme.textMuted)
                }
                .padding(.vertical, 30)
            }
        }
        .padding(.horizontal, cards.edge)
        .task { await reload() }
        .polling(every: 30) { await reload() }
        .alert(String(localized: .librarySharesRevokeTitle(revoking?.title ?? "")), isPresented: Binding(
            get: { revoking != nil },
            set: { if !$0 { revoking = nil } }
        ), presenting: revoking) { share in
            Button(String(localized: .libraryItemNotNow), role: .cancel) {}
            Button(String(localized: .libraryShareRevoke), role: .destructive) { Task { await revoke(share) } }
        } message: { _ in
            Text(String(localized: .libraryShareRevokeShort))
        }
    }

    private func row(_ share: API.ShareView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Button {
                    openItem(share)
                } label: {
                    RemoteImage(url: api.image(share.posterUrl, width: ImageWidth.points(44)))
                        .frame(width: 44, height: 66)
                        .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Button {
                            openItem(share)
                        } label: {
                            Text(share.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                .expandedHitArea(vertical: 10)
                        }
                        .buttonStyle(.plain)
                        if share.password != nil {
                            Label(String(localized: .authLoginPassword), systemImage: "lock.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .foregroundStyle(Theme.textFaint)
                                .accessibilityIdentifier("share-row-locked")
                        }
                    }
                    Text(facts(share))
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                    Text((share.viewCount > 0 ? String(localized: .libraryShareViews(share.viewCount)) : String(localized: .libraryShareNoViews))
                        + (share.lastAccessedAt.map { String(localized: .librarySharesLastAccess(libraryFromNow($0))) } ?? ""))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Spacer()
                Button {
                    copy(share)
                } label: {
                    Label(String(localized: .commonCopy), systemImage: "doc.on.doc").font(.footnote)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("share-copy-\(share.slug)")
                Button {
                    revoking = share
                } label: {
                    Text(String(localized: .commonCancel)).font(.footnote).foregroundStyle(Color(red: 1, green: 0.62, blue: 0.62))
                }
                .buttonStyle(.glass)
                .disabled(busyId == share.id)
                .accessibilityIdentifier("share-revoke-\(share.slug)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.line))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share-row-\(share.slug)")
    }

    /// 「形态 · 年份 · N 天后失效（绝对时间）」；合集分享没有形态，写它此刻有几部
    private func facts(_ share: API.ShareView) -> String {
        var parts: [String] = []
        if share.collectionId != nil {
            parts.append(String(localized: .libraryShareCollectionCount(share.itemCount ?? 0)))
        } else if let kind = share.kind {
            parts.append(ManageKind.label(kind))
        }
        if let year = share.year { parts.append(String(year)) }
        parts.append("\(ShareLinkKit.expiryHint(share.expiresAt))（\(Formatters.dateTime(share.expiresAt))）")
        return parts.joined(separator: " · ")
    }

    private func openItem(_ share: API.ShareView) {
        if let libraryId = share.libraryId, let itemId = share.mediaItemId {
            router.push(.libraryItem(libraryId: libraryId, itemId: itemId))
        } else if let collectionId = share.collectionId {
            router.push(.collection(libraryId: share.libraryId, collectionId: collectionId))
        }
    }

    private func copy(_ share: API.ShareView) {
        let link = ShareLinkKit.absoluteURL(share.url, origin: api.server.origin)
        UIPasteboard.general.string = ShareLinkKit.copyText(title: share.title, url: link, password: share.password)
        feedback.success(share.password != nil ? String(localized: .libraryShareCopiedProtected) : String(localized: .libraryShareCopiedLink))
    }

    private func revoke(_ share: API.ShareView) async {
        busyId = share.id
        defer { busyId = nil }
        do {
            _ = try await api.sharesRevoke(shareId: share.id)
            feedback.success(String(localized: .libraryShareRevoked))
            await reload()
        } catch {
            feedback.error(error.localizedDescription.isEmpty ? String(localized: .libraryShareRevokeFailed) : error.localizedDescription)
        }
    }

    private func reload() async {
        do {
            let rows = try await api.sharesList()
            failed = false
            if rows != shares { shares = rows }
            onCountChange(rows.count)
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}
