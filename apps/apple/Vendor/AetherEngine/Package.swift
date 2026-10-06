// swift-tools-version: 6.0
//
// MovieClaw 内置的 AetherEngine（上游 github.com/superuser404notfound/AetherEngine 7.28.0，
// LGPL-3.0 + App Store 例外，许可见 LICENSE）。
//
// 为什么放进仓库而不是直接引用上游包：自研播放引擎要在上游之上打几处起播优化补丁
// （清单与动机见 PATCHES.md），改动按 LGPL 随本仓库公开，并逐个提给上游；上游合并后删掉对应补丁、
// 最终回到直接引用上游版本。与上游的差别只有：
// 1. 只保留引擎本体目标 `AetherEngine`（去掉 SMB 读取器、aetherctl 命令行、示例与测试）；
// 2. Sources/AetherEngine 里 PATCHES.md 列出的补丁。
// FFmpegBuild / LibDovi 的版本约束与上游 7.28.0 完全一致。

import PackageDescription

let package = Package(
    name: "AetherEngine",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "AetherEngine", targets: ["AetherEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", .upToNextMinor(from: "3.6.0")),
        .package(url: "https://github.com/superuser404notfound/LibDovi", .upToNextMinor(from: "2.1.0")),
    ],
    targets: [
        .target(
            name: "AetherEngine",
            dependencies: [
                .product(name: "AetherFFmpegBuild", package: "FFmpegBuild"),
                .product(name: "Dovi", package: "LibDovi"),
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
    ]
)
