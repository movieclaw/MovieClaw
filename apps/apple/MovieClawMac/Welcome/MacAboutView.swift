import AppKit
import SwiftUI

/// 关于（菜单「关于 MovieClaw」、账号浮层里打开的独立窗口）：App 图标、名称、版本、副标题，开源组件与许可全文，数据来源声明。
///
/// 与 iPhone、Apple TV 版同样承担分发义务（LGPL：组件、许可全文、修改后的源码地址；TMDB 使用条款的署名），
/// 组件清单与许可全文三端共用一份（`OpenSourceComponent`、Shared/Resources/Licenses），这里只是 Mac 的排版：
/// 窗口固定约 520×640，内容可滚动；点一个组件推进到它的许可全文（可选中复制），源码地址可点开。
struct MacAboutView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    MacAboutSection(title: "开源组件",
                                    note: "播放引擎 AetherEngine 与 FFmpeg 以动态框架随 App 分发，你可以按各自的许可获取源码、修改并替换。本 App 使用的 AetherEngine 修改版源码可通过下方组件链接获取，链接对应本次构建使用的提交。") {
                        VStack(spacing: 0) {
                            ForEach(Array(OpenSourceComponent.all.enumerated()), id: \.element.id) { index, component in
                                if index > 0 { Divider().padding(.leading, 14) }
                                NavigationLink(value: component.name) {
                                    MacAboutComponentRow(component: component)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("mac-about-component-\(index)")
                            }
                        }
                        .background(.white.opacity(0.05), in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                    }
                    MacAboutSection(title: "数据来源",
                                    note: "影视资料与图片由你的服务器从 TMDB（themoviedb.org）等来源获取。本产品使用 TMDB API，但未经 TMDB 认可或认证。") {
                        EmptyView()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .navigationDestination(for: String.self) { name in
                if let component = OpenSourceComponent.all.first(where: { $0.name == name }) {
                    MacLicenseTextView(component: component)
                }
            }
        }
        .frame(width: 520, height: 640)
        .accessibilityIdentifier("mac-about")
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("MovieClaw")
                .font(.system(size: 22, weight: .bold))
                .padding(.top, 4)
            Text("智能影音服务器")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("版本 \(Self.versionText)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .padding(.top, 2)
            Text("MovieClaw 是自托管服务的客户端：你的媒体、账号与观看记录都在你自己部署的服务器上，App 不向开发者或任何第三方上传数据。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Link("github.com/movieclaw/movieclaw", destination: URL(string: "https://github.com/movieclaw/movieclaw")!)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity)
    }

    /// 「0.3.0（202610021200）」：营销版本 + 构建号
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }
}

/// 关于页的一节：小标题、说明、内容
private struct MacAboutSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 组件列表的一行：名称、许可，右侧箭头；悬停提亮
private struct MacAboutComponentRow: View {
    let component: OpenSourceComponent
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(component.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Text(component.license)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(hovering ? 0.06 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// 一个组件的源码地址与许可全文（可选中复制）。LGPL-3.0 以 GPL-3.0 为基础，两份全文都在
private struct MacLicenseTextView: View {
    let component: OpenSourceComponent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(component.name)
                    .font(.system(size: 17, weight: .semibold))
                Text(component.license)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let url = URL(string: component.source) {
                    Link(destination: url) {
                        Label(component.source, systemImage: "arrow.up.right.square")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.leading)
                    }
                }
                ForEach(component.licenseFiles, id: \.self) { file in
                    Text(Self.text(of: file))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.white.opacity(0.04), in: .rect(cornerRadius: 8))
                }
            }
            .padding(24)
        }
        .navigationTitle(component.name)
    }

    private static func text(of file: String) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "（许可全文缺失：\(file).txt）" }
        return text
    }
}
