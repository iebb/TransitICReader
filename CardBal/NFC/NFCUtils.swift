import Foundation
import CoreNFC

struct ResultField: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: String
}

struct RawDataSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let fields: [RawDataField]
}

struct RawDataField: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: String
}

struct ParsedBalance: Hashable {
    let formatted: String
    let detail: String
    let rawFields: [RawDataField]
}

struct TransitCardSnapshot: Identifiable {
    let id = UUID()
    let technology: String
    let cardFamily: String
    let identifierLabel: String
    let identifierValue: String
    let rawIdentifierValue: String
    let systemCode: String?
    let selectedAID: String?
    let balanceText: String?
    let balanceDetail: String?
    let resultFields: [ResultField]
    let rawSections: [RawDataSection]
    let scannedAt: Date
}

func formatCurrency(amount: Decimal, code: String, fractionDigits: Int = 2) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(code)"
}

func octopusOffset(for date: Date) -> Int {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    let seed = (components.year ?? 2024) * 10000 + (components.month ?? 1) * 100 + (components.day ?? 1) + (components.hour ?? 0)
    var x = UInt64(seed)
    x ^= x << 13
    x ^= x >> 7
    x ^= x << 17
    return Int(x % 400) + 150
}

func ksx6924BalanceParser(data: Data) -> ParsedBalance? {
    guard data.count >= 4 else { return nil }
    let balance = data.bigEndianInt(start: 0, length: 4)
    return ParsedBalance(
        formatted: formatCurrency(amount: Decimal(balance), code: "KRW", fractionDigits: 0),
        detail: "Standard Korean KSX6924 balance.",
        rawFields: [RawDataField(title: "Balance Bytes", value: data.hexString)]
    )
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
    func sliceHexString(start: Int, length: Int) -> String {
        guard start < count else { return "" }
        let end = Swift.min(count, start + length)
        return self[start..<end].hexString
    }
    func bigEndianInt(start: Int, length: Int) -> Int {
        guard start + length <= count else { return 0 }
        var result: Int = 0
        for i in 0..<length {
            result = (result << 8) | Int(self[start + i])
        }
        return result
    }
}

extension NFCISO7816APDU {
    static func selectByName(_ aid: String) -> NFCISO7816APDU {
        let aidData = Data(hexString: aid)
        return NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: aidData, expectedResponseLength: -1)
    }

    static let ksx6924Balance = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0xF8, p1Parameter: 0x00, p2Parameter: 0x00, data: Data(), expectedResponseLength: 4)
    
    static let ksx6924CardInfo = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0xCA, p1Parameter: 0x9F, p2Parameter: 0x08, data: Data(), expectedResponseLength: -1)

    static func getData(tag: UInt16) -> NFCISO7816APDU {
        return NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xCA, p1Parameter: UInt8(tag >> 8), p2Parameter: UInt8(tag & 0xFF), data: Data(), expectedResponseLength: -1)
    }

    static func readRecord(recordNumber: UInt8, sfi: UInt8) -> NFCISO7816APDU {
        let p2 = (sfi << 3) | 0x04
        return NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: recordNumber, p2Parameter: p2, data: Data(), expectedResponseLength: -1)
    }

    static func getDataCommandData(tag: UInt16) -> Data {
        return Data([0x00, 0xCA, UInt8(tag >> 8), UInt8(tag & 0xFF), 0x00])
    }

    static func readRecordCommandData(recordNumber: UInt8, sfi: UInt8) -> Data {
        let p2 = (sfi << 3) | 0x04
        return Data([0x00, 0xB2, recordNumber, p2, 0x00])
    }
}

extension Data {
    init(hexString: String) {
        var data = Data()
        var status = hexString.startIndex
        while status < hexString.endIndex {
            let nextIndex = hexString.index(status, offsetBy: 2)
            if let byte = UInt8(hexString[status..<nextIndex], radix: 16) {
                data.append(byte)
            }
            status = nextIndex
        }
        self = data
    }
}
