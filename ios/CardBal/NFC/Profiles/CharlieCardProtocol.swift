// SPDX-License-Identifier: GPL-3.0-or-later
// CharlieCard (Boston MBTA) format adapted from Metrodroid.
// Copyright 2018 Google, 2015-2018 Michael Farrell.
// See docs/decoding/charliecard.md and docs/licenses/FareBot-GPL-3.0.txt.
import Foundation

/// CharlieCard of the Massachusetts Bay Transportation Authority (Boston).
/// A MIFARE Classic 1K card whose sectors are protected with keys that are
/// public (shipped in the Proxmark3 and Metrodroid dictionaries). CardBal
/// bundles those keys to read the card and never authenticates to write.
enum CharlieCardProtocol {
    static let name = "CharlieCard"
    static let region = "Boston"

    /// Public MBTA CharlieCard keys, tried per sector as key A and key B.
    /// Source: Proxmark3 `mfc_default_keys.dic` (Boston, MA Transit - MBTA).
    static let keys: [Data] = [
        "3060206F5B0A", "5EC39B022F2B", "3A09594C8587", "F1B9F5669CC8", "F662248E7E89",
        "62387B8D250D", "F238D78FF48F", "9DC282D46217", "AFD0BA94D624", "92EE4DC87191",
        "B35A0E4ACC09", "756EF55E2507", "447AB7FD5A6B", "932B9CB730EF", "1F1A0A111B5B",
        "AD9E0A1CA2F7", "D58023BA2BDC", "62CED42A6D87", "2548A443DF28", "2ED3B15E7C0F",
        "F66224EE1E89",
    ].map { Data(hexString: $0) }

    /// Sector 0 is read with these specific keys; authenticating with them
    /// identifies a CharlieCard without writing or guessing other sectors.
    /// Either may be key A or key B, so both are tried in both roles.
    static let sector0Keys = ["3060206F5B0A", "F1B9F5669CC8"].map { Data(hexString: $0) }

    /// Sectors whose data blocks the reader needs, in read order.
    static let requiredSectors = [0, 2, 3, 6, 7, 8]

    /// 2003-01-01 00:00 in Boston local time; timestamps are minutes from here.
    static let epoch: Date = {
        var components = DateComponents()
        components.year = 2003; components.month = 1; components.day = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(from: components)!
    }()

    /// Signed half-cent price field: two big-endian bytes, 0x8000 marks a
    /// negative value, divided by two to reach whole cents.
    static func price(_ data: Data, _ offset: Int) -> Int {
        var value = data.bigEndianInt(start: offset, length: 2)
        if value & 0x8000 != 0 { value = -(value & 0x7FFF) }
        return value / 2
    }

    static func bits(_ data: Data, _ offset: Int, _ count: Int) -> Int {
        (offset..<(offset + count)).reduce(0) { result, bit in
            let byte = bit / 8
            let value = byte < data.count ? Int(data[data.startIndex + byte]) : 0
            return (result << 1) | ((value >> (7 - bit % 8)) & 1)
        }
    }

    static func date(minutes: Int) -> Date { epoch.addingTimeInterval(Double(minutes) * 60) }

    static func dateTimeText(_ date: Date, format: String = "yyyy-MM-dd HH:mm") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    /// Parsed card. `sectors[s]` holds the three data blocks (0, 1, 2) of
    /// sector `s`, each 16 bytes; the sector trailer is never read.
    static func snapshot(sectors: [Int: [Data]], identifier: Data, scannedAt: Date) -> TransitCardSnapshot? {
        guard let sector0 = sectors[0], sector0.count == 3,
              let sector2 = sectors[2], sector2.count == 3,
              let sector3 = sectors[3], sector3.count == 3 else { return nil }

        let serial = sector0[0].bigEndianInt(start: 0, length: 4)
        let serialText = "5-\(serial)"

        let balanceSector = bits(sector2[0], 81, 16) > bits(sector3[0], 81, 16) ? sector2 : sector3
        let cents = price(balanceSector[1], 5)
        let startMinutes = balanceSector[0].bigEndianInt(start: 6, length: 3)
        let start = date(minutes: startMinutes)

        var trips: [Data] = []
        for i in 0..<12 {
            guard let block = sectors[6 + i / 6]?[(i / 2) % 3] else { continue }
            let offset = 7 * (i % 2)
            guard block.count >= offset + 7, block.bigEndianInt(start: offset, length: 4) != 0 else { continue }
            trips.append(block.subdata(in: offset..<(offset + 7)))
        }

        var fields = [ResultField(title: "Card Number", value: serialText),
                      ResultField(title: "Card Type", value: name),
                      ResultField(title: "Region", value: region),
                      ResultField(title: "Issue Date", value: dateTimeText(start, format: "yyyy-MM-dd"))]

        var expiry = Calendar(identifier: .gregorian).date(byAdding: DateComponents(year: 11, day: -1), to: start) ?? start
        if let lastTrip = trips.compactMap({ CharlieCardProtocol.date(minutes: $0.bigEndianInt(start: 0, length: 3)) }).max(),
           let twoYears = Calendar(identifier: .gregorian).date(byAdding: .year, value: 2, to: lastTrip), twoYears < expiry {
            expiry = twoYears
        }
        fields.append(ResultField(title: "Expiry Date", value: dateTimeText(expiry, format: "yyyy-MM-dd")))

        if let sector8 = sectors[8]?.first {
            let second = sector8.bigEndianInt(start: 0, length: 4)
            if second != 0, second != 0xFFFF_FFFF {
                fields.append(ResultField(title: "Second Card Number", value: "A" + String(format: "%010d", second)))
            }
        }

        let sections = sectors.keys.sorted().map { index in
            RawDataSection(title: "CharlieCard Sector \(index)",
                           fields: [RawDataField(title: "Payload", value: sectors[index]!.reduce(Data(), +).hexString)])
        }
        return TransitCardSnapshot(
            technology: "MIFARE Classic", cardFamily: name, identifierLabel: "Card Number",
            identifierValue: serialText, rawIdentifierValue: identifier.isEmpty ? serialText : identifier.hexString,
            pmm: nil, systemCode: nil, selectedAID: nil,
            balanceText: formatCurrency(amount: Decimal(cents) / 100, code: "USD", fractionDigits: 2),
            balanceDetail: "CharlieCard stored-value balance.", realSerialNumber: serialText, region: region,
            resultFields: fields, rawSections: sections, rawTransactions: [],
            rawTransitHistory: trips.map(\.hexString), scannedAt: scannedAt)
    }

    /// A seven-byte trip record: `[timestamp(3)][validator(2)][fare(2)]`.
    static func decodeTransaction(_ data: Data) -> TransitTransaction? {
        guard data.count == 7, data.bigEndianInt(start: 0, length: 4) != 0 else { return nil }
        let date = date(minutes: data.bigEndianInt(start: 0, length: 3))
        let validator = data.bigEndianInt(start: 3, length: 2)
        let fare = price(data, 5)
        let category: TransactionCategory
        let type: String
        switch validator & 7 {
        case 0: (category, type) = (.purchase, "Ticket Machine")
        case 1: (category, type) = (.bus, "Bus")
        default: (category, type) = (.train, "Subway")
        }
        let station = validator >> 3
        var transaction = TransitTransaction(
            date: date, time: dateTimeText(date, format: "HH:mm"), amount: -Decimal(fare) / 100,
            terminalID: station != 0 ? String(station) : nil, type: type, category: category,
            rawData: data.hexString)
        transaction.currencyCode = "USD"
        transaction.issuerTimeZone = "America/New_York"
        transaction.amountIsSigned = true
        return transaction
    }
}
