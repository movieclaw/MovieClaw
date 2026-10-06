import Foundation
import CoreMedia
import AudioToolbox
import AetherLibavutil
import AetherLibavcodec

/// The `nativeRemoteHLS` bypass runs no libav probe, so the fields a stats panel reads (dimensions, colour
/// description, audio tracks) had no source on it, and a host fell back to metadata of the ORIGINAL file:
/// a capped 1280x720 H.264 transcode read "3840x2160, Main 10". AVPlayer has already parsed the delivered
/// stream into its item tracks' format descriptions, so this maps those onto the probe path's vocabulary
/// (libav names), without a second connection to the origin. Pure so it is unit-testable; the host does
/// the async track reads.
enum RemoteHLSStreamDescription {

    /// First id of the audio tracks published on the bypass. Synthetic, like the legible range at
    /// `RemoteHLSMediaSelection.subtitleTrackIDBase`: there is no AVStream index on this route, and a
    /// small ordinal would collide with a host's own source stream numbering.
    static let audioTrackIDBase = 400_000

    // MARK: - Video

    struct Video: Equatable, Sendable {
        let width: Int32
        let height: Int32
        let codecName: String?
        let format: VideoStreamFormat
    }

    static func video(from description: CMFormatDescription) -> Video? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else { return nil }
        let subType = CMFormatDescriptionGetMediaSubType(description)
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        let ext = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        return Video(
            width: dims.width, height: dims.height,
            codecName: RemoteHLSFormatDetection.codecName(videoSubType: subType),
            format: videoStreamFormat(extensions: ext))
    }

    static func videoStreamFormat(extensions ext: [String: Any]) -> VideoStreamFormat {
        let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        let config: CodecConfiguration? =
            (atoms["avcC"] as? Data).flatMap(avcConfiguration)
            ?? (atoms["hvcC"] as? Data).flatMap(hevcConfiguration)
        let declaredDepth = (ext[kCMFormatDescriptionExtension_BitsPerComponent as String] as? NSNumber)?.intValue
        let range: String?
        if let full = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool {
            range = full ? "pc" : "tv"
        } else {
            range = nil
        }
        return VideoStreamFormat(
            pixelFormat: config?.pixelFormat,
            bitDepth: config?.bitDepth ?? declaredDepth,
            colorPrimaries: (ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String).map(primariesName),
            transfer: (ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String).map(transferName),
            matrix: (ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String).map(matrixName),
            range: range,
            profile: config?.profileName)
    }

    /// CoreMedia's colour names onto libav's. An unknown name passes through: a value CoreMedia adds later
    /// is still the stream's own declaration, and dropping it would read as "untagged".
    static func primariesName(_ name: String) -> String { primariesNames[name] ?? name }
    static func transferName(_ name: String) -> String { transferNames[name] ?? name }
    static func matrixName(_ name: String) -> String { matrixNames[name] ?? name }

    private static let primariesNames: [String: String] = [
        kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String: "bt709",
        kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String: "bt2020",
        kCMFormatDescriptionColorPrimaries_EBU_3213 as String: "bt470bg",
        kCMFormatDescriptionColorPrimaries_SMPTE_C as String: "smpte170m",
        kCMFormatDescriptionColorPrimaries_P3_D65 as String: "smpte432",
        kCMFormatDescriptionColorPrimaries_DCI_P3 as String: "smpte431",
    ]

    private static let transferNames: [String: String] = [
        kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String: "bt709",
        kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String: "smpte2084",
        kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String: "arib-std-b67",
        kCMFormatDescriptionTransferFunction_ITU_R_2020 as String: "bt2020-10",
        kCMFormatDescriptionTransferFunction_SMPTE_240M_1995 as String: "smpte240m",
        kCMFormatDescriptionTransferFunction_Linear as String: "linear",
        kCMFormatDescriptionTransferFunction_sRGB as String: "iec61966-2-1",
    ]

    private static let matrixNames: [String: String] = [
        kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String: "bt709",
        kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String: "smpte170m",
        kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String: "bt2020nc",
        kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995 as String: "smpte240m",
    ]

    /// What a decoder configuration record declares: libav's profile name, and where the record pins
    /// them, chroma format and luma depth as a libav pixel format.
    struct CodecConfiguration: Equatable {
        let profileName: String?
        let pixelFormat: String?
        let bitDepth: Int?
    }

    /// ISO/IEC 14496-15 avcC. The chroma/depth extension exists only for the High family, and there only
    /// when the muxer wrote it; the lower profiles are 8-bit 4:2:0 by definition, and so is plain High.
    static func avcConfiguration(_ record: Data) -> CodecConfiguration? {
        let b = [UInt8](record)
        guard b.count >= 7, b[0] == 1 else { return nil }
        let idc = Int32(b[1])
        let compatibility = b[2]
        var profile = idc
        if idc == 66, compatibility & 0x40 != 0 { profile |= 1 << 9 }            // AV_PROFILE_H264_CONSTRAINED
        if [110, 122, 244].contains(idc), compatibility & 0x10 != 0 { profile |= 1 << 11 }   // _INTRA
        let highFamily: Set<Int32> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

        var chroma: Int?
        var depth: Int?
        if highFamily.contains(idc) {
            // Skip the SPS and PPS arrays to reach the extension.
            var i = 5
            let spsCount = Int(b[i] & 0x1F); i += 1
            var ok = true
            for _ in 0..<spsCount {
                guard i + 2 <= b.count else { ok = false; break }
                i += 2 + (Int(b[i]) << 8 | Int(b[i + 1]))
            }
            if ok, i < b.count {
                let ppsCount = Int(b[i]); i += 1
                for _ in 0..<ppsCount {
                    guard i + 2 <= b.count else { ok = false; break }
                    i += 2 + (Int(b[i]) << 8 | Int(b[i + 1]))
                }
            }
            if ok, i + 2 <= b.count {
                chroma = Int(b[i] & 0x03)
                depth = Int(b[i + 1] & 0x07) + 8
            } else if idc == 100 {
                chroma = 1
                depth = 8
            }
        } else {
            chroma = 1
            depth = 8
        }
        return CodecConfiguration(
            profileName: VideoStreamFormat.profileName(codecID: AV_CODEC_ID_H264, profile: profile),
            pixelFormat: pixelFormatName(chroma: chroma, depth: depth),
            bitDepth: depth)
    }

    /// ISO/IEC 14496-15 hvcC: general_profile_idc in byte 1, chroma_format_idc in byte 16, luma depth in 17.
    static func hevcConfiguration(_ record: Data) -> CodecConfiguration? {
        let b = [UInt8](record)
        guard b.count >= 23, b[0] == 1 else { return nil }
        let depth = Int(b[17] & 0x07) + 8
        return CodecConfiguration(
            profileName: VideoStreamFormat.profileName(codecID: AV_CODEC_ID_HEVC, profile: Int32(b[1] & 0x1F)),
            pixelFormat: pixelFormatName(chroma: Int(b[16] & 0x03), depth: depth),
            bitDepth: depth)
    }

    /// The pixel format libav's decoder reports for a chroma format and depth, checked against libav's own
    /// table so a combination it has no name for stays nil instead of becoming a made-up one.
    static func pixelFormatName(chroma: Int?, depth: Int?) -> String? {
        guard let chroma, let depth else { return nil }
        let base: String
        switch chroma {
        case 0: base = "gray"
        case 1: base = "yuv420p"
        case 2: base = "yuv422p"
        case 3: base = "yuv444p"
        default: return nil
        }
        let name = depth == 8 ? base : "\(base)\(depth)le"
        return av_get_pix_fmt(name) == AV_PIX_FMT_NONE ? nil : name
    }

    // MARK: - Audio

    /// One audio track as AVPlayer built it, reduced to values so the mapping below stays pure.
    struct AudioReading: Equatable, Sendable {
        let formatID: AudioFormatID
        let sampleRate: Double
        let channels: Int
        let bitsPerChannel: Int
        let carriesJOC: Bool
        let isEnabled: Bool
        let language: String?
    }

    static func audioReading(from description: CMFormatDescription, isEnabled: Bool, language: String?) -> AudioReading? {
        guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        var joc = false
        if asbd.mFormatID == kAudioFormatEnhancedAC3 {
            var size = 0
            if let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size), size > 0 {
                joc = eac3CarriesJOC(dec3: Data(bytes: cookie, count: size))
            }
        }
        return AudioReading(
            formatID: asbd.mFormatID,
            sampleRate: asbd.mSampleRate,
            channels: Int(asbd.mChannelsPerFrame),
            bitsPerChannel: Int(asbd.mBitsPerChannel),
            carriesJOC: joc,
            isEnabled: isEnabled,
            language: language)
    }

    /// ETSI TS 102 366 Annex F dec3: `flag_ec3_extension_type_a` after the substream loop is the JOC
    /// (Atmos) signal, the same one libav reads into E-AC-3 profile 30. Accepts the bare payload or the
    /// whole box, since the magic cookie AVFoundation hands back has been seen both ways.
    static func eac3CarriesJOC(dec3 record: Data) -> Bool {
        var b = [UInt8](record)
        if b.count >= 8, Array(b[4..<8]) == Array("dec3".utf8) { b.removeFirst(8) }
        var reader = BitReader(bytes: b)
        guard reader.skip(13), let indSubs = reader.read(3) else { return false }
        for _ in 0...indSubs {
            // fscod bsid reserved asvc bsmod acmod lfeon reserved
            guard reader.skip(2 + 5 + 1 + 1 + 3 + 3 + 1 + 3), let depSubs = reader.read(4) else { return false }
            guard reader.skip(depSubs > 0 ? 9 : 1) else { return false }
        }
        guard reader.skip(7), let flag = reader.read(1) else { return false }
        return flag == 1
    }

    /// Audio format IDs onto the libavcodec name the probe path publishes, AAC's object type onto its profile.
    static func audioCodec(formatID: AudioFormatID) -> (name: String, profile: String?) {
        switch formatID {
        case kAudioFormatMPEG4AAC:
            return ("aac", VideoStreamFormat.profileName(codecID: AV_CODEC_ID_AAC, profile: 1))
        case kAudioFormatMPEG4AAC_HE:
            return ("aac", VideoStreamFormat.profileName(codecID: AV_CODEC_ID_AAC, profile: 4))
        case kAudioFormatMPEG4AAC_HE_V2:
            return ("aac", VideoStreamFormat.profileName(codecID: AV_CODEC_ID_AAC, profile: 28))
        case kAudioFormatMPEG4AAC_LD: return ("aac", "LD")
        case kAudioFormatMPEG4AAC_ELD: return ("aac", "ELD")
        case kAudioFormatAC3: return ("ac3", nil)
        case kAudioFormatEnhancedAC3: return ("eac3", nil)
        case kAudioFormatMPEGLayer1: return ("mp1", nil)
        case kAudioFormatMPEGLayer2: return ("mp2", nil)
        case kAudioFormatMPEGLayer3: return ("mp3", nil)
        case kAudioFormatFLAC: return ("flac", nil)
        case kAudioFormatOpus: return ("opus", nil)
        case kAudioFormatAppleLossless: return ("alac", nil)
        case kAudioFormatLinearPCM: return ("pcm", nil)
        case 0x61632D34: return ("ac4", nil)   // 'ac-4'
        default:
            let bytes = [UInt8((formatID >> 24) & 0xFF), UInt8((formatID >> 16) & 0xFF),
                         UInt8((formatID >> 8) & 0xFF), UInt8(formatID & 0xFF)]
            return (String(bytes: bytes, encoding: .macOSRoman) ?? "unknown", nil)
        }
    }

    /// The published list: one entry per audio track AVPlayer built, ids from `audioTrackIDBase` in item
    /// order, the enabled one as the active index. Named the way the probe path names an untitled track.
    /// A parsed `mSampleRate` as a whole number, 0 when it cannot be one (audit NAT-106). A QuickTime
    /// SoundDescriptionV2 carries the rate as a Float64 verbatim, so on the bypass the origin controls
    /// it, and `Int(_:)` traps on NaN, infinity and anything past `Int`.
    static func wholeSampleRate(_ rate: Double) -> Int {
        rate.isFinite && rate >= 0 && rate < 1e9 ? Int(rate) : 0
    }

    static func audioTracks(_ readings: [AudioReading]) -> (tracks: [TrackInfo], activeID: Int?) {
        var tracks: [TrackInfo] = []
        var activeID: Int?
        for (i, reading) in readings.enumerated() {
            let id = audioTrackIDBase + i
            let codec = audioCodec(formatID: reading.formatID)
            let language = reading.language.flatMap { $0.isEmpty || $0 == "und" ? nil : $0 }
            let name = language.map { "\($0.uppercased()) (\(codec.name))" } ?? "Track \(i + 1) (\(codec.name))"
            let profile = reading.carriesJOC
                ? VideoStreamFormat.profileName(codecID: AV_CODEC_ID_EAC3, profile: 30)
                : codec.profile
            tracks.append(TrackInfo(
                id: id, name: name, codec: codec.name, language: language,
                channels: reading.channels, isDefault: reading.isEnabled, isAtmos: reading.carriesJOC,
                sampleRate: wholeSampleRate(reading.sampleRate),
                bitsPerSample: reading.bitsPerChannel, profile: profile))
            if reading.isEnabled, activeID == nil { activeID = id }
        }
        return (tracks, activeID)
    }

    private struct BitReader {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func read(_ count: Int) -> Int? {
            guard position + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                let bit = (bytes[position / 8] >> (7 - UInt8(position % 8))) & 1
                value = value << 1 | Int(bit)
                position += 1
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool { read(count) != nil || count == 0 }
    }
}
