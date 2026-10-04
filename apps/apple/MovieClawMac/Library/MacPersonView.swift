import SwiftUI

/// 影人页（同 Apple Music 的艺人页）：这个人在**我库里**的作品，从条目详情的「演职员」进入。
///
/// 与 iPhone、Apple TV 版、网页同一个接口（`GET /people/{tmdbPersonId}`）、同一个口径：数据全部来自本地表、不联网，
/// 所以没有生平简介——这页回答「这个人在我库里有哪些片」：
/// - 头部：大圆头像 + 姓名（原名不同才写）+「库内 12 部 · 参演 10 · 执导 2」；姓名、头像随路由带过来，打开就是全的；
/// - 作品：与海报墙同一套网格（列宽随窗口），海报下面写片名与「饰 柯布 · 2010」；既演又导分两段；
/// - 从哪部片点进来的那张标「本片」，点它退回上一页；文件已删的置灰、写「片源已移除」，点不进去；
/// - 背景是这个人头像放大模糊（同海报墙的模糊底），整页有颜色而不是一片死黑。
struct MacPersonView: View {
    let tmdbId: Int
    let name: String
    let avatar: String?
    let fromItem: Int?

    @Environment(\.api) private var api
    @Environment(MacRouter.self) private var router
    @State private var person: API.PersonView?
    @State private var failure: Failure?

    private enum Failure { case missing, error }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 32) {
                header
                if let failure {
                    fallback(failure).frame(height: 420)
                } else if let person {
                    credits(person)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 100)
                }
            }
            .padding(.horizontal, MacMetrics.edge)
            .padding(.top, 20)
            .padding(.bottom, 48)
        }
        .background {
            MacBlurredBackdrop(url: api.image(person?.avatarUrl ?? avatar, width: ImageWidth.points(MacMetrics.blurredBackdropWidth)))
                .ignoresSafeArea()
        }
        .navigationTitle(person?.name ?? name)
        .toolbar(removing: .title)
        .task { if person == nil { await load() } }
        .accessibilityIdentifier("mac-person-\(tmdbId)")
    }

    private var header: some View {
        let displayName = person?.name ?? name
        return HStack(alignment: .center, spacing: 24) {
            MacAvatar(url: api.image(person?.avatarUrl ?? avatar, width: ImageWidth.points(140)), name: displayName, size: 140)
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            VStack(alignment: .leading, spacing: 6) {
                Text(displayName)
                    .font(.system(size: 32, weight: .bold))
                    .lineLimit(1)
                if let original = person?.originalName, original != displayName {
                    Text(original)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                // 统计没回来时占住一行，接口回来不跳动
                Text(person.map(Self.summary) ?? " ")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mac-person-header")
    }

    /// 「库内 12 部 · 参演 10 · 执导 2」：只有一种身份时只写总数
    private static func summary(_ person: API.PersonView) -> String {
        let all = "库内 \(Set(person.credits.map(\.mediaItemId)).count) 部"
        let parts = sections(person)
        guard parts.count > 1 else { return all }
        return ([all] + parts.map { "\($0.title) \($0.credits.count)" }).joined(separator: " · ")
    }

    /// 参演在前、执导在后（接口已按主演在前、同档按年份倒序排好）
    private static func sections(_ person: API.PersonView) -> [(title: String, credits: [API.PersonCreditView])] {
        let cast = person.credits.filter { $0.department == "cast" }
        let directed = person.credits.filter { $0.department == "director" }
        return [("参演", cast), ("执导", directed)].filter { !$0.1.isEmpty }
    }

    @ViewBuilder
    private func credits(_ person: API.PersonView) -> some View {
        let parts = Self.sections(person)
        if parts.isEmpty {
            MacStateView(symbol: "film", title: "库内还没有这位影人的作品").frame(height: 360)
        }
        ForEach(parts, id: \.title) { part in
            VStack(alignment: .leading, spacing: 16) {
                if parts.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(part.title).font(.system(size: 20, weight: .bold))
                        Text("\(part.credits.count) 部").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: MacPosterWall<EmptyView>.columns, alignment: .leading, spacing: 26) {
                    ForEach(part.credits, id: \.mediaItemId) { credit in
                        card(credit)
                    }
                }
            }
        }
    }

    private func card(_ credit: API.PersonCreditView) -> some View {
        let gone = credit.libraryId == nil
        let current = credit.mediaItemId == fromItem
        return GeometryReader { proxy in
            MacPosterCard(
                title: credit.title,
                subtitle: Self.roleLine(credit),
                imageURL: api.image(credit.posterUrl, width: ImageWidth.macCard(200)),
                width: proxy.size.width,
                badge: current ? "本片" : nil,
                play: gone ? nil : { router.play(PlayRequest(mediaItemId: credit.mediaItemId)) }
            ) {
                if current {
                    // 「本片」就是上一页：退回去，不在栈里再压一份同样的详情
                    router.pop()
                } else if let libraryId = credit.libraryId {
                    router.push(.item(libraryId: libraryId, itemId: credit.mediaItemId))
                }
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .padding(.bottom, 38)
        .opacity(gone ? 0.45 : 1)
        .disabled(gone)
        .accessibilityIdentifier("mac-person-credit-\(credit.department)-\(credit.mediaItemId)")
    }

    /// 「饰 柯布 · 2010」「导演 · 2010」（剧集的导演栏写「主创」）；文件已删的写明为什么点不进去
    private static func roleLine(_ credit: API.PersonCreditView) -> String {
        let role: String? = credit.department == "director"
            ? (credit.kind == "tv" ? "主创" : "导演")
            : credit.character.flatMap { $0.isEmpty ? nil : "饰 \($0)" }
        let line = [role, credit.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        if credit.libraryId == nil { return line.isEmpty ? "片源已移除" : line + " · 片源已移除" }
        return line
    }

    private func load() async {
        failure = nil
        do {
            person = try await api.peopleShow(tmdbPersonId: tmdbId)
        } catch is CancellationError {
        } catch {
            failure = error.isDiscoverNotFound ? .missing : .error
        }
    }

    /// 404 = 库内没有这位影人的作品：多半是这个库早前扫描时还没建影人档案，不是坏了（同 iPhone、网页的说法）
    @ViewBuilder
    private func fallback(_ failure: Failure) -> some View {
        switch failure {
        case .missing:
            MacStateView(
                symbol: "person.crop.rectangle",
                title: "库内没有这位影人的作品",
                message: "可能是这位影人参演的片都已从库里移除；也可能这个库是早前扫描的——影人档案随入库刮削一并建立，"
                    + "在网页上对这个库执行一次「刷新元数据」即可补齐。",
                actionTitle: "返回"
            ) { router.pop() }
        case .error:
            MacStateView(symbol: "exclamationmark.triangle", title: "未能加载影人档案",
                         message: "请稍后重试；若持续失败，请查看服务器日志。", actionTitle: "重试") {
                Task { await load() }
            }
        }
    }
}
