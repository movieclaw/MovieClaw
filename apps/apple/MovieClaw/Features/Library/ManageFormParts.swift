import PhotosUI
import SwiftUI

// 媒体库表单（`LibraryFormSheet`）的零件，逐个对应 Web `library-form-dialog.tsx` 里的子组件：
// RootsEditor / ScopeEditor / AccessScopeEditor / CoverEditor / SwitchRow。全部是 Form 行，
// 由表单按分区嵌进 Section。

// MARK: - 收藏范围可选项

/// `GET /libraries/routing-options` 的强类型视图（生成接口只给了任意 JSON 字典）。
///
/// 区域的展示顺序必须跟后端一致（大陆、香港、台湾、新加坡、日本…），而 JSON 对象解成 Swift 字典
/// 会丢顺序——所以国家表单独从原始响应里按出现顺序扫出来，其余数组字段正常解码。
struct ManageRoutingOptions: Sendable {
    struct Genre: Decodable, Hashable, Sendable { let id: Int; let label: String }
    struct Preset: Decodable, Hashable, Sendable { let key: String; let label: String; let countries: [String] }

    var movieGenres: [Genre]
    var tvGenres: [Genre]
    var regionPresets: [Preset]
    /// 国家码 → 中文名，按后端顺序
    var countries: [(code: String, name: String)]

    func countryName(_ code: String) -> String { countries.first { $0.code == code }?.name ?? code }

    /// 类型可选项：电影取电影类型表，其余取剧集类型表
    func genres(for kind: String) -> [Genre] { kind == "movie" ? movieGenres : tvGenres }

    /// 区域码折叠成展示名：整组命中的折叠成预设组名（如「日韩」），折不进组的逐个显示中文名
    func regionLabels(_ regions: [String]) -> [String] {
        var parts: [String] = []
        var rest = regions
        for preset in regionPresets where preset.countries.allSatisfy(rest.contains) {
            parts.append(preset.label)
            rest.removeAll { preset.countries.contains($0) }
        }
        return parts + rest.map(countryName)
    }

    /// 模块级缓存：后端静态常量，表单每次打开不必重拉；失败清空，下次重试
    @MainActor private static var cached: ManageRoutingOptions?

    @MainActor
    static func load(_ api: APIClient) async -> ManageRoutingOptions? {
        if let cached { return cached }
        do {
            var request = URLRequest(url: api.url("/libraries/routing-options"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let data = try await api.perform(request)
            let parsed = try parse(data)
            cached = parsed
            return parsed
        } catch {
            return nil
        }
    }

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let movieGenres: [Genre]
            let tvGenres: [Genre]
            let regionPresets: [Preset]
            enum CodingKeys: String, CodingKey {
                case movieGenres = "movie_genres", tvGenres = "tv_genres", regionPresets = "region_presets"
            }
        }
        let data: Body
    }

    static func parse(_ data: Data) throws -> ManageRoutingOptions {
        let body = try JSONDecoder().decode(Envelope.self, from: data).data
        return ManageRoutingOptions(
            movieGenres: body.movieGenres, tvGenres: body.tvGenres, regionPresets: body.regionPresets,
            countries: orderedCountries(data)
        )
    }

    /// 从原始 JSON 里按出现顺序扫出 `country_names` 对象的键值（值按 JSON 字符串解码，兼容转义）
    private static func orderedCountries(_ data: Data) -> [(code: String, name: String)] {
        guard let text = String(data: data, encoding: .utf8),
              let start = text.range(of: "\"country_names\"") else { return [] }
        let tail = text[start.upperBound...]
        guard let open = tail.firstIndex(of: "{"), let close = tail[open...].firstIndex(of: "}") else { return [] }
        let object = String(tail[open ... close])
        guard let regex = try? NSRegularExpression(pattern: #""([^"\\]+)"\s*:\s*("(?:[^"\\]|\\.)*")"#) else { return [] }
        let ns = object as NSString
        return regex.matches(in: object, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let code = ns.substring(with: m.range(at: 1))
            let literal = ns.substring(with: m.range(at: 2))
            guard let name = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)) else { return nil }
            return (code, name)
        }
    }
}

