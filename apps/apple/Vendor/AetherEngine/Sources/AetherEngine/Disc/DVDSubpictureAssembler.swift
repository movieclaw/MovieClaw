import Foundation

/// #651: joins the PES fragments of one DVD subpicture unit back into the packet `dvdsubdec` expects.
///
/// `mpegps` hands a subpicture stream it created itself to libavformat's `dvdsub` parser, which does
/// this join. A stream the engine declares from the IFO before the probe cannot ask for that parser
/// (`need_parsing` is internal to libavformat), and a unit larger than one 2 KB pack then reaches the
/// decoder as its first fragment alone, which does not decode. This is the same rule as
/// `libavcodec/dvdsub_parser.c`: the unit's size is its first 16 bits (or the 32 bits after a zero
/// there), fragments append until that size is reached, the unit carries the first fragment's
/// timing, and a fragment that would overrun the size drops the unit.
struct DVDSubpictureAssembler {

    /// Timing of the fragment that opened the unit, which the joined packet carries.
    struct Timing: Equatable {
        let pts: Int64
        let dts: Int64
        let pos: Int64
        let duration: Int64
    }

    struct Unit: Equatable {
        let data: [UInt8]
        let timing: Timing
    }

    private var buffer: [UInt8] = []
    private var expected = 0
    private var timing: Timing?

    var isAssembling: Bool { timing != nil }

    var reservedCapacity: Int { buffer.capacity }

    static let maxUnitBytes = 1 << 20
    static let initialReservationBytes = 64 * 1024

    /// Feed one demuxed fragment. Returns the unit once it is complete, nil while it is not (or when
    /// the fragment was dropped).
    mutating func ingest(_ fragment: UnsafeRawBufferPointer, timing fragmentTiming: Timing) -> Unit? {
        if timing == nil {
            let bytes = fragment.bindMemory(to: UInt8.self)
            guard bytes.count >= 2 else { return nil }
            var size = Int(bytes[0]) << 8 | Int(bytes[1])
            if size == 0 {
                guard bytes.count >= 6 else { return nil }
                size = Int(bytes[2]) << 24 | Int(bytes[3]) << 16 | Int(bytes[4]) << 8 | Int(bytes[5])
            } else if bytes.count < 6 {
                return nil
            }
            // Audit NET-104: the 32-bit form stated up to 4 GiB, all of it reserved up front, and the
            // unit then swallowed every later fragment of the stream. A DVD SPU is at most 53,220
            // bytes; 1 MiB leaves room for the HD-DVD units `dvdsubdec` decodes.
            guard size > 0, size <= Self.maxUnitBytes else { return nil }
            expected = size
            timing = fragmentTiming
            buffer.removeAll(keepingCapacity: true)
            buffer.reserveCapacity(min(size, Self.initialReservationBytes))
        }
        guard buffer.count + fragment.count <= expected, let unitTiming = timing else {
            reset()
            return nil
        }
        buffer.append(contentsOf: fragment.bindMemory(to: UInt8.self))
        guard buffer.count >= expected else { return nil }
        let unit = Unit(data: buffer, timing: unitTiming)
        reset()
        return unit
    }

    /// Drop a half-joined unit, for a seek: the next fragment read is from somewhere else.
    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        expected = 0
        timing = nil
    }
}
