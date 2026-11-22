import SwiftUI

/// 控制条在舞台可移动区间内的归一化位置（`0...1`），随窗口缩放、选集侧栏开合与进出全屏按相对位置还原
struct MacControlBarPosition: Equatable, Sendable {
    let rx: Double
    let ry: Double

    init(rx: Double, ry: Double) {
        self.rx = min(1, max(0, rx))
        self.ry = min(1, max(0, ry))
    }

    var encoded: String {
        String(format: "%.4f,%.4f", rx, ry)
    }

    static func decode(_ raw: String) -> MacControlBarPosition? {
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, parts[0].isFinite, parts[1].isFinite else { return nil }
        return MacControlBarPosition(rx: parts[0], ry: parts[1])
    }
}

/// Mac 播放器浮动控制条的纯几何与耦合判定（独立于视图状态，方便单元测试）
enum MacControlBarLayout {
    static let storageKey = MacPlayerMetrics.controlBarPositionKey

    /// 拖动边界边距：左右各 10、上方让开左上角红绿灯与片名 70、下方 10
    static let marginX: CGFloat = 10
    static let marginTop: CGFloat = 70
    static let marginBottom: CGFloat = 10

    /// 横向靠近舞台中线 5 点内吸附居中
    static let snapThreshold: CGFloat = 5
    /// 拖回默认底部居中 6 点内松手时视为恢复默认
    static let defaultSnapThreshold: CGFloat = 6
    /// 小于 3 点按点击 / 双击处理，避免误把双击全屏变成拖动
    static let dragThreshold: CGFloat = 3
    /// 距离默认底边 36 点内保留底部托字渐变，拖离后淡出
    static let bottomGradientThreshold: CGFloat = 36
    /// 控制条顶边距顶不足 156 点时，进度条缩略图预览改为向下弹出
    static let previewFlipThreshold: CGFloat = 156

    /// 控制胶囊宽度：两侧留窗口宽的 5%（至多 48），最宽 720
    static func panelWidth(for stage: CGSize) -> CGFloat {
        max(0, min(stage.width - min(MacPlayerMetrics.panelSideInset, stage.width * 0.05) * 2, MacPlayerMetrics.panelMaxWidth))
    }

    /// 默认位置：水平居中，距底 `panelBottom`
    static func defaultOrigin(stage: CGSize, panelWidth: CGFloat) -> CGPoint {
        let x = max(0, (stage.width - panelWidth) / 2)
        let y = max(marginTop, stage.height - MacPlayerMetrics.panelHeight - MacPlayerMetrics.panelBottom)
        return CGPoint(x: x, y: y)
    }

