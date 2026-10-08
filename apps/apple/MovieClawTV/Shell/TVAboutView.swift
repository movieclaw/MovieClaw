import SwiftUI

/// 关于（docs/design/tvos-app.md §3.1，收在「谁在看」里）：版本、开源组件与许可全文、数据来源声明。
///
/// 与 iPhone 版同样承担上架义务（LGPL：组件、许可全文、修改后的源码地址；TMDB 使用条款的署名），
/// 组件清单与许可全文两端共用一份（`OpenSourceComponent`、Shared/Resources/Licenses）。
/// 电视上没有浏览器，地址只显示、不能点开。
struct TVAboutView: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 48) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("MovieClaw")
                        .font(.title.weight(.bold))
                    Text("版本 \(Self.versionText)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("MovieClaw 是自托管服务的客户端：你的媒体、账号与观看记录都在你自己部署的服务器上，App 不向开发者或任何第三方上传数据。项目主页：github.com/movieclaw/movieclaw")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1300, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 20) {
                    Text("开源组件")
                        .font(.title3.weight(.semibold))
                    Text("播放引擎 AetherEngine 与 FFmpeg 以动态框架随 App 分发，你可以按各自的许可获取源码、修改并替换。本 App 使用的 AetherEngine 修改版源码可通过下方组件链接获取，链接对应本次构建使用的提交。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 1300, alignment: .leading)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 40), count: 2), alignment: .leading, spacing: 30) {
                        ForEach(OpenSourceComponent.all) { component in
                            NavigationLink {
                                TVLicenseTextView(component: component)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(component.name).font(.headline)
                                    Text(component.license).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("数据来源")
                        .font(.title3.weight(.semibold))
                    Text("影视资料与图片由你的服务器从 TMDB（themoviedb.org）等来源获取。本产品使用 TMDB API，但未经 TMDB 认可或认证。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 40)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tv-about")
    }

    /// 「0.3.0（202610021200）」：营销版本 + 构建号
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }
}

/// 一个组件的源码地址与许可全文。电视上长文要靠焦点滚动：全文按页切成可聚焦的块，上下滑动一页一页翻。
/// 不能整篇一个块：焦点只在块与块之间跳，比一屏高的块中间那段永远滚不到（LGPL 正文大半读不到，
/// 标题也被顶出屏幕，2026-10-05 模拟器走查发现）
private struct TVLicenseTextView: View {
    let component: OpenSourceComponent

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 30) {
                Text(component.name)
                    .font(.title2.weight(.bold))
                Text("源码：\(component.source)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(component.licenseFiles, id: \.self) { file in
                    // 同一份文件的各页紧挨着排（不用外层的段距），读起来还是连续的一篇
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Self.pages(of: Self.text(of: file)).enumerated()), id: \.offset) { _, page in
                            Text(page)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .focusable()
                        }
                    }
                }
            }
            .padding(.horizontal, TVMetrics.edge)
            .padding(.vertical, 40)
        }
    }

    /// 每块的行数：等宽小字一屏放得下，翻页时上一块的尾巴还露在屏幕上，读着不断档
    private static let linesPerPage = 20

    private static func pages(of text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        return stride(from: 0, to: lines.count, by: linesPerPage).map {
            lines[$0 ..< min($0 + linesPerPage, lines.count)].joined(separator: "\n")
        }
    }

    private static func text(of file: String) -> String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "（许可全文缺失：\(file).txt）" }
        return text
    }
}
