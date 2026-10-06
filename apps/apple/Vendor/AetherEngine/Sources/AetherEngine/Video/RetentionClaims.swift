import Foundation

/// What the running sessions may still write to the tmp volume (#687).
///
/// A session sizes its retention from the volume's free space, measured once at its start. A claim
/// another session has made but not yet written is still free at that moment, so several sessions
/// started together each took a quarter of the same space: four engines (a multiview host) claimed
/// four quarters, i.e. the volume the clamp exists to protect.
///
/// So every session claims here, and a new one is sized from what is really left: the free space
/// minus what the others have claimed and not yet written. A session alone gets what it always got;
/// n sessions together leave at least `(3/4)^n` of the volume.
final class RetentionClaims: @unchecked Sendable {

    static let shared = RetentionClaims()

    /// One session's allowance. Released by `release()` or when dropped.
    final class Claim: @unchecked Sendable {
        let bytes: Int
        /// What the other sessions could still write when this claim was sized; for the log.
        let heldBackBytes: Int
        private let id = UUID()
        private let ledger: RetentionClaims

        fileprivate init(bytes: Int, heldBackBytes: Int, ledger: RetentionClaims) {
            self.bytes = bytes
            self.heldBackBytes = heldBackBytes
            self.ledger = ledger
            ledger.entries[id] = Entry(bytes: bytes, used: nil)
        }

        /// Reports what the session has written so far. Until it is set the whole claim counts as
        /// unwritten, which only ever sizes a later session smaller.
        func track(_ used: @escaping @Sendable () -> Int) {
            ledger.lock.lock()
            defer { ledger.lock.unlock() }
            ledger.entries[id]?.used = used
        }

        func release() {
            ledger.lock.lock()
            defer { ledger.lock.unlock() }
            ledger.entries.removeValue(forKey: id)
        }

        deinit { release() }
    }

    private struct Entry {
        let bytes: Int
        var used: (@Sendable () -> Int)?
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    /// Sizes a session with `sizing` over the free space the other claims leave, and records the
    /// result. Unknown capacity is passed through as unknown.
    ///
    /// The `used` closures of the other claims run under this ledger's lock; they must not claim.
    func claim(volumeAvailableBytes: Int64?, sizing: (Int64?) -> Int) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        let heldBack = entries.values.reduce(0) { $0 + max(0, $1.bytes - ($1.used?() ?? 0)) }
        let left = volumeAvailableBytes.map { max(0, $0 - Int64(heldBack)) }
        return Claim(bytes: max(0, sizing(left)), heldBackBytes: heldBack, ledger: self)
    }
}
