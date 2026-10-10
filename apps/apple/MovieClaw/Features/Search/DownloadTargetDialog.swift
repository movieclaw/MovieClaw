import SwiftUI

/// 下载目标选择（对应 Web `components/download-target-dialog.tsx`）。
///
/// 点搜索结果的「下载」先让用户看清文件会落到哪，而不是静默提交。候选三层：
///   1. 智能入库：`POST /downloaders/resolve-target` 预演「识别 → 库路由 → 监听投递目录」，
///      展示真实归宿与配置警示。种子自己的身份（类型 + 片名 + 年份）识别不出来时，后端按
///      用户的搜索词给出 TMDB 候选，弹窗只问一句「这是哪部作品？」——点选即与自动识别同权，
///      媒体库仍由收藏范围自动分配；
///   2. 下载器已配置的目录：默认保存目录 + 各路径映射的 movieclaw 侧目录（双视角展示）；
///   3. 下载器默认目录兜底。
///
/// 保存位置记忆（按种子分类）：勾「记住本次选择」才写记忆（已有记忆时默认勾上——从确认条「更改」进来
/// 就是要改它）；有记忆时点「下载」先弹 `DownloadConfirmSheet` 给用户确认落点。
///
/// 成员版（member-permissions-v2 §3.7 U7）：下载器配置、智能入库预检都是超管接口，成员提交也不许带
/// 保存目录 / 下载器 / 智能入库。所以成员只在两种落点里选：「下载器默认目录」，或自己能看到的某个
/// 媒体库（带 library_id，由后端按库推导目录并入库）；不读也不写本机记忆的保存位置偏好。

/// 弹窗需要的种子身份切片（由 TorrentHit 提炼）
struct DownloadTargetRequest: Identifiable, Hashable {
    struct Identity: Hashable {
        var kind: String
        var title: String
        var year: Int
    }

    var siteId: String
    var downloadUrl: String
    var torrentId: String
    /// 三件套不全时为 nil（智能入库选项不出现）
    var identity: Identity?
    var subtitle: String?
    /// 用户的搜索关键词：种子身份识别失败时后端拿它检索 TMDB 候选
    var hint: String?
    /// 记忆的桶键：站点声明的一级分类（缺省 other）
    var category: String
    /// 记忆失效等原因（显示在弹窗顶部，静默回落最让人困惑）
    var reason: String?
    /// 对应搜索结果行（下载按钮状态按行记）
    var hitKey: String

    var id: String { "\(siteId):\(downloadUrl)" }

    init?(hit: API.TorrentHit, keyword: String = "") {
        guard let url = hit.downloadUrl else { return nil }
        hitKey = hit.rowKey
        siteId = hit.siteId
        downloadUrl = url
        torrentId = hit.torrentId
        let a = hit.attrs
        let title = a?.titlesZh.first ?? a?.titlesEn.first
        if let kind = a?.mediaType, kind == "movie" || kind == "tv", let title, let year = a?.year {
            identity = Identity(kind: kind, title: title, year: year)
        }
        subtitle = hit.subtitle.isEmpty ? nil : hit.subtitle
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        hint = trimmed.isEmpty ? nil : trimmed
        category = hit.category ?? "other"
    }
}

/// 当前登录者的保存位置记忆 + 下载器目录候选（整页只拉一次）
@Observable
final class DownloadTargetPrefs {
    private(set) var byCategory: [String: API.DownloadTargetPrefView] = [:]
    /// 可用下载器的全部目录（默认保存目录 + 映射本地侧）；nil = 拉不到，宁可不判失效
    private(set) var dirs: Set<String>?

