import AppKit
import SwiftUI
import Testing
@testable import MovieClaw

struct MacControlBarLayoutTests {
    // MARK: - 持久化编解码

    @Test func positionEncodingAndDecodingRoundTrip() {
        let pos = MacControlBarPosition(rx: 0.25, ry: 0.75)
        let decoded = MacControlBarPosition.decode(pos.encoded)
        #expect(decoded != nil)
        #expect(abs((decoded?.rx ?? -1) - 0.25) < 0.0002)
        #expect(abs((decoded?.ry ?? -1) - 0.75) < 0.0002)

        // 越界自动夹在 0...1
        let clamped = MacControlBarPosition.decode("-0.4,1.8")
        #expect(clamped == MacControlBarPosition(rx: 0, ry: 1))

        // 空串与非法值回退 nil（默认底部居中）
        #expect(MacControlBarPosition.decode("") == nil)
        #expect(MacControlBarPosition.decode("invalid") == nil)
        #expect(MacControlBarPosition.decode("nan,0.5") == nil)
        #expect(MacControlBarPosition.decode("0.5") == nil)
    }

    // MARK: - 默认位置、边界与吸附

    @Test func defaultFrameIsCenteredAtBottom() {
        let stage = CGSize(width: 1440, height: 810)
        let frame = MacControlBarLayout.resolveFrame(stored: nil, dragOrigin: nil, stage: stage)
        #expect(frame.width == MacPlayerMetrics.panelMaxWidth)
        #expect(frame.height == MacPlayerMetrics.panelHeight)
        #expect(frame.minX == (stage.width - frame.width) / 2)
        #expect(frame.minY == stage.height - MacPlayerMetrics.panelHeight - MacPlayerMetrics.panelBottom)
    }

    @Test func dragClampsWithinSafeMarginsAndClearsTopBar() {
        let stage = CGSize(width: 1200, height: 700)
        let width = MacControlBarLayout.panelWidth(for: stage)
        let start = MacControlBarLayout.defaultOrigin(stage: stage, panelWidth: width)

        // 拖出左上角：左留 10、顶留 70
        let topLeft = MacControlBarLayout.clampedDragOrigin(
            startOrigin: start,
            translation: CGSize(width: -2000, height: -2000),
            stage: stage,
            panelWidth: width
        )
        #expect(topLeft.origin.x == MacControlBarLayout.marginX)
        #expect(topLeft.origin.y == MacControlBarLayout.marginTop)
        #expect(!topLeft.snappedCenter)

        // 拖出右下角：右留 10、底留 10
        let bottomRight = MacControlBarLayout.clampedDragOrigin(
            startOrigin: start,
            translation: CGSize(width: 2000, height: 2000),
            stage: stage,
            panelWidth: width
        )
        #expect(bottomRight.origin.x == stage.width - width - MacControlBarLayout.marginX)
        #expect(bottomRight.origin.y == stage.height - MacPlayerMetrics.panelHeight - MacControlBarLayout.marginBottom)
        #expect(!bottomRight.snappedCenter)
    }

    @Test func horizontalCenterSnapWithinFivePoints() {
        let stage = CGSize(width: 1200, height: 700)
        let width = MacControlBarLayout.panelWidth(for: stage)
        let centerX = (stage.width - width) / 2

        // 偏离中线 4 点：吸附正中
        let snapped = MacControlBarLayout.clampedDragOrigin(
            startOrigin: CGPoint(x: centerX, y: 300),
            translation: CGSize(width: 4, height: -50),
            stage: stage,
            panelWidth: width
        )
        #expect(snapped.snappedCenter)
        #expect(snapped.origin.x == centerX)
        #expect(snapped.origin.y == 250)

        // 偏离中线 6 点：不吸附
        let free = MacControlBarLayout.clampedDragOrigin(
            startOrigin: CGPoint(x: centerX, y: 300),
            translation: CGSize(width: 6, height: -50),
            stage: stage,
            panelWidth: width
        )
        #expect(!free.snappedCenter)
        #expect(free.origin.x == centerX + 6)
    }

