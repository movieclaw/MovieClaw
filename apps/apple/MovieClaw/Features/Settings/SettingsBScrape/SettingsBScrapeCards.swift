import SwiftUI

// 刮削设置编辑器和媒体库覆盖编辑器共用的原生表单行。

/// 卡片清单：顺序、标题、说明、覆盖判定所用的后端字段名都与 Web 一致
enum SettingsBScrapeCard: String, CaseIterable, Identifiable {
    case metaLanguage, certCountry, sources, poster, backdrop, logo, quality, naming, mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .metaLanguage: String(localized: .settingsScrapeMetadataLanguage)
        case .certCountry: String(localized: .settingsMembersAccessContentRating)
        case .sources: String(localized: .settingsScrapeImageSources)
        case .logo: String(localized: .settingsScrapeTitleLogo)
        case .poster: String(localized: .settingsScrapePoster)
        case .backdrop: String(localized: .settingsAppearanceBackdropTab)
        case .quality: String(localized: .settingsScrapeCardsQuality)
        case .naming: String(localized: .settingsScrapeNamingTemplates)
        case .mirror: String(localized: .settingsScrapeMediaDirectoryWrites)
        }
    }

    var desc: String {
        switch self {
        case .metaLanguage:
            String(localized: .settingsScrapeCardsLanguagesHint)
        case .certCountry:
            String(localized: .settingsScrapeContentRatingHint)
        case .sources:
            String(localized: .settingsScrapeCardsImagesHint)
        case .logo:
            String(localized: .settingsScrapeCardsLogoHint)
        case .poster:
            String(localized: .settingsScrapePosterHint)
        case .backdrop:
            String(localized: .settingsScrapeCardsBackdropHint)
        case .quality:
            String(localized: .settingsScrapeCardsQualityHint)
        case .naming:
            String(localized: .settingsScrapeNamingHint)
        case .mirror:
            String(localized: .settingsScrapeCardsMirrorHint)
        }
    }

    /// 本卡片管的后端字段（用于判定「N 个库已覆盖」）
    var keys: [String] {
        switch self {
        case .metaLanguage: ["language_priority"]
        case .certCountry: ["cert_country_priority"]
        case .sources: ["fanart_enabled", "poster_source_order", "backdrop_source_order", "logo_source_order", "season_poster_source_order"]
        case .logo: ["logo_language_priority"]
        case .poster: ["poster_mode", "poster_language_priority"]
        case .backdrop: ["backdrop_language_priority"]
        case .quality: ["poster_min_width", "backdrop_min_width", "poster_size", "backdrop_size", "still_size", "profile_size", "image_quality"]
        case .naming: SettingsBScrapeNaming.fields.map(\.key)
        case .mirror: SettingsBScrapeMirrorRow.all.map(\.key)
        }
    }

    /// 服务端支持部分更新；只提交当前编辑项，保留其他分类和新版本新增的字段。
    func payload(_ s: API.MetadataScrapeSetting) -> API.MetadataScrapeSettingInput {
        API.MetadataScrapeSettingInput(
            languagePriority: self == .metaLanguage ? s.languagePriority : nil,
            certCountryPriority: self == .certCountry ? s.certCountryPriority : nil,
            posterMode: self == .poster ? s.posterMode : nil,
            posterLanguagePriority: self == .poster ? s.posterLanguagePriority : nil,
            backdropLanguagePriority: self == .backdrop ? s.backdropLanguagePriority : nil,
            posterMinWidth: self == .quality ? s.posterMinWidth : nil,
            backdropMinWidth: self == .quality ? s.backdropMinWidth : nil,
            posterSize: self == .quality ? s.posterSize : nil,
            backdropSize: self == .quality ? s.backdropSize : nil,
            stillSize: self == .quality ? s.stillSize : nil,
            profileSize: self == .quality ? s.profileSize : nil,
            imageQuality: self == .quality ? s.imageQuality : nil,
            logoLanguagePriority: self == .logo ? s.logoLanguagePriority : nil,
            fanartEnabled: self == .sources ? s.fanartEnabled : nil,
            posterSourceOrder: self == .sources ? s.posterSourceOrder : nil,
            backdropSourceOrder: self == .sources ? s.backdropSourceOrder : nil,
            logoSourceOrder: self == .sources ? s.logoSourceOrder : nil,
            seasonPosterSourceOrder: self == .sources ? s.seasonPosterSourceOrder : nil,
            namingEntryDir: self == .naming ? s.namingEntryDir : nil,
            namingMovieFile: self == .naming ? s.namingMovieFile : nil,
            namingSeasonDir: self == .naming ? s.namingSeasonDir : nil,
            namingEpisodeFile: self == .naming ? s.namingEpisodeFile : nil,
            mirrorImages: self == .mirror ? s.mirrorImages : nil,
            mirrorNfo: self == .mirror ? s.mirrorNfo : nil,
            mirrorEpisodeThumbs: self == .mirror ? s.mirrorEpisodeThumbs : nil
        )
    }

    func summary(_ s: API.MetadataScrapeSetting) -> String {
        switch self {
        case .metaLanguage: SettingsBScrapeSummary.metaLanguage(s)
        case .certCountry: SettingsBScrapeSummary.certCountry(s)
        case .sources: s.fanartEnabled == true ? String(localized: .settingsScrapeCardsSourcesBoth) : String(localized: .settingsScrapeCardsSourcesTmdb)
        case .logo: (s.logoLanguagePriority ?? ["meta", "en", "orig", "null"]).map { id in
            SettingsBScrapeCatalog.commonImageLangs.first { $0.id == id }?.name ?? id
        }.joined(separator: " → ")
        case .poster: SettingsBScrapeSummary.poster(s)
        case .backdrop: SettingsBScrapeSummary.backdrop(s)
        case .quality: SettingsBScrapeSummary.quality(s)
        case .naming: SettingsBScrapeSummary.naming(s)
        case .mirror: SettingsBScrapeSummary.mirror(s)
        }
    }
}

