import SwiftUI

/// 关于页：版本、开源组件许可、数据来源声明。入口在「我的」页底部，所有成员可见。
///
/// 这一页承担两项上架前必须满足的义务：
/// - **LGPL**：自研播放引擎 AetherEngine（LGPL-3.0 + App Store 例外）与它自带的 FFmpeg（LGPL-2.1）
///   以动态框架随包（见 project.yml 的 AetherCore 目标）。许可要求向用户说明组件、附上许可全文、
///   给出（修改后的）源码地址——全文随包放在 Shared/Resources/Licenses 下，点组件即可阅读；
/// - **TMDB 使用条款**：使用 TMDB 数据的产品必须注明「使用 TMDB API，但未经 TMDB 认可或认证」。
///
/// 升级 AetherEngine / FFmpegBuild / Nuke 等依赖时，同步核对这里的版本、许可与地址。
struct AboutView: View {
    var body: some View {
        List {
            Section {
                LabeledContent("版本", value: Self.versionText)
                Link(destination: URL(string: "https://github.com/movieclaw/movieclaw")!) {
                    Label("项目主页（开源）", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/movieclaw/movieclaw/blob/main/docs/privacy-policy.md")!) {
                    Label("隐私政策", systemImage: "hand.raised")
                }
            } footer: {
                Text("MovieClaw 是自托管服务的客户端：你的媒体、账号与观看记录都在你自己部署的服务器上，App 不向开发者或任何第三方上传数据。")
            }

            Section {
                ForEach(OpenSourceComponent.all) { component in
                    NavigationLink {
                        LicenseTextView(component: component)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(component.name)
                            Text(component.license)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                }
            } header: {
                Text("开源组件")
            } footer: {
                Text("播放引擎 AetherEngine 与 FFmpeg 以动态框架随 App 分发，你可以按各自的许可获取源码、修改并替换。本 App 使用的 AetherEngine 修改版源码可通过下方组件链接获取，链接对应本次构建使用的提交。")
            }

            Section {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label("The Movie Database (TMDB)", systemImage: "film.stack")
                }
            } header: {
                Text("数据来源")
            } footer: {
                Text("影视资料与图片由你的服务器从 TMDB 等来源获取。本产品使用 TMDB API，但未经 TMDB 认可或认证。")
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
    }

    /// 「0.1.0（202609281530）」：营销版本 + 构建号，反馈问题时据此确认用户装的是哪一次构建
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }
}

/// 一个组件的源码地址与许可全文
private struct LicenseTextView: View {
    let component: OpenSourceComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let url = URL(string: component.source) {
                    Link(destination: url) {
                        Label("源码：\(component.source)", systemImage: "link")
                            .font(.footnote)
                    }
                }
                ForEach(component.licenseFiles, id: \.self) { file in
                    Text(Self.text(of: file))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
        .appBackground()
    }

    private static func text(of file: String) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "（许可全文缺失：\(file).txt）" }
        return text
    }
}