/// 收藏范围 ↔ 表单状态（v1 两个维度：类型 ID / 区域国家码）
enum ManageMatchRules {
    static func parse(_ rules: [[String: API.JSONValue]]) -> (genres: [Int], regions: [String]) {
        func values(_ field: String) -> [API.JSONValue] {
            guard let rule = rules.first(where: { $0["field"]?.stringValue == field }),
                  case let .array(items) = rule["values"] else { return [] }
            return items
        }
        let genres = values("genres").compactMap { v -> Int? in if case let .int(i) = v { return i }; return nil }
        let regions = values("origin_countries").compactMap { v -> String? in if case let .string(s) = v { return s }; return nil }
        return (genres, regions)
    }

    /// 空维度不生成条件；两者都空 = 不声明
    static func build(genres: [Int], regions: [String]) -> [[String: API.JSONValue]] {
        var rules: [[String: API.JSONValue]] = []
        if !genres.isEmpty {
            rules.append(["field": .string("genres"), "op": .string("any_of"), "values": .array(genres.map { .int($0) })])
        }
        if !regions.isEmpty {
            rules.append(["field": .string("origin_countries"), "op": .string("any_of"), "values": .array(regions.map { .string($0) })])
        }
        return rules
    }

    /// 类型 ID 只保留当前库类型下有效的（切换过类型时另一类型独有的 ID 不带进声明）
    static func validGenres(kind: String, genres: [Int], options: ManageRoutingOptions?) -> [Int] {
        guard let options else { return genres }
        let valid = Set(options.genres(for: kind).map(\.id))
        return genres.filter(valid.contains)
    }

    /// 收藏范围的一句话摘要：「日韩 / 美国 的 动画 / 喜剧」；都没选 =「未声明」
    static func summary(kind: String, regions: [String], genres: [Int], options: ManageRoutingOptions?) -> (declared: Bool, text: String) {
        guard let options else {
            let declared = !regions.isEmpty || !genres.isEmpty
            return (declared, declared ? String(localized: .libraryFormScopeSet) : String(localized: .libraryFormScopeUnset))
        }
        let parts = [
            options.regionLabels(regions).joined(separator: " / "),
            options.genres(for: kind).filter { genres.contains($0.id) }.map(\.label).joined(separator: " / "),
        ].filter { !$0.isEmpty }
        return parts.isEmpty ? (false, String(localized: .libraryFormScopeUnset)) : (true, parts.joined(separator: String(localized: .libraryFormScopeJoiner)))
    }
}

// MARK: - 根目录

/// 根目录列表：第一项为主根（新内容落盘位置）；行内可原位更改（从该路径开始重选）、设为主根、移除。
/// 服务器目录选择器复用设置模块的 `SettingsBDirectoryPicker`（`GET /fs/browse`，只读）。
struct ManageRootsEditor: View {
    @Binding var roots: [String]

    /// 目录选择器的目标：追加，或原位更改某一项
    private enum PickTarget: Identifiable {
        case add
        case replace(Int)
        var id: String {
            switch self {
            case .add: "add"
            case let .replace(i): "replace-\(i)"
            }
        }
    }

    @State private var target: PickTarget?

