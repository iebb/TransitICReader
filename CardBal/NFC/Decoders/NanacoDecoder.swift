import Foundation
import CoreNFC

struct NanacoDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        // 1. Switch to FE00 system
        _ = try? await feliCa.polling(systemCode: Data([0xFE, 0x00]), requestCode: .systemCode, timeSlot: .max1)
        
        // 2. Read balance (5597), number (558B), and points (560B)
        let svcBalance = Data([0x97, 0x55])
        let svcNumber = Data([0x8B, 0x55])
        let svcPoints = Data([0x0B, 0x56])
        let svcMeta = Data([0xCB, 0x55])
        
        let readResult = try? await feliCa.readWithoutEncryption(
            serviceCodeList: [svcBalance, svcNumber, svcPoints, svcMeta],
            blockList: [
                Data([0x80, 0x00]), // Balance svc, Block 0
                Data([0x81, 0x00]), // Number svc, Block 0
                Data([0x82, 0x01]), // Points svc, Block 1
                Data([0x83, 0x00])  // Meta svc, Block 0
            ]
        )
        
        guard let blocks = readResult?.2, blocks.count >= 4 else {
            throw NFCTestError.unsupportedCard
        }
        
        let balanceBlock = blocks[0]
        let numberBlock = blocks[1]
        let pointsBlock = blocks[2]
        let metaBlock = blocks[3]
        
        // Balance: 4 bytes LE at 5597
        let balance = Int(balanceBlock[0]) | (Int(balanceBlock[1]) << 8) | (Int(balanceBlock[2]) << 16) | (Int(balanceBlock[3]) << 24)
        
        // nanaco Number: 8 bytes BCD at 558B
        let nanacoNumber = numberBlock.prefix(8).hexString.uppercased()
        
        func parseFeliCaDate(_ b1: UInt8, _ b2: UInt8) -> String {
            let dateVal = (UInt16(b1) << 8) | UInt16(b2)
            let day = Int(dateVal & 0x1F)
            let month = Int((dateVal >> 5) & 0x0F)
            let yearPart = Int((dateVal >> 9) & 0x7F)
            return String(format: "%04d-%02d-%02d", 2000 + yearPart, month, day)
        }

        // Last Use Date: Bytes 0-1 of 55CB
        let lastUseDate = parseFeliCaDate(metaBlock[0], metaBlock[1])
        // Issue Date: Bytes 4-5 of 55CB
        let issueDate = parseFeliCaDate(metaBlock[4], metaBlock[5])

        // Points: Bytes 0-2 (3 bytes LE) of svc 560B block 1
        let pointsVal = Int(pointsBlock[0]) | (Int(pointsBlock[1]) << 8) | (Int(pointsBlock[2]) << 16)
        let pointsText = "\(pointsVal) pts"
        
        let idm = feliCa.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        
        let resultFields = [
            ResultField(title: "nanaco Number", value: nanacoNumber),
            ResultField(title: "Points", value: pointsText),
            ResultField(title: "Last Use Date", value: lastUseDate),
            ResultField(title: "Issue Date", value: issueDate),
            ResultField(title: "Card Number (IDm)", value: formattedIDm)
        ]
        
        var rawSections = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"),
                RawDataField(title: "IDm", value: formattedIDm),
                RawDataField(title: "System", value: "FE00")
            ]),
            RawDataSection(title: "Balance (5597)", fields: [
                RawDataField(title: "Block 0", value: balanceBlock.hexString),
                RawDataField(title: "Parsed", value: "\(balance)")
            ]),
            RawDataSection(title: "nanaco Number (558B)", fields: [
                RawDataField(title: "Block 0", value: numberBlock.hexString),
                RawDataField(title: "BCD Parsed", value: nanacoNumber)
            ]),
            RawDataSection(title: "Metadata (55CB)", fields: [
                RawDataField(title: "Block 0", value: metaBlock.hexString),
                RawDataField(title: "Last Use", value: lastUseDate),
                RawDataField(title: "Issue Date", value: issueDate)
            ]),
            RawDataSection(title: "Points (560B)", fields: [
                RawDataField(title: "Block 1", value: pointsBlock.hexString),
                RawDataField(title: "Parsed", value: "\(pointsVal)")
            ])
        ]

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: "nanaco",
            identifierLabel: "nanaco No.",
            identifierValue: nanacoNumber,
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
            transactions: [],
            scannedAt: scannedAt
        )
    }
}
