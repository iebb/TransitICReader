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
            transactions: [],
            scannedAt: scannedAt
        )
    }
}
