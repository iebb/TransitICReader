import Foundation

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
