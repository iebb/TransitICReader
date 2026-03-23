import Foundation

struct Localizer {
    static func localize(_ key: String, preferredLocale: String? = nil) -> String {
        let currentLocale = preferredLocale ?? Locale.current.language.languageCode?.identifier ?? "en"
        
        // Normalize locale to bundle names (en, ja, zh-Hans)
        var lprojName = "en"
        if currentLocale.hasPrefix("ja") {
            lprojName = "ja"
        } else if currentLocale.hasPrefix("zh") {
            lprojName = "zh-Hans"
        }
        
        // Attempt to load from the specific bundle
        if let path = Bundle.main.path(forResource: lprojName, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
            if localized != key {
                return localized
            }
        }
        
        // Fallback to English if the current locale bundle is missing the key
        if lprojName != "en",
           let path = Bundle.main.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            let localized = bundle.localizedString(forKey: key, value: nil, table: nil)
            if localized != key {
                return localized
            }
        }
        
        return key
    }
}
