import Foundation

/// 随包分发的一个开源组件：名称、许可、源码地址、随包许可全文的资源名（Shared/Resources/Licenses/<licenseFile>.txt）。
struct OpenSourceComponent: Identifiable {
    let name: String
    let license: String
    let source: String
    /// 可能有多份：LGPL-3.0 以 GPL-3.0 为基础，两份全文都要附上
    let licenseFiles: [String]

    var id: String { name }

    static let all: [OpenSourceComponent] = [
        .init(name: "AetherEngine（MovieClaw 修改版）", license: "LGPL-3.0，附 App Store 例外",
              source: AetherEngineDependency.sourceURL,
              licenseFiles: ["License-AetherEngine", "License-GPL-3.0"]),
        .init(name: "FFmpeg", license: "LGPL-2.1 或更新版本",
              source: "https://github.com/superuser404notfound/FFmpegBuild",
              licenseFiles: ["License-LGPL-2.1"]),
        .init(name: "libzvbi", license: "LGPL-2.1（ure.c 为 MIT）",
              source: "https://github.com/superuser404notfound/FFmpegBuild",
              licenseFiles: ["License-LGPL-2.1", "License-libzvbi-ure"]),
        .init(name: "dav1d", license: "BSD-2-Clause",
              source: "https://code.videolan.org/videolan/dav1d",
              licenseFiles: ["License-dav1d"]),
        .init(name: "zimg", license: "WTFPL",
              source: "https://github.com/sekrit-twc/zimg",
              licenseFiles: ["License-zimg"]),
        .init(name: "LibDovi / libdovi", license: "MIT",
              source: "https://github.com/superuser404notfound/LibDovi",
              licenseFiles: ["License-LibDovi"]),
        .init(name: "Nuke", license: "MIT",
              source: "https://github.com/kean/Nuke",
              licenseFiles: ["License-Nuke"]),
        .init(name: "思源宋体（Noto Serif SC，欢迎页子集）", license: "SIL Open Font License 1.1",
              source: "https://github.com/notofonts/noto-cjk",
              licenseFiles: ["OFL"]),
    ]
}
