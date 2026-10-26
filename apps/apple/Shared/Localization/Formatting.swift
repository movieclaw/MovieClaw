import Foundation

nonisolated enum AppFormatting {
    static func number(_ value: Int, locale: Locale = AppLanguage.locale) -> String {
        value.formatted(.number.locale(locale))
    }

    static func dateTime(_ date: Date, locale: Locale = AppLanguage.locale) -> String {
        date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(locale))
    }

    static func relative(_ date: Date, now: Date = .now, locale: Locale = AppLanguage.locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func bytes(_ value: Int, locale: Locale = AppLanguage.locale) -> String {
        Int64(value).formatted(.byteCount(style: .binary).locale(locale))
    }

    static func duration(seconds: Int, locale: Locale = AppLanguage.locale) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(locale))
    }

    /// Inline list: Chinese keeps 「、」, other languages use a comma.
    static func list(_ items: [String]) -> String {
        items.joined(separator: AppLanguage.identifier == "zh-Hans" ? "、" : ", ")
    }

    /// Independent clauses in one line: Chinese 「；」, other languages "; ".
    static func clauses(_ items: [String]) -> String {
        items.joined(separator: AppLanguage.identifier == "zh-Hans" ? "；" : "; ")
    }

    /// Consecutive sentences: Chinese runs them together, other languages separate them with a space.
    static func sentences(_ items: [String]) -> String {
        items.filter { !$0.isEmpty }.joined(separator: AppLanguage.identifier == "zh-Hans" ? "" : " ")
    }

    static func runtime(minutes: Int) -> String {
        let hours = minutes / 60, remainder = minutes % 60
        if hours == 0 { return String(localized: .unitsDurationMinutesShort(remainder)) }
        if remainder == 0 { return String(localized: .unitsDurationHoursShort(hours)) }
        return String(localized: .unitsDurationHoursMinutes(hours, remainder))
    }
}
