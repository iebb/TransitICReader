import Foundation

enum DateDisplayResolution {
    case date
    case minute
    case second
}

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
        if brand == .clipper { return TimeZone(identifier: "America/Los_Angeles") }
        switch brand.region {
        case .china:
            return TimeZone(identifier: "Asia/Shanghai")
        case .korea:
            return TimeZone(identifier: "Asia/Seoul")
        case .mongolia:
            return TimeZone(identifier: "Asia/Ulaanbaatar")
        case .japan:
            return TimeZone(identifier: "Asia/Tokyo")
        case .singapore:
            return TimeZone(identifier: "Asia/Singapore")
        case .hongkong:
            return TimeZone(identifier: "Asia/Hong_Kong")
        case .macau:
            return TimeZone(identifier: "Asia/Macau")
        case .newZealand:
            return TimeZone(identifier: "Pacific/Auckland")
        case .indonesia:
            return TimeZone(identifier: "Asia/Jakarta")
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

    static func formatDisplayDate(_ date: Date, brand: ICCardBrand, issuerTimeZone: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = timeZonePreference() == .issuer ? (issuerTimeZone.flatMap(TimeZone.init(identifier:)) ?? displayTimeZone(for: brand)) : .current
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func formatDisplayDateTime(_ date: Date, brand: ICCardBrand, includeTime: Bool) -> String {
        formatDisplayDateTime(date, brand: brand, resolution: includeTime ? .second : .date)
    }

    static func formatDisplayDateTime(_ date: Date, brand: ICCardBrand, resolution: DateDisplayResolution, issuerTimeZone: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = timeZonePreference() == .issuer ? (issuerTimeZone.flatMap(TimeZone.init(identifier:)) ?? displayTimeZone(for: brand)) : .current
        formatter.dateStyle = .short
        switch resolution {
        case .date:
            formatter.timeStyle = .none
        case .minute:
            formatter.timeStyle = .short
        case .second:
            formatter.timeStyle = .medium
        }
        return formatter.string(from: date)
    }

    static func formatDisplayTime(_ date: Date, brand: ICCardBrand) -> String {
        formatDisplayTime(date, brand: brand, resolution: .second)
    }

    static func formatDisplayTime(_ date: Date, brand: ICCardBrand, resolution: DateDisplayResolution, issuerTimeZone: String? = nil) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = timeZonePreference() == .issuer ? (issuerTimeZone.flatMap(TimeZone.init(identifier:)) ?? displayTimeZone(for: brand)) : .current
        formatter.dateStyle = .none
        formatter.timeStyle = resolution == .second ? .medium : .short
        return formatter.string(from: date)
    }

    static func resolution(forTimeText time: String?) -> DateDisplayResolution {
        guard let time else { return .date }
        let normalized = time.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "n/a" || normalized.contains("record #") {
            return .date
        }
        if time.range(of: #"(^|\D)\d{1,2}:\d{2}:\d{2}($|\D)"#, options: .regularExpression) != nil {
            return .second
        }
        if time.range(of: #"(^|\D)\d{1,2}:\d{2}($|\D)"#, options: .regularExpression) != nil {
            return .minute
        }
        return .date
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
