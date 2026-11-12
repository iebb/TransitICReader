import Foundation

/// Hanica (Hankyu Bus / Hanshin Bus) keeps one FeliCa system, 84A1, with the bus
/// platform layout shared by Ryuto, ICa and Passca: a cyclic 16-byte log at service
/// 898F, newest record first. Bytes 0-4 pack the date with boarding and alighting
/// times, 5-6 and 7-8 hold bus-stop codes and byte 9 a record type. Across that
/// family the balance position and unit differ, and Hanica's own layout is not
/// publicly documented. A balance is therefore shown only when exactly one known
/// layout makes the log self-consistent; otherwise the card is recognised with its
/// balance unconfirmed.
enum HanicaCardFormat {
    static let systemCode = "84A1"
    static let service = Data([0x8F, 0x89])
    static let historyReadLimit = 20
    /// The largest stored value a Japanese bus IC card accepts.
    static let maximumBalanceYen = 30_000
    /// No fare or top-up is smaller. Whole-yen and 10-yen layouts share the same
    /// bytes, so this is what tells a 230-yen fare (raw 23 × 10) from 23 yen.
    static let minimumAmountYen = 50

    struct Layout: Equatable {
        let name: String
        let balanceOffset: Int
        let amountOffset: Int
        let unitYen: Int

        func balance(_ block: Data) -> Int { HanicaCardFormat.uint16(block, balanceOffset) * unitYen }
        func amount(_ block: Data) -> Int { HanicaCardFormat.uint16(block, amountOffset) * unitYen }

        var summary: String {
            let unit = unitYen == 1 ? "yen" : "units of \(unitYen) yen"
            return "\(name): balance bytes \(balanceOffset)-\(balanceOffset + 1), amount bytes "
                + "\(amountOffset)-\(amountOffset + 1), big-endian, \(unit)"
        }
    }

    static let ryutoStyle = Layout(name: "Ryuto-style", balanceOffset: 14, amountOffset: 10, unitYen: 1)
    static let passcaStyle = Layout(name: "Passca-style", balanceOffset: 14, amountOffset: 10, unitYen: 10)
    static let icaStyle = Layout(name: "ICa-style", balanceOffset: 13, amountOffset: 10, unitYen: 1)
    static let layouts = [ryutoStyle, passcaStyle, icaStyle]

    struct Record {
        let boardingDate: Date?
        let date: Date?
        let boardingStop: String
        let alightingStop: String
        let typeCode: UInt8

        var hasValidDates: Bool { boardingDate != nil && date != nil }
        var isTopUpType: Bool { typeCode == 0x55 }
        var isRideType: Bool { typeCode == 0x52 }
    }

    /// Amount and balance of one record under a confirmed layout.
    struct Value {
        let amount: Int
        let balance: Int
        let isTopUp: Bool
    }

    /// A read log block: a full 16 bytes that are not all zero.
    static func isLogBlock(_ block: Data) -> Bool {
        block.count == 16 && block.contains { $0 != 0 }
    }

    static func decode(_ data: Data) -> Record? {
        guard isLogBlock(data) else { return nil }
        let b = [UInt8](data)
        let year = 2000 + Int(b[0] >> 1)
        let month = Int((b[0] & 1) << 3 | b[1] >> 5)
        let day = Int(b[1] & 31)
        let boardHour = Int((b[2] >> 2) & 31)
        let boardMinute = Int((b[2] & 3) << 4 | b[3] >> 4)
        let exitHour = Int((b[3] & 7) << 2 | b[4] >> 6)
        let exitMinute = Int(b[4] & 63)
        return Record(boardingDate: localDate(year, month, day, boardHour, boardMinute),
                      date: localDate(year, month, day, exitHour, exitMinute),
                      boardingStop: String(format: "%02X%02X", b[5], b[6]),
                      alightingStop: String(format: "%02X%02X", b[7], b[8]),
                      typeCode: b[9])
    }

    /// The only layout the log proves, or nil when none or several fit.
    /// `blocks` is newest first, as read from the cyclic service.
    static func detectLayout(_ blocks: [Data]) -> Layout? {
        let accepted = layouts.filter { accepts($0, blocks: blocks) }
        return accepted.count == 1 ? accepted[0] : nil
    }

    /// A layout fits when at least two consecutive pairs move the balance by exactly the
    /// newer record's amount, no dated pair contradicts it, every balance is within the
    /// stored-value limit and every proven amount is a plausible fare or top-up.
    static func accepts(_ layout: Layout, blocks: [Data]) -> Bool {
        let log = blocks.filter(isLogBlock)
        guard log.count >= 3, log.allSatisfy({ layout.balance($0) <= maximumBalanceYen }) else { return false }
        var consistent = 0
        for index in 0..<(log.count - 1) {
            let newer = log[index], older = log[index + 1]
            if direction(layout, newer: newer, older: older) != nil {
                guard layout.amount(newer) >= minimumAmountYen else { return false }
                consistent += 1
                continue
            }
            // A zero-amount record that leaves the balance unchanged neither proves nor refutes.
            if layout.amount(newer) == 0 && layout.balance(newer) == layout.balance(older) { continue }
            if decode(newer)?.hasValidDates == true && decode(older)?.hasValidDates == true { return false }
        }
        return consistent >= 2
    }

    /// True for a top-up, false for a fare, nil when the pair does not fit the layout.
    static func direction(_ layout: Layout, newer: Data, older: Data) -> Bool? {
        let amount = layout.amount(newer)
        guard amount > 0 else { return nil }
        let balance = layout.balance(newer), previous = layout.balance(older)
        if balance == previous - amount { return false }
        if balance == previous + amount { return true }
        return nil
    }

    /// Amount and balance of `blocks[index]` under `layout`; nil without a confirmed layout.
    static func value(at index: Int, in blocks: [Data], layout: Layout?) -> Value? {
        guard let layout, blocks.indices.contains(index), isLogBlock(blocks[index]) else { return nil }
        let block = blocks[index]
        let older = blocks.indices.contains(index + 1) ? blocks[index + 1] : nil
        let isTopUp = older.flatMap { isLogBlock($0) ? direction(layout, newer: block, older: $0) : nil }
            ?? (block[block.startIndex + 9] == 0x55)
        return Value(amount: layout.amount(block), balance: layout.balance(block), isTopUp: isTopUp)
    }

    /// The current balance in yen, from the newest record, when a layout is confirmed.
    static func confirmedBalance(_ blocks: [Data]) -> (layout: Layout, balance: Int)? {
        guard let layout = detectLayout(blocks), let newest = blocks.first, isLogBlock(newest) else { return nil }
        return (layout, layout.balance(newest))
    }

    private static func uint16(_ block: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 1 < block.count else { return 0 }
        let start = block.startIndex + offset
        return Int(block[start]) << 8 | Int(block[start + 1])
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
