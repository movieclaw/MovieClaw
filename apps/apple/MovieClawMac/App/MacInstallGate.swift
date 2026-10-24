import AppKit
import SwiftUI

/// 安装位置检查（docs/design/macos-app.md「安装与更新」）：GitHub 下载的 Mac 版必须装在「应用程序」文件夹里。
///
/// 留在安装盘（DMG）上或「下载」里直接打开时，App 所在的位置是只读的（从网上下载的还会被系统挪到一个随机路径隔离运行），
/// 以后自动更新没法原地替换，必然失败。所以启动时先查位置，不对就整个窗口换成安装引导，不给「不移动」。
///
/// 引导用户在访达里拖进「应用程序」，App 不自己拷：Mac 版是沙盒 App，从网上下载的安装盘里打开时，它写出去的文件都会被
/// 系统加上隔离标记、而且清不掉，拷进去的那份以后每次打开仍被挪到随机路径运行（2026-10-24 实测）。只有在访达里拖进去的，
/// 系统才当作用户自己装的。
///
/// 只对 GitHub 下载的直接分发版生效：TestFlight / App Store 版有商店收据，由系统负责安装和更新；
/// 调试版和 Xcode 编译目录里跑的不检查。
enum MacInstallLocation {
    enum Problem: Equatable {
        /// 在安装盘里直接打开；volume 是安装盘的卷
        case diskImage(volume: URL)
        /// 在「下载」等别的地方打开；app 是它原来的位置
        case elsewhere(app: URL)
    }

    /// 本次启动的检查结果（启动时算一次）
    @MainActor static let problem: Problem? = {
        #if DEBUG
        return nil
        #else
        if ProcessInfo.processInfo.arguments.contains("-mcSkipInstallCheck") { return nil }
        let bundle = originalLocation(of: Bundle.main.bundleURL)
        let receipt = Bundle.main.appStoreReceiptURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return check(bundle: bundle, home: realHome, hasStoreReceipt: receipt,
                     diskImageVolume: { diskImageVolume(containing: bundle) })
        #endif
    }()

    /// 判定规则（纯函数，单测覆盖）。bundle 是 App 原来的位置；diskImageVolume 只在位置不对时才调用：App 所在的安装盘，不是安装盘时为 nil
    static func check(bundle: URL, home: URL, hasStoreReceipt: Bool, diskImageVolume: () -> URL?) -> Problem? {
        if hasStoreReceipt { return nil }
        let path = bundle.standardizedFileURL.path
        // Xcode 与打包脚本的编译目录：开发者自己跑 Release 构建时不拦
        if path.contains("/Build/Products/") { return nil }
        if installFolders(home: home).contains(where: { path.hasPrefix($0.path + "/") }) { return nil }
        return diskImageVolume().map { .diskImage(volume: $0) } ?? .elsewhere(app: bundle)
    }

    /// 能装的两个位置：系统的「应用程序」与个人目录下的 Applications
    static func installFolders(home: URL) -> [URL] {
        [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// 真正的个人目录。沙盒里 NSHomeDirectory() 是容器目录，不能用
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// 从网上下载的 App 第一次打开时会被系统挪到随机路径运行（App Translocation）：那里是原位置的只读镜像挂载，
    /// 挂载来源就是原来的 App 路径（不用私有接口，也不用读安装盘里的文件——沙盒读不了）
    private static func originalLocation(of bundle: URL) -> URL {
        guard bundle.path.contains("/AppTranslocation/") else { return bundle }
        var info = statfs()
        guard statfs(bundle.path, &info) == 0 else { return bundle }
        let source = withUnsafeBytes(of: &info.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return source.hasPrefix("/") ? URL(fileURLWithPath: source) : bundle
    }

    /// App 所在的安装盘：在 /Volumes 下的只读卷。放在外接硬盘上的不算（那是「别的地方」）
    private static func diskImageVolume(containing bundle: URL) -> URL? {
        let parts = bundle.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        let volume = URL(fileURLWithPath: "/Volumes/" + parts[2])
        return (try? volume.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true ? volume : nil
    }
}

/// 安装引导：位置不对时代替整个主界面，说清楚去哪拖，只有一个退出按钮（退出后也不再占着安装盘）。
/// 不替用户打开访达窗口：沙盒 App 打开没有访问权限的文件夹（安装盘、「下载」）会被系统静默拒绝（2026-10-24 实测）
struct MacInstallGateView: View {
    let problem: MacInstallLocation.Problem

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("把 MovieClaw 装到「应用程序」")
                .font(.system(size: 22, weight: .bold))
            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if case let .elsewhere(app) = problem {
                Text(app.path.replacingOccurrences(of: MacInstallLocation.realHome.path, with: "~", options: .anchored))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("知道了，退出") { NSApp.terminate(nil) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
                .accessibilityIdentifier("mac-install-gate-quit")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .accessibilityIdentifier("mac-install-gate")
    }

    private var explanation: String {
        switch problem {
        case .diskImage:
            "你现在是直接在安装盘里打开的。请退出后回到安装盘窗口，把 MovieClaw 拖到右边的「应用程序」文件夹，再从「应用程序」或启动台打开。"
                + "装进去之后才能正常使用，以后也能自动更新。"
        case .elsewhere:
            "你现在是在「应用程序」以外的地方打开的（比如「下载」）。请退出后在访达里把它拖进「应用程序」文件夹，再从那里打开。"
                + "装进去之后才能正常使用，以后也能自动更新。它现在在："
        }
    }
}
