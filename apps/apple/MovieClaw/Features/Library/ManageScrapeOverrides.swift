import SwiftUI

/// 「编辑库 → 刮削设置」（Web `library-scrape-settings.tsx`，设计见 docs/design/scrape-customization.md §14.5）。
///
/// 与全局设置页共用同一套卡片内控件（设置模块的 `SettingsBScrape*`），差别在外层：这里是手风琴，
/// 每张卡的折叠头直接写「跟随全局：…」/「自定义：…」——「我这个库到底改了哪几项」是这个页面最该一眼回答的问题。
///
/// 三态怎么表达（同 Web）：
/// - 排序芯片与数字输入没有「空值」可表达跟随，用**卡片级**「跟随全局 / 自定义」开关；切到自定义时拿全局当前值做种子，
///   跟随时控件只读（看得见全局值，改不动）；
/// - 命名模板留空即跟随；
/// - 目录写入是「跟随全局 / 开 / 关」三档。
///
/// 覆盖对象的语义与后端一致：**只存显式覆盖的字段**，空对象 = 全跟全局。
/// 实现上把全局设置编码成 JSON 字典、叠加本库覆盖再解回 `MetadataScrapeSetting` 交给共用控件渲染；
/// 控件改动后只把该卡片管的字段写回覆盖对象。
struct ManageScrapeOverrides: View {
    @Binding var overrides: [String: API.JSONValue]

    @Environment(\.api) private var api
    @State private var config: API.ScrapeConfigView?
    @State private var error: String?
    @State private var open: String?
    @State private var languages: [API.LanguageOption] = []
    @State private var countries: [API.CountryOption] = []
    /// 本地图片画质各档的磁盘估算（全站口径，拿不到不写）
    @State private var estimate: API.ImageStorageEstimateView?

    /// 卡片级三态的五张卡
    private static let followCards: [SettingsBScrapeCard] = [.metaLanguage, .certCountry, .poster, .backdrop, .quality]

    /// 卡片所在分节的标题（只在该节第一张卡前出现）
    private static func groupTitle(before card: SettingsBScrapeCard) -> String? {
        switch card {
        case .metaLanguage: String(localized: .libraryFormMetadata)
        case .poster: String(localized: .libraryFormImages)
        default: nil
        }
    }

    private static let namingFields: [(key: String, label: String, fallback: String)] = [
        ("naming_entry_dir", String(localized: .settingsScrapeEntryDirectory), "{title} ({year})"),
        ("naming_movie_file", String(localized: .settingsScrapeMovieFilename), "{title} ({year})"),
        ("naming_season_dir", String(localized: .settingsScrapeSeasonDirectory), "Season {season:02d}"),
        ("naming_episode_file", String(localized: .settingsScrapeEpisodeFilename), "{title} ({year}) - S{season:02d}E{episode:02d}"),
    ]

    private static let mirrorFields: [(key: String, label: String)] = [
        ("mirror_images", String(localized: .settingsScrapeMirrorImages)),
        ("mirror_nfo", String(localized: .settingsScrapeMirrorNfo)),
        ("mirror_episode_thumbs", String(localized: .settingsScrapeMirrorStills)),
    ]

    /// 全局基线：与设置页同一套「编辑态用生效值起步」的口径
    private var base: API.MetadataScrapeSetting? {
        guard var setting = config?.setting else { return nil }
        if setting.languagePriority.isEmpty, let effective = config?.effective.languagePriority {
            setting.languagePriority = effective
        }
        return setting
    }

    private var baseDict: [String: API.JSONValue] { base.flatMap(Self.encode) ?? [:] }

    /// 交给共用控件渲染的完整设置 = 全局基线叠加本库覆盖
    private var merged: API.MetadataScrapeSetting? {
        guard base != nil else { return nil }
        return Self.decode(baseDict.merging(overrides) { _, new in new })
    }

