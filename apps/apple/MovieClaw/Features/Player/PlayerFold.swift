import SwiftUI

/// 播放器在 iPhone Duo 半折时怎么排（docs/design/iphone-duo.md §6.4），由窗口里生效的折痕（系统的「分隔」保留区域）算出：
/// - `tabletop`：折痕横向——内屏竖着、下半平放在桌上（像笔记本）。上半放画面，下半是常显的控制台：
///   按钮、进度条、音轨字幕都在下半屏，功能与全屏时完全一样，只是换了位置（同 Netflix、Prime Video 的桌面模式）；
/// - `book`：折痕竖向——像捧着一本书。画面不动；正中的后退 / 播放 / 前进正好压在折痕上（折痕处难点），整组挪到折痕外；
/// - `flat`：没有生效的折痕（全开、合上、不是 Duo）。
///
/// 没用系统的 `ArrangementView`：播放器的控制层是画面上的一整套叠层（手势层、控制条、菜单、HUD、各种提示卡），
/// 拆不成它要的「一主一辅」两个视图；这里只在现有布局上按折痕挪位置，过渡跟着系统改窗口尺寸走。
nonisolated enum PlayerFold: Equatable, Sendable {
    case flat
    /// 画面区的底边、控制台的顶边（播放器 GeometryReader 坐标）
    case tabletop(videoBottom: CGFloat, deckTop: CGFloat)
    /// 中部按钮组水平挪多少点：挪到折痕外较宽那一半的正中（一样宽时去右半边，离右手拇指近）
    case book(centerShift: CGFloat)

    var isTabletop: Bool {
        if case .tabletop = self { return true }
        return false
    }

    /// `folds`：生效的折痕区域（与 `size` 同一坐标系）。折痕离边太近（上下或左右某一半不到四分之一）当没折——
    /// 那样的「一半」放不下画面或控制台
    static func resolve(size: CGSize, folds: [CGRect]) -> PlayerFold {
        guard size.width > 0, size.height > 0,
              let fold = folds.first(where: { !$0.isNull && ($0.width > 0 || $0.height > 0) })
        else { return .flat }
        if fold.width >= fold.height {
            guard fold.minY > size.height * 0.25, fold.maxY < size.height * 0.75 else { return .flat }
            return .tabletop(videoBottom: fold.minY, deckTop: fold.maxY)
        }
        guard fold.minX > size.width * 0.25, fold.maxX < size.width * 0.75 else { return .flat }
        let left = fold.minX, right = size.width - fold.maxX
        let target = right >= left ? fold.maxX + right / 2 : left / 2
        // 那一半放不下整组时，至少别出屏（左右各留 16 点）
        let limit = max(0, size.width / 2 - centerClusterWidth / 2 - 16)
        return .book(centerShift: min(max(target - size.width / 2, -limit), limit))
    }

    /// 中部「后退 / 播放 / 前进」整组的宽（56 + 36 + 76 + 36 + 56，见 `PlayerCenterControls`）
    static let centerClusterWidth: CGFloat = 260

    /// 读窗口里生效的折痕（iOS 27.1 起的保留区域；更早的系统没有折叠屏）
    static func activeFolds(_ proxy: GeometryProxy) -> [CGRect] {
        #if DEBUG
        if let simulated = simulated(size: proxy.size) { return simulated }
        #endif
        guard #available(iOS 27.1, *) else { return [] }
        return proxy.reservedRegions(kind: .division).map(\.frame)
    }

    #if DEBUG
    /// 开发期：`-mcSimulateFold tabletop|book` 在任何模拟器上假装窗口正中有一道折痕（宽 24 点），核对两种排法用。
    /// 真的开合只能在 DeviceHub 里点（simctl、XCUITest 都没有铰链接口）
    private static func simulated(size: CGSize) -> [CGRect]? {
        switch UserDefaults.standard.string(forKey: "mcSimulateFold") {
        case "tabletop": [CGRect(x: 0, y: size.height / 2 - 12, width: size.width, height: 24)]
        case "book": [CGRect(x: size.width / 2 - 12, y: 0, width: 24, height: size.height)]
        default: nil
        }
    }
    #endif
}
