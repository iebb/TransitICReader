import Foundation

enum CardTimeZonePreference: String {
    case current
    case issuer
}

struct CardDateFormatting {
    static func timeZonePreference() -> CardTimeZonePreference {
        let raw = UserDefaults.standard.string(forKey: "cardTimeZonePreference") ?? CardTimeZonePreference.issuer.rawValue
        return CardTimeZonePreference(rawValue: raw) ?? .issuer
    }

    static func issuerTimeZone(for brand: ICCardBrand) -> TimeZone? {
        switch brand.region {
        case .china:
            return TimeZone(identifier: "Asia/Shanghai")
        case .korea:
            return TimeZone(identifier: "Asia/Seoul")
        case .japan:
            return TimeZone(identifier: "Asia/Tokyo")
        case .hongkong:
            return TimeZone(identifier: "Asia/Hong_Kong")
        default:
            return nil
        }
    }

    static func displayTimeZone(for brand: ICCardBrand) -> TimeZone {
        switch timeZonePreference() {
        case .current:
            return .current
        case .issuer:
            return issuerTimeZone(for: brand) ?? .current
        }
    }

    static func calendar(for brand: ICCardBrand) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = issuerTimeZone(for: brand) ?? .current
        return calendar
    }

    static func date(year: Int?, month: Int?, day: Int?, hour: Int? = 0, minute: Int? = 0, second: Int? = 0, brand: ICCardBrand) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = issuerTimeZone(for: brand) ?? .current
        return calendar(for: brand).date(from: components)
    }

    static func parseCompactDateTime(_ value: String, format: String, brand: ICCardBrand) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar(for: brand)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = issuerTimeZone(for: brand) ?? .current
        formatter.dateFormat = format
        return formatter.date(from: value)
    }

    static func formatDisplayDate(_ date: Date, brand: ICCardBrand) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = displayTimeZone(for: brand)
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func formatDisplayDateTime(_ date: Date, brand: ICCardBrand, includeTime: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = displayTimeZone(for: brand)
        formatter.dateStyle = .short
        formatter.timeStyle = includeTime ? .medium : .none
        return formatter.string(from: date)
    }

    static func formatDisplayTime(_ date: Date, brand: ICCardBrand) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = displayTimeZone(for: brand)
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

struct KSX6924DateFormatting {
    static func formatBCDDateForDisplay(_ bcdDate: String?) -> String? {
        guard let bcdDate = bcdDate else { return nil }
        let parts = bcdDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return bcdDate }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        guard let date = Calendar.current.date(from: components) else { return bcdDate }
        let format = UserDefaults.standard.string(forKey: "dateFormat") ?? "yyyy-MM-dd"
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func formatRawDateForDisplay(_ date: Date, includeTime: Bool = true) -> String {
        let format = UserDefaults.standard.string(forKey: "dateFormat") ?? "yyyy-MM-dd"
        let formatter = DateFormatter()
        var combinedFormat = format
        if includeTime {
            combinedFormat += (format.contains("/") || format.contains("-")) ? " HH:mm:ss" : ", HH:mm:ss"
        }
        formatter.dateFormat = combinedFormat
        return formatter.string(from: date)
    }
}
