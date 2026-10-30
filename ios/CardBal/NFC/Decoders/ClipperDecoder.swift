// SPDX-License-Identifier: GPL-3.0-or-later
// Clipper format adapted from FareBot / Metrodroid.
// Copyright (C) 2014-2016, 2025 Eric Butler, 2014 Bao-Long Nguyen-Trong,
// 2016, 2018 Michael Farrell, 2018 Google. Thanks to Anonymous Contributor.
// See docs/decoding/clipper.md and docs/licenses/FareBot-GPL-3.0.txt.
import Foundation

struct ClipperDecoder: TransitCardDecoder {
    static let applicationID = "9011F2"
    static let epochOffset: TimeInterval = 2_208_988_800

    static func canDecode(tag: CardTag) async -> Bool {
        switch tag {
        case .miFare(let card): return card.mifareFamily == .desfire
        case .iso7816: return true
        default: return false
        }
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        let reader: DESFireReader
        let identifier: Data
        switch tag {
        case .miFare(let card) where card.mifareFamily == .desfire:
            identifier = card.identifier
            reader = DESFireReader(card: card)
        case .iso7816(let card):
            identifier = card.identifier
            reader = DESFireReader(card: card)
        default: throw NFCTestError.unsupportedCard
        }
        try Task.checkCancellation()
        try await reader.select(application: Data(hexString: applicationID))
        var files: [UInt8: Data] = [:]
        files[8] = try await reader.readFile(8)
        files[2] = try await reader.readFile(2)
        var unavailable: [UInt8] = []
        for number: UInt8 in [1, 4, 14] {
            do {
                files[number] = try await reader.readFile(number)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unavailable.append(number)
            }
        }
        try Task.checkCancellation()
        return try snapshot(files: files, identifier: identifier, scannedAt: scannedAt, unavailable: unavailable)
    }

    static func snapshot(files: [UInt8: Data], identifier: Data, scannedAt: Date,
                         unavailable: [UInt8] = []) throws -> TransitCardSnapshot {
        guard let serial = files[8], serial.count >= 5, let balance = files[2], balance.count >= 20 else {
            throw NFCTestError.unsupportedCard
        }
        let number = String(serial.bigEndianInt(start: 1, length: 4))
        let cents = Int(Int16(bitPattern: UInt16(balance.bigEndianInt(start: 18, length: 2))))
        var fields = [ResultField(title: "Card Number", value: number),
                      ResultField(title: "Card Type", value: "Clipper (DESFire)"),
                      ResultField(title: "Region", value: "San Francisco Bay Area")]
        if let expiry = files[1], expiry.count >= 10 {
            let days = expiry.bigEndianInt(start: 8, length: 2)
            if days > 0 { fields.append(ResultField(title: "Expiry Date", value: dateText(seconds: days * 86400))) }
        }
        let trips = records(files[14], file: 14)
        let refills = records(files[4], file: 4)
        var sections = files.keys.sorted().map { number in
            RawDataSection(title: String(format: "Clipper File %02X", number),
                           fields: [RawDataField(title: "Payload", value: files[number]!.hexString)])
        }
        if !unavailable.isEmpty {
            sections.append(RawDataSection(title: "Clipper Read Status", fields: [
                RawDataField(title: "Unavailable Files", value: unavailable.map { String(format: "%02X", $0) }.joined(separator: ", "))
            ]))
        }
        return TransitCardSnapshot(
            technology: "ISO7816", cardFamily: "Clipper", identifierLabel: "Card Number",
            identifierValue: number, rawIdentifierValue: identifier.hexString,
            pmm: nil, systemCode: nil, selectedAID: applicationID,
            balanceText: formatCurrency(amount: Decimal(cents) / 100, code: "USD", fractionDigits: 2),
            balanceDetail: "Clipper stored-value balance.", realSerialNumber: number, region: "San Francisco Bay Area",
            resultFields: fields, rawSections: sections, rawTransactions: trips + refills,
            rawTransitHistory: trips, scannedAt: scannedAt)
    }

    /// File prefix preserves the distinction between equally sized trip and
    /// refill records when they are saved, merged, or exported by the wallet.
    static func records(_ fileData: Data?, file: UInt8) -> [String] {
        guard let fileData, !fileData.isEmpty, fileData.count.isMultiple(of: 32) else { return [] }
        return stride(from: fileData.count - 32, through: 0, by: -32).compactMap { offset in
            let bytes = fileData.subdata(in: offset..<(offset + 32))
            let record = Data([file]) + bytes
            return decodeRecord(record) == nil ? nil : record.hexString
        }
    }

