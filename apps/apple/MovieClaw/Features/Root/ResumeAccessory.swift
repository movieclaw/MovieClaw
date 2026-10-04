import SwiftUI

/// 标签栏上方的「接着看」条（iOS 26 标签栏附件 `tabViewBottomAccessory`，同 Apple Music 的播放条）。
///
/// 为什么放正片而不是「片段」（2026-09-30 与用户讨论后定）：标签栏附件的语义是「一件还没结束、离开页面也还在的事」
/// ——音乐的正在播放、导航的进行中。片段离开页面就停、每条几十秒，不存在「没看完」；正片才有：从播放器退出时
/// 电影看到一半，这里常驻一条，点一下原地接着放，不用回媒体库找「继续观看」。
///
/// 内容取「继续观看」的第一条（`/playback/up-next`，最近播放的作品：看了一半的接着放，看完一集的放下一集），
/// 与媒体库首页那一行同源。整条点一下就起播（同一条的「继续观看」卡片的播放键）；长按可以看详情或先隐藏。
///
/// 右边的 ✕ 把这条叉掉（2026-10-04 用户要求）：叉掉后一直不显示，直到这台设备再播一次——
/// 记下的是「作品 + 季集 + 最近播放时刻」，再播任何一部（包括同一部）最近播放时刻都会变，条就自己回来。
/// 叉掉的记录存本机，App 重启也不会冒出来。
///
/// 只认**这台设备**播过的（`this_device`）：附件说的是「你刚才在这台手机上看到哪了」，在 Infuse、电视上放的
/// 不该顶上来；媒体库首页那一行照旧跨设备。进度仍按人合并——别处把这一集看完了，这里接下一集。
///
/// 什么时候不显示：没有可接着看的、停在「片段」页（它自己占满底部）、AI 会话页（底部是输入框）、iOS 26.0（能按需开关附件的 API 从 26.1 起；
/// 26.0 上开关附件会重建整个标签栏，宁可不显示）。
@Observable
@MainActor
final class ResumeBarStore {
    private(set) var item: API.UpNextItemView?
    /// 叉掉 / 长按「隐藏」掉的那一条（作品 + 季集 + 最近播放时刻）：再看过别的、或这部又往后看了，才重新出现。
    /// 存 UserDefaults：只是本机的显示偏好，重启后仍然有效
    private var hiddenKey: String? = UserDefaults.standard.string(forKey: ResumeBarStore.hiddenKeyDefaultsKey)
    private static let hiddenKeyDefaultsKey = "movieclaw.resumeBar.hiddenKey"

    var visibleItem: API.UpNextItemView? {
        guard let item, Self.key(item) != hiddenKey else { return nil }
        return item
    }

    func refresh(api: APIClient) async {
        guard let latest = try? await api.playbackUpNext(limit: 1, thisDevice: true) else { return }
        item = latest.items.first
    }

    func hide() {
        guard let item else { return }
        hiddenKey = Self.key(item)
        UserDefaults.standard.set(hiddenKey, forKey: Self.hiddenKeyDefaultsKey)
    }

    private static func key(_ item: API.UpNextItemView) -> String {
        "\(item.mediaItemId)|\(item.seasonNumber)|\(item.episodeNumber)|\(item.lastPlayedAt)"
    }
}

/// 附件的开关：iOS 26.1 起用 `isEnabled` 按需显示；26.0 不挂（见 `ResumeBarStore` 说明）
struct ResumeAccessoryModifier: ViewModifier {
    let item: API.UpNextItemView?
    let enabled: Bool
    let onHide: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled && item != nil) {
                if let item { ResumeBar(item: item, onHide: onHide) }
            }
        } else {
            content
        }
    }
}

/// 条本身：剧照缩略图 + 片名 + 看到哪 + 播放键 + ✕。标签栏下滑收起时（`.inline`）附件挤进标签栏那一行，
/// 小图缩小照留（收起就没图，看着像条目丢了，2026-09-30 用户反馈），第二行放不下才省掉
private struct ResumeBar: View {
    let item: API.UpNextItemView
    let onHide: () -> Void
    @Environment(\.api) private var api
    @Environment(Router.self) private var router
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isEpisode: Bool { item.kind == "tv" }

    /// 第二行：剧集是季集 + 看到哪，电影是看到哪（试过加「已播 / 总时长」、季集挪到片名后，
    /// 都不如这一版清爽，2026-09-30 用户定回这一版）
    private var detail: String {
        var parts: [String] = []
        if isEpisode { parts.append(episodeCode(season: item.seasonNumber, episode: item.episodeNumber)) }
        if item.positionMs > 0, let percent = item.progressPercent {
            parts.append("看到 \(percent)%")
        } else if item.advanced {
            parts.append("下一集")
        }
        return parts.joined(separator: " · ")
    }

    private var playVerb: String {
        if item.positionMs > 0 { return "继续播放" }
        return item.advanced ? "播放下一集" : "播放"
    }

    var body: some View {
        // 播放与 ✕ 是并排的两个按钮（按钮里套按钮点击会串），左边整块点了起播
        HStack(spacing: 0) {
            Button(action: play) {
                HStack(spacing: 10) {
                    RemoteImage(url: api.image(item.episodeStillUrl ?? item.backdropUrl ?? item.posterUrl, width: ImageWidth.points(52)))
                        .frame(width: placement == .inline ? 40 : 52, height: placement == .inline ? 23 : 30)
                        .clipShape(.rect(cornerRadius: placement == .inline ? 5 : 6))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if placement != .inline, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 32, height: 32)
                }
                .padding(.leading, 12)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(playVerb)《\(item.title)》\(detail.isEmpty ? "" : " \(detail)")")
            .accessibilityIdentifier("resume-accessory")

            Button {
                withAnimation { onHide() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .accessibilityLabel("不再显示")
            .accessibilityIdentifier("resume-accessory-dismiss")
        }
        .contextMenu {
            Button("查看详情", systemImage: "film") {
                router.open(.libraryItem(libraryId: item.libraryId, itemId: item.mediaItemId,
                                         season: isEpisode ? item.seasonNumber : nil,
                                         episode: isEpisode ? item.episodeNumber : nil))
            }
            Button("先隐藏", systemImage: "eye.slash", action: onHide)
        }
    }

    private func play() {
        router.play(PlayRequest(
            mediaItemId: item.mediaItemId,
            season: isEpisode ? item.seasonNumber : nil,
            episode: isEpisode ? item.episodeNumber : nil
        ))
    }
}
