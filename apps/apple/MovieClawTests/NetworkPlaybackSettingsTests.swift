import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct NetworkPlaybackSettingsTests {
    @Test func validatesAddressesBeforeSavingConnectionConfiguration() {
        #expect(NetworkSettingsValidation.validURL("socks5h://192.168.1.2:7891", proxy: true))
        #expect(NetworkSettingsValidation.validURL(" HTTPS://example.com/3 \n"))
        #expect(NetworkSettingsValidation.validURL("http://[::1]:8000"))
        #expect(!NetworkSettingsValidation.validURL("http://"))
        #expect(!NetworkSettingsValidation.validURL("ftp://example.com"))
        #expect(!NetworkSettingsValidation.validURL("socks5://example.com"))
        #expect(!NetworkSettingsValidation.validURL("http://some host"))
        #expect(!NetworkSettingsValidation.validURL(""))
        #expect(NetworkSettingsValidation.validURL("  ", allowEmpty: true))
    }

    @Test func validatesPortBoundaryBeforeRestartConfirmation() {
        #expect(NetworkSettingsValidation.port("1") == 1)
        #expect(NetworkSettingsValidation.port(" 65535 ") == 65535)
        for value in ["", "0", "65536", "-1", "80.0", "1e3", "abc"] {
            #expect(NetworkSettingsValidation.port(value) == nil)
        }
    }

    @Test func transcodeDraftPreservesOverrideAndOnlyChangesOnSave() {
        let config = API.RemoteTranscodeConfigView(enabled: true, baseUrl: "http://auto.local:3000",
            baseUrlOverride: "", baseUrlSource: "worker_connection", maxArtifactBytes: 123,
            ready: true, issues: [])
        var draft = RemoteTranscodeDraft(config)
        #expect(draft.baseURL.isEmpty)
        #expect(draft.valid)
        draft.enabled = false
        draft.baseURL = " https://media.example.com/ \n"
        #expect(draft.valid)
        #expect(draft.payload.enabled == false)
        #expect(draft.payload.baseUrl == "https://media.example.com/")
        #expect(draft.payload.maxArtifactBytes == 512 * 1024 * 1024)
        #expect(config.enabled)
        #expect(config.baseUrlOverride.isEmpty)
        draft.baseURL = "socks5://proxy.local"
        #expect(!draft.valid)
    }

    @Test func editorDoesNotReplayUnrelatedOptimisticOrStaleConfiguration() {
        let latest = API.NetworkConfigPayload(proxyMode: "env", proxyUrl: "http://current:7890", proxyServices: ["tmdb"],
            tmdbApiBaseUrl: "https://current-api/3", tmdbImageBaseUrl: "https://current-image/t/p", doubanApiBaseUrl: "https://douban")
        var staleDraft = latest
        staleDraft.proxyServices = ["tmdb", "image"] // A failed optimistic toggle must not be replayed.
        staleDraft.tmdbApiBaseUrl = "https://stale-api/3"
        staleDraft.proxyMode = "manual"
        staleDraft.proxyUrl = "socks5h://new-proxy:7891"
        let proxy = NetworkEditorKind.proxy.merging(staleDraft, into: latest)
        #expect(proxy.proxyServices == latest.proxyServices)
        #expect(proxy.tmdbApiBaseUrl == latest.tmdbApiBaseUrl)
        #expect(proxy.tmdbImageBaseUrl == latest.tmdbImageBaseUrl)
        #expect(proxy.doubanApiBaseUrl == latest.doubanApiBaseUrl)
        #expect(proxy.proxyMode == "manual")
        #expect(proxy.proxyUrl == "socks5h://new-proxy:7891")

        staleDraft.tmdbApiBaseUrl = "" // Clearing a mirror is an intentional edit.
        let mirrors = NetworkEditorKind.mirrors.merging(staleDraft, into: latest)
        #expect(mirrors.proxyMode == latest.proxyMode)
        #expect(mirrors.proxyUrl == latest.proxyUrl)
        #expect(mirrors.proxyServices == latest.proxyServices)
        #expect(mirrors.tmdbApiBaseUrl == "")
        #expect(mirrors.doubanApiBaseUrl == latest.doubanApiBaseUrl)
    }

}
