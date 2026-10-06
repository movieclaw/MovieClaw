import Darwin
import Foundation

/// AE#451: the liveness half of the `aether-segments/` stale-session sweep. A session directory's
/// creation date is its session's START time, so age alone cannot tell a session an hour in from one
/// that crashed an hour ago; an flock(2) held on `<dir>/session.lock` for the owner's lifetime can.
///
/// flock and not fcntl: flock locks belong to the open file description, so a second owner in the
/// SAME process fails to take it too. fcntl locks are per-process and a process never blocks itself.
/// The kernel drops the lock when the process dies, so a crashed session leaves an unheld marker and
/// sweeps as before.
///
/// Audit SEG-105: shared by `SegmentCache` and the software DVR ring, which lives under the same base
/// directory and was swept an hour into a DVR session because its directory carried no marker.
enum SessionDirectoryLiveness {
    static let markerName = "session.lock"

    /// The held marker's descriptor, or -1 when open or flock failed (such a directory is swept by
    /// age, the pre-AE#451 behaviour rather than a new failure).
    static func acquire(sessionDir: URL, logPrefix: String) -> Int32 {
        let path = sessionDir.appendingPathComponent(markerName).path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            EngineLog.emit("\(logPrefix) live marker open failed at \(path): errno=\(errno)",
                           category: .session)
            return -1
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            EngineLog.emit("\(logPrefix) live marker lock failed at \(path): errno=\(errno)",
                           category: .session)
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    /// Whether some open file description still holds `entry`'s marker. A missing marker answers
    /// false: it is a directory from a build without one, and the age check decides it as before.
    static func isLive(_ entry: URL) -> Bool {
        let path = entry.appendingPathComponent(markerName).path
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return true
    }
}
