// Sources/AetherEngine/Video/IFramePayloadCache.swift
import Foundation

/// AE#682: keyframe payloads read for the I-frame rendition, on disk with a byte cap. It holds the
/// raw keyframe rather than the built fragment so a neighbour can be re-stamped for an index whose
/// own read failed.
final class IFramePayloadCache: @unchecked Sendable {
    private let directory: URL
    private let byteLimit: Int
    private let lock = NSLock()
    private var sizes: [Int: Int] = [:]
    private var recency: [Int] = []
    private var totalBytes = 0

    init(directory: URL, byteLimit: Int = 64 * 1024 * 1024) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    private func url(_ index: Int) -> URL {
        directory.appendingPathComponent("payload-\(index).bin")
    }

    private func forgetLocked(_ index: Int) {
        guard let size = sizes.removeValue(forKey: index) else { return }
        totalBytes -= size
        recency.removeAll { $0 == index }
        try? FileManager.default.removeItem(at: url(index))
    }

    func payload(for index: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard sizes[index] != nil else { return nil }
        guard let data = try? Data(contentsOf: url(index)), !data.isEmpty else {
            forgetLocked(index)
            return nil
        }
        recency.removeAll { $0 == index }
        recency.append(index)
        return data
    }

    func store(_ data: Data, for index: Int) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        forgetLocked(index)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url(index), options: .atomic)
        } catch {
            return
        }
        sizes[index] = data.count
        totalBytes += data.count
        recency.append(index)
        while totalBytes > byteLimit, let oldest = recency.first, oldest != index {
            forgetLocked(oldest)
        }
    }

    func nearestIndex(to index: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return sizes.keys
            .filter { FileManager.default.fileExists(atPath: url($0).path) }
            .min { a, b in
                let da = abs(a - index), db = abs(b - index)
                return da != db ? da < db : a < b
            }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        sizes.removeAll()
        recency.removeAll()
        totalBytes = 0
        try? FileManager.default.removeItem(at: directory)
    }
}
