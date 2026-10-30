import Foundation

/// Independently implemented from published Snapper+ wire-format facts:
/// https://github.com/metrodroid/metrodroid/wiki/Snapper
/// Reference revision b910c1806fd86aa545223baf1d21fc5afe68eee2 establishes
/// the 52-byte trip record (the wiki's decimal length contains a typo).
/// No reference-project implementation or card captures are included here.
enum SnapperPlusProtocol {
    static let applicationAID = "D4100000030001"
    static func normalizedSerial(_ serial: String?) -> String? {
        guard let serial else { return nil }
        let hex = serial.filter { !$0.isWhitespace }.uppercased()
        guard hex.count == 16, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              !hex.allSatisfy({ $0 == "0" }), !hex.allSatisfy({ $0 == "F" }) else { return nil }
        return stride(from: 0, to: 16, by: 4).map { offset in
            String(hex.dropFirst(offset).prefix(4))
        }.joined(separator: " ")
    }
    private static let envelope = Data([0x53, 0x50, 0x2B, 0x01])

    struct History {
        let transactionData: Data
        let tripData: Data?
        let recordNumber: Int
        let transactionType: Int
        let counter: UInt32
        let amountMinor: Int64
        let balanceMinor: Int64
        let operatorID: String?
        let timestamp: Date?
        let journeyID: Int?
        let sequence: Int?
        let isTapOn: Bool?
    }

    struct ReadResult {
        let balanceMinor: Int64
        let history: [Data]
        let transactions: [Int: Data]
        let trips: [Int: Data]
    }

    static func read(
        applicationAID aid: String, issuerID: UInt8?, balance: (Data, UInt8, UInt8),
        readRecord: (Int, Int) async -> (Data, UInt8, UInt8)?
    ) async -> ReadResult? {
        guard aid.uppercased() == applicationAID, issuerID == 2,
              let minor = balanceMinor(balance.0, sw1: balance.1, sw2: balance.2) else { return nil }
        var amounts: [Int: Data] = [:]
        for number in 1...20 {
            guard let response = await readRecord(number, 4), response.1 == 0x90, response.2 == 0,
                  !response.0.isEmpty, !response.0.allSatisfy({ $0 == 0 || $0 == 0xFF }) else { break }
            amounts[number] = response.0
        }
        guard matches(applicationAID: aid, issuerID: issuerID, transactionRecords: Array(amounts.values)) else { return nil }
        var trips: [Int: Data] = [:]
        var history: [Data] = []
        for number in amounts.keys.sorted() {
            let response = await readRecord(number, 3)
            let trip = response.flatMap { $0.1 == 0x90 && $0.2 == 0 ? $0.0 : nil }
            if let trip { trips[number] = trip }
            if let paired = encodeHistory(transaction: amounts[number]!, trip: trip, recordNumber: number) {
                history.append(paired)
            }
        }
        return ReadResult(balanceMinor: minor, history: history, transactions: amounts, trips: trips)
    }

    static func matches(applicationAID aid: String, issuerID: UInt8?, transactionRecords: [Data]) -> Bool {
        aid.uppercased() == applicationAID && issuerID == 0x02
            && !transactionRecords.isEmpty && transactionRecords.allSatisfy(isTransactionRecord)
    }

    static func isTransactionRecord(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        return bytes.count == 46 && (bytes[0] == 1 || bytes[0] == 2)
            && bytes[1] == 0x2C && bytes[26..<46].allSatisfy { $0 == 0xFF }
    }

    static func balanceMinor(_ payload: Data, sw1: UInt8, sw2: UInt8) -> Int64? {
        guard sw1 == 0x90, sw2 == 0, payload.count == 4 else { return nil }
        return signed32([UInt8](payload), at: 0)
    }

    static func purseIssuer(_ fci: Data) -> UInt8? {
        let bytes = [UInt8](fci)
        var issuers: [UInt8] = []
        func scan(_ start: Int, _ end: Int, _ depth: Int) -> Bool {
            guard depth <= 8 else { return false }
            var offset = start
            while offset < end {
                let tag = bytes[offset]; offset += 1
                if tag & 31 == 31 {
                    var count = 1
                    var next: UInt8
                    repeat {
                        count += 1
                        guard offset < end, count <= 4 else { return false }
                        next = bytes[offset]; offset += 1
                    } while next & 0x80 != 0
                }
                guard offset < end else { return false }
                let first = bytes[offset]; offset += 1
                var length = Int(first)
                if first >= 128 {
                    let count = Int(first & 127)
                    guard (1...3).contains(count), count <= end - offset else { return false }
                    length = 0
                    for _ in 0..<count { length = (length << 8) | Int(bytes[offset]); offset += 1 }
                }
                guard length <= end - offset else { return false }
                let next = offset + length
                if tag == 0xB0 {
                    guard length >= 47 else { return false }
                    issuers.append(bytes[offset + 3])
                } else if tag & 0x20 != 0, !scan(offset, next, depth + 1) { return false }
                offset = next
            }
            return true
        }
        guard scan(0, bytes.count, 0), issuers.count == 1 else { return nil }
        return issuers[0]
    }

