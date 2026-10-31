// SPDX-License-Identifier: MIT
// Macau Pass format adapted from TU-Reader. Copyright (c) 2026 HaoTian22.
// See docs/decoding/macau-pass.md and docs/licenses/TU-Reader-MIT.txt.
import Foundation

struct MacauPassDecoder: TransitCardDecoder {
    static let applicationAID = "B0C4C3C5CDA8C7AEB0FC"

    static func canDecode(tag: CardTag) async -> Bool {
        guard case .iso7816 = tag else { return false }
        // A co-branded card may initially select its T-Union application.
        return true
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let card) = tag else { throw NFCTestError.unsupportedCard }
        let selected = try await read(card, command: CardAPDU(
            instructionClass: 0, instructionCode: 0xA4, p1Parameter: 4, p2Parameter: 0,
            data: Data(hexString: applicationAID), expectedResponseLength: 256))
        var sections = [RawDataSection(title: "Macau Pass Application", fields: [
            RawDataField(title: "AID", value: applicationAID),
            RawDataField(title: "Select Response", value: selected.hexString.uppercased())
        ])]
        var failures: [RawDataField] = []
        var info: Data?
        var balance: Decimal?
        ScanProgress.report(.details)
        do {
            info = try await read(card, command: command(ins: 0xB0, p1: 0x95, length: 256))
            sections.append(RawDataSection(title: "Macau Pass Information (SFI 15)", fields: [
                RawDataField(title: "Payload", value: info!.hexString.uppercased())
            ]))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failures.append(RawDataField(title: "Information", value: String(describing: error)))
        }
        ScanProgress.report(.balance)
        do {
            let payload = try await read(card, command: command(cla: 0x80, ins: 0x5C, p2: 2, length: 4))
            sections.append(RawDataSection(title: "Macau Pass Balance", fields: [
                RawDataField(title: "Payload", value: payload.hexString.uppercased()),
                RawDataField(title: "Unit", value: "0.1 MOP"),
                RawDataField(title: "Reserve", value: "MOP 10.00")
            ]))
            // TU-Reader's high-bit heuristic is documented for Shenzhen only.
            // Preserve such Macau values as raw data until their meaning is known.
            if payload.count == 4, payload[0] & 0x80 == 0 {
                balance = Decimal(payload.bigEndianInt(start: 0, length: 4)) / 10 - 10
            } else {
                failures.append(RawDataField(title: "Balance", value: "Unrecognized balance layout"))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failures.append(RawDataField(title: "Balance", value: String(describing: error)))
        }

        var records: [TransitApplicationRecord] = []
        ScanProgress.report(.transactions)
        for index in 1...30 {
            do {
                let payload = try await read(card, command: command(ins: 0xB2, p1: UInt8(index), p2: 0xC4, length: 23))
                guard payload.count == 23 else {
                    sections.append(RawDataSection(title: "Macau Pass Unrecognized History Record", fields: [
                        RawDataField(title: "Record", value: "\(index)"),
                        RawDataField(title: "Payload", value: payload.hexString.uppercased())
                    ]))
                    failures.append(RawDataField(title: "History", value: "Unexpected record length"))
                    break
                }
                if !payload.allSatisfy({ $0 == 0 }) {
                    records.append(TransitApplicationRecord(kind: .transaction, sfi: 0x18,
                        index: index, hex: payload.hexString.uppercased()))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch ReadError.status(0x6A83) {
                break // End of the cyclic history file.
            } catch {
                failures.append(RawDataField(title: "History Record \(index)", value: String(describing: error)))
                break
            }
        }
        let serial: String? = info.flatMap { payload in
            guard payload.count >= 20 else { return nil }
            let bytes = payload.subdata(in: 16..<20)
            guard !bytes.allSatisfy({ $0 == 0 }), !bytes.allSatisfy({ $0 == 0xFF }) else { return nil }
            return bytes.hexString.uppercased()
        }
        guard serial != nil || balance != nil || records.contains(where: { decodeTransaction($0.data) != nil }) else {
            throw NFCTestError.unsupportedCard
        }
        var fields = [ResultField(title: "Brand", value: "Macau Pass"),
                      ResultField(title: "Region", value: "Macau"),
                      ResultField(title: "Currency", value: "MOP")]
        if let serial { fields.append(ResultField(title: "Application Serial", value: serial)) }
        if let info {
            if info.count >= 8 {
                fields.append(ResultField(title: "Issuer", value: info.prefix(8).hexString.uppercased()))
            }
            if info.count >= 10 {
                fields.append(ResultField(title: "Application Version", value: String(format: "%02X", info[9])))
            }
            for (title, offset) in [("Issue Date", 20), ("Expiry Date", 24)] {
                if info.count >= offset + 4,
                   let value = dateText(info.subdata(in: offset..<(offset + 4))) {
                    fields.append(ResultField(title: title, value: value))
                }
            }
        }
        if !failures.isEmpty { sections.append(RawDataSection(title: "Macau Pass Read Status", fields: failures)) }
        let uid = card.identifier.hexString.uppercased()
        // An external reader may not expose a UID. Without either identifier,
        // different physical cards would share the same empty wallet identity.
        guard serial != nil || !uid.isEmpty else { throw NFCTestError.unsupportedCard }
        var snapshot = TransitCardSnapshot(
            technology: "ISO7816", cardFamily: "Macau Pass",
            identifierLabel: serial == nil ? "UID" : "Application Serial",
            identifierValue: serial ?? uid, rawIdentifierValue: uid.isEmpty ? serial ?? "" : uid,
            pmm: nil, systemCode: nil, selectedAID: applicationAID,
            balanceText: balance.map { formatCurrency(amount: $0, code: "MOP", fractionDigits: 2) },
            balanceDetail: "Stored-value balance excluding the MOP 10 reserve.",
            realSerialNumber: serial, region: "Macau", resultFields: fields, rawSections: sections,
            rawTransactions: records.map(\.hex), rawTransitHistory: [], scannedAt: scannedAt)
        snapshot.applications = [TransitApplication(snapshot: snapshot, cityCode: "0446", records: records)]

        // Same connected card, separate currency and history. A failed companion
        // read must not discard the readable Macau purse.
        try Task.checkCancellation()
        let companion = try? await TUnionDecoder.decode(tag: tag, scannedAt: scannedAt)
        try Task.checkCancellation()
        if let companion, let combined = TransitCardSnapshot.combining([snapshot, companion]) { return combined }
        return snapshot
    }

    static func decodeTransaction(_ data: Data) -> TransitTransaction? {
        guard data.count == 23, !data.allSatisfy({ $0 == 0 }),
              let date = timestamp(data.subdata(in: 16..<23)) else { return nil }
        // The Macau-specific upstream field layout uses four bytes; its generic
        // parser drops byte 5. Retain the full field instead of truncating it.
        let value = Decimal(data.bigEndianInt(start: 5, length: 4)) / 10
        let amount: Decimal
        let type: String
        let category: TransactionCategory
        switch data[9] {
        case 0x02:
            (amount, type, category) = (value, "Top-up", .topUp)
        case 0x06, 0x09:
            (amount, type, category) = (-value, "Payment", .payment)
        default:
            // Unknown event codes have no established credit/debit semantics.
            (amount, type, category) = (0, String(format: "Transaction (%02X)", data[9]), .unknown)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Macau")
        formatter.dateFormat = "HH:mm:ss"
        var transaction = TransitTransaction(
            date: date, time: formatter.string(from: date), amount: amount,
            terminalID: data.subdata(in: 10..<16).hexString.uppercased(),
            type: type, category: category, rawData: data.hexString.uppercased(),
            recordNumber: data.bigEndianInt(start: 0, length: 2))
        transaction.currencyCode = "MOP"
        transaction.issuerTimeZone = "Asia/Macau"
        transaction.amountIsSigned = true
        transaction.amountKnown = category != .unknown
        return transaction
    }

    private static func timestamp(_ data: Data) -> Date? {
        let bytes = [UInt8](data)
        guard bytes.count == 7, bytes.allSatisfy({ $0 >> 4 < 10 && $0 & 15 < 10 }) else { return nil }
        let values = bytes.map { Int($0 >> 4) * 10 + Int($0 & 15) }
        let year = values[0] * 100 + values[1]
        guard (1900...2200).contains(year), (1...12).contains(values[2]), (1...31).contains(values[3]),
              values[4] < 24, values[5] < 60, values[6] < 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Macau")!
        let components = DateComponents(year: year, month: values[2], day: values[3],
                                        hour: values[4], minute: values[5], second: values[6])
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard roundTrip.year == year, roundTrip.month == values[2], roundTrip.day == values[3],
              roundTrip.hour == values[4], roundTrip.minute == values[5], roundTrip.second == values[6] else { return nil }
        return date
    }

    private static func dateText(_ data: Data) -> String? {
        guard timestamp(data + Data([0, 0, 0])) != nil else { return nil }
        let raw = data.hexString.uppercased()
        return "\(raw.prefix(4))-\(raw.dropFirst(4).prefix(2))-\(raw.suffix(2))"
    }

    private enum ReadError: Error, CustomStringConvertible {
        case status(UInt16), responseLimit
        var description: String {
            switch self {
            case .status(let value): return String(format: "Card status %04X", value)
            case .responseLimit: return "Response exceeded the read limit"
            }
        }
    }

    private static func command(cla: UInt8 = 0, ins: UInt8, p1: UInt8 = 0, p2: UInt8 = 0, length: Int) -> CardAPDU {
        CardAPDU(instructionClass: cla, instructionCode: ins, p1Parameter: p1,
                 p2Parameter: p2, data: Data(), expectedResponseLength: length)
    }

    private static func read(_ card: any ISO7816Card, command: CardAPDU) async throws -> Data {
        var current = command
        var result = Data()
        var correctedLength = false
        for _ in 0..<16 {
            try Task.checkCancellation()
            let (payload, sw1, sw2) = try await card.sendCommand(apdu: current)
            if sw1 == 0x6C && !correctedLength {
                current = CardAPDU(instructionClass: current.instructionClass, instructionCode: current.instructionCode,
                    p1Parameter: current.p1Parameter, p2Parameter: current.p2Parameter,
                    data: current.data ?? Data(), expectedResponseLength: sw2 == 0 ? 256 : Int(sw2))
                correctedLength = true
                continue
            }
            guard (sw1 == 0x90 && sw2 == 0) || sw1 == 0x61 else {
                throw ReadError.status(UInt16(sw1) << 8 | UInt16(sw2))
            }
            guard result.count + payload.count <= 2048 else { throw ReadError.responseLimit }
            result.append(payload)
            if sw1 == 0x90 { return result }
            current = Self.command(ins: 0xC0, length: sw2 == 0 ? 256 : Int(sw2))
            correctedLength = false
        }
        throw ReadError.responseLimit
    }
}
