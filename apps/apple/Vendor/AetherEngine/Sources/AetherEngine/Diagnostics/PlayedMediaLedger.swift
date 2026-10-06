import Foundation

/// AE#514 round 2: the bytes of the media the session plays, keyed by presentation time on the source
/// axis, so the bitrate fields can be metered from what the playhead crossed rather than from what the
/// reader transferred.
///
/// The transfer counter and playback part ways on every route that reads ahead: VOD prefetches minutes
/// in front of the playhead, a seek discards a buffer and fetches it again, and a paused live session
/// keeps draining the origin into its DVR window (AE#443). A rate metered off that counter reported the
/// prefetch (35 Mbps for a 20 Mbps stream) and climbed without bound through a live pause.
///
/// The pump records every packet of the played video and audio streams as it hands them on; the
/// sampler consumes the span the playhead crossed since its last tick. Thread-safe: the pump records
/// on its read thread, the sampler consumes on the main actor.
final class PlayedMediaLedger: @unchecked Sendable {

    enum Track: Int, CaseIterable {
        case video = 0
        case audio = 1
    }

    private struct Entry {
        let pts: Double
        var bytes: Int
    }

    /// A packet this far behind the newest one on its track is a re-read (a seek replaying a range the
    /// reader already delivered), not B-frame reorder, which stays well under a second.
    static let rereadThresholdSeconds: Double = 2.0

    /// Entries held across both tracks. A VOD read-ahead of several minutes stays far below it; past
    /// it the farthest-ahead packets go unrecorded, so the span they cover later reads as unmeasured
    /// rather than as a lower rate.
    static let maxEntries = 262_144

    private let lock = NSLock()
    private var tracks: [[Entry]] = Array(repeating: [], count: Track.allCases.count)
    private var count = 0

    /// Records one played packet. `pts` is in seconds on the source axis, the axis the playhead the
    /// sampler hands `consume` is on.
    func record(_ track: Track, pts: Double, bytes: Int) {
        guard pts.isFinite, bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = tracks[track.rawValue]
        tracks[track.rawValue] = []
        defer { tracks[track.rawValue] = entries }

        if let newest = entries.last?.pts, pts < newest - Self.rereadThresholdSeconds {
            let cut = Self.lowerBound(entries, pts)
            count -= entries.count - cut
            entries.removeSubrange(cut...)
        }
        var index = entries.count
        while index > 0, entries[index - 1].pts > pts { index -= 1 }
        if index > 0, entries[index - 1].pts == pts {
            entries[index - 1].bytes = bytes
            return
        }
        guard count < Self.maxEntries else { return }
        entries.insert(Entry(pts: pts, bytes: bytes), at: index)
        count += 1
    }

    /// Bytes of every packet presented in `[from, to)`, which leave the ledger with everything before `to`.
    func consume(from: Double, to: Double) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        var total: Int64 = 0
        for track in tracks.indices {
            let start = Self.lowerBound(tracks[track], from)
            let end = Self.lowerBound(tracks[track], to)
            if start < end {
                for entry in tracks[track][start..<end] { total += Int64(entry.bytes) }
            }
            dropLocked(track, below: end)
        }
        return total
    }

    /// Forgets everything presented before `pts` without charging it: the playhead jumped over it.
    func discard(below pts: Double) {
        lock.lock()
        defer { lock.unlock() }
        for track in tracks.indices {
            dropLocked(track, below: Self.lowerBound(tracks[track], pts))
        }
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    private func dropLocked(_ track: Int, below end: Int) {
        guard end > 0 else { return }
        tracks[track].removeFirst(end)
        count -= end
    }

    private static func lowerBound(_ entries: [Entry], _ pts: Double) -> Int {
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].pts < pts { low = mid + 1 } else { high = mid }
        }
        return low
    }
}

/// AE#514 round 2: both bitrate fields over the media the playhead crossed. Advanced once per sampler
/// tick with the playhead on the ledger's axis.
///
/// A step forward no larger than playback could have covered in the tick is charged: its bytes from the
/// ledger, its media seconds as the divisor. Anything else is a seek or a jump and charges nothing, and a
/// paused playhead does not move, so both values stand still through a pause on every route, live
/// included. A step whose span the ledger holds no bytes for is left out too (the ledger was not fed
/// there, or its axis does not line up with this playhead): an unmeasured span is a gap, never a zero.
struct PlayedBitrateMeter {

    /// Fastest playback the charge accepts, as media seconds per wall second, plus a fixed slack for
    /// tick jitter. Past that the playhead jumped.
    static let maxRate: Double = 4.0
    static let stepSlackSeconds: Double = 0.5

    /// Charged ticks the instant value averages over, about the last ten seconds of playback.
    static let windowTicks = 10

    private var lastPlayhead: Double?
    private var window: [(bytes: Int64, seconds: Double)] = []
    private(set) var lifetimeBytes: Int64 = 0
    private(set) var lifetimeSeconds: Double = 0

    mutating func advance(to playhead: Double?, wallSeconds: Double, ledger: PlayedMediaLedger) {
        guard let playhead, playhead.isFinite else { return }
        defer { lastPlayhead = playhead }
        guard let last = lastPlayhead else {
            ledger.discard(below: playhead)
            return
        }
        let step = playhead - last
        guard step != 0 else { return }
        guard step > 0, step <= max(0, wallSeconds) * Self.maxRate + Self.stepSlackSeconds else {
            ledger.discard(below: playhead)
            return
        }
        let bytes = ledger.consume(from: last, to: playhead)
        guard bytes > 0 else { return }
        lifetimeBytes += bytes
        lifetimeSeconds += step
        window.append((bytes, step))
        if window.count > Self.windowTicks { window.removeFirst(window.count - Self.windowTicks) }
    }

    /// Mean rate of the last `windowTicks` charged ticks. nil before the first one.
    var instantMbps: Double? {
        let seconds = window.reduce(0) { $0 + $1.seconds }
        let bytes = window.reduce(Int64(0)) { $0 + $1.bytes }
        return Self.mbps(bytes: bytes, seconds: seconds)
    }

    /// Mean rate of everything played this session. nil before the first charged tick.
    var averageMbps: Double? { Self.mbps(bytes: lifetimeBytes, seconds: lifetimeSeconds) }

    private static func mbps(bytes: Int64, seconds: Double) -> Double? {
        guard seconds > 0, bytes > 0 else { return nil }
        return Double(bytes) * 8.0 / seconds / 1_000_000.0
    }
}
