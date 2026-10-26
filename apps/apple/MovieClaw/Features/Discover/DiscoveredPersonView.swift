import SwiftUI

/// TMDB 影人页（对应 Web `discovered-person-detail-view.tsx`）：`GET /discover/people/{id}`，
/// 参演与幕后合并去重的完整 TMDB 影视履历。海报自带「已入库」绿斜标，未入库但已订阅的打「已订阅」蓝斜标；
/// 点海报进发现详情。
struct DiscoveredPersonView: View {
    @Environment(\.cardMetrics) private var cards
    let tmdbId: Int

    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @State private var person: API.DiscoveredPersonDetailsView?
    @State private var failure: PersonDetailView.Failure?

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView {
                    Label(failure == .missing ? String(localized: .mediaPersonNotFound) : String(localized: .mediaPersonCreditsFailed), systemImage: "person.crop.rectangle")
                } description: {
                    Text(failure == .missing ? String(localized: .mediaPersonNotFoundHint) : String(localized: .mediaPersonCreditsHint))
                } actions: {
                    if failure == .error {
                        Button(String(localized: .commonRetry)) { Task { await load() } }.discoverProminentButton()
                    }
                    Button(String(localized: .mediaPersonBackDiscovery)) { router.open(.discover()) }.buttonStyle(.glass)
                }
                .accessibilityIdentifier("error-state")
            } else if let person {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        PersonHeader(
                            name: person.name,
                            avatarUrl: person.avatarUrl,
                            eyebrow: String(localized: .mediaPersonTmdbPerson),
                            summary: String(localized: .mediaPersonCreditsCount(person.titles.count))
                        )
                        if person.titles.isEmpty {
                            Text(String(localized: .mediaPersonEmptyCredits))
                                .foregroundStyle(Theme.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                                .cardStyle(radius: 12)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(String(localized: .mediaPersonAllCredits)).font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                                    Text("\(person.titles.count)").font(.subheadline).foregroundStyle(Theme.textFaint)
                                }
                                LazyVGrid(columns: DiscoverGrid.columns, spacing: 20) {
                                    ForEach(person.titles.map(DiscoverPosterItem.init)) { item in
                                        // 同 Web：影人作品页显式给未入库但已订阅的作品打「已订阅」斜标
                                        DiscoverPosterCard(item: item, action: .none, showsSubscribedRibbon: true)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, cards.edge)
                    .padding(.bottom, 40)
                }
                .refreshable { await load() }
                .accessibilityIdentifier("discovered-person")
            } else {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(String(localized: .mediaPersonLoadingCredits)).font(.subheadline).foregroundStyle(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .appBackground()
        .navigationTitle(person?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .tracksSubscriptionIndex()
        .task { if person == nil { await load() } }
    }

    private func load() async {
        failure = nil
        do {
            person = try await api.discoverGetPersonDetails(tmdbPersonId: tmdbId)
        } catch is CancellationError {
        } catch {
            failure = error.isDiscoverNotFound ? .missing : .error
        }
    }
}
