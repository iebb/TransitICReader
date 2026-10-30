import Foundation

struct NanacoDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        // 1. Switch to FE00 system
        guard await RetailFeliCaRead.select(feliCa) else { throw NFCTestError.unsupportedCard }
        
        // 2. Read balance (5597), number (558B), and points (560B)
        let svcBalance = Data([0x97, 0x55])
        let svcNumber = Data([0x8B, 0x55])
        let svcPoints = Data([0x0B, 0x56])
        let svcMeta = Data([0xCB, 0x55])
        
        guard let balanceBlock = await RetailFeliCaRead.block(feliCa, service: svcBalance) else {
            throw NFCTestError.unsupportedCard
        }
        let numberBlock = await RetailFeliCaRead.block(feliCa, service: svcNumber)
        let pointsBlock = await RetailFeliCaRead.block(feliCa, service: svcPoints, index: 1)
        let metaBlock = await RetailFeliCaRead.block(feliCa, service: svcMeta)
        
        // Balance: 4 bytes LE at 5597
        let balance = Int(balanceBlock[0]) | (Int(balanceBlock[1]) << 8) | (Int(balanceBlock[2]) << 16) | (Int(balanceBlock[3]) << 24)
        
        // nanaco Number: 8 bytes BCD at 558B
        let nanacoNumber = RetailFeliCaRead.number(numberBlock, bytes: 0..<8)
        
        func parseFeliCaDate(_ b1: UInt8, _ b2: UInt8) -> String? {
            let dateVal = (UInt16(b1) << 8) | UInt16(b2)
            let day = Int(dateVal & 0x1F)
            let month = Int((dateVal >> 5) & 0x0F)
            let yearPart = Int((dateVal >> 9) & 0x7F)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
            let components = DateComponents(year: 2000 + yearPart, month: month, day: day)
            guard dateVal != 0, let date = calendar.date(from: components),
                  calendar.component(.year, from: date) == 2000 + yearPart,
                  calendar.component(.month, from: date) == month,
                  calendar.component(.day, from: date) == day else { return nil }
            return String(format: "%04d-%02d-%02d", 2000 + yearPart, month, day)
        }

        // Last Use Date: Bytes 0-1 of 55CB
        let lastUseDate = metaBlock.flatMap { parseFeliCaDate($0[0], $0[1]) }
        // Issue Date: Bytes 4-5 of 55CB
        let issueDate = metaBlock.flatMap { parseFeliCaDate($0[4], $0[5]) }

        // Points: Bytes 0-2 (3 bytes LE) of svc 560B block 1
        let pointsVal = pointsBlock.map { Int($0[0]) | (Int($0[1]) << 8) | (Int($0[2]) << 16) }
        
        let idm = feliCa.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        
        var resultFields: [ResultField] = []
        if let nanacoNumber { resultFields.append(ResultField(title: "nanaco Number", value: nanacoNumber)) }
        if let pointsVal { resultFields.append(ResultField(title: "Points", value: "\(pointsVal) pts")) }
        if let lastUseDate { resultFields.append(ResultField(title: "Last Use Date", value: lastUseDate)) }
        if let issueDate { resultFields.append(ResultField(title: "Issue Date", value: issueDate)) }
        resultFields.append(ResultField(title: "Card Number (IDm)", value: formattedIDm))

        let transactions = await readHistoryRecords(feliCa: feliCa)
        
        var rawSections = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"),
                RawDataField(title: "IDm", value: formattedIDm),
                RawDataField(title: "System", value: "FE00")
            ]),
            RawDataSection(title: "Balance (5597)", fields: [
                RawDataField(title: "Block 0", value: balanceBlock.hexString),
                RawDataField(title: "Parsed", value: "\(balance)")
            ])
        ]
        if let numberBlock {
            var fields = [RawDataField(title: "Block 0", value: numberBlock.hexString)]
            if let nanacoNumber { fields.append(RawDataField(title: "BCD Parsed", value: nanacoNumber)) }
            rawSections.append(RawDataSection(title: "nanaco Number (558B)", fields: fields))
        }
        if let metaBlock {
            var fields = [RawDataField(title: "Block 0", value: metaBlock.hexString)]
            if let lastUseDate { fields.append(RawDataField(title: "Last Use", value: lastUseDate)) }
            if let issueDate { fields.append(RawDataField(title: "Issue Date", value: issueDate)) }
            rawSections.append(RawDataSection(title: "Metadata (55CB)", fields: fields))
        }
        if let pointsBlock, let pointsVal {
            rawSections.append(RawDataSection(title: "Points (560B)", fields: [
                RawDataField(title: "Block 1", value: pointsBlock.hexString),
                RawDataField(title: "Parsed", value: "\(pointsVal)")
            ]))
        }
        rawSections.append(RawDataSection(title: "History (564F)", fields: [
            RawDataField(title: "Records", value: "\(transactions.count)"),
            RawDataField(title: "Format", value: "5 x 16-byte records")
        ]))

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: "nanaco",
            identifierLabel: nanacoNumber == nil ? "Card Number (IDm)" : "nanaco No.",
            identifierValue: nanacoNumber ?? formattedIDm,
            rawIdentifierValue: idm,
            pmm: "Unavailable",
            systemCode: "FE00",
            selectedAID: nil,
            balanceText: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
            balanceDetail: "Parsed from service 0x5597 as 4-byte LE.",
            realSerialNumber: nanacoNumber,
            region: nil,
            resultFields: resultFields,
            rawSections: rawSections,
            rawTransactions: transactions,
            rawTransitHistory: [],
            scannedAt: scannedAt
        )
    }

    private static func readHistoryRecords(feliCa: FeliCaCard) async -> [String] {
        let serviceCode = Data([0x4F, 0x56])
        var records: [String] = []

        for blockIndex in 0..<5 {
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