    var body: some View {
        ForEach(Array(roots.enumerated()), id: \.element) { index, root in
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(Theme.accent.opacity(0.8))
                Button {
                    target = .replace(index)
                } label: {
                    Text(root)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .expandedHitArea(vertical: 10)
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: .libraryFormChangeFolderAria))
                if index == 0 {
                    Text(String(localized: .libraryFormPrimaryRoot))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: .capsule)
                } else {
                    Button(String(localized: .libraryFormMakePrimary)) { roots = [root] + roots.filter { $0 != root } }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.textMuted)
                }
                Button {
                    roots.removeAll { $0 == root }
                } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: .libraryFormRemoveEntry(root)))
            }
        }
        Button {
            target = .add
        } label: {
            Label(roots.isEmpty ? String(localized: .libraryFormBrowseServer) : String(localized: .libraryFormAddFolder), systemImage: "plus")
                .font(.subheadline.weight(.medium))
        }
        .accessibilityIdentifier("form-add-root")
        .sheet(item: $target) { target in
            SettingsBDirectoryPicker(initialPath: initialPath(target)) { path in pick(path, target) }
                .sheetFeedback()
        }
    }

    /// 追加时从最近添加的根起步，更改时从被改的根起步
    private func initialPath(_ target: PickTarget) -> String? {
        switch target {
        case .add: roots.last
        case let .replace(i): roots.indices.contains(i) ? roots[i] : nil
        }
    }

    /// 追加去重；更改为原位替换（改主根仍是主根），撞上已有路径时合并去重
    private func pick(_ path: String, _ target: PickTarget) {
        switch target {
        case .add:
            if !roots.contains(path) { roots.append(path) }
        case let .replace(i):
            var next = roots
            guard next.indices.contains(i) else { return }
            next[i] = path
            roots = next.enumerated().filter { $0.element != path || $0.offset == i }.map(\.element)
        }
    }
}

// MARK: - 收藏范围

/// 收藏范围：区域逐国勾选（预设组是一键整组的快捷键）+ 类型多选，两个维度间是「且」
struct ManageScopeEditor: View {
    let kind: String
    @Binding var regions: [String]
    @Binding var genres: [Int]
    let options: ManageRoutingOptions?

    var body: some View {
        if let options {
            let genreOptions = options.genres(for: kind)
            let allCountries = options.countries.map(\.code)
            // 已选中但不在内置映射里的码补进列表，保证选了就能看见、能取消
            let countryChips = options.countries + regions.filter { c in !allCountries.contains(c) }.map { ($0, $0) }
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: .libraryFormMatchRegions)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textMuted)
                ManageFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(countryChips, id: \.code) { item in
                        ManageToggleChip(title: item.name, on: regions.contains(item.code)) {
                            toggle(&regions, item.code)
                        }
                    }
                }
                ManageFlow(spacing: 6, lineSpacing: 6) {
                    Text(String(localized: .libraryFormRegionPresets)).font(.caption).foregroundStyle(Theme.textFaint)
                    let allOn = allCountries.allSatisfy(regions.contains)
                    ManageToggleChip(title: allOn ? String(localized: .commonClear) : String(localized: .commonSelectAll), on: false, small: true) {
                        regions = allOn ? [] : regions + allCountries.filter { !regions.contains($0) }
                    }
                    ForEach(options.regionPresets, id: \.key) { preset in
                        let active = preset.countries.allSatisfy(regions.contains)
                        ManageToggleChip(title: preset.label, on: active, small: true) {
                            regions = active ? regions.filter { !preset.countries.contains($0) } : regions + preset.countries.filter { !regions.contains($0) }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: .libraryFormMatchGenres)).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textMuted)
                ManageFlow(spacing: 6, lineSpacing: 6) {
                    let allOn = genreOptions.allSatisfy { genres.contains($0.id) }
                    ManageToggleChip(title: allOn ? String(localized: .commonClear) : String(localized: .commonSelectAll), on: false, small: true) {
                        genres = allOn ? [] : genres + genreOptions.map(\.id).filter { !genres.contains($0) }
                    }
                    ForEach(genreOptions, id: \.id) { genre in
                        ManageToggleChip(title: genre.label, on: genres.contains(genre.id)) {
                            toggle(&genres, genre.id)
                        }
                    }
                }
                if !regions.isEmpty, !genres.isEmpty {
                    (Text(String(localized: .libraryFormBothLead)) + Text(String(localized: .libraryFormBothEmphasis)).foregroundStyle(Theme.textMuted).fontWeight(.medium)
                    + Text(String(localized: .libraryFormBothTail)))
                        .font(.caption)
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.vertical, 4)
        } else {
            Text(String(localized: .libraryFormLoadingOptions)).font(.subheadline).foregroundStyle(Theme.textFaint)
        }
    }

    private func toggle<T: Equatable>(_ list: inout [T], _ value: T) {
        if let i = list.firstIndex(of: value) { list.remove(at: i) } else { list.append(value) }
    }
}