// MARK: - 海报模式

/// 海报：两种选图模式（单选）+ 按语言模式下才可编辑的语言优先级
struct SettingsBScrapePosterRows: View {
    @Binding var setting: API.MetadataScrapeSetting
    let extraImageLangs: [SettingsBScrapeChipOption]

    private let modes: [(id: String, title: String, desc: String)] = [
        ("default", String(localized: .settingsScrapeTmdbDefault), String(localized: .settingsScrapeDefaultPosterDescription)),
        ("language", String(localized: .settingsScrapeLanguagePoster), String(localized: .settingsScrapeLanguagePosterDescription)),
    ]

    var body: some View {
        ForEach(modes, id: \.id) { mode in
            Button {
                setting.posterMode = mode.id
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mode.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                        Text(mode.id == "default" && setting.fanartEnabled == true
                             ? String(localized: .settingsScrapeCardsPosterCompare) : mode.desc).font(.caption).foregroundStyle(Theme.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .opacity(setting.posterMode == mode.id ? 1 : 0)
                        .foregroundStyle(setting.posterMode == mode.id ? Theme.accent : Theme.textFaint)
                        .font(.title3)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("scrape-poster-mode-\(mode.id)")
            .accessibilityAddTraits(setting.posterMode == mode.id ? .isSelected : [])
        }
        SettingsBScrapeOrderChips(
            options: SettingsBScrapeCatalog.commonImageLangs,
            extraOptions: extraImageLangs,
            moreLabel: String(localized: .settingsAppearanceLanguage),
            value: $setting.posterLanguagePriority,
            max: 4,
            primaryTag: String(localized: .settingsScrapePreferred),
            identifier: "scrape-poster-lang"
        )
        // Fanart 启用时，默认 TMDB 海报也需要按语言与 Fanart 候选比较。
        .disabled(setting.posterMode != "language" && setting.fanartEnabled != true)
        .opacity(setting.posterMode == "language" || setting.fanartEnabled == true ? 1 : 0.4)
    }
}

// MARK: - 画质与门槛

/// 「本地图片画质」四档单选 + 「最低分辨率门槛」（docs/design/image-sizing.md §8.1）。
///
/// 画质管的是**存多大**：刮削时下载到本地的图片尺寸，看图时各设备再按需从本地图缩出合适的宽度；
/// 门槛管的是**选哪张**（过滤模糊候选图），两件事分开摆。
/// - 选中哪一档：设置里 `imageQuality` 非空就用它；没选过（老配置、新装）看后端反推的 `effective.imageQuality`
///   ——四个档位都空是新默认「原图」，显式保存过档位的落在某个预设上就是那一档，否则是「自定义」；
/// - 选了预设时后端忽略四个档位字段，所以只有「自定义」才展开四个下拉；
/// - 每档旁边是按当前媒体库估算的磁盘占用（`scrapeStorageEstimate`），自定义只在它就是当前生效档时给得出数。
struct SettingsBScrapeQualityRows: View {
    @Binding var setting: API.MetadataScrapeSetting
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 档位留空时的生效值（库覆盖页传全局生效值）；`imageQuality` 是没选过档时界面该选中的那一档
    let effective: API.ScrapeEffectiveView?
    /// 各档的磁盘估算；拿不到就不写
    var estimate: API.ImageStorageEstimateView?
    /// 库覆盖页：留空跟随的是全局设置（后端把库覆盖里的空值当「没覆盖」）
    var inheritsGlobal = false

    /// 界面上选中的档
    private var selected: String {
        if !setting.imageQuality.isEmpty { return setting.imageQuality }
        if let inferred = effective?.imageQuality, !inferred.isEmpty { return inferred }
        return "original"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: .settingsScrapeLocalQuality)).font(.body.weight(.medium))
            Text(String(localized: .settingsScrapeCardsQualityPickerHint))
                .font(.caption).foregroundStyle(Theme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)

        ForEach(SettingsBScrapeCatalog.imageQualities) { quality in
            qualityRow(quality)
        }

        if selected == "custom" {
            VStack(alignment: .leading, spacing: 4) {
                sizePicker(String(localized: .settingsScrapePoster), \.posterSize, SettingsBScrapeCatalog.posterSizes, effective?.posterSize, id: "scrape-poster-size")
                sizePicker(String(localized: .settingsScrapeBackdrop), \.backdropSize, SettingsBScrapeCatalog.backdropSizes, effective?.backdropSize, id: "scrape-backdrop-size")
                sizePicker(String(localized: .settingsScrapeStill), \.stillSize, SettingsBScrapeCatalog.stillSizes, effective?.stillSize, id: "scrape-still-size")
                sizePicker(String(localized: .settingsProfileAvatar), \.profileSize, SettingsBScrapeCatalog.profileSizes, effective?.profileSize, id: "scrape-profile-size")
            }
            .padding(.vertical, 4)
        }

        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: .settingsScrapeMinResolution)).font(.body.weight(.medium))
                Text(String(localized: .settingsScrapeCardsThresholdHint))
                    .font(.caption).foregroundStyle(Theme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            widthField(String(localized: .settingsScrapePoster), \.posterMinWidth, id: "scrape-poster-min-width")
            widthField(String(localized: .settingsScrapeBackdrop), \.backdropMinWidth, id: "scrape-backdrop-min-width")
        }
        .padding(.vertical, 4)
    }

    /// 一档：名称 + 估算，下面一句说明，右边单选圈
    private func qualityRow(_ quality: SettingsBScrapeCatalog.ImageQuality) -> some View {
        let isSelected = selected == quality.id
        return Button {
            select(quality.id)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(quality.title).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                        if let bytes = estimatedBytes(quality.id) {
                            Text(String(localized: .settingsScrapeCardsEstimate(inheritsGlobal ? String(localized: .settingsScrapeCardsSiteWide) : "", Self.gigabytes(bytes))))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    Text(quality.desc).font(.caption).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textFaint)
                    .font(.title3)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("scrape-image-quality-\(quality.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 切档。切到「自定义」时把还空着的档位填成当前生效值：否则四个下拉都是「跟随」，
    /// 看不出刚才那一档具体是多大，保存后的行为也跟着环境变量变
    private func select(_ id: String) {
        var next = setting
        next.imageQuality = id
        if id == "custom", let effective {
            if next.posterSize.isEmpty { next.posterSize = effective.posterSize }
            if next.backdropSize.isEmpty { next.backdropSize = effective.backdropSize }
            if next.stillSize.isEmpty { next.stillSize = effective.stillSize }
            if next.profileSize.isEmpty { next.profileSize = effective.profileSize }
        }
        setting = next
    }

    /// 某一档的估算字节数：预设直接查表；自定义只在它就是当前生效档时有数（档位改了要保存后才重算）
    private func estimatedBytes(_ id: String) -> Int? {
        guard let estimate else { return nil }
        if let bytes = estimate.presets[id] { return bytes }
        return id == "custom" && estimate.currentQuality == "custom" ? estimate.currentBytes : nil
    }

    /// 「2.6 GB」「850 MB」：估算只是量级参考，GB 保留一位小数、MB 取整
    static func gigabytes(_ bytes: Int) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return "\(max(1, Int((Double(bytes) / 1_048_576).rounded()))) MB"
    }

    /// 宽度门槛输入：直接绑字符串代理，边打字边写回（空 / 非数字 = 0 = 不限制）
    private func widthField(_ label: String, _ keyPath: WritableKeyPath<API.MetadataScrapeSetting, Int>, id: String) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            Text(String(localized: .settingsScrapeCardsMinWidth(label))).foregroundStyle(Theme.textMuted)
            TextField("0", text: Binding(
                get: { String(setting[keyPath: keyPath]) },
                set: { setting[keyPath: keyPath] = Int($0.filter(\.isNumber)) ?? 0 }
            ))
            .keyboardType(.numberPad)
            .monospacedDigit()
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            .accessibilityLabel(String(localized: .settingsScrapeCardsMinWidthAria(label)))
            .accessibilityIdentifier(id)
        }
    }

    /// 留空选项的文案：库覆盖页是「跟随全局」；全局页是「跟随环境」，生效值只在确实留空时写出来
    /// ——选了具体档位时 effective 就是那个档位，不是环境变量的值
    private func inheritLabel(_ value: String, _ fallback: String) -> String {
        if inheritsGlobal { return String(localized: .settingsScrapeFollowValue(fallback)) }
        return value.isEmpty ? String(localized: .settingsScrapeCardsFollowEnvValue(fallback)) : String(localized: .settingsScrapeCardsFollowEnv)
    }

    private func sizePicker(
        _ label: String,
        _ keyPath: WritableKeyPath<API.MetadataScrapeSetting, String>,
        _ sizes: [String],
        _ fallback: String?,
        id: String
    ) -> some View {
        Picker(label, selection: $setting[dynamicMember: keyPath]) {
            Text(inheritLabel(setting[keyPath: keyPath], fallback ?? "")).tag("")
            ForEach(sizes, id: \.self) { Text($0).tag($0) }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier(id)
    }
}