    @Test func droppingNearDefaultResetsToNil() {
        let stage = CGSize(width: 1200, height: 700)
        let width = MacControlBarLayout.panelWidth(for: stage)
        let def = MacControlBarLayout.defaultOrigin(stage: stage, panelWidth: width)

        #expect(MacControlBarLayout.persistPosition(for: CGPoint(x: def.x + 3, y: def.y - 4), stage: stage, panelWidth: width) == nil)
        #expect(MacControlBarLayout.persistPosition(for: CGPoint(x: def.x + 40, y: def.y - 100), stage: stage, panelWidth: width) != nil)
    }

    @Test func normalizedRatioSurvivesResizeAndNarrowWindowAutoCenters() {
        let wide = CGSize(width: 1440, height: 810)
        let wideW = MacControlBarLayout.panelWidth(for: wide)
        // 拖到左上角偏上（x = 10, y = 100）
        let stored = MacControlBarLayout.persistPosition(for: CGPoint(x: 10, y: 100), stage: wide, panelWidth: wideW)
        #expect(stored != nil)

        // 缩到中等窗口 / 展开选集侧栏后舞台变窄：仍在左侧、相对靠上，且不越界
        let medium = CGSize(width: 900, height: 540)
        let mediumFrame = MacControlBarLayout.resolveFrame(stored: stored, dragOrigin: nil, stage: medium)
        #expect(mediumFrame.minX == MacControlBarLayout.marginX)
        #expect(mediumFrame.minY >= MacControlBarLayout.marginTop)
        #expect(mediumFrame.maxX <= medium.width - MacControlBarLayout.marginX)
        #expect(mediumFrame.maxY <= medium.height - MacControlBarLayout.marginBottom)

        // 缩到窄窗（480 宽时 panelWidth = 432，两侧留 24 > 10；更窄如 400 时验证不越界，或模拟宽几乎等于面板宽时回中）
        let tiny = CGSize(width: 740, height: 420)
        let tinyW = MacControlBarLayout.panelWidth(for: tiny) // min(740 - 74, 720) = 666
        let tinyFrame = MacControlBarLayout.resolveFrame(stored: stored, dragOrigin: nil, stage: tiny)
        #expect(tinyFrame.width == tinyW)
        #expect(tinyFrame.minX >= MacControlBarLayout.marginX)

        // 当面板宽 + 左右边距 >= 舞台宽时（movableBounds.width <= 1）自动回中
        let fullWidthStage = CGSize(width: 200, height: 260)
        let centeredStored = MacControlBarPosition(rx: 0, ry: 0.2)
        let fullFrame = MacControlBarLayout.resolveFrame(stored: centeredStored, dragOrigin: nil, stage: fullWidthStage)
        #expect(fullFrame.minX >= 0)
        #expect(fullFrame.maxX <= fullWidthStage.width)
    }

    // MARK: - 六大耦合点判定

    @Test func pointerHitAndBottomGradientFollowMovedBar() {
        let stage = CGSize(width: 1200, height: 700)
        let topBarFrame = CGRect(x: 240, y: 80, width: 720, height: 100)

        // 指针停在移走后的控制条上命中；停在原来底部空位不再误命中
        #expect(MacControlBarLayout.pointerHitsTransport(CGPoint(x: 500, y: 120), barFrame: topBarFrame))
        #expect(MacControlBarLayout.pointerHitsTransport(CGPoint(x: 237, y: 120), barFrame: topBarFrame)) // 4pt 容差
        #expect(!MacControlBarLayout.pointerHitsTransport(CGPoint(x: 500, y: 650), barFrame: topBarFrame))

        // 拖离底部后，底部托字渐变淡出；默认底部时显示
        #expect(!MacControlBarLayout.showsBottomGradient(barFrame: topBarFrame, stage: stage, hasCustomPosition: true, isDragging: false))
        let defaultFrame = MacControlBarLayout.resolveFrame(stored: nil, dragOrigin: nil, stage: stage)
        #expect(MacControlBarLayout.showsBottomGradient(barFrame: defaultFrame, stage: stage, hasCustomPosition: false, isDragging: false))
    }

