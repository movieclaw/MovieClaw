import Foundation
import VideoToolbox

struct WorkerCapabilities: Sendable {
    let ffmpegVersion: String
    let encoders: [String]
    let backends: [String]
    /// ffmpeg 里 NAS 用得上的 Metal 滤镜（``CapabilityProbe/metalFilters``）。
    var filters: [String] = []
    /// 这台 Mac 的 VideoToolbox 能硬解的片源编码（ffmpeg 编码名）。
    var hwDecoders: [String] = []
    /// ffmpeg 认得的取源选项（``CapabilityProbe/readOptions``）：NAS 只给认得的加，
    /// 未知选项会让 ffmpeg 直接退出。
    var readOptions: [String] = []
}

enum CapabilityProbe {
    static func run(ffmpegPath: String) throws -> WorkerCapabilities {
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw ConfigurationError.message("找不到可执行的 ffmpeg：\(ffmpegPath)")
        }
        let versionOutput = try execute(ffmpegPath, arguments: ["-version"])
        let encoderOutput = try execute(ffmpegPath, arguments: ["-hide_banner", "-encoders"])
        let version = versionOutput
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? "unknown"
        let encoders = Self.parseEncoders(encoderOutput)
        let backends = encoders.contains("h264_videotoolbox") ? ["videotoolbox"] : []
        guard !backends.isEmpty else {
            throw ConfigurationError.message(
                "当前 ffmpeg 没有 h264_videotoolbox，不能把它登记为硬件转码 Worker"
            )
        }
        // 滤镜清单拿不到不影响接单：NAS 当它没有 Metal 滤镜，走 CPU 滤镜的老路
        let filterOutput = (try? execute(ffmpegPath, arguments: ["-hide_banner", "-filters"])) ?? ""
        var filters = parseFilters(filterOutput).filter(metalFilters.contains)
        if filters.contains("scale_vt") {
            let help = (try? execute(ffmpegPath, arguments: ["-hide_banner", "-h", "filter=scale_vt"])) ?? ""
            // 上游也有同名滤镜，但没有 Jellyfin 的 format 选项，不能执行 NAS 的 GPU 链路。
            if !scaleSupportsFormat(help) { filters.removeAll { $0 == "scale_vt" } }
        }
        // 同理：选项清单拿不到就一个都不申报，NAS 照旧装命令
        let helpOutput = (try? execute(ffmpegPath, arguments: ["-hide_banner", "-h", "full"])) ?? ""
        return WorkerCapabilities(
            ffmpegVersion: version,
            encoders: encoders,
            backends: backends,
            filters: filters,
            hwDecoders: hardwareDecoders(ffmpegMajorVersion: majorVersion(of: version)),
            readOptions: parseReadOptions(helpOutput)
        )
    }

    /// NAS 取源时可能加的输入选项（docs/design/transcode-latency.md §6.2）：MPEG-TS（原盘、广电录像）
    /// 打开时不倒着读文件尾估时长。未知选项会让 ffmpeg 直接退出，所以要先问 ffmpeg 自己。
    /// （按块要、连接复用由取源代理做，见 ``SourceReadProxy``。）
    static let readOptions: [String] = ["skip_estimate_duration_from_pts"]

    static func scaleSupportsFormat(_ help: String) -> Bool {
        help.split(separator: "\n").contains {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).first == "format"
        }
    }

    /// 从 `ffmpeg -h full` 的输出里挑出认得的取源选项。选项行形如 `  -skip_estimate_duration_from_pts <boolean> …`。
    static func parseReadOptions(_ output: String) -> [String] {
        let declared = Set(
            output.split(separator: "\n").compactMap { line -> String? in
                let trimmed = line.drop(while: { $0 == " " })
                guard trimmed.hasPrefix("-") else { return nil }
                return trimmed.dropFirst().split(separator: " ", maxSplits: 1).first.map(String.init)
            }
        )
        return readOptions.filter(declared.contains)
    }

    /// NAS 装命令时用得上的 Metal 滤镜（jellyfin-ffmpeg 自带）：GPU 缩放、HDR→SDR
    /// 色调映射（含杜比视界），以及 GPU 上的字幕叠加、反交错、旋转。其余滤镜不申报。
    static let metalFilters: Set<String> = [
        "scale_vt", "tonemap_videotoolbox", "overlay_videotoolbox",
        "yadif_videotoolbox", "bwdif_videotoolbox", "transpose_vt",
    ]

    /// 从 `ffmpeg -filters` 的输出里取滤镜名。数据行形如 ` .S tonemap   V->V   说明`，
    /// 第三列是输入输出类型（含 `->`）；开头的图例行（`T.. = Timeline support`）第二
    /// 列是 `=`、没有 `->`，据此排除。
    static func parseFilters(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 3, fields[2].contains("->") else { return nil }
                return String(fields[1])
            }
    }

    /// ffmpeg 的 VideoToolbox 硬解支持的编码 → 系统编码四字码。能不能真硬解，
    /// 每台 Mac 不一样（AV1 要 M3 起），逐个问系统。
    static let hardwareDecodeCandidates: [(name: String, fourCC: String)] = [
        ("h264", "avc1"), ("hevc", "hvc1"), ("mpeg2video", "mp2v"),
        ("mpeg4", "mp4v"), ("vp9", "vp09"), ("av1", "av01"),
    ]

    /// 这台 Mac 能硬解的片源编码（ffmpeg 编码名）。
    ///
    /// NAS 据此决定要不要硬件帧：解不了的编码硬要硬件帧，ffmpeg 退回软解后，软件帧
    /// 喂给后面的 GPU 滤镜直接失败（实测 VC-1 以 -22 退出）。AV1 只在 ffmpeg 8 起才
    /// 申报——更早的 ffmpeg 没有 AV1 的 VideoToolbox 硬解，系统说能解也用不上。
    static func hardwareDecoders(ffmpegMajorVersion: Int?) -> [String] {
        if #available(macOS 11.0, *) {
            // VP9 / AV1 的系统解码器要先登记才查得到（ffmpeg 硬解时也会这么做）
            VTRegisterSupplementalVideoDecoderIfAvailable(fourCharCode("vp09"))
            VTRegisterSupplementalVideoDecoderIfAvailable(fourCharCode("av01"))
        }
        return hardwareDecodeCandidates.compactMap { candidate in
            if candidate.name == "av1", (ffmpegMajorVersion ?? 0) < 8 { return nil }
            return VTIsHardwareDecodeSupported(fourCharCode(candidate.fourCC)) ? candidate.name : nil
        }
    }

    static func fourCharCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// `ffmpeg version 8.1.2-Jellyfin …` → 8，`ffmpeg version n7.1 …`（git 标签）→ 7；认不出返回 nil。
    static func majorVersion(of versionLine: String) -> Int? {
        guard let range = versionLine.range(of: "version ") else { return nil }
        var rest = versionLine[range.upperBound...]
        if rest.first == "n" { rest = rest.dropFirst() }
        return Int(rest.prefix { $0.isNumber })
    }

    /// 从 `ffmpeg -encoders` 的输出里取编码器名。
    ///
    /// 输出开头是 8 行标志位图例（` V..... = Video`、` .F.... = Frame-level
    /// multithreading` …），它们的第一列同样是 6 个字符，只按列宽过滤会把
    /// 图例的 `=` 当成 8 个编码器收进来（issue #286 的能力快照里
    /// `encoders==,=,=,…` 就是这么来的）。图例行第二列固定是 `=`，据此排除；
    /// `------` 分隔行只有一列，本来就过不了。
    static func parseEncoders(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2, fields[0].count == 6, fields[1] != "=" else { return nil }
                return String(fields[1])
            }
    }

    private static func execute(_ path: String, arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // 先读完再等退出：输出超过管道缓冲（64 KB）时 ffmpeg 会卡在写上，先等退出就是死锁
        // （`-h full` 有 1 MB 多，实测内核启动时卡死在这里）
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ConfigurationError.message("ffmpeg 能力探测失败：\(text.suffix(600))")
        }
        return text
    }
}
