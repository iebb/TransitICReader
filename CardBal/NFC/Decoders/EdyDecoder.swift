import Foundation
import CoreNFC

struct EdyDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        // 1. Switch to FE00 system
        _ = try? await feliCa.polling(systemCode: Data([0xFE, 0x00]), requestCode: .systemCode, timeSlot: .max1)
        
        // 2. Read balance (1317) and number (110B)
        let svcBalance = Data([0x17, 0x13])
        let svcNumber = Data([0x0B, 0x11])
        
        let readResult = try? await feliCa.readWithoutEncryption(
            serviceCodeList: [svcBalance, svcNumber],
            blockList: [Data([0x80, 0x00]), Data([0x81, 0x00])]
        )
        
        guard let blocks = readResult?.2, blocks.count >= 2 else {
            throw NFCTestError.unsupportedCard
        }
        
        let balanceBlock = blocks[0]
        let numberBlock = blocks[1]
        
        // Balance: 4 bytes Little Endian at offset 0 of svc 1317
        let balance = Int(balanceBlock[0]) | (Int(balanceBlock[1]) << 8) | (Int(balanceBlock[2]) << 16) | (Int(balanceBlock[3]) << 24)
        
        // Edy ID: 8 bytes BCD at offset 2 of svc 110B
        let edyId = numberBlock.subdata(in: 2..<10).hexString.uppercased()
        
        let idm = feliCa.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        
        let resultFields = [
            ResultField(title: "Edy ID", value: edyId),
            ResultField(title: "Card Number (IDm)", value: formattedIDm)
        ]
        
        // 3. Decode Issue Date from svc 110B (Bytes 10-13)
        // Bit layout: 15 bits days since 2000-01-01 (high), 17 bits seconds (low)
        // Byte order in FeliCa is typically LE for 32-bit uints.
        let totalVal = UInt32(numberBlock[13]) | (UInt32(numberBlock[12]) << 8) | (UInt32(numberBlock[11]) << 16) | (UInt32(numberBlock[10]) << 24)
        var issuedDateText = "Unavailable"
        if totalVal != 0 {
            let secondsInDay = Int(totalVal & 0x1FFFF)
            let daysSince2k = Int(totalVal >> 17)
            
            var components = DateComponents()
            components.year = 2000; components.month = 1; components.day = 1
            components.timeZone = TimeZone(identifier: "Asia/Tokyo")
            
            let calendar = Calendar.current
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
        if issuedDateText != "Unavailable" {
            finalResultFields.insert(ResultField(title: "Issue Date", value: issuedDateText), at: 1)
        }

        let rawSections = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"),
                RawDataField(title: "IDm", value: formattedIDm),
                RawDataField(title: "System", value: "FE00")
            ]),
            RawDataSection(title: "Balance (1317)", fields: [
                RawDataField(title: "Block 0", value: balanceBlock.hexString),
                RawDataField(title: "Parsed", value: "\(balance)")
            ]),
            RawDataSection(title: "Edy ID (110B)", fields: [
                RawDataField(title: "Block 0", value: numberBlock.hexString),
                RawDataField(title: "BCD Parsed (2-9)", value: edyId),
                RawDataField(title: "Issue Date Raw", value: String(format: "0x%08X", totalVal)),
                RawDataField(title: "Decoded", value: issuedDateText)
            ])
        ]

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: "Rakuten Edy",
            identifierLabel: "Edy ID",
            identifierValue: edyId,
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
            transactions: [],
            transitHistory: [],
            scannedAt: scannedAt
        )
    }
}
