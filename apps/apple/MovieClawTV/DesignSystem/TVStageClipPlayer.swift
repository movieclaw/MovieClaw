import AVFoundation
import UIKit

/// 大图预告的播放器：放原片用自研引擎（`ReelPlayer`），放预切片段用系统播放器（`TVStageClipPlayer`）。
/// `TVStagePreview` 只认这几样：画面、音量、进度、状态回调，以及「装载到起点停着 → 播放 → 暂停 → 拆掉」。
@MainActor
protocol TVStagePlayback: AnyObject {
    var view: UIView { get }
    var volume: Float { get set }
    /// 片段内的进度 0～1
    var progress: Double { get }
    var state: ReelPlayer.State { get }
    var onStateChange: ((ReelPlayer.State) -> Void)? { get set }
    var onFirstFrame: (() -> Void)? { get set }
    /// 装载好、停在起点（开播只差「播放」）
    var onPrerolled: (() -> Void)? { get set }
    /// 装载到起点停着
    func preroll(api: APIClient)
    func play()
    func pause()
    func destroy()
}

extension ReelPlayer: TVStagePlayback {
    var view: UIView { core.view }
    var volume: Float {
        get { core.volume }
        set { core.volume = newValue }
    }

    func preroll(api: APIClient) { start(api: api, autoplay: false) }
}

/// 预切片段（docs/design/reels.md §8）：服务端把这一段切成了 1080p H.264 SDR + AAC 立体声的 MP4
/// （索引在文件头，十几到二十几 MB），系统播放器直接放——不开自研引擎（4K 杜比视界一个一百多 MB）、
/// 不切显示模式、不读原片。第 0 秒就是原片的 `segment.start_ms`，放到文件尾就是终点。
@MainActor
final class TVStageClipPlayer: TVStagePlayback {
    let item: API.ReelItemView
    let view: UIView
    private let player = AVPlayer()
    private let url: URL
    private var observations: [NSKeyValueObservation] = []
    private var endObserver: NSObjectProtocol?
    private var firstFrameSent = false
    private var prerollSent = false

    private(set) var state: ReelPlayer.State = .loading {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((ReelPlayer.State) -> Void)?
    var onFirstFrame: (() -> Void)?
    var onPrerolled: (() -> Void)?

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var progress: Double {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, player.currentTime().seconds / duration))
    }

    /// 条目不是 clip、地址拼不出来时返回 nil（调用方保持剧照）
    init?(item: API.ReelItemView, api: APIClient) {
        guard item.play.mode == "clip", let raw = item.play.clipUrl, let url = api.server.resolve(raw) else { return nil }
        self.item = item
        self.url = url
        let host = ClipLayerView()
        host.playerLayer.player = player
        // 与原片预告的 fillsFrame 一致：铺满大图，不留黑边
        host.playerLayer.videoGravity = .resizeAspectFill
        view = host
        // 预告不进系统「正在播放」、不抢别的 App 的声音焦点：静音起播，音量由 TVStagePreview 渐入
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = true
    }

    func preroll(api: APIClient) {
        let playerItem = AVPlayerItem(url: url)
        // 小文件，整段缓冲也就二十来 MB：让系统按需缓冲，不额外限制
        observations.append(playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error?.localizedDescription
            Task { @MainActor in self?.itemStatusChanged(status, error: error) }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(status) }
        })
        if let host = view as? ClipLayerView {
            observations.append(host.playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] layer, _ in
                guard layer.isReadyForDisplay else { return }
                Task { @MainActor in self?.firstFrame() }
            })
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.state = .ended }
        }
        player.replaceCurrentItem(with: playerItem)
    }

    func play() {
        guard state != .ended, !state.isFailed else { return }
        player.play()
    }

    func pause() {
        player.pause()
        if state == .playing || state == .buffering { state = .paused }
    }

    func destroy() {
        observations.forEach { $0.invalidate() }
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: String?) {
        switch status {
        case .readyToPlay:
            guard !prerollSent else { return }
            // 停在第 0 帧等开播：先预滚一下，按下播放时缓冲已经就位
            player.preroll(atRate: 1) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.prerollSent else { return }
                    self.prerollSent = true
                    if self.state == .loading, self.player.timeControlStatus == .paused { self.state = .paused }
                    self.onPrerolled?()
                }
            }
        case .failed:
            state = .failed(error ?? "片段放不了")
        default:
            break
        }
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        guard state != .ended, !state.isFailed else { return }
        switch status {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = firstFrameSent ? .buffering : .loading
        case .paused: if prerollSent { state = .paused }
        @unknown default: break
        }
    }

    private func firstFrame() {
        guard !firstFrameSent else { return }
        firstFrameSent = true
        onFirstFrame?()
    }
}

/// 以 `AVPlayerLayer` 为底层的视图：跟着宿主的自动布局变大小，不用手动改图层 frame
private final class ClipLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
