import Foundation

/// Local CPU Tianfu Tong, distinct from both City Union and T-Union.
/// Protocol evidence and the Trip Reader comparison: docs/decoding/tianfutong.md.
struct TianfuTongDecoder: TransitCardDecoder {
    static let applicationAID = "D156000015B9ABB9B2D3A6D3C3" // 公共应用
    static let monthlyAID = "D156000015D4C2C6B1D3A6D3C3" // 月票应用

    static func canDecode(tag: CardTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        return await PBOCApplicationReader.select(iso, aid: applicationAID) != nil
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag,
              let selection = await PBOCApplicationReader.select(iso, aid: applicationAID),
              let info = await PBOCApplicationReader.binary(iso, sfi: 0x15, length: 33),
              let metadata = parseCardInfo(info) else { throw NFCTestError.unsupportedCard }

        ScanProgress.report(.balance)
        let balance = await PBOCApplicationReader.command(iso, cla: 0x80, ins: 0x5C, p1: 0, p2: 2, length: 4)
        ScanProgress.report(.transactions)
        var records = await PBOCApplicationReader.records(iso, sfi: 0x18, length: 23, kind: .transaction)
        records += await PBOCApplicationReader.records(iso, sfi: 0x09, length: 23, kind: .transaction)
        var fields = [ResultField(title: "Brand", value: "天府通"),
                      ResultField(title: "Issuing City", value: "成都"),
                      ResultField(title: "Currency", value: "CNY")]
        if let serial = metadata.serial { fields.append(ResultField(title: "Card Number", value: serial)) }
        if let date = metadata.issueDate { fields.append(ResultField(title: "Issue Date", value: date)) }
        if let date = metadata.expiryDate { fields.append(ResultField(title: "Expiry Date", value: date)) }
        var raw = [RawDataSection(title: "天府通 · 公共应用", fields: [
            RawDataField(title: "Application AID", value: applicationAID),
            RawDataField(title: "SELECT", value: selection.hexString),
            RawDataField(title: "Card Info SFI 0x15", value: info.hexString)
        ])]
        if let balance { raw.append(RawDataSection(title: "Cash Purse", fields: [RawDataField(title: "Balance", value: balance.hexString)])) }

        // The monthly application is a ride purse, never another CNY balance.
        // Read only its dated allocation table; do not mix ride debits into cash history.
        ScanProgress.report(.details)
        if await PBOCApplicationReader.select(iso, aid: monthlyAID) != nil,
           let monthlyInfo = await PBOCApplicationReader.binary(iso, sfi: 0x15, length: 33),
           let monthlyMetadata = parseCardInfo(monthlyInfo),
           metadata.serial != nil, monthlyMetadata.serial == metadata.serial,
           let table = await PBOCApplicationReader.binary(iso, sfi: 0x1A, length: 48) {
            for credit in monthlyCredits(table) {
                fields.append(ResultField(title: "Monthly Rides (\(credit.month))", value: "\(credit.rides)"))
            }
            raw.append(RawDataSection(title: "天府通 · 月票应用", fields: [
                RawDataField(title: "Application AID", value: monthlyAID),
                RawDataField(title: "Monthly Credits SFI 0x1A", value: table.hexString)
            ]))
        }
        // Leave the tag on the application represented by the returned snapshot.
        _ = await PBOCApplicationReader.select(iso, aid: applicationAID)
        let transactions = records.map(\.hex)
        var snapshot = TransitCardSnapshot(
            technology: "ISO7816", cardFamily: "天府通", identifierLabel: "UID",
            identifierValue: iso.identifier.hexString, rawIdentifierValue: iso.identifier.hexString,
            pmm: nil, systemCode: nil, selectedAID: applicationAID,
            balanceText: balance.flatMap(balanceMinor).map { formatCurrency(amount: Decimal($0) / 100, code: "CNY", fractionDigits: 2) },
            balanceDetail: nil, realSerialNumber: metadata.serial, region: "成都",
            resultFields: fields, rawSections: raw, rawTransactions: transactions,
            rawTransitHistory: [], scannedAt: scannedAt
        )
        snapshot.applications = [TransitApplication(snapshot: snapshot, cityCode: "6100", records: records)]
        return snapshot
    }

    struct CardInfo {
        let serial: String?
        let issueDate: String?
        let expiryDate: String?
    }

    static func parseCardInfo(_ data: Data) -> CardInfo? {
        guard data.count >= 33, data.prefix(4) == Data(hexString: "54466100") else { return nil }
        let serial = bcd(data.subdata(in: 10..<20))
        func date(_ range: Range<Int>) -> String? {
            guard let text = bcd(data.subdata(in: range)), parseDate(text, format: "yyyyMMdd") != nil else { return nil }
            return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))"
        }
        return CardInfo(serial: serial?.contains(where: { $0 != "0" }) == true ? serial : nil,
                        issueDate: date(20..<24), expiryDate: date(24..<28))
    }

    static func balanceMinor(_ data: Data) -> Int? {
        guard data.count == 4 else { return nil }
        // PBOC cash values are nonnegative; high-bit/all-FF error values are not balances.
        let value = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard value <= UInt32(Int32.max) else { return nil }
        return Int(value)
    }

    struct MonthlyCredit { let month: String; let rides: Int }
    static func monthlyCredits(_ data: Data) -> [MonthlyCredit] {
        guard data.count == 48 else { return [] }
        return (0..<12).compactMap { month in
            let offset = month * 4
            guard let yearText = bcd(data.subdata(in: offset..<offset + 2)),
                  let year = Int(yearText), (2000...2199).contains(year) else { return nil }
            return MonthlyCredit(month: String(format: "%04d-%02d", year, month + 1),
                                 rides: Int(data[offset + 2]) * 256 + Int(data[offset + 3]))
        }
    }

    static func decodeRecord(data: Data, index: Int) -> TransitTransaction? {
        guard data.count == 23, data.contains(where: { $0 != 0 }),
              let minor = balanceMinor(data.subdata(in: 5..<9)) else { return nil }
        let type = data[9]
        let known = [UInt8(0x02), 0x06, 0x09].contains(type)
        let timestamp = bcd(data.subdata(in: 16..<23))
        let date = timestamp.flatMap { parseDate($0, format: "yyyyMMddHHmmss") }
        let time = date == nil ? nil : timestamp.map { "\($0.dropFirst(8).prefix(2)):\($0.dropFirst(10).prefix(2)):\($0.suffix(2))" }
        var transaction = TransitTransaction(
            date: date, time: time, amount: (type == 0x02 ? 1 : -1) * Decimal(minor) / 100,
            terminalID: data.subdata(in: 10..<16).hexString,
            type: type == 0x02 ? "Top-up" : type == 0x09 ? "Transit payment" : type == 0x06 ? "Purchase" : String(format: "Transaction 0x%02X", type),
            category: type == 0x02 ? .topUp : known ? .payment : .unknown,
            rawData: data.hexString, recordNumber: index + 1
        )
        // Local terminal IDs do not carry a T-Union city or station prefix.
        // A zero-fare compound purchase alone does not prove entry or exit.
        transaction.currencyCode = "CNY"
        transaction.issuerTimeZone = "Asia/Shanghai"
        transaction.amountIsSigned = true
        transaction.amountKnown = known
        return transaction
    }

    private static func bcd(_ data: Data) -> String? {
        guard data.allSatisfy({ $0 >> 4 < 10 && $0 & 0x0F < 10 }) else { return nil }
        return data.hexString
    }

    private static func parseDate(_ text: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}
