import Foundation

/// 片段的画质（2026-09-30 用户要求：外网体验靠转码，片段能选画质、默认走转码）。
///
/// 和正片的 `QualityMemory` 分开记：正片按「这部片 + 网络环境」记，片段一条几十秒、每条都是别的片，
/// 只按网络环境记一个值——在外面选了 720p，之后刷到的每一条都是 720p；回家还是原画。竖屏刷和
/// 「全屏观看」（正片播放器的片段模式）共用这一份：全屏里改了画质，回到竖屏也按新的放。
///
/// 网络环境：家里 / 外网（`PlaybackNetwork`：手机和 NAS 在同一网段 = 家里）。服务器配的是公网域名、
/// 分不清时退回按网卡分：Wi-Fi / 蜂窝（2026-09-30 用户拍板）。
///
/// 默认（没手动选过）：家里、Wi-Fi 原画——直出原文件最快、能预起下一条、有字幕；外网、蜂窝 720p——
/// 约 3 Mbps，NAS 上行（实测 5.8MB/s）也容得下，卡了再由卡顿提示降到 480p。
///
/// `nil` 表示原画（直出原文件）。存储里用 0 表示「明确选了原画」，与「没选过、按默认」区分开。
enum ReelsQuality {
    private static let key = "movieclaw.reels.quality-by-network"

    /// 片段页的画质菜单：正片的档位，「自动」在这里就是原画（直出原文件）
    static let options: [QualityOption] = QualityOption.all.map { option in
        option.maxHeight == nil ? QualityOption(maxHeight: nil, label: "原画", hint: "直接放原文件，最快") : option
    }

    static func label(_ maxHeight: Int?) -> String {
        options.first { $0.maxHeight == maxHeight }?.label ?? maxHeight.map { "\($0)p" } ?? "原画"
    }

    /// 当前网络环境下的画质
    static func current(server: ServerAddress) -> Int? {
        let network = networkKey(server: server)
        if let stored = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[network] {
            return stored > 0 ? stored : nil
        }
        return ["away", "cellular"].contains(network) ? 720 : nil
    }

    /// 记下当前网络环境下的选择（选原画也要记：外网的默认是 720p，不记就回到默认了）
    static func remember(_ maxHeight: Int?, server: ServerAddress) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        all[networkKey(server: server)] = maxHeight ?? 0
        UserDefaults.standard.set(all, forKey: key)
    }

    private static func networkKey(server: ServerAddress) -> String {
        switch PlaybackNetwork.current(server: server) {
        case .home: "home"
        case .away: "away"
        case .unknown: NetworkCost.shared.interface == "cellular" ? "cellular" : "wifi"
        }
    }
}
