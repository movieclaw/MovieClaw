import Foundation

nonisolated enum AppLanguage {
    static var identifier: String {
        normalize(Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func normalize(_ language: String) -> String {
        language.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    }

    static var locale: Locale { Locale(identifier: identifier) }

    // i18n-ignore: autonyms are language data.
    static var name: String { identifier == "zh-Hans" ? "简体中文" : "English" }
}
