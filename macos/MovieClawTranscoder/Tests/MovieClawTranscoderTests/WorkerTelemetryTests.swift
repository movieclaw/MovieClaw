import XCTest
@testable import MovieClawTranscoder

final class WorkerTelemetryTests: XCTestCase {
    func testScaleCapabilityRequiresTheOptionsTheServerActuallyUses() {
        XCTAssertFalse(CapabilityProbe.scaleSupportsFormat("  w <string> width\n  h <string> height"))
        XCTAssertTrue(CapabilityProbe.scaleSupportsFormat("  w <string> width\n  format <string> output format"))
        XCTAssertFalse(CapabilityProbe.scaleSupportsFormat(""))
    }
    func testHardwareAndLightweightSampleAreValidJSON() throws {
        let hardware = WorkerTelemetry.hardware()
        XCTAssertFalse((hardware["chip"] as? String ?? "").isEmpty)
        XCTAssertGreaterThan(hardware["cpu_cores"] as? Int ?? 0, 0)
        let telemetry = WorkerTelemetry()
        _ = telemetry.sample()
        let sample = telemetry.sample()
        XCTAssertTrue((0...1).contains(sample["cpu"] as? Double ?? -1))
        XCTAssertTrue((0...2).contains(sample["memory_pressure"] as? Int ?? -1))
        XCTAssertTrue((0...3).contains(sample["thermal_state"] as? Int ?? -1))
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: sample))
    }

    func testServerLimitIsMemoryOnlyAndLocalSaveCannotOverrideIt() throws {
        let suite = "worker-server-config-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(3, forKey: "movieclaw.maxJobs")
        let store = ConfigurationStore(defaults: defaults)
        store.rememberServerMaxJobs(2)
        XCTAssertNil(defaults.object(forKey: "movieclaw.maxJobs"))
        XCTAssertEqual(try store.snapshot().maxJobs, 2)
        var draft = WorkerSettingsDraft(try store.snapshot())
        draft.nasURL = "http://127.0.0.1:8000"
        draft.workerID = "mac"
        draft.ffmpegPath = "/usr/bin/true"
        try store.save(draft)
        XCTAssertEqual(try store.snapshot().maxJobs, 2)
        XCTAssertNil(defaults.object(forKey: "movieclaw.maxJobs"))
        let command = CoreCommand.setMaxJobs(4)
        XCTAssertEqual(try CoreLine.decode(CoreCommand.self, from: CoreLine.encode(command)), command)
    }
}
