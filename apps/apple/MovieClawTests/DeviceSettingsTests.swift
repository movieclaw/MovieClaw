import Foundation
import Testing
@testable import MovieClaw

@MainActor
struct DeviceSettingsTests {
    private func device(_ id: String, kind: String, name: String = "客厅 iPad", owner: String = "小叶") -> API.LoginDeviceView {
        .init(id: id, kind: kind, kindLabel: kind, family: "login", name: name, scope: "full",
              platform: "iOS 27", createdAt: "2026-10-01T00:00:00Z", current: false, connected: false,
              renamable: true, ownerId: 1, ownerUsername: "member", ownerNickname: owner)
    }

    @Test func categoriesNeverLoseUnknownOrOfflineClients() {
        let kinds = ["web", "ios", "tvos", "macos", "android", "cli", "worker", "manual", "jellyfin", "future-client"]
        let devices = kinds.map { device($0, kind: $0) }
        let groups = DeviceGroup.make(devices)
        #expect(groups.flatMap(\.items).count == devices.count)
        #expect(Set(groups.flatMap(\.items).map(\.id)) == Set(kinds))
        #expect(groups.first { $0.id == "paired" }?.items.contains { $0.kind == "future-client" } == true)
        #expect(DeviceGroup.make([]).count == 4, "空分类仍应可发现")
    }

    @Test func searchFindsNameOwnerAndPlatformWithoutChangingOrder() {
        let group = DeviceGroup.make([
            device("1", kind: "ios"), device("2", kind: "ios", name: "Bedroom iPhone", owner: "小林"),
        ]).first { $0.id == "app" }!
        #expect(group.matching("  IPAD \n").map(\.id) == ["1"])
        #expect(group.matching("小林").map(\.id) == ["2"])
        #expect(group.matching("ios 27").map(\.id) == ["1", "2"])
        #expect(group.matching(" \n").map(\.id) == ["1", "2"])
        #expect(group.matching("不存在").isEmpty)
    }

    @Test func connectedTranscoderAndCurrentDeviceRemainOnline() {
        var worker = device("worker", kind: "worker")
        worker.connected = true
        #expect(DeviceText.isLive(worker), "转码器在线状态由长连接决定")
        worker.connected = false
        #expect(!DeviceText.isLive(worker))
        var current = device("current", kind: "ios")
        current.current = true
        #expect(DeviceText.isLive(current), "本机无需依赖最近活动时间")
    }

    @Test func cleanupOnlyIncludesServerEligibleDevicesInThisCategory() {
        let group = DeviceGroup.make([
            device("browser", kind: "web"), device("app-old", kind: "ios"),
            device("app-active", kind: "ios"), device("cli", kind: "cli"),
        ]).first { $0.id == "app" }!
        let preview = ["browser", "app-old", "cli", "unknown"].map {
            API.DeviceCleanupItem(id: $0, name: $0, ownerNickname: "小叶")
        }
        #expect(group.cleanupCandidates(preview).map(\.id) == ["app-old"],
                "其他分类和服务端未判定为不活跃的设备都不能被清理")
        #expect(group.cleanupCandidates([]).isEmpty)
    }
}