    @Test func subtitleLiftsOnlyWhenControlBarIntersectsSubtitleBand() {
        let stage = CGSize(width: 1440, height: 810)
        let fullVideo = CGRect(origin: .zero, size: stage)

        // 默认底部居中：与底部字幕区相交，应抬高到控制条上方
        let defaultBar = MacControlBarLayout.resolveFrame(stored: nil, dragOrigin: nil, stage: stage)
        let lifted = MacControlBarLayout.subtitleLiftBottomPercent(basePercent: 5, barFrame: defaultBar, videoRect: fullVideo, stage: stage)
        #expect(lifted == 17)

        // 拖到上半区：不再与底部字幕区相交，字幕保持原位不跳动
        let topBar = CGRect(x: 360, y: 80, width: 720, height: 100)
        let unlifted = MacControlBarLayout.subtitleLiftBottomPercent(basePercent: 5, barFrame: topBar, videoRect: fullVideo, stage: stage)
        #expect(unlifted == 5)

        // 超宽画面上下有黑边、控制条落在下方黑边里不压字幕：保持原位
        let letterboxedVideo = CGRect(x: 0, y: 180, width: 1440, height: 450)
        let letterboxLift = MacControlBarLayout.subtitleLiftBottomPercent(basePercent: 5, barFrame: defaultBar, videoRect: letterboxedVideo, stage: stage)
        #expect(letterboxLift == 5)
    }

    @Test func contextualCornerStaysBottomRightUnlessOverlapped() {
        let stage = CGSize(width: 1440, height: 810)
        let skipSize = CGSize(width: 120, height: 38)

        // 大屏默认居中控制条（360...1080）与右下角跳过按钮（1288...1408）不重叠：卡片留在原位 32
        let defaultBar = MacControlBarLayout.resolveFrame(stored: nil, dragOrigin: nil, stage: stage)
        #expect(MacControlBarLayout.cornerBottomPadding(chromeVisible: true, barFrame: defaultBar, stage: stage, cornerSize: skipSize) == 32)

        // 控制条拖到右下角冲突区：卡片让位到控制条上方
        let bottomRightBar = CGRect(x: 710, y: 690, width: 720, height: 100)
        let liftedPadding = MacControlBarLayout.cornerBottomPadding(chromeVisible: true, barFrame: bottomRightBar, stage: stage, cornerSize: skipSize)
        #expect(liftedPadding == stage.height - bottomRightBar.minY + 12)

        // 控制条拖到正上方：卡片安静留在右下角 32
        let topBar = CGRect(x: 360, y: 75, width: 720, height: 100)
        #expect(MacControlBarLayout.cornerBottomPadding(chromeVisible: true, barFrame: topBar, stage: stage, cornerSize: skipSize) == 32)

        // 控制层隐藏：卡片回到 32
        #expect(MacControlBarLayout.cornerBottomPadding(chromeVisible: false, barFrame: bottomRightBar, stage: stage, cornerSize: skipSize) == 32)
    }

    @Test func tracksPanelAdaptsAcrossAllFourQuadrants() {
        let stage = CGSize(width: 1200, height: 700)

        // 下半区居中 → 向上、右对齐
        let bottomCenter = CGRect(x: 240, y: 576, width: 720, height: 100)
        let bc = MacControlBarLayout.tracksPanelPlacement(barFrame: bottomCenter, stage: stage)
        #expect(!bc.opensDownward)
        #expect(!bc.alignsLeading)
        #expect(bc.overlayAlignment == .bottomTrailing)
        #expect(bc.maxWidth == bottomCenter.maxX - 12)

        // 上半区居中 → 向下、右对齐
        let topCenter = CGRect(x: 240, y: 75, width: 720, height: 100)
        let tc = MacControlBarLayout.tracksPanelPlacement(barFrame: topCenter, stage: stage)
        #expect(tc.opensDownward)
        #expect(!tc.alignsLeading)
        #expect(tc.overlayAlignment == .topTrailing)

        // 左上角（窄控制条场景，midX < 36% 舞台宽）→ 向下、左对齐向右展开，不顶出左边缘
        let topLeft = CGRect(x: 10, y: 75, width: 380, height: 100)
        let tl = MacControlBarLayout.tracksPanelPlacement(barFrame: topLeft, stage: stage)
        #expect(tl.opensDownward)
        #expect(tl.alignsLeading)
        #expect(tl.overlayAlignment == .topLeading)
        #expect(tl.maxWidth == stage.width - topLeft.minX - 12)

        // 左下角 → 向上、左对齐向右展开
        let bottomLeft = CGRect(x: 10, y: 576, width: 380, height: 100)
        let bl = MacControlBarLayout.tracksPanelPlacement(barFrame: bottomLeft, stage: stage)
        #expect(!bl.opensDownward)
        #expect(bl.alignsLeading)
        #expect(bl.overlayAlignment == .bottomLeading)
    }

