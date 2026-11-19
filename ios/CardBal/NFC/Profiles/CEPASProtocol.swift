import Foundation

/// Independent codec for the public CEPAS purse-3 wire fields, not a GPL port.
/// Facts: FareBot dc09f6f014ea3675b64bcd38335b4b78d77fa374, card/cepas and transit/ezlink.
/// Only on-card stored value is read. No SimplyGo backend/generation inference.
enum CEPASProtocol {
    /// The purse read first; the other IDs 0...15 are tried only when it is missing or invalid.
    static let purseID: UInt8 = 3
    /// Card commands one read may send before the purse search stops.
    private static let exchangeLimit = 64
    static let issuerTimeZone = "Asia/Singapore"
    // Calculate the stated local epoch rather than FareBot's conflicting numeric
    // constant. Metrodroid b910c180 EZLinkTransitData + time/Timestamp confirm it.
    static let epoch: Int64 = 788_889_600 // 1995-01-01 00:00:00 Singapore
    // Saved-record format marker; it stays 3 whichever purse the records came from.
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
        let purseID: UInt8
        let rawHistory: [Data]
        let historyComplete: Bool
        var family: String { purse.family }
        var serial: String { purse.serial }
        var balanceMinor: Int64 { purse.balanceMinor }
    }

    /// Read progress for the scan sheet: the purse, then each history page
    /// by its first record number and the purse's record count.
    enum ReadStage { case purse, history(next: Int, total: Int) }

    static func selectFileCommand() -> Data { Data([0, 0xA4, 0, 0, 2, 0x40, 0]) }
    /// The same SELECT with Le 00, for cards that refuse the case-3 form.
    static func selectFileWithLeCommand() -> Data { Data([0, 0xA4, 0, 0, 2, 0x40, 0, 0]) }
    static func purseCommand(_ id: UInt8 = purseID) -> Data { Data([0x90, 0x32, id, 0, 0]) }
    /// The six-byte GET PURSE some legacy cards need (CoreExtendedNFC's note);
    /// tried first when the short form answers 6700.
    static func purseLegacyCommand(_ id: UInt8 = purseID) -> Data { Data([0x90, 0x32, id, 0, 0, 0]) }
    /// GET PURSE with Lc 1, data 00 and Le 00, for cards that answer the short form with 6700.
    static func purseWithDataCommand(_ id: UInt8 = purseID) -> Data { Data([0x90, 0x32, id, 0, 1, 0, 0]) }

    /// Thrown by an exchange that cannot express a command on its transport.
    /// The card was never asked, so the read skips that form and carries on.
    struct CommandNotSendable: Error {}

    /// The GET PURSE wire form in use: short until a purse answers 6700.
    private enum PurseForm {
        case short, legacy, withData
        func command(_ id: UInt8) -> Data {
            switch self {
            case .short: return CEPASProtocol.purseCommand(id)
            case .legacy: return CEPASProtocol.purseLegacyCommand(id)
            case .withData: return CEPASProtocol.purseWithDataCommand(id)
            }
        }
        func stage(_ id: UInt8) -> String {
            switch self {
            case .short: return "purse \(id)"
            case .legacy: return "purse \(id) legacy"
            case .withData: return "purse \(id) lc"
            }
        }
    }
    static func historyCommand(offset: Int, count: Int, purse id: UInt8 = purseID) -> Data? {
        guard (0...254).contains(offset), (1...15).contains(count) else { return nil }
        return Data([0x90, 0x32, id, 0, 1, UInt8(offset), UInt8(count * 16)])
    }

    /// The structural rule a purse fails, or nil when `parsePurse` accepts it.
    static func purseRejection(_ data: Data) -> String? {
        let b = Array(data)
        if !(63...256).contains(b.count) { return "length not 63..256" }
        if b[0] == 0 || b[0] == 0xFF { return "version 00/FF" }
        if 63 + Int(b[41]) > b.count { return "63+L exceeds length" }
        if !b[8..<16].allSatisfy({ $0 >> 4 <= 9 && $0 & 15 <= 9 }) { return "CAN not BCD" }
        return nil
    }

    /// Accept only complete legacy-layout purses with a BCD CAN. A successful
    /// status or plausible balance alone is insufficient. The CAN names the card
    /// only where its prefix is certain; any other valid purse is plain CEPAS.
    static func parsePurse(_ data: Data) -> Purse? {
        guard purseRejection(data) == nil else { return nil }
        let b = Array(data)
        let serial = b[8..<16].map { String(format: "%02X", $0) }.joined()
        let family: String
        if serial.hasPrefix("100") { family = "EZ-Link" }
        else if serial.hasPrefix("111") { family = "NETS FlashPay" }
        else if serial.hasPrefix("800") { family = "Concession" } // CAN 8000–8009
        else { family = "CEPAS" }
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

    /// Select file 4000 (again with Le if refused; GET PURSE is still tried once
    /// without it), then purse 3, then the other purses 0...15 until one passes
    /// `parsePurse`. A purse answering 6700 is asked again with the legacy
    /// six-byte form, then with Lc 1; the first form understood (9000 or 6B00)
    /// is used for the remaining purses. A form the transport cannot send is
    /// skipped. A lost card or an unsupported command ends the search.
    /// Optional log failures never erase a validated balance. `log` gets
    /// stages, status words and lengths only, never response bytes.
    static func read(exchange: (Data) async throws -> Data,
                     progress: (ReadStage) -> Void = { _ in },
                     log: (String) -> Void = { _ in }) async -> ReadResult? {
        var sent = 0
        func attempt(_ stage: String, _ command: Data, maximum: Int) async -> Reply {
            let reply = await request(command, maximum: maximum) { sent += 1; return try await exchange($0) }
            if reply.notSendable { sent -= 1 } // never reached the card
            else if reply.data == nil { log("\(stage): \(reply.summary)") }
            return reply
        }

        var selected = await attempt("select", selectFileCommand(), maximum: 256).data != nil
        if !selected { selected = await attempt("select-le", selectFileWithLeCommand(), maximum: 256).data != nil }
        if !selected { log("File 4000 not selected; trying purse \(purseID) once") }
        progress(.purse)
        let candidates: [UInt8] = selected ? [purseID] + (UInt8(0)...15).filter { $0 != purseID } : [purseID]
        var found: (id: UInt8, purse: Purse)?
        var stop: String?
        var form = PurseForm.short
        var legacySendable = true
        for id in candidates {
            if sent >= exchangeLimit { stop = "command limit reached"; break }
            var reply = await attempt(form.stage(id), form.command(id), maximum: 256)
            if form == .short, reply.wrongLength {
                for retry in [PurseForm.legacy, .withData] where retry != .legacy || legacySendable {
                    if sent >= exchangeLimit { stop = "command limit reached"; break }
                    log("purse \(id): retrying with \(retry == .legacy ? "legacy form" : "Lc 1")")
                    let next = await attempt(retry.stage(id), retry.command(id), maximum: 256)
                    if next.notSendable {
                        legacySendable = false
                        log("purse \(id): legacy form not sendable on this device")
                        continue
                    }
                    reply = next
                    if reply.understood { form = retry; break }
                    if reply.stopReason != nil { break }
                }
                if stop != nil { break }
            }
            guard let payload = reply.data else {
                if let reason = reply.stopReason { stop = reason; break }
                continue
            }
            if let rejection = purseRejection(payload) {
                log("parse purse \(id): \(rejection), \(payload.count) bytes, L \(lengthByte(payload))")
                continue
            }
            found = (id, parsePurse(payload)!)
            break
        }
        guard let found else {
            log("Unsupported: no valid purse" + (stop.map { " (\($0))" } ?? " in \(candidates.count) tried"))
            return nil
        }
        let chosenID = found.id, purse = found.purse
        if chosenID != purseID { log("Warning: purse \(purseID) unavailable, using purse \(chosenID)") }
        if !selected { log("Warning: purse read without selecting file 4000") }
        var records: [Data] = []
        var offset = 0
        while offset < purse.historyCount {
            let requestedCount = min(15, purse.historyCount - offset)
            progress(.history(next: offset + 1, total: purse.historyCount))
            guard let command = historyCommand(offset: offset, count: requestedCount, purse: chosenID),
                  let page = await attempt("history \(offset)", command, maximum: requestedCount * 16).data else { break }
            guard !page.isEmpty, page.count % 16 == 0 else {
                log("history \(offset): \(page.count) bytes, not whole records")
                break
            }
            let count = page.count / 16
            for index in 0..<count {
                let record = Data(page[(index * 16)..<(index * 16 + 16)])
                if let encoded = encodeHistory(record) { records.append(encoded) }
            }
            offset += count
        }
        if offset != purse.historyCount { log("Warning: history incomplete, \(offset) of \(purse.historyCount) records") }
        return ReadResult(purse: purse, purseID: chosenID, rawHistory: records, historyComplete: offset == purse.historyCount)
    }

    /// Payload on exact 9000, otherwise the last status word, length and any transport error.
    private struct Reply {
        var data: Data?
        var status: Int = -1
        var length = 0
        var error: String?
        /// The exchange refused to send the command; the card was never asked.
        var notSendable = false

        var wrongLength: Bool { data == nil && error == nil && !notSendable && status == 0x6700 }
        /// The card accepted this GET PURSE form: data, or a missing purse.
        var understood: Bool { data != nil || (error == nil && status == 0x6B00) }

        var summary: String {
            if let error { return "no reply (\(error))" }
            if status < 0 { return "short reply, \(length) bytes" }
            return String(format: "status %04X, %d bytes", status, length)
        }
        /// A lost card, or CLA/INS not supported: no other purse can answer either.
        var stopReason: String? {
            if let error { return "card connection lost: \(error)" }
            return status == 0x6D00 || status == 0x6E00 ? "command not supported" : nil
        }
    }

    private static func lengthByte(_ data: Data) -> String {
        data.count > 41 ? String(format: "%02X", data[data.startIndex + 41]) : "-"
    }

    /// Exact 9000 success, one 6C length correction, at most 16 response frames.
    /// Chained data is accepted only if the final status succeeds.
    private static func request(_ original: Data, maximum: Int, exchange: (Data) async throws -> Data) async -> Reply {
        var command = original
        var collected = Data()
        var retriedLength = false
        var status = -1
        for _ in 0..<16 {
            let response: Data
            do { response = try await exchange(command) }
            catch is CommandNotSendable { return Reply(data: nil, status: status, length: collected.count, notSendable: true) }
            catch { return Reply(data: nil, status: status, length: collected.count, error: String(describing: type(of: error))) }
            guard response.count >= 2 else { return Reply(data: nil, length: response.count) }
            let b = Array(response)
            let sw1 = b[b.count - 2], sw2 = b[b.count - 1]
            status = Int(sw1) << 8 | Int(sw2)
            let payload = Data(b.dropLast(2))
            if sw1 == 0x6C {
                // SELECT 4000 has Lc/data but no Le; its last byte is a file ID.
                let hasLe = command.count == 5 || (command.count > 5 && command.count == Int(command[4]) + 6)
                guard payload.isEmpty, !retriedLength, hasLe else { return Reply(data: nil, status: status, length: payload.count) }
                retriedLength = true
                command[command.count - 1] = sw2
                continue
            }
            guard collected.count + payload.count <= maximum else {
                return Reply(data: nil, status: status, length: collected.count + payload.count)
            }
            collected.append(payload)
            if sw1 == 0x90 && sw2 == 0 { return Reply(data: collected, status: status, length: collected.count) }
            guard sw1 == 0x61 else { return Reply(data: nil, status: status, length: collected.count) }
            command = Data([0, 0xC0, 0, 0, sw2])
        }
        return Reply(data: nil, status: status, length: collected.count)
    }

    private static func unsigned(_ b: [UInt8], _ start: Int, _ count: Int) -> UInt32 {
        b[start..<start + count].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func signed24(_ b: [UInt8], _ start: Int) -> Int64 {
        let value = Int64(unsigned(b, start, 3))
        return value & 0x80_0000 == 0 ? value : value - 0x100_0000
    }
}
