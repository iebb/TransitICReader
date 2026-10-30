import Foundation

/// Independent codec for the public CEPAS purse-3 wire fields, not a GPL port.
/// Facts: FareBot dc09f6f014ea3675b64bcd38335b4b78d77fa374, card/cepas and transit/ezlink.
/// Only on-card stored value is read. No SimplyGo backend/generation inference.
enum CEPASProtocol {
    static let purseID: UInt8 = 3
    static let issuerTimeZone = "Asia/Singapore"
    // Calculate the stated local epoch rather than FareBot's conflicting numeric
    // constant. Metrodroid b910c180 EZLinkTransitData + time/Timestamp confirm it.
    static let epoch: Int64 = 788_889_600 // 1995-01-01 00:00:00 Singapore
    private static let envelope = Data([0x43, 0x45, 0x50, 0x01, purseID])

    struct Purse {
        let family: String
        let serial: String // CAN, 16 BCD digits; stable across UID changes
        let chipSerial: String
        let version: Int
        let status: Int
        let balanceMinor: Int64
        let historyCount: Int
        let creationDate: Date
        let expiryDate: Date
        let raw: Data
    }

    enum Kind: String { case train, bus, topUp, refund, creation, purchase, service, unknown }

    struct History {
        let rawType: Int
        let kind: Kind
        let type: String
        let amountMinor: Int64 // signed cents, credits positive
        let hasMonetaryAmount: Bool
        let timestamp: Date?
        let userData: String?
        let record: Data
    }

    struct ReadResult {
        let purse: Purse
        let rawHistory: [Data]
        let historyComplete: Bool
        var family: String { purse.family }
        var serial: String { purse.serial }
        var balanceMinor: Int64 { purse.balanceMinor }
    }

    static func purseCommand() -> Data { Data([0x90, 0x32, purseID, 0, 0]) }
    static func historyCommand(offset: Int) -> Data? {
        guard (0...254).contains(offset) else { return nil }
        return Data([0x90, 0x32, purseID, 0, 1, UInt8(offset), 0])
    }

    /// Accept only complete legacy-layout Singapore purses with a known BCD CAN
    /// issuer. A successful status or plausible balance alone is insufficient.
    static func parsePurse(_ data: Data) -> Purse? {
        let b = Array(data)
        guard (63...256).contains(b.count), b[0] != 0, b[0] != 0xFF,
              63 + Int(b[41]) <= b.count,
              b[8..<16].allSatisfy({ $0 >> 4 <= 9 && $0 & 15 <= 9 }) else { return nil }
        let serial = b[8..<16].map { String(format: "%02X", $0) }.joined()
        let family: String
        if serial.hasPrefix("100") { family = "EZ-Link" }
        else if serial.hasPrefix("111") { family = "NETS FlashPay" }
        else { return nil }
        let created = Int64(unsigned(b, 26, 2)) * 86_400 + epoch
        let expires = Int64(unsigned(b, 24, 2)) * 86_400 + epoch
        return Purse(family: family, serial: serial,
            chipSerial: b[16..<24].map { String(format: "%02X", $0) }.joined(),
            version: Int(b[0]), status: Int(b[1]), balanceMinor: signed24(b, 2),
            historyCount: Int(b[40]), creationDate: Date(timeIntervalSince1970: TimeInterval(created)),
            expiryDate: Date(timeIntervalSince1970: TimeInterval(expires)), raw: data)
    }

    static func encodeHistory(_ record: Data) -> Data? {
        guard record.count == 16, record.contains(where: { $0 != 0 }),
              record.contains(where: { $0 != 0xFF }) else { return nil }
        return envelope + record
    }

    static func decodeHistory(_ data: Data) -> History? {
        guard data.count == 21, data.prefix(5) == envelope else { return nil }
        let record = Data(data.dropFirst(5))
        guard encodeHistory(record) != nil else { return nil }
        let b = Array(record)
        let rawType = Int(b[0])
        let kind: Kind
        let type: String
        switch rawType {
        case 0x30: kind = .train; type = "MRT"
        case 0x31: kind = .bus; type = "Bus"
        case 0x03, 0x75: kind = .topUp; type = "Top-up"
        case 0x76: kind = .refund; type = "Bus refund"
        case 0x05, 0xF0: kind = .creation; type = "Card creation"
        case 0x01: kind = .purchase; type = "Retail purchase"
        case 0x04: kind = .service; type = "Service charge"
        default: kind = .unknown; type = String(format: "CEPAS record 0x%02X", rawType)
        }
        let seconds = unsigned(b, 4, 4)
        let timestamp = seconds == 0 || seconds == UInt32.max ? nil
            : Date(timeIntervalSince1970: TimeInterval(epoch + Int64(seconds)))
        let user = Array(b[8..<16])
        let printable = user.allSatisfy { $0 == 0 || (0x20...0x7E).contains($0) }
        let userData = printable ? String(bytes: user.prefix(while: { $0 != 0 }), encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) : nil
        return History(rawType: rawType, kind: kind, type: type, amountMinor: signed24(b, 1),
            hasMonetaryAmount: kind != .creation, timestamp: timestamp,
            userData: userData?.isEmpty == false ? userData : nil, record: record)
    }

    /// GET PURSE and read-log requests only. Optional log failures never erase a
    /// validated balance. Offset addressing avoids array-index pairing guesses.
    static func read(exchange: (Data) async throws -> Data) async -> ReadResult? {
        guard let payload = await request(purseCommand(), maximum: 256, exchange: exchange),
              let purse = parsePurse(payload) else { return nil }
        var records: [Data] = []
        var offset = 0
        while offset < purse.historyCount {
            guard let command = historyCommand(offset: offset),
                  let page = await request(command, maximum: 4096, exchange: exchange),
                  !page.isEmpty, page.count % 16 == 0 else { break }
            let count = page.count / 16
            // A corrupt response must not bypass the advertised log bound.
            guard count <= purse.historyCount - offset else { break }
            for index in 0..<count {
                let record = Data(page[(index * 16)..<(index * 16 + 16)])
                if let encoded = encodeHistory(record) { records.append(encoded) }
            }
            offset += count
        }
        return ReadResult(purse: purse, rawHistory: records, historyComplete: offset == purse.historyCount)
    }

    /// Exact 9000 success, one 6C length correction, at most 16 response frames.
    /// Chained data is accepted only if the final status succeeds.
    private static func request(_ original: Data, maximum: Int, exchange: (Data) async throws -> Data) async -> Data? {
        var command = original
        var collected = Data()
        var retriedLength = false
        for _ in 0..<16 {
            guard let response = try? await exchange(command), response.count >= 2 else { return nil }
            let b = Array(response)
            let sw1 = b[b.count - 2], sw2 = b[b.count - 1]
            let payload = Data(b.dropLast(2))
            if sw1 == 0x6C {
                guard payload.isEmpty, !retriedLength else { return nil }
                retriedLength = true
                command[command.count - 1] = sw2
                continue
            }
            guard collected.count + payload.count <= maximum else { return nil }
            collected.append(payload)
            if sw1 == 0x90 && sw2 == 0 { return collected }
            guard sw1 == 0x61 else { return nil }
            command = Data([0, 0xC0, 0, 0, sw2])
        }
        return nil
    }

    private static func unsigned(_ b: [UInt8], _ start: Int, _ count: Int) -> UInt32 {
        b[start..<start + count].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func signed24(_ b: [UInt8], _ start: Int) -> Int64 {
        let value = Int64(unsigned(b, start, 3))
        return value & 0x80_0000 == 0 ? value : value - 0x100_0000
    }
}
