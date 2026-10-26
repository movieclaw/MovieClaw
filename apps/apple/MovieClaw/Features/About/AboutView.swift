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
            SettingsFormSection {
                LabeledContent(String(localized: .settingsDevicesApprovalVersion), value: Self.versionText)
                Link(destination: URL(string: "https://github.com/movieclaw/movieclaw")!) {
                    Label(String(localized: .settingsAboutProjectHome), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/movieclaw/movieclaw/blob/main/docs/privacy-policy.md")!) {
                    Label(String(localized: .settingsAboutPrivacyPolicy), systemImage: "hand.raised")
                }
            } footer: {
                Text(String(localized: .settingsAboutPrivacySummary))
            }

            SettingsFormSection {
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
                Text(String(localized: .settingsAboutOpenSource))
            } footer: {
                Text(String(localized: .settingsAboutLicensesHint))
            }

            SettingsFormSection {
                Link(destination: URL(string: "https://www.themoviedb.org")!) {
                    Label("The Movie Database (TMDB)", systemImage: "film.stack")
                }
            } header: {
                Text(String(localized: .settingsAboutDataSources))
            } footer: {
                Text(String(localized: .settingsAboutTmdbNotice))
            }
        }
        .navigationTitle(String(localized: .settingsAboutTitle))
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
                        Label(String(localized: .settingsAboutSourceLink(component.source)), systemImage: "link")
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
        else { return String(localized: .settingsAboutLicenseMissing(file)) }
        return text
    }
}
