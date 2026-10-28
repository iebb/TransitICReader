import Foundation

struct Localizer {
    static func localize(_ key: String, preferredLocale: String? = nil) -> String {
        let currentLocale = preferredLocale ?? Locale.current.language.languageCode?.identifier ?? "en"
        
        // Normalize locale to bundle names (en, ja, zh-Hans, ko)
        var lprojName = "en"
        if currentLocale.hasPrefix("ja") {
            lprojName = "ja"
        } else if currentLocale.hasPrefix("zh") {
            lprojName = "zh-Hans"
        } else if currentLocale.hasPrefix("ko") {
            lprojName = "ko"
        }
        
        // Attempt to load from the specific bundle using standard NSLocalizedString which handles caching well
        if let path = Bundle.main.path(forResource: lprojName, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
        }
        
        // Fallback to English
        if lprojName != "en",
           let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
        }
        
        return NSLocalizedString(key, value: key, comment: "")
    }
}
