import SwiftUI

/// 片段（docs/design/tvos-app.md §3.1，侧边栏「更多」里的二级入口）：客厅版「随便看看」。
///
/// 全屏自动连播自己片库里的片段，一段放完自动接下一段；点按左 / 右换上一段 / 下一段，
/// **按确认键接着看正片**（从当前位置进正片播放器），播放暂停键暂停，返回键回侧边栏。
/// 数据、预取、预起下一段、片段事件全部沿用 iPhone 版的 `ReelsStore`（在 Shared/Reels），这里只是电视的控制层：
/// 手机上的上下滑在电视上换成左右按键，竖屏横带换成全屏。
struct TVReelsView: View {
    @Environment(\.api) private var api
    @Environment(TVRouter.self) private var router
    @State private var store: ReelsStore?
    @FocusState private var surfaceFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .task {
            guard store == nil else { return }
            let created = ReelsStore(api: api, metered: NetworkCost.shared.interface == "cellular")
            store = created
            await created.start()
            surfaceFocused = true
        }
        // 切走（换侧边栏、进正片播放器）就收掉播放器；回来接着放
        .onDisappear { store?.suspend() }
        .onAppear { store?.resume() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-reels")
    }

    @ViewBuilder
    private func content(_ store: ReelsStore) -> some View {
        if let item = current(store) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: store.stillURL(for: item))
                    .ignoresSafeArea()
                    .opacity(store.frameReady(for: item) ? 0 : 1)
                if let player = store.player(for: item) {
                    EngineSurface(engineView: player.core.view)
                        .id(ObjectIdentifier(player))
                        .ignoresSafeArea()
                        .accessibilityIdentifier("tv-reels-video")
                }
                if store.playerState == .loading || store.playerState == .buffering {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                info(item, store: store)
                    .padding(.horizontal, TVMetrics.edge)
                    .padding(.bottom, 60)
                surface(store)
            }
            .onChange(of: store.playerState) { _, state in
                // 一段放完、或这一段放不了：自动接下一段
                if state == .ended || state.isFailed { step(store, by: 1) }
            }
        } else if store.loading {
            ProgressView()
        } else if let error = store.errorMessage {
            TVStateView(symbol: "exclamationmark.triangle", title: "片段加载失败", message: error, actionTitle: "重试") {
                Task { await store.retry() }
            }
        } else if store.serverOutdated {
            TVStateView(symbol: "arrow.up.circle", title: "服务器版本太旧", message: "请先把服务器升级到最新版，再来刷片段。")
        } else {
            TVStateView(symbol: "film.stack", title: "还没有可以刷的片段", message: "媒体库里的电影和剧集扫描完成后，这里会随机放一段。")
        }
    }

    private func info(_ item: API.ReelItemView, store: ReelsStore) -> some View {
        let title = item.title
        return VStack(alignment: .leading, spacing: 12) {
            Text(title.name)
                .font(.system(size: 56, weight: .bold))
                .shadow(radius: 10)
            Text(facts(title).joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
            if let player = store.player(for: item) {
                TVProgressStrip(value: player.progress).frame(width: 520)
            }
            Text("◀ ▶ 换一段　按下 接着看正片")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.top, 6)
        }
        .allowsHitTesting(false)
    }

    /// 拿焦点的全屏按钮：确认 = 接着看正片；左右 = 换一段；播放暂停键 = 暂停
    private func surface(_ store: ReelsStore) -> some View {
        Button { watchFull(store) } label: {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
        }
        .buttonStyle(TVInvisibleButtonStyle())
        .focused($surfaceFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left: step(store, by: -1)
            case .right: step(store, by: 1)
            default: break
            }
        }
        .onPlayPauseCommand { store.togglePause() }
        .ignoresSafeArea()
        .accessibilityLabel("接着看正片")
        .accessibilityIdentifier("tv-reels-surface")
    }

    private func current(_ store: ReelsStore) -> API.ReelItemView? {
        store.items.first { $0.id == store.currentID } ?? store.items.first
    }

    /// 换上一段 / 下一段
    private func step(_ store: ReelsStore, by offset: Int) {
        guard let currentID = store.currentID, let index = store.items.firstIndex(where: { $0.id == currentID }) else { return }
        let target = index + offset
        guard store.items.indices.contains(target) else { return }
        store.currentID = store.items[target].id
        store.settle()
    }

    /// 接着看正片：从这一段的当前位置进正片播放器（片段模式的请求去掉片段，就是正常播放）
    private func watchFull(_ store: ReelsStore) {
        guard var request = store.fullscreenRequest() else { return }
        request.clip = nil
        store.pause()
        router.play(request)
    }

    private func facts(_ title: API.ReelTitleView) -> [String] {
        var facts: [String] = []
        if let episode = title.episode {
            facts.append("第 \(episode.season) 季 第 \(episode.episode) 集" + (episode.name.map { " · \($0)" } ?? ""))
        }
        if let year = title.year { facts.append(String(year)) }
        if let rating = title.rating, rating > 0 { facts.append("★ " + String(format: "%.1f", rating)) }
        if !title.genres.isEmpty { facts.append(title.genres.prefix(3).joined(separator: " · ")) }
        return facts
    }
}
