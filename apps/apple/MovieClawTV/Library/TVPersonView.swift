import SwiftUI

/// 影人页（docs/design/tvos-app.md §3.4「影人页」）：这个人在**我库里**的作品，从条目详情的「演职员」进入。
///
/// 与 iPhone 版 `PersonDetailView`、网页 `person-detail-view.tsx` 同一个接口（`GET /people/{tmdbPersonId}`）、同一个口径：
/// 数据全部来自本地表，不联网，所以没有生平简介、出生地——这页回答「这个人在我库里有哪些片」，主体是作品海报墙。
///
/// 电视上的做法：
/// - **海报与媒体库的海报墙同一套版式**（`TVWallLayout`：一屏 5 列、同样的间距、海报下面不挂字），背景同样跟着焦点那一部
///   模糊、压暗、交叉淡入——从媒体库、合集到影人页，海报的大小、位置、焦点移动的手感都一样（2026-10-04 用户要求）；
/// - 海报墙不挂字，饰演的角色就收进海报底部的暗带，只在获得焦点时浮现（「饰 柯布 · 2010」），不占排版位置；
/// - 头部（圆头像 + 姓名 + 原名 + 「库内 12 部 · 参演 10 · 执导 2」）的姓名、头像随路由带过来，页面一打开就是全的，不等接口；
/// - 既演又导的人分「参演」「执导」两段，只有一种身份就不写段标题，和海报墙一模一样；
/// - 从哪部片点进来的，那张海报标「本片」，一眼看出这部在其作品里排第几；按确认退回那一页，不在栈里再压一份；
/// - 文件已全部删除、只剩档案的作品置灰，按确认不跳转（同 iPhone 版的不可点）。
struct TVPersonView: View {
    let tmdbId: Int
    /// 详情页演职员卡片上的姓名与头像：接口回来之前先用它们画头部
    let name: String
    let avatar: String?
    /// 从哪部片点进来的（媒体条目 id）
    let fromItem: Int?

    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @State private var person: API.PersonView?
    @State private var failure: Failure?
    @FocusState private var focused: CreditKey?
    /// 背景跟着的那一部：焦点停稳 0.2 秒再换，按住方向键一路划过去时不逐张闪（同海报墙）
    @State private var backdropCredit: API.PersonCreditView?

    private enum Failure { case missing, error }

