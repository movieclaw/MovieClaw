import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import VideoToolbox

/// 客户端解码能力快照（字段与后端 ClientCapabilityIn 严格对应，参考 Web `lib/player/capability.ts`）。
///
/// **按当前引擎如实申报**——服务端拿它决定档位，报多了会把放不了的原片直通给我们，报少了白白转码：
/// - 自研引擎：直读原文件、本机解码（硬解不了的软解），申报全解码，服务端直接给原文件；
/// - 系统播放器（放服务端流）：只报 VideoToolbox 真能解、AVFoundation 真能封装的编码；容器只认 MP4 与 HLS fMP4。
///
/// codec 用归一化的编码家族名（h264 / hevc / aac …），服务端直接和 ffprobe 的 codec_name 比对。
enum PlayerCapability {
    /// 系统播放器的能力
    static func avPlayer() -> API.ClientCapabilityIn {
        var video: [API.VideoSupportIn] = [
            .init(codec: "h264", maxHeight: 2160, smooth: true, powerEfficient: true),
            .init(codec: "hevc", maxHeight: 2160, smooth: true, powerEfficient: hardwareHEVC),
        ]
        // AV1 只有 A17 Pro / M 系列之后才有硬解；软解 4K AV1 在手机上放不动，不报
        if hardwareAV1 {
            video.append(.init(codec: "av1", maxHeight: 2160, smooth: true, powerEfficient: true))
        }
        let audio: [API.AudioSupportIn] = [
            .init(codec: "aac", maxChannels: 8),
            .init(codec: "ac3", maxChannels: 6),
            // E-AC-3 含杜比全景声（JOC）：AVPlayer 在支持的输出设备上原样透传
            .init(codec: "eac3", maxChannels: 8),
            .init(codec: "flac", maxChannels: 8),
            .init(codec: "alac", maxChannels: 8),
            .init(codec: "mp3", maxChannels: 2),
        ]
        return API.ClientCapabilityIn(
            video: video,
            audio: audio,
            containers: ["mp4", "hls-fmp4"],
            hdrPassthrough: hdrDisplay,
            mse: "none",
            isMobile: isPhone,
            nativeHls: true
        )
    }

    /// 自研引擎的能力：直读原文件，FFmpeg 解封装，硬解不了的编码由引擎在本机软解，所以申报为全解码播放器
    /// （`universal`）——服务端直接给档 0 的原文件地址，不采样关键帧、不为一路用不上的换封装拉起 ffmpeg
    /// （NAS 实测冷启动白花 1.6 秒）；光盘在本机读：ISO 给原字节、原盘给目录直推（docs/design/disc-direct-play.md）。
    /// 编码与容器清单只在服务端不认 `universal` 时起作用（老服务端），按引擎实际能解的报
    static func native() -> API.ClientCapabilityIn {
        let video = ["h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4", "vc1"].map {
            API.VideoSupportIn(codec: $0, maxHeight: 2160, smooth: true, powerEfficient: $0 == "h264" || $0 == "hevc")
        }
        // 音频只报「能原样装进 fMP4 分片」的编码（对应后端 FMP4_COPY_AUDIO_CODECS）：服务端据此给出的换封装计划
        // 才起得来——报了 TrueHD，服务端会计划「换壳成 HLS fMP4 并原样拷贝 TrueHD」，而 ffmpeg 的 MP4 封装
        // 不支持 TrueHD，转码进程启动即失败（NAS《蜘蛛侠：英雄归来》实测）。引擎本机照样解 TrueHD / DTS / LPCM
        let audio = ["aac", "ac3", "eac3", "dts", "flac", "alac", "opus", "mp3"].map {
            API.AudioSupportIn(codec: $0, maxChannels: 8)
        }
        return API.ClientCapabilityIn(
            video: video,
            audio: audio,
            containers: ["mp4", "hls-fmp4", "mkv", "webm", "ts", "m2ts", "avi"],
            // HDR / 杜比视界由系统播放器原样显示（屏幕不支持时系统自己映射），服务端不需要 tone-map
            hdrPassthrough: true,
            // 服务端对「移动端原生 HLS」（iOS Safari）有 1080p、AAC 双声道等限制，引擎直读原文件不受这些约束
            mse: "full",
            isMobile: false,
            nativeHls: false,
            universal: true,
            discImage: true,
            discFolder: true
        )
    }

    /// 硬件解码能力在进程里只查一次，结果不会变。第一次查要加载 VideoToolbox、问一遍硬件，
    /// 模拟器实测 60 毫秒——正好压在起播请求发出之前，所以 App 启动时就在后台查好（`prewarm`）
    nonisolated private static let hardwareHEVC = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    nonisolated private static let hardwareAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    /// App 启动时调用：在后台把硬件解码能力查好，第一次点播放不再现查
    static func prewarm() {
        Task.detached(priority: .utility) {
            _ = hardwareHEVC
            _ = hardwareAV1
        }
    }

    /// 是不是手机（服务端对移动端有码率、分辨率上的保守限制）
    private static var isPhone: Bool {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// 屏幕能不能显示 HDR（能力快照的 hdr_passthrough）；判 false 只是让服务端 tone-map
    private static var hdrDisplay: Bool {
        #if os(tvOS)
        // Apple TV 的 EDR 余量恒为 1（画面经 HDMI 交给电视，不在本机屏幕上做 EDR），按它判会把所有 HDR 都申报成
        // 「不支持」。改问 AVPlayer：当前设备 + 所接电视能否放 HDR
        return AVPlayer.eligibleForHDRPlayback
        #elseif os(macOS)
        // Mac：主屏的 EDR 潜在余量（XDR / 支持 HDR 的外接屏 > 1）
        return (NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
        #else
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        return (screen?.potentialEDRHeadroom ?? 1) > 1
        #endif
    }
}