    func refresh(api: APIClient) async {
        let rows = (try? await api.dlTargetPrefsList()) ?? []
        byCategory = Dictionary(rows.map { ($0.category, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func loadDirs(api: APIClient) async {
        guard let rows = try? await api.dlList() else { dirs = nil; return }
        var all = Set<String>()
        for d in rows where d.usable {
            if let path = d.savePath { all.insert(Self.trim(path)) }
            for m in d.pathMappings ?? [] { all.insert(Self.trim(m.local)) }
        }
        dirs = all
    }

    /// 记住的固定目录已不在候选里（库被删、路径映射改了）
    func isStaleDir(_ pref: API.DownloadTargetPrefView) -> Bool {
        guard pref.kind == "dir", let path = pref.savePath, let dirs else { return false }
        return !dirs.contains(Self.trim(path))
    }

    /// 「不再记住」：先本地摘掉再打请求
    func forget(_ category: String, api: APIClient) async {
        byCategory[category] = nil
        try? await api.dlTargetPrefsForget(category: category)
    }

    static func trim(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

/// 一个可选的保存目标
private struct TargetOption: Identifiable, Hashable {
    enum Kind: Hashable { case smart, dir, library, fallback }
    var id: String
    var kind: Kind
    var savePath: String?
    /// 成员版「下载到某个媒体库」的库 id
    var libraryId: Int?
    var label: String
    var detail: String?
}

/// 完整的「选择保存位置」弹窗
struct DownloadTargetSheet: View {
    let request: DownloadTargetRequest
    let remembered: API.DownloadTargetPrefView?
    let onSubmitted: (API.DownloadSubmitView) -> Void

    @Environment(\.api) private var api
    @Environment(\.dismiss) private var dismiss
    @Environment(Router.self) private var router
    @Environment(\.permissions) private var permissions

    @State private var downloaders: [API.DownloaderView] = []
    /// 成员版：自己可见的媒体库（nil = 还在拉）
    @State private var memberLibraries: [API.LibraryView]?
    @State private var downloaderId: Int?
    @State private var manualTarget: API.ManualDownloadTargetView?
    /// 「这是哪部作品？」：自动识别没收敛（或种子没身份）时进入确认模式，此后候选与搜索框常驻
    @State private var picking = false
    /// 候选单独留一份：点候选重跑预检期间不清空
    @State private var candidates: [API.ManualDownloadCandidateView] = []
    @State private var selectedCandidate: API.ManualDownloadCandidateView?
    /// 当前生效的搜索词与输入框草稿
    @State private var hint: String?
    @State private var hintDraft = ""
    @State private var showOther = false
    @State private var downloadersLoaded = false
    @State private var loadingDownloaders = false
    @State private var loadingTarget = false
    @State private var selected: String?
    @State private var remember = false
    @State private var busy = false
    @State private var error: String?
    /// 预检请求序号：只允许最后一次请求更新界面
    @State private var targetRequestId = 0
    @State private var initialized = false

    private var downloader: API.DownloaderView? { downloaders.first { $0.id == downloaderId } }
    private var canResolve: Bool { request.identity != nil || request.hint != nil }

    private var options: [TargetOption] {
        guard permissions.isAdmin else { return memberOptions }
        var result: [TargetOption] = []
        if let t = manualTarget, t.status == "ready", t.tmdbId != nil, t.libraryId != nil, t.ok {
            let entryDir = t.entryDir ?? t.path
            let reason = t.routeReason ?? ""
            let detail: String? = switch t.mode {
            case "watch":
                t.stagingPath.map { "\(reason)；投递到自动入库的监听目录 \(t.path ?? "")，完成后整理到 \($0)（外部流转回库根后入账）" }
                    ?? "\(reason)；投递到自动入库的监听目录 \(t.path ?? "")，完成后自动整理入库"
            case "inplace":
                "\(reason)；直接下载到 \(DownloadTargetPrefs.trim(entryDir ?? ""))，完成后自动入账"
            default: nil
            }
            result.append(TargetOption(id: "smart", kind: .smart, label: "自动入库到「\(t.libraryName ?? "")」", detail: detail))
        }
        if showOther {
            var seen = Set<String>()
            var dirs: [(path: String, source: String)] = []
            if let save = downloader?.savePath { dirs.append((save, "默认保存目录")) }
            for m in downloader?.pathMappings ?? [] {
                if !seen.contains(m.local), m.local != downloader?.savePath { dirs.append((m.local, "路径映射")) }
                seen.insert(m.local)
            }
            for dir in dirs {
                let remote = Self.remoteView(dir.path, downloader?.pathMappings)
                result.append(TargetOption(
                    id: "dir:\(dir.path)", kind: .dir, savePath: dir.path, label: dir.path,
                    detail: remote != dir.path ? "下载器视角：\(remote)（\(dir.source)）" : dir.source
                ))
            }
            result.append(TargetOption(id: "default", kind: .fallback, label: "下载器默认目录", detail: "不指定路径，由下载器按自身设置决定；movieclaw 不会自动整理入库"))
        }
        return result
    }

    /// 成员版候选：可见的影视库（种子类型对得上的排前面）+ 下载器默认目录。图片库不收种子
    private var memberOptions: [TargetOption] {
        guard let libraries = memberLibraries else { return [] }
        let kind = request.identity?.kind
        let fit = libraries.filter { $0.kind != "photo" }
        let ordered = fit.filter { $0.kind == kind } + fit.filter { $0.kind != kind }
        var result = ordered.map { library in
            TargetOption(
                id: "library:\(library.id)", kind: .library, libraryId: library.id,
                label: "下载到「\(library.name)」",
                detail: "\(LibraryKindMeta.label(library.kind))库；按库的设置决定保存目录，完成后自动入库"
            )
        }
        result.append(TargetOption(id: "default", kind: .fallback, label: "下载器默认目录", detail: "由下载器按自身设置决定保存位置；不会自动整理入库"))
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let reason = request.reason {
                        notice(reason, tone: Theme.warning)
                    }
                    if let error {
                        notice(error, tone: Theme.danger)
                    }
                    if permissions.isAdmin {
                        smartSection
                    }
                    if (showOther && loadingDownloaders) || (!permissions.isAdmin && memberLibraries == nil) {
                        DiscoverSkeletonBlock(cornerRadius: 12).frame(height: 52)
                    }
                    ForEach(options) { option in
                        optionRow(option)
                    }
                    // 收在自动入库选项之后：点完候选，视线从条目直接落到入库结论
                    if permissions.isAdmin, !showOther {
                        Button {
                            showOther = true
                        } label: {
                            Label("其他保存位置", systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("download-other-targets")
                    }
                    if showOther, downloaders.count >= 2 {
                        Picker("下载器", selection: Binding(mcGet: { downloaderId ?? -1 }, set: { id in
                            downloaderId = id
                            reloadManualTarget(downloaderId: id, candidate: selectedCandidate, hint: hint)
                        })) {
                            ForEach(downloaders, id: \.id) { d in
                                Text(d.name + (d.isDefault ? "（默认）" : "")).tag(d.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    if permissions.isAdmin {
                        Toggle(isOn: $remember) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("记住本次选择，作为「\(TorrentCategories.label(request.category))」的默认位置")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.text)
                                Text(remember
                                    ? "之后点「下载」先给你确认一次落点，随时可以改，或在确认条上「不再记住」。"
                                    : "不勾选就只对这一次下载生效，不会留下默认位置。")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textFaint)
                            }
                        }
                        .padding(12)
                        .cardStyle(radius: 12)
                        .accessibilityIdentifier("download-remember")
                    }
                    if permissions.isAdmin, showOther {
                        Button {
                            dismiss()
                            router.push(.settingsSection(.downloaders))
                        } label: {
                            Text("movieclaw 与下载器不在同一容器/主机、看到的路径不同？到「设置 → 下载器」配置路径映射，提交时会自动翻译成下载器视角。")
                                .font(.caption)
                                .foregroundStyle(Theme.textFaint)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Theme.pagePadding)
            }
            .background(Theme.background)
            .navigationTitle("选择保存位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "提交中…" : confirmTitle) { submit() }
                        .discoverProminentButton()
                        .disabled(busy || selected == nil)
                        .accessibilityIdentifier("download-confirm")
                }
            }
        }
        .discoverContainer("download-target-sheet")
        .task {
            guard !initialized else { return }
            initialized = true
            guard permissions.isAdmin else {
                // 成员版：只拉自己可见的库，不碰下载器配置与智能入库预检
                memberLibraries = (try? await api.libraryList(scope: "all")) ?? []
                autoSelect()
                return
            }
            remember = remembered != nil
            hint = request.hint
            hintDraft = request.hint ?? ""
            picking = request.identity == nil
            // 有线索时先问「这是哪部」，目录收在「其他保存位置」里：摊开的目录会被默认选中，
            // 用户一点确认就下进了不会自动入库的目录
            showOther = !canResolve || (remembered != nil && remembered?.kind != "smart")
            if remembered?.kind == "smart" { downloaderId = remembered?.downloaderId }
            if canResolve {
                // 不挂在 .task 上：弹窗入场时会被移除再挂回一次，.task 随之取消，而 initialized 挡住了重试
                let rememberedId = remembered?.kind == "smart" ? remembered?.downloaderId : nil
                await Task { await runPreflight(downloaderId: rememberedId, candidate: nil, hint: request.hint, initial: true) }.value
            }
            autoSelect()
        }
        .task(id: showOther) {
            guard showOther, !downloadersLoaded else { return }
            await loadDownloaders()
        }
        .onChange(of: options) { _, new in
            if let current = selected, !new.contains(where: { $0.id == current }) { selected = nil }
            autoSelect()
        }
    }

    private var confirmTitle: String {
        if selected == "smart", let name = manualTarget?.libraryName { return "下载到「\(name)」" }
        return "确认下载"
    }

    @ViewBuilder
    private var smartSection: some View {
        if picking {
            candidatePicker
        }
        if loadingTarget {
            HStack(spacing: 10) {
                ProgressView()
                Text(selectedCandidate != nil ? "正在预演自动入库…" : "正在识别影视条目并预演智能入库…").font(.caption).foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .padding(.horizontal, 14)
            .cardStyle(radius: 12)
        } else if let t = manualTarget {
            if t.status == "ready", !t.ok {
                notice("已识别资源，但当前不能自动入库：\(t.warning ?? "请检查媒体库和自动入库配置。")", tone: Theme.warning)
            }
        } else if canResolve {
            notice("自动识别暂不可用；为避免投错库请手选保存目录后再下载。", tone: Theme.warning)
        }
    }

    /// 「这是哪部作品？」：候选来自种子标题的歧义结果 + 搜索词的 TMDB 检索；都不对就地换个词搜
    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("这是哪部作品？").font(.subheadline.weight(.medium)).foregroundStyle(Theme.text)
                Text(pickerCaption).font(.caption).foregroundStyle(Theme.textFaint)
            }
            if !candidates.isEmpty {
                DiscoverFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(candidates, id: \.self) { c in
                        DiscoverChip(
                            label: c.title + (c.year.map { " (\($0))" } ?? "") + " · " + (c.kind == "tv" ? "剧集" : "电影")
                                + (c.episodeCount.map { " · \($0) 集" } ?? ""),
                            active: selectedCandidate?.kind == c.kind && selectedCandidate?.tmdbId == c.tmdbId
                        ) {
                            selectedCandidate = c
                            reloadManualTarget(downloaderId: downloaderId, candidate: c, hint: hint)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                TextField(candidates.isEmpty ? "输入片名" : "都不对？换个片名搜", text: $hintDraft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit(searchHint)
                    .accessibilityIdentifier("download-hint-field")
                Button("搜索", action: searchHint)
                    .buttonStyle(.glass)
                    .disabled(hintDraft.trimmingCharacters(in: .whitespaces).isEmpty || loadingTarget)
            }
        }
        .padding(12)
        .background(Theme.warning.opacity(0.06), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.warning.opacity(0.2)))
    }

    private var pickerCaption: String {
        if !loadingTarget, manualTarget?.status == "not_found" {
            return hint.map { "没找到与「\($0)」匹配的作品，换个片名试试（中文名搜不到时可试英文/原名）。" }
                ?? "输入片名搜索，确认后会自动分配媒体库。"
        }
        return candidates.isEmpty
            ? "输入片名搜索，确认后会自动分配媒体库。"
            : "没能自动认出这条资源。点选正确的作品，媒体库会按收藏范围自动分配。"
    }

    private func searchHint() {
        let q = hintDraft.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        hint = q
        selectedCandidate = nil
        reloadManualTarget(downloaderId: downloaderId, candidate: nil, hint: q)
    }

    private func notice(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tone.opacity(0.95))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tone.opacity(0.1), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tone.opacity(0.25)))
    }

    private func optionRow(_ option: TargetOption) -> some View {
        Button {
            selected = option.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected == option.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected == option.id ? Theme.accentStrong : Theme.textFaint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: option.kind == .smart ? "sparkles" : "folder").foregroundStyle(Theme.accent.opacity(0.8))
                        Text(option.label).font(.subheadline.weight(.medium).monospaced()).foregroundStyle(Theme.text)
                    }
                    if let detail = option.detail {
                        Text(detail).font(.caption).foregroundStyle(Theme.textFaint).multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected == option.id ? Color.white.opacity(0.08) : Color.white.opacity(0.03), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected == option.id ? Color.white.opacity(0.25) : Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("download-option-\(option.id)")
        .accessibilityAddTraits(selected == option.id ? .isSelected : [])
    }

    // MARK: 数据

    private func runPreflight(downloaderId: Int?, candidate: API.ManualDownloadCandidateView?, hint: String?, initial: Bool = false) async {
        targetRequestId += 1
        let requestId = targetRequestId
        loadingTarget = true
        if !initial { manualTarget = nil }
        let identity = request.identity
        let target = try? await api.dlResolveTarget(body: .init(
            kind: identity?.kind, title: identity?.title, year: identity?.year,
            subtitle: request.subtitle, hint: hint, downloaderId: downloaderId,
            selectedTmdbId: candidate?.tmdbId, selectedKind: candidate?.kind
        ))
        guard requestId == targetRequestId else { return }
        manualTarget = target
        loadingTarget = false
        if let target { candidates = target.candidates }
        if initial, let target, target.status != "ready" { picking = true }
        // 有候选可点时目录继续收着；找不到/不能自动入库/识别不可用时才摊开目录兜底
        if target == nil || target?.status == "not_found" || (target?.status == "ready" && target?.ok != true) {
            showOther = true
        }
        // 用户刚点选了条目：直接选中随之出现的「自动入库」，不让选中项停在先前默认的目录上
        if candidate != nil, target?.status == "ready", target?.ok == true { selected = "smart" }
    }

    private func reloadManualTarget(downloaderId: Int?, candidate: API.ManualDownloadCandidateView?, hint: String?) {
        guard request.identity != nil || hint != nil else { return }
        Task { await runPreflight(downloaderId: downloaderId, candidate: candidate, hint: hint) }
    }

    /// 展开「其他保存位置」才读取下载器配置；最终选中的不是初始预检用的下载器时补一次预检
    private func loadDownloaders() async {
        loadingDownloaders = true
        let usable = ((try? await api.dlList()) ?? []).filter(\.usable)
        let current = usable.first { $0.id == downloaderId }
        let rememberedDownloader = remembered?.downloaderId.flatMap { id in usable.first { $0.id == id } }
        let chosen = current ?? rememberedDownloader ?? usable.first { $0.isDefault } ?? usable.first
        let preflightId = chosen.flatMap { $0.isDefault ? nil : $0.id }
        downloaders = usable
        let previous = downloaderId
        downloaderId = chosen?.id
        downloadersLoaded = true
        loadingDownloaders = false
        if canResolve, preflightId != previous {
            reloadManualTarget(downloaderId: preflightId, candidate: selectedCandidate, hint: hint)
        }
        autoSelect()
    }

    /// 默认选中：已记住的目标 > 智能入库可用 > 第一个目录 > 下载器默认；没有记忆时等两边都返回再选
    private func autoSelect() {
        let opts = options
        guard !opts.isEmpty, selected == nil else { return }
        if let remembered {
            let match = opts.first { o in
                remembered.kind == "dir" ? (o.kind == .dir && o.savePath == remembered.savePath)
                    : remembered.kind == "smart" ? o.kind == .smart : o.kind == .fallback
            }
            if let match { selected = match.id; return }
        }
        if !permissions.isAdmin {
            // 成员版：种子类型对得上的默认库 > 同类型第一个库 > 下载器默认目录
            let kind = request.identity?.kind
            let fit = (memberLibraries ?? []).filter { $0.kind == kind }
            let library = fit.first { $0.isDefault } ?? fit.first
            selected = library.map { "library:\($0.id)" } ?? "default"
            return
        }
        if loadingTarget || (showOther && !downloadersLoaded) { return }
        selected = (opts.first { $0.kind == .smart } ?? opts.first { $0.kind != .smart } ?? opts[0]).id
    }

    private func submit() {
        guard let option = options.first(where: { $0.id == selected }), !busy else { return }
        busy = true
        error = nil
        var payload = API.DownloadSubmitPayload(siteId: request.siteId, downloadUrl: request.downloadUrl)
        payload.torrentId = request.torrentId
        guard permissions.isAdmin else {
            // 成员版只带 library_id（+ 推导条目子目录用的片名年份）；不带目录 / 下载器 / 智能入库 / 记忆分类
            if option.kind == .library {
                payload.libraryId = option.libraryId
                payload.title = request.identity?.title
                payload.year = request.identity?.year
                payload.subtitle = request.subtitle
            }
            send(payload)
            return
        }
        // 只在非默认下载器时显式带 downloader_id：默认台走后端原有语义
        let pickedDownloaderId = downloader.map { $0.isDefault ? nil : $0.id } ?? downloaderId
        // 只有勾了「记住本次选择」才带分类：后端拿不到分类就不写记忆
        if remember { payload.category = request.category }
        // 身份一律取预检确认的结论：类型可能与种子解析的不同，标题是 TMDB 标题（会进条目别名）
        if option.kind == .smart, let t = manualTarget, let tmdbId = t.tmdbId, let kind = t.kind, let title = t.title {
            payload.autoRoute = true
            payload.mediaKind = kind
            payload.tmdbId = tmdbId
            payload.title = title
            payload.year = t.year
            payload.subtitle = request.subtitle
        }
        if option.kind == .dir { payload.savePath = option.savePath }
        if let pickedDownloaderId { payload.downloaderId = pickedDownloaderId }
        send(payload)
    }

    private func send(_ payload: API.DownloadSubmitPayload) {
        Task {
            do {
                let result = try await api.dlSubmit(body: payload)
                onSubmitted(result)
                dismiss()
            } catch {
                self.error = error.localizedDescription.isEmpty ? "提交失败，请重试" : error.localizedDescription
            }
            busy = false
        }
    }

    /// 与后端 translate_save_path 同规则（仅用于展示下载器视角）
    static func remoteView(_ path: String, _ mappings: [API.PathMapping]?) -> String {
        guard let mappings else { return path }
        var best: API.PathMapping?
        for m in mappings {
            let local = DownloadTargetPrefs.trim(m.local)
            if path == local || path.hasPrefix(local + "/"), best.map({ local.count > DownloadTargetPrefs.trim($0.local).count }) ?? true {
                best = m
            }
        }
        guard let best else { return path }
        let local = DownloadTargetPrefs.trim(best.local)
        return DownloadTargetPrefs.trim(best.remote) + path.dropFirst(local.count)
    }
}

/// 保存位置确认条：命中记忆时点「下载」先弹它，提交前就看得见落点
/// （smart 记忆存的是策略不是路径，要重跑预检才知道这次落到哪）
struct DownloadConfirmSheet: View {
    let request: DownloadTargetRequest
    let target: API.DownloadTargetPrefView
    let onConfirm: () -> Void
    let onChange: () -> Void
    let onForget: () -> Void

    @Environment(\.api) private var api
    @State private var resolvedPath: String?
    @State private var preflighting = false
    @State private var busy = false
    /// 内容实测高度：弹层高度随内容自适应，长路径换行也不截断（同 Web break-all 自动换行）
    @State private var contentHeight: CGFloat = 250

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accentSoft, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text("保存到").font(.caption).tracking(1).foregroundStyle(Theme.textFaint)
                    HStack(spacing: 6) {
                        Text(TorrentCategories.label(request.category)).font(.headline).foregroundStyle(.white)
                        Text("·").foregroundStyle(Theme.textFaint)
                        Text(target.kind == "smart" ? "智能入库" : (target.downloaderName ?? "默认下载器"))
                            .font(.subheadline).foregroundStyle(Theme.textMuted)
                    }
                    if preflighting {
                        DiscoverSkeletonBlock(cornerRadius: 4).frame(height: 10).frame(maxWidth: 220)
                    } else {
                        Text(headline ?? "由下载器决定")
                            .font(.caption.monospaced())
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 4) {
                Text("上次用过 · \(SubsFormat.relative(target.updatedAt)) ·")
                Button("不再记住", action: onForget).underline()
            }
            .font(.caption)
            .foregroundStyle(Theme.textFaint)
            HStack(spacing: 10) {
                Button("更改", action: onChange)
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                Button(busy ? "提交中…" : "确认下载") {
                    busy = true
                    onConfirm()
                }
                .discoverProminentButton()
                .disabled(busy || preflighting)
                .accessibilityIdentifier("download-confirm-remembered")
            }
        }
        .padding(20)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(contentHeight)])
        .task {
            guard target.kind == "smart", let identity = request.identity else { return }
            preflighting = true
            let t = try? await api.dlResolveTarget(body: .init(kind: identity.kind, title: identity.title, year: identity.year, subtitle: request.subtitle, downloaderId: target.downloaderId))
            resolvedPath = t?.entryDir ?? t?.path
            preflighting = false
        }
    }

    private var headline: String? {
        switch target.kind {
        case "dir": target.savePath
        case "default": "下载器的默认目录"
        default: resolvedPath
        }
    }
}

