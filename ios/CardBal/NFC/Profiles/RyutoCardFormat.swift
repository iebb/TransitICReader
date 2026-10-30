import Foundation

/// Ryuto's public 16-byte log: local calendar, bus-stop codes and whole JPY.
/// Wire layout independently implemented from the MIT TRETJapanNFCReader reference.
enum RyutoCardFormat {
    static let systemCode = "8B5D"
    static let service = Data([0x8F, 0x89])
    struct Record {
        let boardingDate: Date
        let date: Date
        let boardingStop: String
        let alightingStop: String
        let amount: Int
        let balance: Int
        let isTopUp: Bool
    }
    static func decode(_ data: Data) -> Record? {
        guard data.count == 16, [0x52, 0x55].contains(data[9]) else { return nil }
        let year = 2000 + Int(data[0] >> 1)
        let month = Int((data[0] & 1) << 3 | data[1] >> 5)
        let day = Int(data[1] & 31)
        let boardHour = Int((data[2] >> 2) & 31)
        let boardMinute = Int((data[2] & 3) << 4 | data[3] >> 4)
        let exitHour = Int((data[3] & 7) << 2 | data[4] >> 6)
        let exitMinute = Int(data[4] & 63)
        guard let boarding = localDate(year, month, day, boardHour, boardMinute),
              let exit = localDate(year, month, day, exitHour, exitMinute) else { return nil }
        return Record(boardingDate: boarding, date: exit,
                      boardingStop: String(format: "%02X%02X", data[5], data[6]),
                      alightingStop: String(format: "%02X%02X", data[7], data[8]),
                      amount: Int(data[10]) << 8 | Int(data[11]),
                      balance: Int(data[14]) << 8 | Int(data[15]), isTopUp: data[9] == 0x55)
    }
    private static func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        guard let date = calendar.date(from: parts) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard actual.year == year, actual.month == month, actual.day == day, actual.hour == hour, actual.minute == minute else { return nil }
        return date
    }
}
