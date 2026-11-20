import Foundation

nonisolated enum AppLanguage {
    static var identifier: String {
        normalize(Bundle.main.preferredLocalizations.first ?? "en")
    }

    static func normalize(_ language: String) -> String {
        let language = language.lowercased()
        if language.hasPrefix("zh") { return "zh-Hans" }
        if language == "de" || language.hasPrefix("de-") || language.hasPrefix("de_") { return "de" }
        return "en"
    }

    static var locale: Locale { Locale(identifier: identifier) }

    static var germanLocale: Locale? { identifier == "de" ? locale : nil }

    static var name: String {
        switch identifier {
        case "zh-Hans": "简体中文" // i18n-ignore: autonym is language data.
        case "de": "Deutsch"
        default: "English"
        }
    }
}
