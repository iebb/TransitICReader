import Foundation
import CoreNFC
import os

struct NAMANEDecoder {
    static func parseNAMANELog(_ block: Data, sfi: UInt8, recordIndex: Int, isNAMANE: Bool, logger: os.Logger) -> TransitTransaction? {
        if block.allSatisfy({ $0 == 0x00 }) || block.allSatisfy({ $0 == 0xFF }) { return nil }
        
        // Offset 0: Type
        // Offset 2-5: Balance (4 BE)
        // Offset 6-9: Counter / Record ID (4 BE)
        // Offset 10-13: Amount (4 BE)
        if block.count >= 14 {
            let balance = Decimal(block.bigEndianInt(start: 2, length: 4))
            let amountVal = block.bigEndianInt(start: 10, length: 4)
            let amount = Decimal(amountVal)
            let type = block[0]
            let isTopup = type == 0x02
            let signedAmount = isTopup ? amount : -amount
            let typeStr = isTopup ? "Top-up" : (amountVal == 0 ? "Entry" : "Payment")
            let cardRecordID = Int(block.bigEndianInt(start: 6, length: 4))
            return TransitTransaction(date: nil, time: nil, amount: signedAmount, terminalID: block.prefix(2).hexString, type: typeStr, balanceAfter: balance, rawData: block.hexString, recordNumber: cardRecordID)
        }
        return nil
    }
}