    @Test func scrubberPreviewFlipsDownNearTopAndClampsHorizontally() {
        let stage = CGSize(width: 960, height: 540)
        let previewW: CGFloat = 192

        // 底部默认位置：向上弹出
        let bottomBar = MacControlBarLayout.resolveFrame(stored: nil, dragOrigin: nil, stage: stage)
        let bottomScrubber = CGRect(x: bottomBar.minX + 74, y: bottomBar.maxY - 40, width: bottomBar.width - 148, height: 34)
        let pBottom = MacControlBarLayout.scrubberPreviewPlacement(
            hoverX: bottomScrubber.width / 2,
            scrubberFrame: bottomScrubber,
            barFrame: bottomBar,
            stage: stage,
            previewWidth: previewW
        )
        #expect(!pBottom.opensDownward)
        #expect(abs(pBottom.offsetX) < 0.5)

        // 拖到最左上角并悬停在进度条最左端（hoverX = 0）：向下弹出，且水平夹紧不出左边界 10
        let topLeftBar = CGRect(x: 10, y: 72, width: 600, height: 100)
        let topLeftScrubber = CGRect(x: 20, y: 132, width: 500, height: 34)
        let pTopLeft = MacControlBarLayout.scrubberPreviewPlacement(
            hoverX: 0,
            scrubberFrame: topLeftScrubber,
            barFrame: topLeftBar,
            stage: stage,
            previewWidth: previewW
        )
        #expect(pTopLeft.opensDownward)
        let resolvedLeftEdge = topLeftScrubber.midX + pTopLeft.offsetX - previewW / 2
        #expect(resolvedLeftEdge >= MacControlBarLayout.marginX - 0.1)

        // 拖到最右上角并悬停在进度条最右端：水平夹紧不出右边界 stage.width - 10
        let topRightBar = CGRect(x: stage.width - 610, y: 72, width: 600, height: 100)
        let topRightScrubber = CGRect(x: stage.width - 520, y: 132, width: 500, height: 34)
        let pTopRight = MacControlBarLayout.scrubberPreviewPlacement(
            hoverX: topRightScrubber.width,
            scrubberFrame: topRightScrubber,
            barFrame: topRightBar,
            stage: stage,
            previewWidth: previewW
        )
        #expect(pTopRight.opensDownward)
        let resolvedRightEdge = topRightScrubber.midX + pTopRight.offsetX + previewW / 2
        #expect(resolvedRightEdge <= stage.width - MacControlBarLayout.marginX + 0.1)
    }

    // MARK: - 真实窗口端到端场景（SwiftUI + AppKit 宿主 + UserDefaults 持久化往返）