    /// Normalize only the previous Clipper DFSV envelope; keep every unknown
    /// record byte-for-byte so merging a rescan cannot erase saved evidence.
    static func canonicalHistoryRecord(_ raw: String) -> String {
        guard raw.utf8.count == 86, raw.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { return raw }
        let data = Data(hexString: raw)
        guard data.count == 43, data.prefix(6) == Data([0x44, 0x46, 0x53, 0x56, 1, 5]),
              data.bigEndianInt(start: 9, length: 2) == 32 else { return raw }
        let file: UInt8
        switch data[6] {
        case 2: file = 4
        case 3: file = 14
        default: return raw
        }
        return (Data([file]) + data.dropFirst(11)).hexString
    }

    static func decodeTransaction(_ data: Data, context: [Data], index: Int) -> TransitTransaction? {
        guard let transaction = decodeRecord(data) else { return nil }
        if let timestamp = tripEntryTimestamp(data), context.indices.contains(index) {
            let matches = context.indices.filter {
                tripEntryTimestamp(context[$0]) == timestamp && decodeRecord(context[$0]) != nil
            }
            // A tap-out supersedes the provisional tap-in, including across
            // rescans. Prefer the first completed record in newest-first data.
            let preferred = matches.first { context[$0].bigEndianInt(start: 17, length: 4) != 0 } ?? matches.first
            if preferred != index { return nil }
        }
        return transaction
    }

    /// Shared identity for display deduplication and deleting every backing
    /// record of a trip. Refills use a separate file and must never match.
    static func tripEntryTimestamp(_ data: Data) -> Int? {
        guard data.count == 33, data.first == 14 else { return nil }
        let timestamp = data.bigEndianInt(start: 13, length: 4)
        return timestamp == 0 ? nil : timestamp
    }

    static func decodeRecord(_ data: Data) -> TransitTransaction? {
        guard data.count == 33, let file = data.first, file == 4 || file == 14 else { return nil }
        let record = Data(data.dropFirst())
        let agency = record.bigEndianInt(start: 2, length: 2)
        let seconds = record.bigEndianInt(start: file == 4 ? 4 : 12, length: 4)
        guard seconds != 0, file == 4 || agency != 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(seconds) - epochOffset)
        let catalog = ClipperTransitCatalog.shared
        let agencyName = catalog.agencyName(agency)
        var transaction: TransitTransaction
        if file == 4 {
            transaction = TransitTransaction(date: date, time: timeText(date),
                amount: Decimal(record.bigEndianInt(start: 14, length: 2)) / 100,
                terminalID: String(record.bigEndianInt(start: 8, length: 4)),
                type: "Top-up", category: .topUp, location: agencyName, rawData: data.hexString)
        } else {
            let from = record.bigEndianInt(start: 20, length: 2)
            let to = record.bigEndianInt(start: 22, length: 2)
            let route = record.bigEndianInt(start: 28, length: 2)
            let mode = record.bigEndianInt(start: 30, length: 2)
            let category: TransactionCategory
            let modeName: String
            switch mode {
            case 0x61, 0x75, 0x77: (category, modeName) = (.bus, "Bus")
            case 0x6F: (category, modeName) = (.train, "Metro")
            case 0x78: (category, modeName) = (.train, "Train")
            case 0x73: (category, modeName) = (.ferry, "Ferry")
            case 0x62:
                if agency == 0x19 || agency == 0x1B { (category, modeName) = (.ferry, "Ferry") }
                else { (category, modeName) = (.train, agency == 6 || agency == 12 ? "Train" : "Tram") }
            default: (category, modeName) = (.unknown, "Transit")
            }
            let routeName = catalog.routeName(agency: agency, route: route)
            let location = [agencyName, routeName].compactMap { $0 }.joined(separator: " - ")
            transaction = TransitTransaction(date: date, time: timeText(date),
                amount: -Decimal(record.bigEndianInt(start: 6, length: 2)) / 100,
                terminalID: vehicleName(record.bigEndianInt(start: 10, length: 2)),
                type: "\(agencyName) - \(modeName)", category: category, location: location,
                entryStation: catalog.stationName(agency: agency, station: from, isEnd: false),
                exitStation: catalog.stationName(agency: agency, station: to, isEnd: true),
                entryStationCode: catalog.station(agency: agency, station: from)?.lookupCode,
                exitStationCode: catalog.station(agency: agency, station: to)?.lookupCode,
                rawData: data.hexString)
        }
        transaction.currencyCode = "USD"
        transaction.issuerTimeZone = "America/Los_Angeles"
        transaction.amountIsSigned = true
        return transaction
    }

    static func vehicleName(_ number: Int) -> String? {
        guard number != 0, number != 0xFFFF else { return nil }
        return number < 10_000 ? String(number) : "\(number / 10)\(String(number % 10 + 9, radix: 16).uppercased())"
    }

    static func timeText(_ date: Date) -> String {
        dateTimeText(date, format: "HH:mm:ss")
    }

    static func dateTimeText(_ date: Date, format: String = "yyyy-MM-dd HH:mm:ss") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Los_Angeles")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func dateText(seconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Day counters are calendar dates; do not shift midnight into yesterday.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(seconds) - epochOffset))
    }
}
