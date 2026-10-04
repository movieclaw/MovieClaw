import MediaPlayer
import Nuke
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 锁屏 / 控制中心（对应 Web 的 navigator.mediaSession）。
///
/// 两个引擎都不会自动发布「正在播放」信息（AVPlayer 只有交给 AVPlayerViewController 才会），
/// 所以统一由这里维护：标题、季集、封面（剧集用剧照）、时长、进度、速率；远程命令支持播放/暂停、±10 秒、
/// 拖动进度、上一集/下一集（有才启用）。
@MainActor
final class NowPlayingBridge {
    private weak var controller: PlaybackController?
    private var targets: [(MPRemoteCommand, Any)] = []
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?

    func attach(to controller: PlaybackController) {
        self.controller = controller
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.playCommand) { $0.play() }
        add(center.pauseCommand) { $0.pause() }
        add(center.togglePlayPauseCommand) { $0.togglePlay() }
        add(center.skipForwardCommand) { $0.seek(by: 10, source: .remote) }
        add(center.skipBackwardCommand) { $0.seek(by: -10, source: .remote) }
        add(center.nextTrackCommand) { $0.playNext() }
        add(center.previousTrackCommand) { $0.playPrevious() }
        let target = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = event.positionTime
            MainActor.assumeIsolated {
                // 锁屏进度条是时间轴上的位置（片段模式从片段起点算），换回文件时间再跳
                guard let controller = self?.controller else { return }
                controller.seek(toFileMs: controller.timelineStartMs + Int(seconds * 1000), source: .remote)
            }
            return .success
        }
        targets.append((center.changePlaybackPositionCommand, target))
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlaybackController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let controller = self?.controller else { return .noActionableNowPlayingItem }
                action(controller)
                return .success
            }
        }
        targets.append((command, target))
    }

    func detach() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// 条目/单元变化：刷新静态信息（标题、季集、海报）与上一集/下一集的可用性
    func update(controller: PlaybackController) {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = controller.nextEpisode != nil
        center.previousTrackCommand.isEnabled = controller.previousEpisode != nil
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = controller.title
        info[MPMediaItemPropertyArtist] = controller.episodeLabel(controller.currentEpisode) ?? controller.info?.year.map(String.init) ?? ""
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updatePosition(controller: controller)
        loadArtwork(controller)
    }

    /// 每秒一次：进度、时长、速率（按时间轴：片段模式下是这一段的进度与长度，与播放器里的进度条一致）
    func updatePosition(controller: PlaybackController) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(controller.timelineMs(fromFileMs: controller.positionMs)) / 1000
        if let duration = controller.timelineDurationMs { info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000 }
        let rate = controller.paused ? 0.0 : (controller.holdSpeedActive ? 2.0 : 1.0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = controller.paused ? .paused : .playing
    }

    /// 系统可能在任意线程回调取图闭包：必须在非隔离上下文里创建，免得闭包被推断成主线程隔离
    nonisolated private static func makeArtwork(_ image: NativeImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func loadArtwork(_ controller: PlaybackController) {
        // 剧集用本集剧照（换集封面跟着变，与副标题的季集对得上），没有剧照或电影用海报。
        // 锁屏 / 控制中心的封面最大约一个手机屏宽：按 400 点取，不下整张原图
        let raw = controller.currentEpisode?.stillUrl.flatMap { $0.isEmpty ? nil : $0 } ?? controller.info?.posterUrl
        guard let url = controller.scope.api.image(raw, width: ImageWidth.points(400)), url != artworkURL else { return }
        artworkURL = url
        // 走 Nuke 共享管线：海报接口要设备令牌（AuthorizedDataLoader 会补上），裸 URLSession 取会 401；
        // 详情页刚展示过同一张图时还能直接命中缓存
        Task { [weak self, weak controller] in
            guard let image = try? await ImagePipeline.shared.image(for: url) else { return }
            self?.artwork = Self.makeArtwork(image)
            if let controller { self?.update(controller: controller) }
        }
    }
}