// MARK: - 命名模板

/// 命名模板：四个模板输入 + 占位符点击插入 + 实时预览 + 恢复默认。
///
/// 占位符插入到「最后聚焦的输入框」的光标处（默认剧集文件名，同 Web），
/// 用 iOS 18 起的 `TextField(selection:)` 拿光标；插入后光标移到占位符之后并保持聚焦。
struct SettingsBScrapeNamingRows: View {
    @Binding var setting: API.MetadataScrapeSetting

    @FocusState private var focusedKey: String?
    @State private var lastFocused = "naming_episode_file"
    @State private var selections: [String: TextSelection] = [:]

    private var fields: [SettingsBScrapeNaming.Field] { SettingsBScrapeNaming.fields }
    private var errors: [String?] { fields.map { SettingsBScrapeNaming.error(for: $0, template: setting[keyPath: $0.keyPath]) } }
    private var focusedField: SettingsBScrapeNaming.Field { fields.first { $0.key == lastFocused } ?? fields[3] }

    var body: some View {
        ForEach(Array(fields.enumerated()), id: \.element.key) { index, field in
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(field.label).font(.subheadline.weight(.semibold))
                    if !field.note.isEmpty {
                        Text(field.note).font(.caption).foregroundStyle(Theme.textFaint)
                    }
                }
                TextField(field.fallback, text: $setting[dynamicMember: field.keyPath], selection: selectionBinding(field.key), axis: .vertical)
                    .font(.subheadline.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedKey, equals: field.key)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(errors[index] == nil ? Color.clear : Theme.danger.opacity(0.55)))
                    .accessibilityIdentifier("scrape-\(field.key)")
                if let error = errors[index] {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("scrape-\(field.key)-error")
                }
            }
            .padding(.vertical, 4)
        }

        Menu {
            ForEach(SettingsBScrapeNaming.tokenGroups, id: \.label) { group in
                let tokens = group.tokens.filter { focusedField.tokens.contains($0.key) }
                if !tokens.isEmpty {
                    SettingsFormSection(group.label) {
                        ForEach(tokens, id: \.key) { token in
                            Button(token.name) { insert(token.key) }
                                .accessibilityIdentifier("scrape-token-\(token.key)")
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: .settingsScrapeCardsInsertToken(focusedField.label)), systemImage: "plus.circle")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("scrape-token-menu")
        // 挂在单一行上（挂在 ForEach 上会被分发成每行一份）
        .onChange(of: focusedKey) { _, key in
            if let key { lastFocused = key }
        }

        preview

        Text(String(localized: .settingsScrapeCardsNamingHint))
            .font(.caption).foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 实时预览：两条样例路径（模板有误时只显示「✕ 模板有误」）
    private var preview: some View {
        let valid = errors.allSatisfy { $0 == nil }
        let tpl = { (key: String) in
            SettingsBScrapeNaming.effective(fields.first { $0.key == key }!, in: setting)
        }
        let movie = SettingsBScrapeNaming.sampleMovie
        let episode = SettingsBScrapeNaming.sampleEpisode
        let render = SettingsBScrapeNaming.render
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(String(localized: .settingsScrapeLivePreview)).font(.caption2).foregroundStyle(Theme.textFaint)
                Spacer()
                Text(valid ? String(localized: .settingsScrapeTemplateValid) : String(localized: .settingsScrapeTemplateInvalid))
                    .font(.caption)
                    .foregroundStyle(valid ? Theme.success : Theme.danger)
                    .accessibilityIdentifier("scrape-naming-validity")
            }
            if valid {
                previewLine(
                    caption: String(localized: .settingsScrapeMovieExample),
                    root: String(localized: .settingsScrapeMovieExampleRoot),
                    path: "\(render(tpl("naming_entry_dir"), movie))/\(render(tpl("naming_movie_file"), movie)).mkv",
                    id: "scrape-preview-movie"
                )
                previewLine(
                    caption: String(localized: .settingsScrapeEpisodeExample),
                    root: String(localized: .settingsScrapeEpisodeExampleRoot),
                    path: "\(render(tpl("naming_entry_dir"), episode))/\(render(tpl("naming_season_dir"), episode))/\(render(tpl("naming_episode_file"), episode)).mkv",
                    id: "scrape-preview-episode"
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func previewLine(caption: String, root: String, path: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(Theme.textFaint)
            Text("\(Text(root).foregroundStyle(Theme.textFaint))\(Text(path).foregroundStyle(Theme.accent))")
                .font(.footnote.monospaced())
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(id)
        }
    }

    private func selectionBinding(_ key: String) -> Binding<TextSelection?> {
        Binding(mcGet: { selections[key] }, set: { selections[key] = $0 })
    }

    /// 在最后聚焦的输入框光标处插入占位符；输入框为空时以默认模板为底（同 Web：`setting[key] || fallback`）
    private func insert(_ token: String) {
        let field = focusedField
        let raw = setting[keyPath: field.keyPath]
        let current = raw.isEmpty ? field.fallback : raw
        let utf16 = current.utf16.count
        var start = utf16
        var end = utf16
        if !raw.isEmpty, let selection = selections[field.key], case let .selection(range) = selection.indices {
            start = min(max(range.lowerBound.utf16Offset(in: current), 0), utf16)
            end = min(max(range.upperBound.utf16Offset(in: current), start), utf16)
        }
        let ns = current as NSString
        let inserted = "{\(token)}"
        let next = ns.replacingCharacters(in: NSRange(location: start, length: end - start), with: inserted)
        setting[keyPath: field.keyPath] = next
        let caret = String.Index(utf16Offset: start + inserted.utf16.count, in: next)
        selections[field.key] = TextSelection(insertionPoint: caret)
        focusedKey = field.key
    }
}

// MARK: - 媒体目录写入

struct SettingsBScrapeMirrorRows: View {
    @Binding var setting: API.MetadataScrapeSetting

    var body: some View {
        ForEach(SettingsBScrapeMirrorRow.all, id: \.key) { row in
            Toggle(isOn: $setting[dynamicMember: row.keyPath]) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label).font(.body.weight(.medium))
                    Text(row.hint).font(.caption).foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityIdentifier("scrape-\(row.key)")
        }
    }
}
