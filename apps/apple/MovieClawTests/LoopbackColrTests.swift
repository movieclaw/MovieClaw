import Foundation
import Testing
@testable import AetherEngine

/// 换封装通路的 `colr`（引擎补丁 P60）：真跑 HLSVideoEngine，读本机服务吐出的 init.mp4。
/// 样片是 x265 编的 128×64 小片，色彩标签只在码流 VUI（容器里没写传递函数，现实里常见的形态）：
/// SDR（未标注 / BT.709）写成 1/13/1，HDR 不能被改成 sRGB。
@Suite(.serialized)
struct LoopbackColrTests {
    private final class BundleToken {}

    private func initSegment(of fixture: String) async throws -> [UInt8] {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: fixture, withExtension: "mkv")
            ?? bundle.url(forResource: fixture, withExtension: "mkv", subdirectory: "Fixtures"))
        let engine = HLSVideoEngine(url: url)
        defer { engine.stop() }
        let playlist = try await Task.detached { try engine.start() }.value
        let initURL = playlist.deletingLastPathComponent().appendingPathComponent("init.mp4")
        for _ in 0..<50 {
            if let (data, response) = try? await URLSession.shared.data(from: initURL),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return [UInt8](data)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("init.mp4 没产出：\(initURL)")
        return []
    }

    /// init.mp4 里 `colr nclx` 的原色 / 传递函数 / 矩阵，没有就是 nil
    private func nclx(_ bytes: [UInt8]) -> [Int]? {
        let tag: [UInt8] = Array("colrnclx".utf8)
        guard bytes.count > tag.count + 6 else { return nil }
        for i in 0...(bytes.count - tag.count - 6) where Array(bytes[i..<i + tag.count]) == tag {
            let p = i + tag.count
            return (0..<3).map { Int(bytes[p + 2 * $0]) << 8 | Int(bytes[p + 2 * $0 + 1]) }
        }
        return nil
    }

    @Test func untaggedSDRGoesOutAsSRGB() async throws {
        #expect(nclx(try await initSegment(of: "sdr-untagged")) == [1, 13, 1])
    }

    @Test func bt709SDRGoesOutAsSRGB() async throws {
        #expect(nclx(try await initSegment(of: "sdr-bt709")) == [1, 13, 1])
    }

    @Test func hdrIsNotRetagged() async throws {
        let colr = nclx(try await initSegment(of: "hdr-pq"))
        #expect(colr?[1] != 13, "HDR 被写成了 sRGB：\(String(describing: colr))")
    }
}