    var body: some View {
        if let error {
            Text(error).font(.subheadline).foregroundStyle(Theme.textMuted)
        } else if let merged, let base {
            content(merged: merged, base: base)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text(String(localized: .settingsScrapeGlobalLoading)).font(.subheadline).foregroundStyle(Theme.textMuted)
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func content(merged: API.MetadataScrapeSetting, base: API.MetadataScrapeSetting) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(localized: .settingsScrapeLibraryIntro))
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !overrides.isEmpty {
                Text(String(localized: .settingsScrapeOverrideCount(overrides.count)))
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Theme.accentSoft, in: .capsule)
                    .fixedSize()
            }
        }
        // 一键回到全跟随：否则想撤掉本库的全部个性化得逐张卡切「跟随全局」+ 逐个模板清空
        if !overrides.isEmpty {
            Button(String(localized: .settingsScrapeResetOverrides)) { overrides = [:] }
                .font(.footnote)
                .accessibilityIdentifier("form-scrape-reset")
        }

        // 四个分节同 Web ScrapeSection：元数据 / 图片 / 命名与整理 / 目录写入
        ForEach(Self.followCards) { card in
            if let group = Self.groupTitle(before: card) { ManageScrapeGroupTitle(text: group) }
            followCard(card, merged: merged, base: base)
        }
        ManageScrapeGroupTitle(text: String(localized: .libraryFormNaming))
        namingCard(base: base)
        ManageScrapeGroupTitle(text: String(localized: .libraryFormFolderWrites))
        mirrorCard(base: base)

        (Text(String(localized: .libraryScrapeOwnerLead)) + Text(String(localized: .libraryScrapeOwnerEmphasis)).foregroundStyle(Theme.textMuted).fontWeight(.medium)
                + Text(String(localized: .libraryScrapeOwnerTail)))
            .font(.caption)
            .foregroundStyle(Theme.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 卡片级三态

    @ViewBuilder
    private func followCard(_ card: SettingsBScrapeCard, merged: API.MetadataScrapeSetting, base: API.MetadataScrapeSetting) -> some View {
        let custom = card.keys.contains { overrides[$0] != nil }
        cardHeader(id: card.rawValue, title: card.title, customized: custom,
                   status: custom ? String(localized: .settingsScrapeCustomStatus(card.summary(merged))) : String(localized: .settingsScrapeFollowStatus(card.summary(base))))
        if open == card.rawValue {
            Text(card.desc).font(.footnote).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Text(String(localized: .settingsScrapeGlobalSummary(card.summary(base)))).font(.caption).foregroundStyle(Theme.textFaint).lineLimit(2)
                Spacer(minLength: 4)
                Picker(String(localized: .settingsScrapeInherit), selection: Binding(
                    get: { custom },
                    set: { next in
                        var patched = overrides
                        for key in card.keys {
                            if next { patched[key] = baseDict[key] } else { patched.removeValue(forKey: key) }
                        }
                        overrides = patched
                    }
                )) {
                    Text(String(localized: .settingsScrapeFollowGlobal)).tag(false)
                    Text(String(localized: .subscriptionSmartCustomWait)).tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("form-scrape-follow-\(card.rawValue)")
            }
            // 跟随全局时控件只读：看得见全局值长什么样，但改不动
            Group {
                switch card {
                case .metaLanguage:
                    SettingsBScrapeOrderChips(
                        options: SettingsBScrapeCatalog.commonMetaLangs,
                        extraOptions: SettingsBScrapeCatalog.extraMetaLangs(languages),
                        moreLabel: String(localized: .libraryFiltersLanguage), value: binding(card)[dynamicMember: \.languagePriority],
                        max: 3, primaryTag: String(localized: .settingsScrapePrimaryLanguage), identifier: "form-scrape-meta-lang"
                    )
                case .certCountry:
                    SettingsBScrapeOrderChips(
                        options: SettingsBScrapeCatalog.commonCertCountries,
                        extraOptions: SettingsBScrapeCatalog.extraCountries(countries),
                        moreLabel: String(localized: .libraryFiltersRegions), value: binding(card)[dynamicMember: \.certCountryPriority],
                        max: 6, primaryTag: "", identifier: "form-scrape-cert-country"
                    )
                case .poster:
                    SettingsBScrapePosterRows(setting: binding(card), extraImageLangs: SettingsBScrapeCatalog.extraImageLangs(languages))
                case .backdrop:
                    SettingsBScrapeOrderChips(
                        options: SettingsBScrapeCatalog.commonImageLangs,
                        extraOptions: SettingsBScrapeCatalog.extraImageLangs(languages),
                        moreLabel: String(localized: .libraryFiltersLanguage), value: binding(card)[dynamicMember: \.backdropLanguagePriority],
                        max: 4, primaryTag: String(localized: .settingsScrapePreferred), identifier: "form-scrape-backdrop-lang"
                    )
                case .quality:
                    SettingsBScrapeQualityRows(setting: binding(card), effective: config?.effective, estimate: estimate, inheritsGlobal: true)
                default:
                    EmptyView()
                }
            }
            .disabled(!custom)
            .opacity(custom ? 1 : 0.45)
        }
    }

    /// 一张卡的设置绑定：读合成值；写时只把这张卡管的字段写回覆盖对象
    private func binding(_ card: SettingsBScrapeCard) -> Binding<API.MetadataScrapeSetting> {
        Binding(
            get: { merged ?? base ?? Self.emptySetting },
            set: { next in
                guard let dict = Self.encode(next) else { return }
                var patched = overrides
                for key in card.keys { patched[key] = dict[key] }
                overrides = patched
            }
        )
    }

    // MARK: 字段级三态

    @ViewBuilder
    private func namingCard(base: API.MetadataScrapeSetting) -> some View {
        let hit = Self.namingFields.filter { overrides[$0.key] != nil }
        cardHeader(id: "naming", title: String(localized: .settingsScrapeNamingTemplates), customized: !hit.isEmpty,
                   status: hit.isEmpty ? String(localized: .settingsScrapeFollowGlobal) : String(localized: .settingsScrapeCustomStatus(AppFormatting.list(hit.map(\.label)))))
        if open == "naming" {
            Text(String(localized: .settingsScrapeLibraryNamingHint))
                .font(.footnote).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            ForEach(Self.namingFields, id: \.key) { field in
                let globalValue = baseDict[field.key]?.stringValue ?? ""
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.caption).foregroundStyle(Theme.textMuted)
                    TextField(String(localized: .libraryScrapeFollowGlobalValue(globalValue.isEmpty ? field.fallback : globalValue)), text: Binding(
                        get: { overrides[field.key]?.stringValue ?? "" },
                        set: { value in
                            if value.trimmingCharacters(in: .whitespaces).isEmpty {
                                overrides.removeValue(forKey: field.key)
                            } else {
                                overrides[field.key] = .string(value)
                            }
                        }
                    ))
                    .font(.footnote.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("form-scrape-\(field.key)")
                }
            }
        }
    }

    @ViewBuilder
    private func mirrorCard(base: API.MetadataScrapeSetting) -> some View {
        let hit = Self.mirrorFields.filter { overrides[$0.key] != nil }
        cardHeader(id: "mirror", title: String(localized: .settingsScrapeMediaDirectoryWrites), customized: !hit.isEmpty,
                   status: hit.isEmpty ? String(localized: .settingsScrapeFollowGlobal) : String(localized: .settingsScrapeCustomStatus(AppFormatting.list(hit.map(\.label)))))
        if open == "mirror" {
            Text(String(localized: .settingsScrapeLibraryMirrorHint))
                .font(.footnote).foregroundStyle(Theme.textMuted).fixedSize(horizontal: false, vertical: true)
            ForEach(Self.mirrorFields, id: \.key) { field in
                let globalOn = baseDict[field.key]?.boolValue ?? true
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.label).font(.subheadline)
                    Picker(field.label, selection: Binding<Int>(
                        get: {
                            guard let value = overrides[field.key]?.boolValue else { return 0 }
                            return value ? 1 : 2
                        },
                        set: { choice in
                            switch choice {
                            case 1: overrides[field.key] = .bool(true)
                            case 2: overrides[field.key] = .bool(false)
                            default: overrides.removeValue(forKey: field.key)
                            }
                        }
                    )) {
                        Text(String(localized: .libraryScrapeFollowGlobalValue(globalOn ? String(localized: .settingsScrapeOn) : String(localized: .libraryScrapeOff)))).tag(0)
                        Text(String(localized: .settingsScrapeOn)).tag(1)
                        Text(String(localized: .agentThinkingOff)).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("form-scrape-\(field.key)")
                }
            }
        }
    }

    // MARK: 折叠头

    private func cardHeader(id: String, title: String, customized: Bool, status: String) -> some View {
        Button {
            withAnimation(.snappy) { open = open == id ? nil : id }
        } label: {
            HStack(spacing: 10) {
                Circle().fill(customized ? Theme.accent : Color.white.opacity(0.2)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(customized ? Theme.text : Theme.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(open == id ? 180 : 0))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("form-scrape-card-\(id)")
    }

    // MARK: 数据

    private func load() async {
        do {
            config = try await api.scrapeShow()
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription.isEmpty ? String(localized: .settingsScrapeGlobalLoadFailed) : error.localizedDescription
        }
        // 语种 / 地区全量表拉不到不阻断（「更多」面板回落只显示常用项）
        languages = (try? await api.scrapeLanguages()) ?? []
        countries = (try? await api.scrapeCountries()) ?? []
        estimate = try? await api.scrapeStorageEstimate()
    }

    /// 仅作绑定兜底（加载成功前不会渲染卡片）
    private static let emptySetting = API.MetadataScrapeSetting(
        languagePriority: [], certCountryPriority: [], posterMode: "default",
        posterLanguagePriority: [], backdropLanguagePriority: [], posterMinWidth: 0, backdropMinWidth: 0,
        posterSize: "", backdropSize: "", stillSize: "", profileSize: "", imageQuality: "",
        namingEntryDir: "", namingMovieFile: "", namingSeasonDir: "", namingEpisodeFile: "",
        mirrorImages: true, mirrorNfo: true, mirrorEpisodeThumbs: true
    )

    static func encode(_ setting: API.MetadataScrapeSetting) -> [String: API.JSONValue]? {
        guard let data = try? JSONEncoder().encode(setting) else { return nil }
        return try? JSONDecoder().decode([String: API.JSONValue].self, from: data)
    }

    static func decode(_ dict: [String: API.JSONValue]) -> API.MetadataScrapeSetting? {
        guard let data = try? JSONEncoder().encode(dict) else { return nil }
        return try? JSONDecoder().decode(API.MetadataScrapeSetting.self, from: data)
    }
}

/// 刮削覆盖里的分节标题（同 Web ScrapeSection 的小标题）
struct ManageScrapeGroupTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textFaint)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }
}
