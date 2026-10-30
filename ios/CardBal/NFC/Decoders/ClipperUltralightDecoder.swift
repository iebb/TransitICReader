// SPDX-License-Identifier: GPL-3.0-or-later
// Clipper ticket format adapted from FareBot / Metrodroid.
// Copyright 2018 Google, 2025 Eric Butler.
// See docs/decoding/clipper.md and docs/licenses/FareBot-GPL-3.0.txt.
import Foundation

struct ClipperUltralightDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .miFare(let card) = tag else { return false }
        return card.mifareFamily == .ultralight
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .miFare(let card) = tag, card.mifareFamily == .ultralight else {
            throw NFCTestError.unsupportedCard
        }
        func readPages(_ page: UInt8) async throws -> Data {
            try Task.checkCancellation()
            let response = try await card.sendMiFareCommand(commandPacket: Data([0x30, page]))
            try Task.checkCancellation()
            guard response.count == 16 else { throw ExternalReaderError.malformedResponse }
            return response
        }
        let header = try await readPages(4)
        guard header.count == 16, header.first == 0x13 else { throw NFCTestError.unsupportedCard }
        let first = try await readPages(0)
        let middle = try await readPages(8)
        let last = try await readPages(12)
        return try snapshot(data: first + header + middle + last, identifier: card.identifier, scannedAt: scannedAt)
    }

    static func snapshot(data: Data, identifier: Data, scannedAt: Date) throws -> TransitCardSnapshot {
        guard data.count == 64, data[16] == 0x13 else { throw NFCTestError.unsupportedCard }
        let number = String(data.bigEndianInt(start: 12, length: 4))
        let baseDays = data.bigEndianInt(start: 22, length: 2)
        let product = data.bigEndianInt(start: 20, length: 2)
        let raw = [24, 44].compactMap { offset -> Data? in
            let record = data.subdata(in: offset..<(offset + 20))
            return record.allSatisfy { $0 == 0 } ? nil : data.subdata(in: 22..<24) + record
        }
        let trips = raw.compactMap(TicketEvent.init)
        let latest = trips.reduce(nil as TicketEvent?) { current, event in
            guard let current else { return event }
            return event.isNewer(than: current) ? event : current
        }
        let ticketType = [0x04: "Adult", 0x44: "Senior", 0x84: "RTC", 0xC4: "Youth"][Int(data[17])]
            ?? String(format: "0x%02X", data[17])
        let productName: String
        switch product & 0x0F {
        case 3...10:
            let passenger = ["Adult", "Senior", "RTC", "Youth"][((product & 0x0F) - 3) / 2]
            productName = passenger + (product & 1 == 1 ? " single ride" : " return")
        default: productName = String(format: "0x%04X", product)
        }
        var fields = [ResultField(title: "Card Number", value: number),
                      ResultField(title: "Card Type", value: "Clipper Ticket"),
                      ResultField(title: "Ticket Type", value: ticketType),
                      ResultField(title: "Product", value: productName),
                      ResultField(title: "Agency", value: ClipperTransitCatalog.shared.agencyName(product >> 4 == 0x21 ? 0x12 : product >> 4))]
        if baseDays > 0 {
            fields.append(ResultField(title: "Expiry Date", value: ClipperDecoder.dateText(seconds: baseDays * 86400)))
        }
        if baseDays > 89 {
            fields.append(ResultField(title: "Issue Date", value: ClipperDecoder.dateText(seconds: (baseDays - 89) * 86400)))
        }
        if let latest {
            fields.append(ResultField(title: "Trips Remaining", value: "\(latest.remaining)"))
            if latest.transferMinutes > 0 {
                let date = Date(timeIntervalSince1970: Double((latest.minutes + latest.transferMinutes) * 60) - ClipperDecoder.epochOffset)
                fields.append(ResultField(title: "Transfer Expiry", value: ClipperDecoder.dateTimeText(date)))
            }
        }
        let history = raw.map(\.hexString)
        return TransitCardSnapshot(
            technology: "MIFARE Ultralight", cardFamily: "Clipper Ticket", identifierLabel: "Card Number",
            identifierValue: number, rawIdentifierValue: identifier.isEmpty ? number : identifier.hexString,
            pmm: nil, systemCode: nil, selectedAID: nil, balanceText: nil, balanceDetail: nil,
            realSerialNumber: number, region: "San Francisco Bay Area", resultFields: fields,
            rawSections: [RawDataSection(title: "Clipper Ticket Pages 0-15", fields: [RawDataField(title: "Payload", value: data.hexString)])],
            rawTransactions: [], rawTransitHistory: history, scannedAt: scannedAt)
    }

    static func decodeTransaction(_ data: Data) -> TransitTransaction? {
        guard let event = TicketEvent(data), event.type != 1 else { return nil }
        let date = Date(timeIntervalSince1970: Double(event.minutes * 60) - ClipperDecoder.epochOffset)
        let catalog = ClipperTransitCatalog.shared
        let category: TransactionCategory
        switch catalog.defaultMode(agency: event.agency) {
        case 1: category = .bus
        case 2, 3, 4: category = .train
        case 5: category = .ferry
        default: category = .unknown
        }
        var result = TransitTransaction(date: date, time: ClipperDecoder.timeText(date), amount: 0,
            terminalID: nil, type: catalog.agencyName(event.agency), category: category,
            entryStation: catalog.stationName(agency: event.agency, station: event.station, isEnd: false),
            entryStationCode: catalog.station(agency: event.agency, station: event.station)?.lookupCode,
            rawData: data.hexString)
        result.currencyCode = "USD"
        result.issuerTimeZone = "America/Los_Angeles"
        result.amountKnown = false
        return result
    }

    struct TicketEvent {
        let minutes: Int, transferMinutes: Int, sequence: Int, balanceSequence: Int
        let remaining: Int, station: Int, agency: Int, type: Int

        init?(_ data: Data) {
            guard data.count == 22, data.dropFirst(2).contains(where: { $0 != 0 }) else { return nil }
            let bytes = [UInt8](data.dropFirst(2))
            func bits(_ offset: Int, _ count: Int) -> Int {
                (offset..<(offset + count)).reduce(0) { ($0 << 1) | Int((bytes[$1 / 8] >> (7 - $1 % 8)) & 1) }
            }
            minutes = data.bigEndianInt(start: 0, length: 2) * 1440 - bits(24, 17)
            transferMinutes = bits(100, 10)
            sequence = bits(0, 7)
            balanceSequence = bits(80, 4)
            remaining = bits(84, 6)
            station = bits(41, 17)
            agency = bits(68, 5)
            type = bits(7, 17)
        }

        func isNewer(than other: Self) -> Bool {
            balanceSequence != other.balanceSequence
                ? (balanceSequence - other.balanceSequence) & 8 == 0
                : (sequence - other.sequence) & 64 == 0
        }
    }
}
