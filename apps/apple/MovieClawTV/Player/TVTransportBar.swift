import SwiftUI

/// 播放器底部的进度条（同 tvOS 系统播放器）：片名一行、进度条（已缓冲 / 已播放 / 播放头）、
/// 左边当前时间、右边剩余时间。在触控板上拖动时播放头上方出现缩略图与落点时间。
/// 时间一律按「时间轴」算：片段模式下是这一段，不是整部片（见 `PlaybackClip`）。
struct TVTransportBar: View {
    let controller: PlaybackController
    let trickplay: TrickplayImages
    /// 正在拖动的落点（文件时间）；nil = 没在拖
    let scrubMs: Int?

    private static let barHeight: CGFloat = 10

    var body: some View {
        let duration = controller.timelineDurationMs ?? 0
        let position = controller.timelineMs(fromFileMs: scrubMs ?? controller.positionMs)
        let buffered = controller.bufferedEndMs.map { controller.timelineMs(fromFileMs: $0) } ?? 0
        VStack(alignment: .leading, spacing: 18) {
            Text(titleLine)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            GeometryReader { proxy in
                let width = proxy.size.width
                let playedX = width * fraction(position, of: duration)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(0.35))
                        .frame(width: width * fraction(buffered, of: duration))
                    Capsule().fill(.white)
                        .frame(width: playedX)
                }
                .frame(height: Self.barHeight)
                .overlay(alignment: .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: scrubMs == nil ? 0 : 26, height: scrubMs == nil ? 0 : 26)
                        .offset(x: playedX - 13)
                }
                .overlay(alignment: .bottomLeading) {
                    if let scrubMs {
                        scrubPreview(fileMs: scrubMs)
                            // 预览贴着播放头、但不超出两端
                            .frame(width: 320)
                            .offset(x: min(max(0, playedX - 160), width - 320), y: -Self.barHeight - 24)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 30)
            HStack {
                Text(Formatters.clock(Double(position) / 1000))
                Spacer()
                Text("-" + Formatters.clock(Double(max(0, duration - position)) / 1000))
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("tv-player-transport")
    }

    private var titleLine: String {
        if let episode = controller.episodeLabel(controller.currentEpisode) {
            return "\(controller.title) · \(episode)"
        }
        return controller.title
    }

    private func fraction(_ value: Int, of total: Int) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(max(0, value), total)) / CGFloat(total)
    }

    /// 拖动落点的缩略图（服务端下发的雪碧图，没有就只显示时间）与时间
    private func scrubPreview(fileMs: Int) -> some View {
        VStack(spacing: 10) {
            if let image = trickplay.tile(controller.trickplay, atMs: fileMs, resolve: controller.scope.streamURL, session: controller.scope.api.session) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 320)
                    .clipShape(.rect(cornerRadius: 12))
                    .shadow(radius: 12)
            }
            Text(Formatters.clock(Double(controller.timelineMs(fromFileMs: fileMs)) / 1000))
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
                .shadow(radius: 6)
        }
    }
}
