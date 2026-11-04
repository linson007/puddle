import Foundation

public enum L10n {
    public static func text(_ key: String, locale: Locale? = nil) -> String {
        if let locale, let path = Bundle.module.path(forResource: locale.language.languageCode?.identifier ?? "en", ofType: "lproj"),
           let localized = Bundle(path: path) {
            return localized.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }
}