nonisolated extension APIClient {
    /// 按记住的目标直接提交（确认条的「确认下载」）。smart 记忆每次重跑身份确认与投递预检；
    /// 未收敛或有警示时返回 nil，调用方据此展开完整弹窗并说明原因——绝不把不确定的资源静默放进默认库。
    func submitRememberedDownload(_ request: DownloadTargetRequest, target: API.DownloadTargetPrefView) async throws -> API.DownloadSubmitView? {
        var payload = API.DownloadSubmitPayload(siteId: request.siteId, downloadUrl: request.downloadUrl)
        payload.torrentId = request.torrentId
        payload.category = request.category
        if target.kind == "smart" {
            guard let identity = request.identity,
                  let resolved = try? await dlResolveTarget(body: .init(kind: identity.kind, title: identity.title, year: identity.year, subtitle: request.subtitle, downloaderId: target.downloaderId)),
                  resolved.ok, resolved.status == "ready", let tmdbId = resolved.tmdbId else { return nil }
            payload.autoRoute = true
            payload.mediaKind = identity.kind
            payload.tmdbId = tmdbId
            payload.title = identity.title
            payload.year = identity.year
            payload.subtitle = request.subtitle
        }
        if target.kind == "dir" { payload.savePath = target.savePath }
        if let id = target.downloaderId { payload.downloaderId = id }
        return try await dlSubmit(body: payload)
    }
}
