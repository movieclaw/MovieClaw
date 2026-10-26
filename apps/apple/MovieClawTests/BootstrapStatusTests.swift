import Foundation
import Testing
@testable import MovieClaw

struct BootstrapStatusTests {
    @Test func legacyServerWithoutNativeCapabilitiesStillDecodes() throws {
        let status = try JSONDecoder().decode(
            API.BootstrapStatus.self, from: Data(#"{"initialized":true}"#.utf8)
        )
        #expect(status.initialized)
        #expect(status.nativeDeviceKinds == nil)
    }

    @Test func windowsCapabilitiesKeepInitializationState() throws {
        let status = try JSONDecoder().decode(
            API.BootstrapStatus.self,
            from: Data(#"{"initialized":false,"native_device_kinds":["macos","windows"]}"#.utf8)
        )
        #expect(!status.initialized)
        #expect(status.nativeDeviceKinds == ["macos", "windows"])
    }
}
