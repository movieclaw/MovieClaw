import Foundation
import Testing
@testable import MovieClaw

/// GitHub 下载的 Mac 版必须装在「应用程序」里，否则以后没法自动更新（MacInstallGate.swift）
struct MacInstallLocationTests {
    private let home = URL(fileURLWithPath: "/Users/someone")
    private let dmg = URL(fileURLWithPath: "/Volumes/MovieClaw 0.11.0")

    private func check(_ path: String, receipt: Bool = false, volume: URL? = nil) -> MacInstallLocation.Problem? {
        MacInstallLocation.check(bundle: URL(fileURLWithPath: path), home: home, hasStoreReceipt: receipt,
                                 diskImageVolume: { volume })
    }

    @Test func applicationsFoldersPass() {
        #expect(check("/Applications/MovieClaw.app") == nil)
        #expect(check("/Applications/影音/MovieClaw.app") == nil)
        #expect(check("/Users/someone/Applications/MovieClaw.app") == nil)
    }

    @Test func storeAndBuildOutputsAreNeverChecked() {
        // TestFlight / App Store 版有收据，由系统负责安装
        #expect(check("/Users/someone/Downloads/MovieClaw.app", receipt: true) == nil)
        #expect(check("/Users/someone/Library/Developer/Xcode/DerivedData/X/Build/Products/Release/MovieClaw.app") == nil)
    }

    @Test func diskImageNamesTheVolume() {
        // 从网上下载的被系统挪到随机路径运行时，传进来的已经是还原出的原位置
        #expect(check("/Volumes/MovieClaw 0.11.0/MovieClaw.app", volume: dmg) == .diskImage(volume: dmg))
    }

    @Test func everywhereElseNeedsMoving() {
        // 记着原来的位置，引导里在访达中选中它
        for path in ["/Users/someone/Downloads/MovieClaw.app",
                     // 可写的外接硬盘不是安装盘
                     "/Volumes/外接硬盘/MovieClaw.app",
                     // 名字像但不是那两个文件夹
                     "/Applications-old/MovieClaw.app", "/Users/someone/Desktop/Applications/MovieClaw.app"] {
            #expect(check(path) == .elsewhere(app: URL(fileURLWithPath: path)))
        }
    }
}
