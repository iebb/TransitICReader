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
        _ = try? await feliCa.polling(systemCode: Data([0xFE, 0x00]), requestCode: .systemCode, timeSlot: .max1)
        
        // 2. Read balance (6817), number (684F), and points (684B)
        let svcBalance = Data([0x17, 0x68])
        let svcNumber = Data([0x4F, 0x68])
        let svcPoints = Data([0x4B, 0x68])
        
        let readResult = try? await feliCa.readWithoutEncryption(
            serviceCodeList: [svcBalance, svcNumber, svcPoints],
            blockList: [Data([0x80, 0x00]), Data([0x81, 0x00]), Data([0x82, 0x00])]
        )
        
        guard let blocks = readResult?.2, blocks.count >= 2 else {
            throw NFCTestError.unsupportedCard
        }
        
        let balanceBlock = blocks[0]
        let numberBlock = blocks[1]
        
        // Balance: 2 bytes Little Endian at offset 0 of svc 6817
        let balance = Int(balanceBlock[0]) | (Int(balanceBlock[1]) << 8)
        
        // WAON Number: 8 bytes BCD at offset 0 of svc 684F
        let waonNumber = numberBlock.prefix(8).hexString.uppercased()
        
        // Points: Bytes 0-2 (3 bytes LE?) of svc 684B
        var pointsText = "Unavailable"
        var pointsVal: Int?
        if blocks.count >= 3 {
            let pBlock = blocks[2]
            pointsVal = Int(pBlock[0]) | (Int(pBlock[1]) << 8) | (Int(pBlock[2]) << 16)
            pointsText = "\(pointsVal!) pts"
        }
        
        let idm = feliCa.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        
        var resultFields = [
            ResultField(title: "WAON Number", value: waonNumber),
            ResultField(title: "Card Number (IDm)", value: formattedIDm)
        ]
        if pointsVal != nil {
            resultFields.insert(ResultField(title: "Points", value: pointsText), at: 1)
        }

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
            RawDataSection(title: "WAON Number (684F)", fields: [
                RawDataField(title: "Block 0", value: numberBlock.hexString),
                RawDataField(title: "BCD Parsed", value: waonNumber)
            ]),
            RawDataSection(title: "History (680B)", fields: [
                RawDataField(title: "Records", value: "\(transactions.count)"),
                RawDataField(title: "Format", value: "3 x 32-byte records")
            ])
        ]
        if let pVal = pointsVal, blocks.count >= 3 {
             rawSections.append(RawDataSection(title: "Points (684B)", fields: [
                 RawDataField(title: "Block 0", value: blocks[2].hexString),
                 RawDataField(title: "Parsed", value: "\(pVal)")
             ]))
        }

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: "WAON",
            identifierLabel: "WAON No.",
            identifierValue: waonNumber,
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
        var blocks: [Data] = []

        for blockIndex in 0..<6 {
            let blockList = [Data([0x80, UInt8(blockIndex)])]
            guard let readResult = try? await feliCa.readWithoutEncryption(
                serviceCodeList: [serviceCode],
                blockList: blockList
            ), let block = readResult.2.first, block.count >= 16 else {
                break
            }
            blocks.append(block)
        }

        var records: [String] = []
        for start in stride(from: 0, to: blocks.count, by: 2) {
            guard start + 1 < blocks.count else { break }
            let record = blocks[start] + blocks[start + 1]
            if record.allSatisfy({ $0 == 0 }) {
                continue
            }
            records.append(record.hexString.uppercased())
        }

        return records
    }
}
