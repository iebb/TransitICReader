import Foundation
import CoreNFC

struct WAONDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        // 1. Switch to FE00 system
        guard await RetailFeliCaRead.select(feliCa) else { throw NFCTestError.unsupportedCard }
        
        // 2. Read balance (6817), number (684F), and points (684B)
        let svcBalance = Data([0x17, 0x68])
        let svcNumber = Data([0x4F, 0x68])
        let svcPoints = Data([0x4B, 0x68])
        
        guard let balanceBlock = await RetailFeliCaRead.block(feliCa, service: svcBalance) else {
            throw NFCTestError.unsupportedCard
        }
        let numberBlock = await RetailFeliCaRead.block(feliCa, service: svcNumber)
        let pointsBlock = await RetailFeliCaRead.block(feliCa, service: svcPoints)
        
        // Balance: 2 bytes Little Endian at offset 0 of svc 6817
        let balance = Int(balanceBlock[0]) | (Int(balanceBlock[1]) << 8)
        
        // WAON Number: 8 bytes BCD at offset 0 of svc 684F
        let waonNumber = RetailFeliCaRead.number(numberBlock, bytes: 0..<8)
        
        // Points: Bytes 0-2 (3 bytes LE?) of svc 684B
        let pointsVal = pointsBlock.map { Int($0[0]) | (Int($0[1]) << 8) | (Int($0[2]) << 16) }
        
        let idm = feliCa.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        
        var resultFields: [ResultField] = []
        if let waonNumber { resultFields.append(ResultField(title: "WAON Number", value: waonNumber)) }
        if let pointsVal { resultFields.append(ResultField(title: "Points", value: "\(pointsVal) pts")) }
        resultFields.append(ResultField(title: "Card Number (IDm)", value: formattedIDm))

        let transactions = await readHistoryRecords(feliCa: feliCa)
        
        var rawSections = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"),
                RawDataField(title: "IDm", value: formattedIDm),
                RawDataField(title: "System", value: "FE00")
            ]),
            RawDataSection(title: "Balance (6817)", fields: [
                RawDataField(title: "Block 0", value: balanceBlock.hexString),
                RawDataField(title: "Parsed", value: "\(balance)")
            ]),
            RawDataSection(title: "History (680B)", fields: [
                RawDataField(title: "Records", value: "\(transactions.count)"),
                RawDataField(title: "Format", value: "3 x 32-byte records")
            ])
        ]
        if let numberBlock {
            var fields = [RawDataField(title: "Block 0", value: numberBlock.hexString)]
            if let waonNumber { fields.append(RawDataField(title: "BCD Parsed", value: waonNumber)) }
            rawSections.insert(RawDataSection(title: "WAON Number (684F)", fields: fields), at: 2)
        }
        if let pVal = pointsVal, let pointsBlock {
             rawSections.append(RawDataSection(title: "Points (684B)", fields: [
                 RawDataField(title: "Block 0", value: pointsBlock.hexString),
                 RawDataField(title: "Parsed", value: "\(pVal)")
             ]))
        }

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: "WAON",
            identifierLabel: waonNumber == nil ? "Card Number (IDm)" : "WAON No.",
            identifierValue: waonNumber ?? formattedIDm,
            rawIdentifierValue: idm,
            pmm: "Unavailable",
            systemCode: "FE00",
            selectedAID: nil,
            balanceText: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
            balanceDetail: "Parsed from service 0x6817 as 2-byte LE.",
            realSerialNumber: waonNumber,
            region: nil,
            resultFields: resultFields,
            rawSections: rawSections,
            rawTransactions: transactions,
            rawTransitHistory: [],
            scannedAt: scannedAt
        )
    }

    private static func readHistoryRecords(feliCa: NFCFeliCaTag) async -> [String] {
        let serviceCode = Data([0x0B, 0x68])
        var records: [String] = []
        for start in stride(from: 0, to: 6, by: 2) {
            // Keep each record's addressed pair together even if an earlier
            // pair is unreadable; never compact blocks across a missing slot.
            let first = await RetailFeliCaRead.block(feliCa, service: serviceCode, index: UInt8(start))
            let second = await RetailFeliCaRead.block(feliCa, service: serviceCode, index: UInt8(start + 1))
            guard let first, let second else { continue }
            let record = first + second
            if record.allSatisfy({ $0 == 0 }) {
                continue
            }
            records.append(record.hexString.uppercased())
        }

        return records
    }
}