/// 可多选的芯片（区域 / 类型 / 预设组）
struct ManageToggleChip: View {
    let title: String
    let on: Bool
    var small = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(small ? .caption.weight(.medium) : .footnote.weight(.medium))
                .foregroundStyle(on ? Color.black.opacity(0.85) : Theme.textMuted)
                .padding(.horizontal, small ? 10 : 12)
                .padding(.vertical, small ? 4 : 6)
                .background(on ? AnyShapeStyle(Theme.accentStrong) : AnyShapeStyle(Color.white.opacity(0.05)), in: .capsule)
                .overlay(Capsule().strokeBorder(on ? .clear : Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - 可见范围

/// 可见范围编辑器（docs/design/library-access.md 2.1）：
/// 「所有成员」= 对全部成员自动开放（含以后新建的）；「指定成员」= 只对勾选的人开放，
/// 名单第一项固定是「超管（我自己）」——超管不是成员，单独存在 admin_visible 上，但对用户就是同一份名单。
/// 管理权与浏览权分离：超管把自己摘掉后仍能管理这个库，只是看不到内容。
/// Web 是可搜索的多选下拉；手机上直接铺成带搜索框的勾选列表（成员多时也能筛）。
struct ManageAccessEditor: View {
    @Binding var mode: String
    @Binding var adminVisible: Bool
    @Binding var memberIds: [Int]

    @Environment(\.api) private var api
    @State private var members: [API.MemberView]?
    @State private var query = ""

    var body: some View {
        Picker(String(localized: .libraryFormAccessScope), selection: $mode) {
            Text(String(localized: .libraryFormAllMembers)).tag("everyone")
            Text(String(localized: .libraryFormSelectedMembers)).tag("selected")
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("form-access-mode")
        Text(mode == "everyone"
            ? String(localized: .libraryFormEveryoneHint)
            : String(localized: .libraryFormSelectedHint))
            .font(.caption)
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
        if mode == "selected" {
            TextField(String(localized: .libraryFormViewerPlaceholder), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
            if let members {
                let options = [(id: -1, label: String(localized: .libraryFormAdminSelf), hint: String(localized: .libraryFormYourself))]
                    + members.map { (id: $0.id, label: $0.nickname.isEmpty ? $0.username : $0.nickname, hint: "@\($0.username)") }
                let keyword = query.trimmingCharacters(in: .whitespaces).lowercased()
                let matches = options.filter { keyword.isEmpty || $0.label.lowercased().contains(keyword) || $0.hint.lowercased().contains(keyword) }
                if matches.isEmpty {
                    Text(String(localized: .libraryFormNoMembersMatch)).font(.caption).foregroundStyle(Theme.textFaint)
                }
                ForEach(matches, id: \.id) { option in
                    let on = option.id == -1 ? adminVisible : memberIds.contains(option.id)
                    Button {
                        if option.id == -1 {
                            adminVisible.toggle()
                        } else if on {
                            memberIds.removeAll { $0 == option.id }
                        } else {
                            memberIds.append(option.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.square.fill" : "square")
                                .foregroundStyle(on ? Theme.accent : Theme.textFaint)
                            Text(option.label).foregroundStyle(Theme.text)
                            Spacer()
                            Text(option.hint).font(.caption).foregroundStyle(Theme.textFaint)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .accessibilityIdentifier("form-viewer-\(option.id)")
                }
            } else {
                Text(String(localized: .libraryFormLoadingMembers)).font(.caption).foregroundStyle(Theme.textFaint)
                    .task { await loadMembers() }
            }
        }
        if mode == "selected", !adminVisible, memberIds.isEmpty {
            Text(String(localized: .libraryFormNoViewersWarning))
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadMembers() async {
        let rows = (try? await api.membersList()) ?? []
        members = rows.filter { $0.status == "active" }
    }

    /// 可见范围的一句话摘要（编辑表单的分区摘要行）
    static func summary(mode: String, adminVisible: Bool, memberCount: Int) -> String {
        if mode == "everyone" { return String(localized: .libraryFormAllMembers) }
        let parts = [adminVisible ? String(localized: .libraryFormMyself) : nil, memberCount > 0 ? String(localized: .libraryFormMemberCount(memberCount)) : nil].compactMap { $0 }
        return parts.isEmpty ? String(localized: .libraryFormNoSelectedViewers) : String(localized: .libraryFormSelectedViewers(parts.joined(separator: " + ")))
    }
}

// MARK: - 封面

/// 封面编辑器：上传一张自己的图顶掉服务端自动拼贴的「氛围光货架」（issue #427）。
///
/// 与表单里其它字段不同，封面**上传即生效**、不等「保存」——它是一次文件传输而不是表单字段，
/// 攒到保存再传只会让失败反馈来得更晚。上传前先在本地压一道（长边 1600 的 JPEG），省流量、也避开
/// 10MB 上限；服务端还会再归一化一次，那才是真正的保证。
struct ManageCoverEditor: View {
    let libraryId: Int
    @Binding var custom: Bool

    @Environment(\.api) private var api
    @State private var picked: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?
    /// 换图后让预览真的重取：地址里的版本号变了，图片缓存才不会命中旧图
    @State private var stamp = Int(Date.now.timeIntervalSince1970)

    var body: some View {
        // 加载失败写「暂无封面」（同 Web），不是一个意义不明的图标
        MeasuredRemoteImage(raw: "/libraries/\(libraryId)/cover?v=\(stamp)", aspect: 21 / 10, placeholderText: String(localized: .libraryFormNoCover))
            .aspectRatio(21 / 10, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        VStack(alignment: .leading, spacing: 6) {
            Text(custom
                ? String(localized: .libraryFormCustomCoverHint)
                : String(localized: .libraryFormAutoCoverHint))
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
            Text(String(localized: .libraryFormCoverHint))
                .font(.caption)
                .foregroundStyle(Theme.textFaint)
        }
        .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
            PhotosPicker(selection: $picked, matching: .images) {
                Text(busy ? String(localized: .libraryFormProcessingCover) : custom ? String(localized: .libraryFormReplaceCover) : String(localized: .libraryFormUploadCover)).font(.subheadline.weight(.medium))
            }
            .buttonStyle(.glass)
            .disabled(busy)
            .accessibilityIdentifier("form-cover-upload")
            if custom {
                Button(String(localized: .libraryFormRestoreAutoCover)) { Task { await restore() } }
                    .font(.subheadline)
                    .buttonStyle(.glass)
                    .disabled(busy)
                    .accessibilityIdentifier("form-cover-restore")
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        if let error {
            Text(error).font(.caption).foregroundStyle(Theme.danger)
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        busy = true
        error = nil
        defer {
            busy = false
            picked = nil
        }
        do {
            guard let raw = try await item.loadTransferable(type: Data.self), let jpeg = Self.compress(raw) else {
                error = String(localized: .libraryFormImageReadFailed)
                return
            }
            let _: [String: API.JSONValue] = try await api.upload(
                "/libraries/\(libraryId)/cover",
                file: (name: "file", filename: "cover.jpg", mimeType: "image/jpeg", data: jpeg)
            )
            stamp += 1
            custom = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restore() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await api.libraryCoverClear(libraryId: libraryId)
            stamp += 1
            custom = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 长边压到 1600 以内再编码成 JPEG（同 Web `fileToCompressedJpeg`）
    private static func compress(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > 1600 ? 1600 / longest : 1
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - 开关行

/// 开关行：一句话标题 + ⓘ 长说明（点开气泡）+ 开关；长篇解释不常驻表单
struct ManageSwitchRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var identifier: String

    @State private var showDetail = false

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.medium))
                Button {
                    showDetail = true
                } label: {
                    Image(systemName: "info.circle").font(.footnote).foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(String(localized: .libraryFormAboutSetting(title)))
                .popover(isPresented: $showDetail) {
                    Text(detail)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                        .frame(width: 300)
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