    /// The original ISO record number is retained even when an invalid trip is
    /// omitted. Paired records must never be joined by filtered-array indexes.
    static func encodeHistory(transaction: Data, trip: Data?, recordNumber: Int) -> Data? {
        guard (1...255).contains(recordNumber), isTransactionRecord(transaction) else { return nil }
        // Preserve complete source bytes even when their wall time is invalid
        // or ambiguous; only the date interpretation is optional.
        let validTrip = trip.flatMap { isTripRecord($0) ? $0 : nil }
        var result = envelope
        result.append(UInt8(recordNumber))
        result.append(validTrip == nil ? 0 : 52)
        result.append(transaction)
        if let validTrip { result.append(validTrip) }
        return result
    }

    static func decodeHistory(_ data: Data) -> History? {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, data.prefix(4) == envelope,
              bytes[4] != 0, bytes[5] == 0 || bytes[5] == 52,
              bytes.count == 52 + Int(bytes[5]) else { return nil }
        let transaction = Data(bytes[6..<52])
        guard isTransactionRecord(transaction) else { return nil }
        let tx = [UInt8](transaction)
        let trip = bytes[5] == 52 ? Data(bytes[52..<104]) : nil
        if let trip, !isTripRecord(trip) { return nil }
        let date = trip.flatMap(tripDate)
        let t = trip.map { [UInt8]($0) }
        let cost = signed32(tx, at: 10)
        let agency = tx[14..<19].map { String(format: "%02X", $0) }.joined().prefix(9)
        return History(
            transactionData: transaction, tripData: trip,
            recordNumber: Int(bytes[4]), transactionType: Int(tx[0]), counter: unsigned32(tx, at: 6),
            amountMinor: tx[0] == 2 ? cost : -cost, balanceMinor: signed32(tx, at: 2),
            operatorID: agency.allSatisfy({ $0.isASCII && $0.isNumber }) ? String(agency) : nil,
            timestamp: date, journeyID: date == nil ? nil : t.map { Int($0[5]) },
            sequence: date == nil ? nil : t.map { Int($0[4]) },
            isTapOn: date == nil ? nil : t.map { ($0[51] & 0x10) != 0 }
        )
    }

    /// Supply incoming records first. A moving ring slot is not transaction
    /// identity; preserve complete SFI4 bytes and prefer a valid paired trip.
    /// Unknown envelopes remain available for future redecoding.
    static func mergeHistory(_ records: [String]) -> [String] {
        var result: [String] = []
        var known: [Data: (index: Int, quality: Int)] = [:]
        var unknown = Set<String>()
        for raw in records {
            guard let bytes = fromHex(raw), let history = decodeHistory(bytes) else {
                if unknown.insert(raw).inserted { result.append(raw) }
                continue
            }
            let quality = history.timestamp != nil ? 2 : (history.tripData != nil ? 1 : 0)
            if let previous = known[history.transactionData] {
                if quality > previous.quality {
                    result[previous.index] = raw
                    known[history.transactionData] = (previous.index, quality)
                }
            } else {
                known[history.transactionData] = (result.count, quality)
                result.append(raw)
            }
        }
        return result
    }

    private static func fromHex(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        func nibble(_ char: UInt8) -> UInt8? {
            switch char {
            case 48...57: return char - 48
            case 65...70: return char - 55
            case 97...102: return char - 87
            default: return nil
            }
        }
        var result = Data()
        for offset in stride(from: 0, to: chars.count, by: 2) {
            guard let high = nibble(chars[offset]), let low = nibble(chars[offset + 1]) else { return nil }
            result.append(high * 16 + low)
        }
        return result
    }

    private static func isTripRecord(_ data: Data) -> Bool {
        data.count == 52 && data[data.startIndex] == 1 && data[data.startIndex + 1] == 0x32
    }

    private static func tripDate(_ data: Data) -> Date? {
        let bytes = [UInt8](data)
        guard isTripRecord(data) else { return nil }
        let raw = Array(bytes[13..<20])
        guard raw.allSatisfy({ ($0 >> 4) <= 9 && ($0 & 15) <= 9 }),
              let zone = TimeZone(identifier: "Pacific/Auckland") else { return nil }
        let values = raw.map { Int($0 >> 4) * 10 + Int($0 & 15) }
        let year = values[0] * 100 + values[1]
        guard (2000...2199).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = DateComponents(year: year, month: values[2], day: values[3], hour: values[4], minute: values[5], second: values[6])
        guard let date = calendar.date(from: parts) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == parts.year, roundTrip.month == parts.month, roundTrip.day == parts.day,
              roundTrip.hour == parts.hour, roundTrip.minute == parts.minute, roundTrip.second == parts.second else { return nil }
        // A timestamp without a UTC offset cannot distinguish a repeated DST
        // hour. Preserve the amount while leaving that date unknown.
        let before = date.addingTimeInterval(-86400)
        let first = calendar.nextDate(after: before, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: before, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last)
        guard first == last else { return nil }
        return date
    }

    private static func unsigned32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func signed32(_ bytes: [UInt8], at offset: Int) -> Int64 {
        Int64(Int32(bitPattern: unsigned32(bytes, at: offset)))
    }
}