    /// 一张海报的焦点标识：同一部片可能既演又导，两段里各出现一次，所以带上身份
    private struct CreditKey: Hashable {
        let department: String
        let mediaItemId: Int
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 36) {
                header
                if let failure {
                    fallback(failure).frame(height: 640)
                } else if let person {
                    credits(person)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.top, 20)
            .padding(.bottom, 80)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background {
            TVBlurredBackdrop(url: api.image(backdropCredit?.posterUrl, width: ImageWidth.points(TVMetrics.blurredBackdropWidth)))
                .ignoresSafeArea()
        }
        .task { if person == nil { await load() } }
        .task(id: focused) {
            guard let key = focused, key.mediaItemId != backdropCredit?.mediaItemId else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            backdropCredit = person?.credits.first { $0.mediaItemId == key.mediaItemId }
        }
        // 作品出来时焦点还没地方落（加载那一刻页面上没有可聚焦的东西）：放到第一张
        .task(id: person != nil) {
            guard let first = person.flatMap(Self.sections)?.first?.credits.first else { return }
            try? await Task.sleep(for: .milliseconds(150))
            if focused == nil { focused = CreditKey(department: first.department, mediaItemId: first.mediaItemId) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-person-\(tmdbId)")
    }

    // MARK: 头部

    /// 圆头像 + 姓名（与海报墙的标题同号）+ 原名 + 库内作品统计
    private var header: some View {
        let displayName = person?.name ?? name
        return HStack(alignment: .center, spacing: 36) {
            // 头部头像不可聚焦、不放大：按 168 点框宽取
            TVAvatar(url: api.image(person?.avatarUrl ?? avatar, width: ImageWidth.points(168)), name: displayName, size: 168)
                .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(displayName)
                        .font(.system(size: 52, weight: .bold))
                        .lineLimit(1)
                    if let original = person?.originalName, original != displayName {
                        Text(original)
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                // 统计没回来时占住一行，接口回来不跳动
                Text(person.map(Self.summary) ?? " ")
                    .font(.system(size: 26, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tv-person-header")
    }

    /// 「库内 12 部 · 参演 10 · 执导 2」：只有一种身份时只写总数
    private static func summary(_ person: API.PersonView) -> String {
        let all = "库内 \(Set(person.credits.map(\.mediaItemId)).count) 部"
        let parts = sections(person)
        guard parts.count > 1 else { return all }
        return ([all] + parts.map { "\($0.title) \($0.credits.count)" }).joined(separator: " · ")
    }

    // MARK: 作品

    /// 参演在前、执导在后（接口已按主演在前、同档按剧组主次与年份倒序排好，这里不再排）
    private static func sections(_ person: API.PersonView) -> [(title: String, credits: [API.PersonCreditView])] {
        let cast = person.credits.filter { $0.department == "cast" }
        let directed = person.credits.filter { $0.department == "director" }
        return [("参演", cast), ("执导", directed)].filter { !$0.1.isEmpty }
    }

    @ViewBuilder
    private func credits(_ person: API.PersonView) -> some View {
        let parts = Self.sections(person)
        if parts.isEmpty {
            TVStateView(symbol: "film", title: "库内还没有这位影人的作品")
                .frame(height: 500)
        }
        ForEach(parts, id: \.title) { part in
            VStack(alignment: .leading, spacing: 24) {
                // 只有一种身份时不写段标题：和媒体库的海报墙一模一样
                if parts.count > 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(part.title)
                            .font(.system(size: 32, weight: .semibold))
                        Text("\(part.credits.count) 部")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                // 与海报墙同样的列宽、间距，但逐排排版、每排横贯整屏做成焦点区：作品数常不满一排，
                // 网格的话从第一排中间往下，正下方没有海报，焦点停住不动、下面「执导」那段也到不了（模拟器实测）。
                // 每排是一个焦点区，往下就落到下一排（或下一段）离焦点最近的那张。
                // 用普通 VStack：换成 LazyVStack 后整页被系统推到 (160, 120)、右下伸出屏幕（实测）；
                // 一个人在库里的作品通常几十部以内，一次建完无妨
                VStack(alignment: .leading, spacing: TVWallLayout.rowSpacing) {
                    ForEach(Self.rows(part.credits), id: \.first?.mediaItemId) { row in
                        HStack(spacing: TVWallLayout.columnSpacing) {
                            ForEach(row, id: \.mediaItemId) { credit in
                                card(credit)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusSection()
                    }
                }
            }
        }
    }

    /// 按海报墙的列数切成一排排
    private static func rows(_ credits: [API.PersonCreditView]) -> [[API.PersonCreditView]] {
        stride(from: 0, to: credits.count, by: TVWallLayout.columnCount).map {
            Array(credits[$0 ..< min($0 + TVWallLayout.columnCount, credits.count)])
        }
    }

    private func card(_ credit: API.PersonCreditView) -> some View {
        let gone = credit.libraryId == nil
        return TVPosterCard(
            title: credit.title,
            subtitle: credit.year.map(String.init),
            imageURL: api.image(credit.posterUrl, width: ImageWidth.tvCard(TVWallLayout.posterWidth)),
            width: TVWallLayout.posterWidth,
            badge: credit.mediaItemId == fromItem ? "本片" : nil,
            caption: .hidden,
            focusDetail: Self.focusDetail(credit)
        ) {
            if credit.mediaItemId == fromItem {
                // 「本片」就是上一页：退回去，不在栈里再压一份同样的详情
                router.pop()
            } else if let libraryId = credit.libraryId {
                router.push(.item(libraryId: libraryId, itemId: credit.mediaItemId))
            }
        }
        .opacity(gone ? 0.45 : 1)
        .focused($focused, equals: CreditKey(department: credit.department, mediaItemId: credit.mediaItemId))
        .accessibilityLabel([credit.title, Self.focusDetail(credit)].joined(separator: "，"))
        .accessibilityIdentifier("tv-person-credit-\(credit.department)-\(credit.mediaItemId)")
    }

    /// 海报底部暗带里那一行：「饰 柯布 · 2010」「导演 · 2010」（剧集的导演栏是主创）；文件已删的写明为什么点不进去
    private static func focusDetail(_ credit: API.PersonCreditView) -> String {
        let role: String? = credit.department == "director"
            ? (credit.kind == "tv" ? "主创" : "导演")
            : credit.character.flatMap { $0.isEmpty ? nil : "饰 \($0)" }
        let line = [role, credit.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        if credit.libraryId == nil { return line.isEmpty ? "片源已移除" : line + " · 片源已移除" }
        return line.isEmpty ? credit.title : line
    }

    // MARK: 加载与失败

    private func load() async {
        failure = nil
        do {
            person = try await api.peopleShow(tmdbPersonId: tmdbId)
        } catch is CancellationError {
        } catch {
            failure = error.isDiscoverNotFound ? .missing : .error
        }
    }

    /// 404 = 库内没有这位影人的作品：多半是这个库早前扫描时还没建影人档案，不是坏了，文案要分开说（同 iPhone、网页）
    @ViewBuilder
    private func fallback(_ failure: Failure) -> some View {
        switch failure {
        case .missing:
            TVStateView(
                symbol: "person.crop.rectangle",
                title: "库内没有这位影人的作品",
                message: "可能是这位影人参演的片都已从库里移除；也可能这个库是早前扫描的——影人档案随入库刮削一并建立，"
                    + "在手机或网页上对这个库执行一次「刷新元数据」即可补齐。",
                actionTitle: "返回"
            ) { router.pop() }
        case .error:
            TVStateView(symbol: "exclamationmark.triangle", title: "未能加载影人档案",
                        message: "请稍后重试；若持续失败，请查看系统日志。", actionTitle: "重试") {
                Task { await load() }
            }
        }
    }
}
