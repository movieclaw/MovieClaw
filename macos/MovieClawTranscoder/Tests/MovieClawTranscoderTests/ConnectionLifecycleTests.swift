import Darwin
import Foundation
import XCTest
@testable import MovieClawTranscoder

/// 用真实子进程覆盖先停后启的竞态；旧内核故意延迟退出并上报旧状态。
@MainActor
final class ConnectionLifecycleTests: XCTestCase {
    private func configuration(_ name: String) -> WorkerConfiguration {
        WorkerConfiguration(nasURL: URL(string: "http://127.0.0.1:1")!, workerToken: "test",
                            workerID: name, ffmpegPath: "/tmp/ffmpeg", maxJobs: 1)
    }

    private func fixture() throws -> (CoreSupervisor, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("core")
        var source = "#!/bin/sh\nIFS= read -r config\ncase \"$config\" in\n"
        for name in ["first", "second", "third"] {
            let ready = WorkerStatus.offline(.ready, message: "ready", workerID: name, maxJobs: 1)
            let stopped = WorkerStatus.offline(.stopped, message: "stopped", workerID: name, maxJobs: 1)
            let readyJSON = String(decoding: try CoreLine.encode(CoreEvent.status(ready)), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            let stoppedJSON = String(decoding: try CoreLine.encode(CoreEvent.status(stopped)), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            source += "*\(name)*) ready='\(readyJSON)'; stopped='\(stoppedJSON)';;\n"
        }
        source += "esac\nprintf '%s\\n' \"$ready\"\n"
            + "while IFS= read -r command; do\ncase \"$command\" in\n"
            + "*shutdown*) sleep 0.2; printf '%s\\n' \"$stopped\"; exit 0;;\nesac\ndone\n"
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (CoreSupervisor(executableURL: script), directory)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "进程状态未在期限内恢复")
    }

    func testRapidRenamesUseLastConfigurationAndIgnoreOldStatus() async throws {
        let (supervisor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var statuses: [WorkerStatus] = []
        supervisor.onStatus = { statuses.append($0) }
        supervisor.start(configuration("first"))
        try await waitUntil { statuses.last?.workerID == "first" }
        let oldPID = try XCTUnwrap(supervisor.corePID)
        statuses.removeAll()
        supervisor.start(configuration("second"))
        supervisor.start(configuration("third"))
        try await waitUntil { statuses.last?.workerID == "third" }
        XCTAssertTrue(statuses.allSatisfy { $0.workerID == "third" && $0.state == .ready })
        XCTAssertEqual(kill(oldPID, 0), -1, "新内核启动前旧内核必须退出")
        XCTAssertTrue(supervisor.isActive)
        await supervisor.stop()
    }

    func testDisconnectThenImmediateStartDoesNotStopNewCore() async throws {
        let (supervisor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var name: String?
        supervisor.onStatus = { name = $0.workerID }
        supervisor.start(configuration("first"))
        try await waitUntil { name == "first" }
        supervisor.disconnect()
        XCTAssertFalse(supervisor.isActive, "断开意图须同步生效")
        supervisor.start(configuration("second"))
        try await waitUntil { name == "second" }
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(supervisor.isActive)
        XCTAssertNotNil(supervisor.corePID)
        await supervisor.stop()
        supervisor.reconnectNow()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(supervisor.isActive)
        XCTAssertNil(supervisor.corePID, "手动断开后唤醒不得重新启动")
    }

    func testCrashRecoveryIsCancelledByManualDisconnect() async throws {
        let (supervisor, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var readyCount = 0
        supervisor.onStatus = { if $0.state == .ready { readyCount += 1 } }
        supervisor.start(configuration("first"))
        try await waitUntil { readyCount == 1 }
        kill(try XCTUnwrap(supervisor.corePID), SIGKILL)
        try await waitUntil { readyCount == 2 }
        kill(try XCTUnwrap(supervisor.corePID), SIGKILL)
        try await waitUntil { supervisor.recoveries.count == 2 }
        await supervisor.stop()
        supervisor.reconnectNow()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertNil(supervisor.corePID)
        XCTAssertEqual(readyCount, 2)
    }

    func testDrainingWhileOfflineDoesNotClaimConnectionAndStopBeforeRunIsRespected() async {
        let client = WorkerClient(configuration: configuration("first"),
                                  capabilities: WorkerCapabilities(ffmpegVersion: "test", encoders: [], backends: []))
        var iterator = client.statuses.makeAsyncIterator()
        await client.setDraining(true)
        let status = await iterator.next()
        XCTAssertEqual(status?.state, .stopped)
        await client.stop()
        await client.reconnectNow()
        let exit = await client.runForever()
        XCTAssertEqual(exit, .stopped)
    }
}
