import Foundation
import AetherLibavcodec
import AetherLibavutil

/// Decoder-free HDR Vivid (CUVA T/UWA 005.1) confirmation for the detail probe (#699).
///
/// HDR Vivid's dynamic metadata rides a registered ITU-T T.35 SEI in HEVC: country code 0x26 (China),
/// terminal provider code 0x0004, provider oriented code 0x0005, then the CUVA body. No container
/// declares it and no demuxer lifts it into packet side data, so like HDR10+ it is only visible in the
/// packet payload. FFmpeg's own body parser is internal (`ff_parse_itu_t_t35_to_dynamic_hdr_vivid`),
/// so the body is walked here with the same field widths, and a message only counts when it is
/// complete and every bit after its last field is zero. A marker alone is not proof.
///
/// HEVC only, matching libavcodec, which ignores this payload on every other codec.
enum HDRVividMetadataScan {
    private static let t35Header: [UInt8] = [0x26, 0x00, 0x04, 0x00, 0x05]

    static func packetCarriesHDRVivid(
        _ packet: UnsafePointer<AVPacket>,
        codecParameters: UnsafePointer<AVCodecParameters>
    ) -> Bool {
        let parameters = codecParameters.pointee
        guard parameters.codec_id == AV_CODEC_ID_HEVC else { return false }
        let framing: VideoNALFraming = NALUnitChain.lengthPrefixSize(
            codecID: parameters.codec_id,
            extradata: parameters.extradata,
            extradataSize: Int(parameters.extradata_size)
        ).map { .lengthPrefixed(size: $0) } ?? .annexB
        return bytesCarryHDRVivid(packet.pointee.data, size: Int(packet.pointee.size), framing: framing)
    }

    static func bytesCarryHDRVivid(
        _ data: UnsafePointer<UInt8>?, size: Int, framing: VideoNALFraming = .annexB
    ) -> Bool {
        guard let data, size >= t35Header.count,
              t35Header.withUnsafeBufferPointer({ memmem(data, size, $0.baseAddress, $0.count) != nil })
        else { return false }
        return HDR10PlusMetadataScan.scanNALs(
            UnsafeBufferPointer(start: data, count: size),
            codecID: AV_CODEC_ID_HEVC, framing: framing, payload: validT35)
    }

    private static func validT35(_ bytes: UnsafePointer<UInt8>, _ size: Int) -> Bool {
        guard size > t35Header.count,
              t35Header.indices.allSatisfy({ bytes[$0] == t35Header[$0] }) else { return false }
        return bodyIsComplete(UnsafeBufferPointer(start: bytes + t35Header.count, count: size - t35Header.count))
    }

    /// The CUVA body, field for field as libavcodec's `dynamic_hdr_vivid.c` reads it. Only
    /// `system_start_code` 1 to 7 has a defined syntax (T/UWA 005.1-2022, table 11), so any other value
    /// is not evidence of this format.
    static func bodyIsComplete(_ body: UnsafeBufferPointer<UInt8>) -> Bool {
        var reader = BitReader(body)
        guard let startCode = reader.read(8), (1...7).contains(startCode),
              reader.skip(4 * 12),
              let toneMapping = reader.read(1) else { return false }
        if toneMapping == 1 {
            guard let extraParams = reader.read(1) else { return false }
            for _ in 0...extraParams {
                guard reader.skip(12), let baseEnable = reader.read(1) else { return false }
                if baseEnable == 1, !reader.skip(14 + 6 + 10 + 10 + 6 + 2 + 2 + 4 + 3 + 7) { return false }
                guard let splineEnable = reader.read(1) else { return false }
                if splineEnable == 1 {
                    guard let extraSplines = reader.read(1) else { return false }
                    for _ in 0...extraSplines {
                        guard let mode = reader.read(2) else { return false }
                        if mode == 0 || mode == 2, !reader.skip(8) { return false }
                        guard reader.skip(12 + 10 + 10 + 8) else { return false }
                    }
                }
            }
        }
        guard let saturationMapping = reader.read(1) else { return false }
        if saturationMapping == 1 {
            guard let gains = reader.read(3), reader.skip(gains * 8) else { return false }
        }
        return reader.remainderIsZero
    }

    private struct BitReader {
        let bytes: UnsafeBufferPointer<UInt8>
        private(set) var position = 0

        init(_ bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        mutating func read(_ count: Int) -> Int? {
            guard count <= bytes.count * 8 - position else { return nil }
            var value = 0
            for _ in 0..<count {
                let bit = (bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
                value = (value << 1) | Int(bit)
                position += 1
            }
            return value
        }

        mutating func skip(_ count: Int) -> Bool {
            guard count <= bytes.count * 8 - position else { return false }
            position += count
            return true
        }

        var remainderIsZero: Bool {
            var index = position
            while index < bytes.count * 8 {
                if (bytes[index >> 3] >> (7 - UInt8(index & 7))) & 1 != 0 { return false }
                index += 1
            }
            return true
        }
    }
}