    /// 控制条左上角原点允许移动的矩形区间
    static func movableBounds(stage: CGSize, panelWidth: CGFloat) -> CGRect {
        let minX = marginX
        let maxX = max(minX, stage.width - panelWidth - marginX)
        let minY = marginTop
        let maxY = max(minY, stage.height - MacPlayerMetrics.panelHeight - marginBottom)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 按当前拖动位置 / 已存归一化比例 / 默认值解析控制条实时 frame（舞台坐标，左上角为原点）
    static func resolveFrame(stored: MacControlBarPosition?, dragOrigin: CGPoint?, stage: CGSize) -> CGRect {
        let width = panelWidth(for: stage)
        let height = MacPlayerMetrics.panelHeight
        guard stage.width > 0, stage.height > 0 else {
            return CGRect(x: 0, y: 0, width: width, height: height)
        }
        let bounds = movableBounds(stage: stage, panelWidth: width)
        if let dragOrigin {
            let x = bounds.width <= 1 ? (stage.width - width) / 2 : min(max(dragOrigin.x, bounds.minX), bounds.maxX)
            let y = bounds.height <= 1 ? bounds.minY : min(max(dragOrigin.y, bounds.minY), bounds.maxY)
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard let stored else {
            return CGRect(origin: defaultOrigin(stage: stage, panelWidth: width), size: CGSize(width: width, height: height))
        }
        // 窗口缩到比控制条 + 边距还窄时自动回中
        let x = bounds.width <= 1 ? (stage.width - width) / 2 : bounds.minX + CGFloat(stored.rx) * bounds.width
        let y = bounds.height <= 1 ? bounds.minY : bounds.minY + CGFloat(stored.ry) * bounds.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// 拖动中的坐标夹紧 + 水平中心 5 点吸附
    static func clampedDragOrigin(
        startOrigin: CGPoint,
        translation: CGSize,
        stage: CGSize,
        panelWidth: CGFloat
    ) -> (origin: CGPoint, snappedCenter: Bool) {
        let bounds = movableBounds(stage: stage, panelWidth: panelWidth)
        var x = bounds.width <= 1
            ? (stage.width - panelWidth) / 2
            : min(max(startOrigin.x + translation.width, bounds.minX), bounds.maxX)
        let y = bounds.height <= 1
            ? bounds.minY
            : min(max(startOrigin.y + translation.height, bounds.minY), bounds.maxY)

        let centerX = (stage.width - panelWidth) / 2
        var snapped = false
        if bounds.width > 1, abs(x - centerX) <= snapThreshold {
            x = centerX
            snapped = true
        }
        return (CGPoint(x: x, y: y), snapped)
    }

    /// 松手时将原点换算为持久化比例；落回默认底部居中附近直接清为 nil
    static func persistPosition(for origin: CGPoint, stage: CGSize, panelWidth: CGFloat) -> MacControlBarPosition? {
        let def = defaultOrigin(stage: stage, panelWidth: panelWidth)
        if hypot(origin.x - def.x, origin.y - def.y) <= defaultSnapThreshold {
            return nil
        }
        let bounds = movableBounds(stage: stage, panelWidth: panelWidth)
        let rx = bounds.width <= 1 ? 0.5 : Double((origin.x - bounds.minX) / bounds.width)
        let ry = bounds.height <= 1 ? 1.0 : Double((origin.y - bounds.minY) / bounds.height)
        return MacControlBarPosition(rx: rx, ry: ry)
    }

    /// 控制条仍在底部默认带时显示底部暗色渐变，拖走后淡出
    static func showsBottomGradient(barFrame: CGRect, stage: CGSize, hasCustomPosition: Bool, isDragging: Bool) -> Bool {
        guard hasCustomPosition || isDragging else { return true }
        let def = defaultOrigin(stage: stage, panelWidth: barFrame.width)
        return abs(barFrame.minY - def.y) < bottomGradientThreshold
    }

    /// 指针是否停在控制条上（四边外扩 4 点，避免边缘晃动触发隐藏）
    static func pointerHitsTransport(_ pointer: CGPoint, barFrame: CGRect) -> Bool {
        guard barFrame.width > 0, barFrame.height > 0 else { return false }
        return barFrame.insetBy(dx: -4, dy: -4).contains(pointer)
    }

    /// 字幕避让：仅当控制条实时 frame 与底部字幕区实际相交时才把字幕抬到控制条上方
    static func subtitleLiftBottomPercent(
        basePercent: Double,
        barFrame: CGRect,
        videoRect: CGRect,
        stage: CGSize
    ) -> Double {
        guard videoRect.height > 0, stage.height > 0, barFrame.width > 0, barFrame.height > 0 else { return basePercent }
        let subBottomY = videoRect.maxY - videoRect.height * CGFloat(basePercent) / 100
        let bandHeight = min(72, max(28, videoRect.height * 0.14))
        let subBand = CGRect(
            x: videoRect.minX + videoRect.width * 0.12,
            y: subBottomY - bandHeight,
            width: videoRect.width * 0.76,
            height: bandHeight
        )
        guard barFrame.insetBy(dx: 0, dy: -8).intersects(subBand) else { return basePercent }
        let needed = (videoRect.maxY - (barFrame.minY - 12)) / videoRect.height * 100
        return needed > basePercent ? min(40, needed.rounded(.up)) : basePercent
    }

    /// 右下角卡片（跳过片头 / 下一集 / 换画质）的底边距：始终锚在右下角，仅在控制条与之重叠时抬到控制条上方
    static func cornerBottomPadding(
        chromeVisible: Bool,
        barFrame: CGRect,
        stage: CGSize,
        cornerSize: CGSize
    ) -> CGFloat {
        let defaultBottom: CGFloat = 32
        guard chromeVisible, stage.width > 0, stage.height > 0, barFrame.width > 0, barFrame.height > 0 else {
            return defaultBottom
        }
        let effectiveSize = CGSize(
            width: cornerSize.width > 0 ? cornerSize.width : 160,
            height: cornerSize.height > 0 ? cornerSize.height : 44
        )
        let cornerRect = CGRect(
            x: stage.width - 32 - effectiveSize.width,
            y: stage.height - defaultBottom - effectiveSize.height,
            width: effectiveSize.width,
            height: effectiveSize.height
        )
        guard barFrame.insetBy(dx: -12, dy: -12).intersects(cornerRect) else {
            return defaultBottom
        }
        return max(defaultBottom, stage.height - barFrame.minY + 12)
    }

    /// 字幕 / 音轨浮层的四象限展开方向与可用尺寸
    struct TracksPanelPlacement: Equatable, Sendable {
        let opensDownward: Bool
        let alignsLeading: Bool
        let maxWidth: CGFloat
        let maxHeight: CGFloat

        var overlayAlignment: Alignment {
            switch (opensDownward, alignsLeading) {
            case (false, false): .bottomTrailing
            case (false, true): .bottomLeading
            case (true, false): .topTrailing
            case (true, true): .topLeading
            }
        }

        var scaleAnchor: UnitPoint {
            switch (opensDownward, alignsLeading) {
            case (false, false): .bottomTrailing
            case (false, true): .bottomLeading
            case (true, false): .topTrailing
            case (true, true): .topLeading
            }
        }
    }

    static func tracksPanelPlacement(barFrame: CGRect, stage: CGSize) -> TracksPanelPlacement {
        let spaceAbove = max(0, barFrame.minY - 12)
        let spaceBelow = max(0, stage.height - barFrame.maxY - 12)
        let opensDownward = spaceBelow > spaceAbove && barFrame.midY < stage.height * 0.48
        let alignsLeading = stage.width > 0 && barFrame.midX < stage.width * 0.36

        let availableWidth = alignsLeading
            ? max(160, stage.width - barFrame.minX - 12)
            : max(160, barFrame.maxX - 12)
        let verticalSpace = (opensDownward ? spaceBelow : spaceAbove) - 10
        let availableHeight = max(80, min(380, verticalSpace - 54))

        return TracksPanelPlacement(
            opensDownward: opensDownward,
            alignsLeading: alignsLeading,
            maxWidth: availableWidth,
            maxHeight: availableHeight
        )
    }

    /// 进度条缩略图预览的弹出方向与水平偏移（夹紧在舞台左右边距内，上方不够放时自动向下翻转）
    struct ScrubberPreviewPlacement: Equatable, Sendable {
        let opensDownward: Bool
        let offsetX: CGFloat
    }

    static func scrubberPreviewPlacement(
        hoverX: CGFloat,
        scrubberFrame: CGRect,
        barFrame: CGRect,
        stage: CGSize,
        previewWidth: CGFloat
    ) -> ScrubberPreviewPlacement {
        let opensDownward = barFrame.minY < previewFlipThreshold
        guard stage.width > 0, scrubberFrame.width > 0 else {
            return ScrubberPreviewPlacement(opensDownward: opensDownward, offsetX: hoverX - scrubberFrame.width / 2)
        }
        let idealCenterX = scrubberFrame.minX + hoverX
        let halfW = previewWidth / 2
        let minCenterX = marginX + halfW
        let maxCenterX = max(minCenterX, stage.width - marginX - halfW)
        let clampedCenterX = min(max(idealCenterX, minCenterX), maxCenterX)
        return ScrubberPreviewPlacement(
            opensDownward: opensDownward,
            offsetX: clampedCenterX - scrubberFrame.midX
        )
    }
}