    @Test func hostedFloatingControlBarPersistsResizesAndResetsEndToEnd() async throws {
        let key = MacControlBarLayout.storageKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let api = APIClient(server: try ServerAddress(parsing: "http://127.0.0.1:9"))
        let controller = PlaybackController(request: .init(mediaItemId: 1), api: api)
        defer { controller.close() }
        let volume = MacPlayerVolume()
        let trickplay = TrickplayImages()

        final class FrameProbe {
            var transportFrame: CGRect = .zero
            var doubleClicked = false
            var resetTriggered = false
        }
        let probe = FrameProbe()

        struct Harness: View {
            let controller: PlaybackController
            let trickplay: TrickplayImages
            let volume: MacPlayerVolume
            let probe: FrameProbe
            @AppStorage(MacControlBarLayout.storageKey) var rawPosition = ""
            @State var scrubMs: Int?
            @State var panel: MacPlayerPanelKind?
            @State var episodesOpen = false

            var body: some View {
                GeometryReader { proxy in
                    let stage = proxy.size
                    let stored = MacControlBarPosition.decode(rawPosition)
                    let barFrame = MacControlBarLayout.resolveFrame(stored: stored, dragOrigin: nil, stage: stage)
                    let placement = MacControlBarLayout.tracksPanelPlacement(barFrame: barFrame, stage: stage)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        MacPlayerTransport(
                            controller: controller,
                            trickplay: trickplay,
                            volume: volume,
                            isFullScreen: false,
                            pointer: nil,
                            stageSize: stage,
                            barFrame: barFrame,
                            scrubMs: $scrubMs,
                            panel: $panel,
                            episodesOpen: $episodesOpen,
                            togglePlay: {},
                            skip: { _ in },
                            toggleFullScreen: { probe.doubleClicked = true }
                        )
                        .frame(width: barFrame.width)
                        .contentShape(.rect(cornerRadius: MacPlayerMetrics.panelCorner))
                        .onTapGesture {
                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { probe.doubleClicked = true }
                        }
                        .overlay(alignment: placement.overlayAlignment) {
                            if panel == .tracks {
                                MacTracksPanel(controller: controller, maxWidth: placement.maxWidth, maxHeight: placement.maxHeight) { panel = nil }
                                    .offset(y: placement.opensDownward ? (MacPlayerMetrics.panelHeight + 10) : -(MacPlayerMetrics.panelHeight + 10))
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MacPlayerMetrics.space)) } action: {
                            probe.transportFrame = $0
                        }
                        .offset(x: barFrame.minX, y: barFrame.minY)
                    }
                    .coordinateSpace(.named(MacPlayerMetrics.space))
                }
                .allowsWindowActivationEvents(true)
            }
        }

        let initialSize = CGSize(width: 1200, height: 700)
        let host = NSHostingView(rootView: Harness(controller: controller, trickplay: trickplay, volume: volume, probe: probe))
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: initialSize),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(200))
        host.layoutSubtreeIfNeeded()

        // 1. 默认应落在底部居中
        let expectedDefault = MacControlBarLayout.resolveFrame(stored: nil, dragOrigin: nil, stage: initialSize)
        #expect(abs(probe.transportFrame.minX - expectedDefault.minX) < 2)
        #expect(abs(probe.transportFrame.minY - expectedDefault.minY) < 2)
        #expect(abs(probe.transportFrame.width - expectedDefault.width) < 2)

        // 2. 模拟用户拖动到左上区并写入持久化存储，视图应实时移动到新位置
        let moved = MacControlBarPosition(rx: 0.0, ry: 0.05)
        UserDefaults.standard.set(moved.encoded, forKey: key)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()

        let expectedMoved = MacControlBarLayout.resolveFrame(stored: moved, dragOrigin: nil, stage: initialSize)
        #expect(abs(probe.transportFrame.minX - expectedMoved.minX) < 2)
        #expect(abs(probe.transportFrame.minY - expectedMoved.minY) < 2)
        #expect(probe.transportFrame.minY >= MacControlBarLayout.marginTop)

        // 3. 缩放到小窗（480×300）：自动约束在安全区内，不越界
        let smallSize = CGSize(width: 480, height: 300)
        window.setContentSize(smallSize)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()

        #expect(probe.transportFrame.minX >= MacControlBarLayout.marginX - 1)
        #expect(probe.transportFrame.maxX <= smallSize.width - MacControlBarLayout.marginX + 1)
        #expect(probe.transportFrame.minY >= MacControlBarLayout.marginTop - 1)
        #expect(probe.transportFrame.maxY <= smallSize.height - MacControlBarLayout.marginBottom + 1)

        // 4. 恢复大窗（模拟退出小窗 / 进全屏）：按相对比例还原
        let largeSize = CGSize(width: 1440, height: 810)
        window.setContentSize(largeSize)
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()

        let expectedLarge = MacControlBarLayout.resolveFrame(stored: moved, dragOrigin: nil, stage: largeSize)
        #expect(abs(probe.transportFrame.minX - expectedLarge.minX) < 2)
        #expect(abs(probe.transportFrame.minY - expectedLarge.minY) < 2)

        // 5. 从菜单栏重置（清空 AppStorage）：自动平滑归位到底部居中
        UserDefaults.standard.set("", forKey: key)
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()

        let expectedReset = MacControlBarLayout.resolveFrame(stored: nil, dragOrigin: nil, stage: largeSize)
        #expect(abs(probe.transportFrame.minX - expectedReset.minX) < 2)
        #expect(abs(probe.transportFrame.minY - expectedReset.minY) < 2)
    }

    /// 真实 AppKit 鼠标事件端到端验证：空白处拖起控制条、双击空白处仍触发全屏、音量滑条拖动不误拖控制条、按钮点击正常
    @Test func realMouseEventsDragBlankAreaWithoutBreakingDoubleClickOrSliders() async throws {
        let key = MacControlBarLayout.storageKey
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let api = APIClient(server: try ServerAddress(parsing: "http://127.0.0.1:9"))
        let controller = PlaybackController(request: .init(mediaItemId: 1), api: api)
        defer { controller.close() }
        let volume = MacPlayerVolume()
        let prevLevel = volume.level
        let prevMuted = volume.muted
        defer {
            volume.level = prevLevel
            volume.muted = prevMuted
        }
        volume.muted = false
        volume.level = 0.8
        let trickplay = TrickplayImages()

        final class EventProbe {
            var transportFrame: CGRect = .zero
            var doubleClicks = 0
            var playToggles = 0
            var dragEndedCount = 0
        }
        let probe = EventProbe()

        struct InteractiveHarness: View {
            let controller: PlaybackController
            let trickplay: TrickplayImages
            let volume: MacPlayerVolume
            let probe: EventProbe
            @AppStorage(MacControlBarLayout.storageKey) var rawPosition = ""
            @State var dragStartOrigin: CGPoint?
            @State var dragOrigin: CGPoint?
            @State var scrubMs: Int?
            @State var panel: MacPlayerPanelKind?
            @State var episodesOpen = false

            var body: some View {
                GeometryReader { proxy in
                    let stage = proxy.size
                    let stored = MacControlBarPosition.decode(rawPosition)
                    let barFrame = MacControlBarLayout.resolveFrame(stored: stored, dragOrigin: dragOrigin, stage: stage)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        MacPlayerTransport(
                            controller: controller,
                            trickplay: trickplay,
                            volume: volume,
                            isFullScreen: false,
                            pointer: nil,
                            stageSize: stage,
                            barFrame: barFrame,
                            scrubMs: $scrubMs,
                            panel: $panel,
                            episodesOpen: $episodesOpen,
                            togglePlay: { probe.playToggles += 1 },
                            skip: { _ in },
                            toggleFullScreen: {}
                        )
                        .frame(width: barFrame.width)
                        .contentShape(.rect(cornerRadius: MacPlayerMetrics.panelCorner))
                        .onTapGesture {
                            guard let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown else { return }
                            if event.clickCount >= 2 { probe.doubleClicks += 1 }
                        }
                        .gesture(
                            DragGesture(minimumDistance: MacControlBarLayout.dragThreshold, coordinateSpace: .named(MacPlayerMetrics.space))
                                .onChanged { value in
                                    if dragStartOrigin == nil { dragStartOrigin = barFrame.origin }
                                    let start = dragStartOrigin ?? barFrame.origin
                                    let resolved = MacControlBarLayout.clampedDragOrigin(
                                        startOrigin: start,
                                        translation: value.translation,
                                        stage: stage,
                                        panelWidth: barFrame.width
                                    )
                                    dragOrigin = resolved.origin
                                }
                                .onEnded { value in
                                    let start = dragStartOrigin ?? barFrame.origin
                                    let resolved = MacControlBarLayout.clampedDragOrigin(
                                        startOrigin: start,
                                        translation: value.translation,
                                        stage: stage,
                                        panelWidth: barFrame.width
                                    )
                                    let persisted = MacControlBarLayout.persistPosition(for: resolved.origin, stage: stage, panelWidth: barFrame.width)
                                    rawPosition = persisted?.encoded ?? ""
                                    dragStartOrigin = nil
                                    dragOrigin = nil
                                    probe.dragEndedCount += 1
                                }
                        )
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MacPlayerMetrics.space)) } action: {
                            probe.transportFrame = $0
                        }
                        .offset(x: barFrame.minX, y: barFrame.minY)
                    }
                    .coordinateSpace(.named(MacPlayerMetrics.space))
                }
                .allowsWindowActivationEvents(true)
            }
        }

        let stageSize = CGSize(width: 1200, height: 700)
        let host = NSHostingView(rootView: InteractiveHarness(controller: controller, trickplay: trickplay, volume: volume, probe: probe))
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: 80, y: 80), size: stageSize),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        func sendMouse(_ type: NSEvent.EventType, stagePoint: CGPoint, clicks: Int = 1) {
            let appKitPoint = CGPoint(x: stagePoint.x, y: stageSize.height - stagePoint.y)
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: appKitPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clicks,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else { return }
            NSApp.postEvent(event, atStart: false)
        }

        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()

        let startFrame = probe.transportFrame
        #expect(startFrame.width == MacPlayerMetrics.panelMaxWidth)

        // 1. 按住控制条上行空白处（音量滑条与居中按钮之间的空隙）向左上拖动 (-180, -320)
        let blankStart = CGPoint(x: startFrame.minX + 190, y: startFrame.minY + 26)
        sendMouse(.leftMouseDown, stagePoint: blankStart)
        for step in 1 ... 10 {
            let t = CGFloat(step) / 10
            let pt = CGPoint(x: blankStart.x - 180 * t, y: blankStart.y - 320 * t)
            sendMouse(.leftMouseDragged, stagePoint: pt)
            try await Task.sleep(for: .milliseconds(16))
        }
        sendMouse(.leftMouseUp, stagePoint: CGPoint(x: blankStart.x - 180, y: blankStart.y - 320))
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()

        #expect(probe.dragEndedCount == 1)
        #expect(probe.doubleClicks == 0)
        #expect(abs(probe.transportFrame.minX - (startFrame.minX - 180)) < 4)
        #expect(abs(probe.transportFrame.minY - (startFrame.minY - 320)) < 4)
        #expect(MacControlBarPosition.decode(UserDefaults.standard.string(forKey: key) ?? "") != nil)

        // 2. 在移动后的控制条空白处双击：应触发全屏回调，且不误触发拖动
        let movedFrame = probe.transportFrame
        let movedBlank = CGPoint(x: movedFrame.minX + 190, y: movedFrame.minY + 26)
        sendMouse(.leftMouseDown, stagePoint: movedBlank, clicks: 1)
        sendMouse(.leftMouseUp, stagePoint: movedBlank, clicks: 1)
        sendMouse(.leftMouseDown, stagePoint: movedBlank, clicks: 2)
        sendMouse(.leftMouseUp, stagePoint: movedBlank, clicks: 2)
        try await Task.sleep(for: .milliseconds(150))

        #expect(probe.doubleClicks >= 1)
        #expect(probe.dragEndedCount == 1)
        #expect(abs(probe.transportFrame.minX - movedFrame.minX) < 1)
        #expect(abs(probe.transportFrame.minY - movedFrame.minY) < 1)

        // 3. 在移动后的控制条上拖动音量滑条：音量应变化，且控制条本身不被拖走
        let volStart = CGPoint(x: movedFrame.minX + 115, y: movedFrame.minY + 30)
        sendMouse(.leftMouseDown, stagePoint: volStart)
        sendMouse(.leftMouseDragged, stagePoint: CGPoint(x: movedFrame.minX + 70, y: movedFrame.minY + 30))
        sendMouse(.leftMouseUp, stagePoint: CGPoint(x: movedFrame.minX + 70, y: movedFrame.minY + 30))
        try await Task.sleep(for: .milliseconds(150))

        #expect(volume.level < 0.5)
        #expect(probe.dragEndedCount == 1)
        #expect(abs(probe.transportFrame.minX - movedFrame.minX) < 1)

        // 4. 在移动后的控制条正中点播放键：播放回调触发，控制条不动
        let playCenter = CGPoint(x: movedFrame.midX, y: movedFrame.minY + 31)
        sendMouse(.leftMouseDown, stagePoint: playCenter)
        sendMouse(.leftMouseUp, stagePoint: playCenter)
        try await Task.sleep(for: .milliseconds(150))

        #expect(probe.playToggles == 1)
        #expect(probe.dragEndedCount == 1)
    }
}
