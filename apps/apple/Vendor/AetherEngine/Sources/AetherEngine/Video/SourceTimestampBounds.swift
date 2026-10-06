import Foundation
import CoreMedia
import AetherLibavcodec

/// Audit SEG-1: demuxed timestamps reach the pump unchecked (matroskadec stores a uint64 cluster
/// time into an int64 pts, a live fMP4 tfdt is whatever the origin wrote), and Swift traps on
/// Int64 overflow. Values outside `plausibleMagnitude` become AV_NOPTS_VALUE at the source funnel,
/// which the pump's NOPTS repair already handles, and the tick arithmetic downstream saturates
/// instead of trapping.
enum SourceTimestampBounds {

    /// 2^60 still holds an epoch-anchored tfdt at a 10 MHz timescale by three orders of magnitude,
    /// and leaves room for the pump's three-term shift chains below 2^63.
    static let plausibleMagnitude: Int64 = 1 << 60

    static func plausible(_ ticks: Int64) -> Int64 {
        guard ticks != Int64.min else { return ticks }
        return ticks > -plausibleMagnitude && ticks < plausibleMagnitude ? ticks : Int64.min
    }

    /// Audit NAT-101 / DEC-101 / FEA-101 / SUB-105: the demuxer-wide bound, applied to every packet
    /// the engine reads. 2^62 keeps any difference of two bounded values inside Int64 and holds an
    /// epoch-anchored nanosecond timestamp (1.79e18 in 2026) until about 2116.
    static let demuxedMagnitude: Int64 = 1 << 62

    /// Epoch seconds pass until about 2096. `ticks * num == seconds * den` and
    /// `4e9 * (2^31 - 1) < 2^63`, so a tick inside this bound times any AVRational numerator stays
    /// inside Int64, and a bounded time scaled to milliseconds or centiseconds stays inside Int.
    static let maxPlausibleSeconds: Double = 4e9

    /// AV_NOPTS_VALUE for a tick at or past `demuxedMagnitude`, or one whose time on `timeBase` is at
    /// or past `maxPlausibleSeconds`. A degenerate time base leaves only the tick rule.
    static func plausible(_ ticks: Int64, timeBase: AVRational) -> Int64 {
        guard ticks != Int64.min else { return ticks }
        guard ticks > -demuxedMagnitude, ticks < demuxedMagnitude else { return Int64.min }
        guard timeBase.num > 0, timeBase.den > 0 else { return ticks }
        let seconds = Double(ticks) * Double(timeBase.num) / Double(timeBase.den)
        return abs(seconds) < maxPlausibleSeconds ? ticks : Int64.min
    }

    /// The demuxer's funnel: implausible pts / dts become AV_NOPTS_VALUE, an implausible or negative
    /// duration becomes 0. Idempotent, so a second pass over repaired output is free. Returns whether
    /// any field was replaced.
    @discardableResult
    static func sanitize(_ packet: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) -> Bool {
        let pts = plausible(packet.pointee.pts, timeBase: timeBase)
        let dts = plausible(packet.pointee.dts, timeBase: timeBase)
        let duration = packet.pointee.duration
        let durationOK = duration >= 0 && plausible(duration, timeBase: timeBase) == duration
        guard pts != packet.pointee.pts || dts != packet.pointee.dts || !durationOK else { return false }
        packet.pointee.pts = pts
        packet.pointee.dts = dts
        if !durationOK { packet.pointee.duration = 0 }
        return true
    }

    /// Returns whether any field was out of range and got replaced.
    @discardableResult
    static func sanitize(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        let pts = plausible(packet.pointee.pts)
        let dts = plausible(packet.pointee.dts)
        let duration = packet.pointee.duration
        let durationOK = duration >= 0 && duration < plausibleMagnitude
        guard pts != packet.pointee.pts || dts != packet.pointee.dts || !durationOK else { return false }
        packet.pointee.pts = pts
        packet.pointee.dts = dts
        if !durationOK { packet.pointee.duration = 0 }
        return true
    }

    /// Saturating tick arithmetic. The floor is `Int64.min + 1` so a result never reads as AV_NOPTS_VALUE.
    static func difference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard overflow else { return max(value, Int64.min + 1) }
        return lhs < rhs ? Int64.min + 1 : Int64.max
    }

    static func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return max(value, Int64.min + 1) }
        return lhs < 0 ? Int64.min + 1 : Int64.max
    }

    /// Audit DEC-101: `ticks * num` as a CMTime, `.invalid` for AV_NOPTS_VALUE, a degenerate time
    /// base or a product outside Int64. Decoder-computed frame timestamps and the software host's
    /// folded ones never pass the demuxer's bound, so the conversion itself has to be total.
    static func cmTime(ticks: Int64, timeBase: AVRational) -> CMTime {
        guard ticks != Int64.min, timeBase.den > 0 else { return .invalid }
        let (value, overflow) = ticks.multipliedReportingOverflow(by: Int64(timeBase.num))
        guard !overflow else { return .invalid }
        return CMTimeMake(value: value, timescale: timeBase.den)
    }

    /// A tick count computed in Double, rounded to the nearest tick. nil when it is not finite or
    /// falls outside Int64, Int64.min included (it reads as AV_NOPTS_VALUE).
    static func roundedTicks(_ value: Double) -> Int64? {
        guard let ticks = Int64(exactly: value.rounded()), ticks != Int64.min else { return nil }
        return ticks
    }

    /// Audit NAT-101: moves a timestamp back by `offset` ticks. AV_NOPTS_VALUE when the timestamp or
    /// the offset is unset, or when the result leaves Int64.
    static func shifted(_ ticks: Int64, back offset: Int64?) -> Int64 {
        guard ticks != Int64.min, let offset else { return Int64.min }
        let (value, overflow) = ticks.subtractingReportingOverflow(offset)
        return overflow ? Int64.min : value
    }

    /// Audit SUB-105: a cue or display time about to be scaled into an integer. NaN reads as 0 and
    /// anything past `maxPlausibleSeconds` pins to it.
    static func clampedSeconds(_ seconds: Double) -> Double {
        guard !seconds.isNaN else { return 0 }
        return min(max(seconds, -maxPlausibleSeconds), maxPlausibleSeconds)
    }
}
