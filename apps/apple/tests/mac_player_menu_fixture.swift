// Process-only fixture for mac_player_menu_regression.py. Never orders a window,
// opens a menu, sends input, requests permissions, or uses media/network/keychain.
import AppKit
import Observation
import SwiftUI

@Observable final class PlaybackController {
    var positionMs = 0
    var quality: Int?
    var rate: Float = 1
    var paused = false
    var wantsPlay = true
    let scope = Scope()
    let unit = Unit()
    let previousEpisode: Int? = nil
    let nextEpisode: Int? = nil
    let selectedSubtitle: Int? = nil
    let clip: Int? = nil
    let timelineDurationMs: Int? = 600_000
    var phase = Phase.playing
    func timelineMs(fromFileMs value: Int) -> Int { value }
    func selectQuality(_ value: Int?) { quality = value }
    func selectRate(_ value: Float) { rate = value }
    func playPrevious() {}
    func playNext() {}
    func noteUserActivity() {}
}
struct Scope { let shareSlug: String? = nil }
struct Unit { let isEpisode = false }
enum Phase { case playing, ended }
enum MacPlayerPanelKind { case tracks }
@Observable final class MacPlayerVolume {}
final class TrickplayImages {}
enum AppLanguage { static var germanLocale: Locale? { nil } }
enum Formatters { static func clock(_ value: Double) -> String { String(Int(value)) } }
enum MacPlayerMetrics {
    static let panelHeight: CGFloat = 100
    static let panelCorner: CGFloat = 22
    static let controlBarPositionKey = "movieclaw.mac.player.controlBarPosition"
}
struct MacVolumeControl: View {
    let volume: MacPlayerVolume
    var showsSlider = true
    var body: some View { Color.clear.frame(width: showsSlider ? 100 : 34, height: 34) }
}
struct MacScrubber: View {
    let controller: PlaybackController
    let trickplay: TrickplayImages
    let pointer: CGPoint?
    var stageSize: CGSize = .zero
    var barFrame: CGRect = .zero
    @Binding var scrubMs: Int?
    var body: some View {
        let _ = Probe.scrubberRenders += 1
        Text("\(controller.positionMs)").frame(maxWidth: .infinity)
    }
}
enum Probe {
    static var menuRenders: [Int: Int] = [:]
    static var mountedSlots: Set<Int> = []
    static var transportRenders = 0
    static var scrubberRenders = 0
}

// PRODUCTION_VIEWS

// The real screen also reads position for its accessibility summary. Recreating
// callbacks from a ticking parent must not make the mounted menu observe position.
struct Screen: View {
    let controller: PlaybackController
    let fullScreen: Bool
    @State private var volume = MacPlayerVolume()
    @State private var trickplay = TrickplayImages()
    @State private var scrubMs: Int?
    @State private var panel: MacPlayerPanelKind?
    @State private var episodesOpen = false
    var body: some View {
        VStack {
            Text("\(controller.positionMs / 1000)")
            MacPlayerTransport(controller: controller, trickplay: trickplay, volume: volume,
                               isFullScreen: fullScreen, pointer: nil, scrubMs: $scrubMs,
                               panel: $panel, episodesOpen: $episodesOpen,
                               togglePlay: { controller.paused.toggle() },
                               skip: { _ in controller.noteUserActivity() },
                               toggleFullScreen: { controller.noteUserActivity() })
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var failures = [String]()
var coveredSlots: [Bool: Set<Int>] = [:]
func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message); print("FAIL: \(message)") }
}

func run(width: CGFloat, fullScreen: Bool) {
    Probe.menuRenders = [:]
    Probe.mountedSlots = []
    let controller = PlaybackController()
    let host = NSHostingView(rootView: Screen(controller: controller, fullScreen: fullScreen))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 140),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    defer { window.contentView = nil }
    func render(_ seconds: TimeInterval = 0.03) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
        check(!window.isVisible, "The test window must remain unshown")
    }
    render()
    check(Probe.mountedSlots.count == 1, "Expected exactly one mounted menu at width \(width)")
    guard let slot = Probe.mountedSlots.first else { return }
    coveredSlots[fullScreen, default: []].insert(slot)
    let label = "width=\(Int(width)) fullScreenFlag=\(fullScreen) slot=\(slot)"
    let before = Probe.menuRenders[slot, default: 0]
    let beforeTransport = Probe.transportRenders
    let beforeScrubber = Probe.scrubberRenders
    for tick in 1...8 {
        controller.positionMs = tick * 250
        render(0.25)
    }
    let tickMenus = Probe.menuRenders[slot, default: 0] - before
    check(tickMenus == 0, "\(label): 8 position ticks re-evaluated the mounted menu \(tickMenus) times")
    check(Probe.transportRenders > beforeTransport, "The ticking parent/transport must keep rendering")
    check(Probe.scrubberRenders > beforeScrubber, "Position updates must still reach the timeline")

    controller.paused = true
    render()
    let paused = Probe.menuRenders[slot, default: 0]
    for _ in 0..<4 { render() }
    check(Probe.menuRenders[slot, default: 0] == paused, "\(label): paused menu should remain stable")
    controller.selectQuality(720)
    render()
    let quality = Probe.menuRenders[slot, default: 0]
    check(quality > paused, "\(label): quality changes must refresh the menu")
    controller.selectRate(1.5)
    render()
    check(Probe.menuRenders[slot, default: 0] > quality, "\(label): speed changes must refresh the menu")
    print("\(label): tick_menu_renders=\(tickMenus), paused stable, quality/speed refreshed")
}

for width: CGFloat in [720, 390, 300] {
    for fullScreen in [false, true] { run(width: width, fullScreen: fullScreen) }
}
for fullScreen in [false, true] {
    check(coveredSlots[fullScreen] == Set([0, 1, 2]),
          "fullScreenFlag=\(fullScreen): must exercise all three ViewThatFits alternatives")
}
if !failures.isEmpty { exit(1) }
print("PASS: process-only SwiftUI observation regression; native menu/fullscreen E2E remains unverified")
