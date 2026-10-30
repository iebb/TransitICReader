import Foundation

struct EdyDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        // 1. Switch to FE00 system
        guard await RetailFeliCaRead.select(feliCa) else { throw NFCTestError.unsupportedCard }
        
        // 2. Read balance (1317) and number (110B)
        let svcBalance = Data([0x17, 0x13])
        let svcNumber = Data([0x0B, 0x11])
        
        guard let balanceBlock = await RetailFeliCaRead.block(feliCa, service: svcBalance) else {
            throw NFCTestError.unsupportedCard
        }
        let numberBlock = await RetailFeliCaRead.block(feliCa, service: svcNumber)
        
        // Balance: 4 bytes Little Endian at offset 0 of svc 1317
        let balance = Int(balanceBlock[0]) | (Int(balanceBlock[1]) << 8) | (Int(balanceBlock[2]) << 16) | (Int(balanceBlock[3]) << 24)
        
        // Edy ID: 8 bytes BCD at offset 2 of svc 110B
        let edyId = RetailFeliCaRead.number(numberBlock, bytes: 2..<10)
        
        let idm = feliCa.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        
        var resultFields: [ResultField] = []
        if let edyId { resultFields.append(ResultField(title: "Edy ID", value: edyId)) }
        resultFields.append(ResultField(title: "Card Number (IDm)", value: formattedIDm))
        
        // 3. Decode Issue Date from svc 110B (Bytes 10-13)
        // Bit layout: 15 bits days since 2000-01-01 (high), 17 bits seconds (low)
        // This packed clock is big-endian in the number service.
        let totalVal = numberBlock.map { UInt32($0[13]) | (UInt32($0[12]) << 8) | (UInt32($0[11]) << 16) | (UInt32($0[10]) << 24) }
        var issuedDateText: String?
        if let totalVal, totalVal != 0, totalVal != UInt32.max, totalVal & 0x1FFFF < 86_400 {
            let secondsInDay = Int(totalVal & 0x1FFFF)
            let daysSince2k = Int(totalVal >> 17)
            
            var components = DateComponents()
            components.year = 2000; components.month = 1; components.day = 1
            components.timeZone = TimeZone(identifier: "Asia/Tokyo")
            
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            if let baseDate = calendar.date(from: components),
               let issuedDate = calendar.date(byAdding: .day, value: daysSince2k, to: baseDate),
               let finalDate = calendar.date(byAdding: .second, value: secondsInDay, to: issuedDate) {
                 let formatter = DateFormatter()
                 formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                 formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
                 issuedDateText = formatter.string(from: finalDate) + " JST"
            }
        }
        
        var finalResultFields = resultFields
        if let issuedDateText {
            finalResultFields.insert(ResultField(title: "Issue Date", value: issuedDateText), at: edyId == nil ? 0 : 1)
        }

        let transactions = await readHistoryRecords(feliCa: feliCa)

        var rawSections = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"),
                RawDataField(title: "IDm", value: formattedIDm),
                RawDataField(title: "System", value: "FE00")
            ]),
            RawDataSection(title: "Balance (1317)", fields: [
                RawDataField(title: "Block 0", value: balanceBlock.hexString),
                RawDataField(title: "Parsed", value: "\(balance)")
            ]),
            RawDataSection(title: "History (170F)", fields: [
                RawDataField(title: "Records", value: "\(transactions.count)"),
                RawDataField(title: "Format", value: "6 x 16-byte records")
            ])
        ]
        if let numberBlock, let totalVal {
            var fields = [RawDataField(title: "Block 0", value: numberBlock.hexString)]
            if let edyId { fields.append(RawDataField(title: "BCD Parsed (2-9)", value: edyId)) }
            fields.append(RawDataField(title: "Issue Date Raw", value: String(format: "0x%08X", totalVal)))
            if let issuedDateText { fields.append(RawDataField(title: "Decoded", value: issuedDateText)) }
            rawSections.insert(RawDataSection(title: "Edy ID (110B)", fields: fields), at: 2)
        }

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: "Rakuten Edy",
            identifierLabel: edyId == nil ? "Card Number (IDm)" : "Edy ID",
            identifierValue: edyId ?? formattedIDm,
            rawIdentifierValue: idm,
            pmm: "Unavailable",
            systemCode: "FE00",
            selectedAID: nil,
            balanceText: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
            balanceDetail: "Parsed from service 0x1317 as 4-byte LE.",
            realSerialNumber: edyId,
            region: nil,
            resultFields: finalResultFields,
            rawSections: rawSections,
            rawTransactions: transactions,
            rawTransitHistory: [],
            scannedAt: scannedAt
        )
    }

    private static func readHistoryRecords(feliCa: FeliCaCard) async -> [String] {
        let serviceCode = Data([0x0F, 0x17])
        var records: [String] = []

        for blockIndex in 0..<6 {
            guard let block = await RetailFeliCaRead.block(feliCa, service: serviceCode, index: UInt8(blockIndex)) else {
                break
            }

            if block.allSatisfy({ $0 == 0 }) {
                continue
            }

            records.append(block.hexString.uppercased())
        }

        return records
    }
}
