import Foundation
import CoreNFC
import os
import SwiftUI

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
    let pmm: String?
    let systemCode: String?
    let selectedAID: String?
    let balanceText: String?
    let balanceDetail: String?
    let realSerialNumber: String?
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
    let formatter = ISO8601DateFormatter()
    let changeDate = formatter.date(from: "2017-10-01T00:00:00+08:00") ?? .distantPast
    return date >= changeDate ? 500 : 350
}

func ksx6924BalanceParser(data: Data) -> ParsedBalance? {
    guard data.count >= 4 else { return nil }
    let balance = data.bigEndianInt(start: 0, length: 4)
    return ParsedBalance(
        formatted: formatCurrency(amount: Decimal(balance), code: "KRW", fractionDigits: 0),
        detail: "Parsed as a 4-byte big-endian stored-value balance from the KS X 6924 balance APDU.",
        rawFields: [
            RawDataField(title: "Balance Bytes", value: data.sliceHexString(start: 0, length: 4)),
            RawDataField(title: "Stored Value", value: String(balance)),
            RawDataField(title: "Formula", value: "b0<<24 | b1<<16 | b2<<8 | b3")
        ]
    )
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
    var binaryString: String {
        map { String($0, radix: 2).leftPadded(to: 8, with: "0") }.joined()
    }
    var systemCodeCandidates: [String] {
        guard count == 2 else { return [hexString.uppercased()] }
        return [
            String(format: "%02X%02X", self[0], self[1]),
            String(format: "%02X%02X", self[1], self[0])
        ]
    }
    func sliceHexString(start: Int, length: Int) -> String {
        guard start >= 0, length > 0, count >= start + length else { return "Unavailable" }
        return self[start..<(start + length)].map { String(format: "%02X", $0) }.joined()
    }
    func bigEndianInt(start: Int, length: Int) -> Int {
        guard start >= 0, length > 0, count >= start + length else { return 0 }
        return self[start..<(start + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
}

extension NFCISO7816APDU {
    static func selectByName(_ aid: String) -> NFCISO7816APDU {
        NFCISO7816APDU(data: selectCommandData(aid: aid))!
    }

    static var ksx6924Balance: NFCISO7816APDU {
        NFCISO7816APDU(
            instructionClass: 0x90,
            instructionCode: 0x4C,
            p1Parameter: 0x00,
            p2Parameter: 0x00,
            data: Data(),
            expectedResponseLength: 4
        )
    }

    static var ksx6924CardInfo: NFCISO7816APDU {
        NFCISO7816APDU(data: ksx6924CardInfoCommand)!
    }

    static var ksx6924BalanceCommand: Data {
        Data([0x90, 0x4C, 0x00, 0x00, 0x04])
    }

    static var ksx6924CardInfoCommand: Data {
        Data([0x00, 0xA4, 0x00, 0x00, 0x02, 0x42, 0x00])
    }

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

    static func selectCommandData(aid: String) -> Data {
        let aidData = Data(hexString: aid)
        return Data([0x00, 0xA4, 0x04, 0x00, UInt8(aidData.count)]) + aidData + Data([0x00])
    }

    static func custom(commandData: Data) -> NFCISO7816APDU {
        NFCISO7816APDU(data: commandData)!
    }
}

extension Data {
    init(hexString: String) {
        var data = Data()
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count % 2 != 0 {
            text = "0" + text
        }
        var status = text.startIndex
        while status < text.endIndex {
            let nextIndex = text.index(status, offsetBy: 2)
            if let byte = UInt8(text[status..<nextIndex], radix: 16) {
                data.append(byte)
            }
            status = nextIndex
        }
        self = data
    }
}

enum StatusKind {
    case idle
    case success
    case error
}

@MainActor
final class NFCTransitReader: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "sm.nekoko.CardBal", category: "NFC")

    @Published private(set) var latestSnapshot: TransitCardSnapshot?
    @Published private(set) var statusMessage = "Ready to scan."
    @Published private(set) var isScanning = false

    private var latestStatusKind: StatusKind = .idle
    private var session: NFCTagReaderSession?

    var isNFCAvailable: Bool {
        NFCTagReaderSession.readingAvailable
    }

    var statusSymbol: String {
        switch latestStatusKind {
        case .idle: return "dot.radiowaves.left.and.right"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var statusColor: Color {
        switch latestStatusKind {
        case .idle: return .secondary
        case .success: return .green
        case .error: return .orange
        }
    }

    func startScanning() {
        beginScanning()
    }

    func beginScanning() {
        guard isNFCAvailable else {
            updateStatus("NFC reading is not available.", kind: .error)
            return
        }

        guard let session = NFCTagReaderSession(pollingOption: [.iso18092, .iso14443], delegate: self, queue: nil) else {
            updateStatus("Unable to start session.", kind: .error)
            return
        }

        session.alertMessage = "Hold your iPhone near a transit card."
        self.session = session
        isScanning = true
        updateStatus("Scanning...", kind: .idle)
        session.begin()
    }

    private func updateStatus(_ message: String, kind: StatusKind) {
        statusMessage = message
        latestStatusKind = kind
        logger.log("Status: \(message)")
    }

    private func finish(with snapshot: TransitCardSnapshot, session: NFCTagReaderSession) {
        latestSnapshot = snapshot
        updateStatus("Read successful: \(snapshot.cardFamily)", kind: .success)
        session.invalidate()
        isScanning = false
    }

    private func fail(_ message: String, session: NFCTagReaderSession) {
        updateStatus(message, kind: .error)
        session.invalidate(errorMessage: message)
        isScanning = false
    }
}

extension NFCTransitReader: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        logger.log("NFC session active.")
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            self.isScanning = false
            let nsError = error as NSError
            if nsError.code != 200 {
                self.updateStatus("Session invalidated: \(error.localizedDescription)", kind: .error)
            } else {
                self.updateStatus("Ready to scan.", kind: .idle)
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }

        Task {
            do {
                try await session.connect(to: tag)
                let snapshot: TransitCardSnapshot

                switch tag {
                case .feliCa(let feliCa):
                    snapshot = try await decodeFeliCaSnapshot(from: feliCa)
                case .iso7816(let iso7816):
                    snapshot = try await decodeISO7816Snapshot(from: iso7816)
                default:
                    throw NFCTestError.unsupportedCard
                }

                await MainActor.run {
                    self.finish(with: snapshot, session: session)
                }
            } catch {
                await MainActor.run {
                    self.fail("Failed to read card.", session: session)
                }
            }
        }
    }
}

private enum NFCTestError: Error {
    case unsupportedCard
}

private struct FeliCaCardProfile {
    let displayName: String
    let systemCode: String
    let serviceCode: String
    let serviceCodeLittleEndian: Data
    let cardNumberTitle: String?
    let brandOverrides: [String: String]
    let parseBalance: (Data, Date) -> ParsedBalance?

    static func matching(candidates: [String]) -> FeliCaCardProfile? {
        let normalized = Set(candidates.map { $0.uppercased() })
        return all.first(where: { normalized.contains($0.systemCode) })
    }

    private static let all: [FeliCaCardProfile] = [
        FeliCaCardProfile(
            displayName: "Japan Transit IC",
            systemCode: "0003",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            cardNumberTitle: "Card Number (IDm)",
            brandOverrides: [
                "86A7": "Suica",
                "927A": "Hayakaken"
            ],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
                    detail: "Parsed from bytes 11-12 in little-endian order from service 0x008B.",
                    rawFields: [
                        RawDataField(title: "Balance Bytes", value: block.sliceHexString(start: 11, length: 2)),
                        RawDataField(title: "Stored Value", value: String(balance)),
                        RawDataField(title: "Formula", value: "Int(byte11) + (Int(byte12) << 8)")
                    ]
                )
            }
        ),
        FeliCaCardProfile(
            displayName: "Octopus",
            systemCode: "8008",
            serviceCode: "0117",
            serviceCodeLittleEndian: Data([0x17, 0x01]),
            cardNumberTitle: "Card Number (IDm)",
            brandOverrides: [:],
            parseBalance: { block, scannedAt in
                guard block.count >= 4 else { return nil }
                let rawStored = block.bigEndianInt(start: 0, length: 4)
                let offset = octopusOffset(for: scannedAt)
                let octopusValue = Decimal(rawStored - offset) / 10
                return ParsedBalance(
                    formatted: formatCurrency(amount: octopusValue, code: "HKD", fractionDigits: 1),
                    detail: "Octopus stores a raw value with an offset. The current formula is (raw - \(offset)) / 10.",
                    rawFields: [
                        RawDataField(title: "Balance Bytes", value: block.sliceHexString(start: 0, length: 4)),
                        RawDataField(title: "Stored Value", value: String(rawStored)),
                        RawDataField(title: "Offset", value: String(offset)),
                        RawDataField(title: "Formula", value: "(\(rawStored) - \(offset)) / 10 = \(octopusValue)")
                    ]
                )
            }
        ),
        FeliCaCardProfile(
            displayName: "IruCa",
            systemCode: "DE80",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            cardNumberTitle: "Card Number (IDm)",
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
                    detail: "Parsed from bytes 11-12 in little-endian order from service 0x008B.",
                    rawFields: [
                        RawDataField(title: "Balance Bytes", value: block.sliceHexString(start: 11, length: 2)),
                        RawDataField(title: "Stored Value", value: String(balance)),
                        RawDataField(title: "Formula", value: "Int(byte11) + (Int(byte12) << 8)")
                    ]
                )
            }
        ),
        FeliCaCardProfile(
            displayName: "SAPICA",
            systemCode: "865E",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            cardNumberTitle: "Card Number (IDm)",
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
                    detail: "Parsed from bytes 11-12 in little-endian order from service 0x008B.",
                    rawFields: [
                        RawDataField(title: "Balance Bytes", value: block.sliceHexString(start: 11, length: 2)),
                        RawDataField(title: "Stored Value", value: String(balance)),
                        RawDataField(title: "Formula", value: "Int(byte11) + (Int(byte12) << 8)")
                    ]
                )
            }
        ),
        FeliCaCardProfile(
            displayName: "PASPY",
            systemCode: "8592",
            serviceCode: "008B",
            serviceCodeLittleEndian: Data([0x8B, 0x00]),
            cardNumberTitle: "Card Number (IDm)",
            brandOverrides: [:],
            parseBalance: { block, _ in
                guard block.count >= 13 else { return nil }
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                return ParsedBalance(
                    formatted: formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0),
                    detail: "Parsed from bytes 11-12 in little-endian order from service 0x008B.",
                    rawFields: [
                        RawDataField(title: "Balance Bytes", value: block.sliceHexString(start: 11, length: 2)),
                        RawDataField(title: "Stored Value", value: String(balance)),
                        RawDataField(title: "Formula", value: "Int(byte11) + (Int(byte12) << 8)")
                    ]
                )
            }
        )
    ]

    func detectedBrand(using systemCodes: [String]) -> String {
        for systemCode in systemCodes.map({ $0.uppercased() }) {
            if let match = brandOverrides[systemCode] {
                return match
            }
        }
        return displayName
    }

    func resultFields(forIDm idm: String, detectedBrand: String) -> [ResultField] {
        var fields: [ResultField] = []
        if displayName == "Japan Transit IC" {
            fields.append(ResultField(title: "Detected Type", value: detectedBrand))
            if detectedBrand == displayName {
                fields.append(ResultField(title: "Note", value: "Exact brand is not exposed on this card's public FeliCa common-area data. Cards like ICOCA, manaca, TOICA, PASMO, and others can share the same profile."))
            }
        }
        guard let cardNumberTitle else { return fields }
        fields.append(ResultField(title: cardNumberTitle, value: idm))
        return fields
    }
}

struct KSX6924DateFormatting {
    static func formatBCDDateForDisplay(_ bcdDate: String?) -> String? {
        guard let bcdDate = bcdDate else { return nil }
        // bcdDate is expected as YYYY-MM-DD from the BCD parser
        let parts = bcdDate.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return bcdDate }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        guard let date = Calendar.current.date(from: components) else { return bcdDate }

        let format = UserDefaults.standard.string(forKey: "dateFormat") ?? "yyyy-MM-dd"
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func formatRawDateForDisplay(_ date: Date, includeTime: Bool = true) -> String {
        let format = UserDefaults.standard.string(forKey: "dateFormat") ?? "yyyy-MM-dd"
        let formatter = DateFormatter()
        
        var combinedFormat = format
        if includeTime {
            // Append time part if needed
            if format.contains("/") || format.contains("-") {
                combinedFormat += " HH:mm:ss"
            } else {
                combinedFormat += ", HH:mm:ss"
            }
        }
        
        formatter.dateFormat = combinedFormat
        return formatter.string(from: date)
    }
}

private struct KSX6924CardInfo {
    let cardNumber: String?
    let issueDate: String?
    let purseInfoFields: [ResultField]?
    let purseInfoRawFields: [RawDataField]?

    init(payload: Data, purseInfo: KSX6924PurseInfo?, configInfo: KSX6924ConfigDFInfo?) {
        self.cardNumber = purseInfo?.serial
            ?? configInfo?.serial
            ?? (payload.count >= 16 ? formatKoreanCardNumber(payload.sliceHexString(start: 8, length: 8)) : nil)
        self.issueDate = purseInfo?.issueDate ?? (payload.count >= 25 ? Self.formatIssueDate(payload[21...24]) : nil)
        self.purseInfoFields = purseInfo?.resultFields
        self.purseInfoRawFields = purseInfo?.rawDataFields
    }

    var resultFields: [ResultField] {
        var fields: [ResultField] = []
        if let cardNumber {
            fields.append(ResultField(title: "Card Number", value: cardNumber))
        }
        if let issueDate {
            fields.append(ResultField(title: "Issue Date", value: KSX6924DateFormatting.formatBCDDateForDisplay(issueDate) ?? issueDate))
        }
        if let purseInfoFields {
            fields.append(contentsOf: purseInfoFields)
        }
        return fields
    }

    private static func formatIssueDate(_ bytes: Data.SubSequence) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        guard hex.count == 8 else { return hex }
        let year = String(hex.prefix(4))
        let month = String(hex.dropFirst(4).prefix(2))
        let day = String(hex.suffix(2))
        if let _ = Int(month), let _ = Int(day) {
            return "\(year)-\(month)-\(day)"
        }
        return hex
    }
}

struct KSX6924ConfigDFInfo {
    let mainApplicationAID: String?
    let serial: String?

    init?(fciPayload: Data, selectedAID: String) {
        guard selectedAID == KSX6924CardProfile.configDFAID else {
            return nil
        }

        self.mainApplicationAID = findTLVValue(tag: [0x4F], in: fciPayload)?.hexString
        self.serial = findTLVValue(tag: [0x12], in: fciPayload).map { formatKoreanCardNumber($0.hexString) }
    }
}

// MARK: - KS X 6924 Purse Info Enums (lookup tables)

private enum KSX6924CardType: UInt8 {
    case prePaid = 0x00
    case postPay = 0x10
    case mobilePostPay = 0x20

    var displayName: String {
        switch self {
        case .prePaid: return "Pre-paid"
        case .postPay: return "Post-pay"
        case .mobilePostPay: return "Mobile post-pay"
        }
    }

    static func lookup(_ value: UInt8) -> String {
        KSX6924CardType(rawValue: value)?.displayName ?? String(format: "Unknown (0x%02X)", value)
    }
}

private enum KSX6924Algorithm: UInt8 {
    case seed = 0x00
    case tripleDES = 0x10

    var displayName: String {
        switch self {
        case .seed: return "SEED"
        case .tripleDES: return "3DES"
        }
    }

    static func lookup(_ value: UInt8) -> String {
        KSX6924Algorithm(rawValue: value)?.displayName ?? String(format: "Unknown (0x%02X)", value)
    }
}

private struct KSX6924IDCenter {
    static let names: [UInt8: String] = [
        0x00: "Reserved",
        0x01: "Korea Financial Telecommunications and Clearings Institute",
        0x02: "A-Cash",
        0x03: "Mybi",
        0x05: "V-Cash",
        0x06: "Mondex Korea",
        0x07: "Korea Expressway Corporation",
        0x08: "Korea Smart Card Corporation",
        0x09: "KORAIL Networks",
        0x0b: "EB Card Corporation",
        0x0c: "Seoul Bus Transport Association",
        0x0d: "Cardnet"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

private struct KSX6924UserCode {
    static let names: [UInt8: String] = [
        0x01: "Regular/Normal",
        0x02: "Child",
        0x04: "Youth",
        0x06: "Elderly",
        0x0f: "Test",
        0xff: "Inactive"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

private struct KSX6924DisRate {
    static let names: [UInt8: String] = [
        0x00: "No discount",
        0x10: "Disabled, basic",
        0x11: "Disabled, companion",
        0x20: "Merit, basic",
        0x21: "Merit, companion"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

private struct KSX6924TCode {
    static let names: [UInt8: String] = [
        0x00: "None",
        0x01: "SK Telecom",
        0x02: "Korea Telecom",
        0x03: "LG Uplus"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

private struct KSX6924CCode {
    static let names: [UInt8: String] = [
        0x00: "None",
        0x01: "KB Kookmin Bank",
        0x02: "Nonghyup Bank",
        0x03: "Lotte Card",
        0x04: "BC Card",
        0x05: "Samsung Card",
        0x06: "Shinhan Bank",
        0x07: "Citibank Korea",
        0x08: "Korea Exchange Bank",
        0x09: "Woori",
        0x0a: "Hana SK Card",
        0x0b: "Hyundai Capital Services"
    ]

    static func lookup(_ value: UInt8) -> String {
        names[value] ?? String(format: "Unknown (0x%02X)", value)
    }
}

private struct KSX6924PurseInfo {
    let rawData: Data
    let serial: String
    let issueDate: String?

    // Full purse info fields (matching on-card binary layout)
    let cardType: UInt8?
    let algorithm: UInt8?
    let vk: UInt8?
    let idCenter: UInt8?
    let csn: String?        // 8 bytes BCD
    let idtr: String?       // 5 bytes BCD
    let expiryDate: String?
    let userCode: UInt8?
    let disRate: UInt8?
    let balMax: Int?         // 4 bytes big-endian
    let bra: String?         // 2 bytes BCD
    let mmax: Int?           // 4 bytes big-endian
    let tcode: UInt8?
    let ccode: UInt8?
    let rfu: String?         // 8 bytes

    init?(fciPayload: Data) {
        guard let purseInfoData = findTLVValue(tag: [0xB0], in: fciPayload), purseInfoData.count >= 21 else {
            return nil
        }

        self.rawData = purseInfoData

        // Purse info structure layout (KS X 6924):
        //  0: cardType (1)
        //  1: alg (1)
        //  2: vk (1)
        //  3: idCenter (1)
        //  4-11: CSN (8 bytes BCD)
        // 12-16: IDTR (5 bytes BCD)
        // 17-20: issueDate (4 bytes BCD: YYYYMMDD)
        // 21-24: expiryDate (4 bytes BCD: YYYYMMDD)
        // 25: userCode (1)
        // 26: disRate (1)
        // 27-30: balMax (4 bytes big-endian)
        // 31-32: BRA (2 bytes BCD)
        // 33-36: mmax (4 bytes big-endian)
        // 37: tcode (1)
        // 38: ccode (1)
        // 39-46: RFU (8 bytes)

        self.cardType = purseInfoData.count > 0 ? purseInfoData[purseInfoData.startIndex] : nil
        self.algorithm = purseInfoData.count > 1 ? purseInfoData[purseInfoData.startIndex + 1] : nil
        self.vk = purseInfoData.count > 2 ? purseInfoData[purseInfoData.startIndex + 2] : nil
        self.idCenter = purseInfoData.count > 3 ? purseInfoData[purseInfoData.startIndex + 3] : nil

        self.csn = purseInfoData.count >= 12 ? purseInfoData.sliceHexString(start: 4, length: 8) : nil
        self.serial = formatKoreanCardNumber(csn ?? purseInfoData.sliceHexString(start: 4, length: 8))

        self.idtr = purseInfoData.count >= 17 ? purseInfoData.sliceHexString(start: 12, length: 5) : nil
        self.issueDate = purseInfoData.count >= 21 ? Self.parseBCDDate(purseInfoData, offset: 17) : nil
        self.expiryDate = purseInfoData.count >= 25 ? Self.parseBCDDate(purseInfoData, offset: 21) : nil
        self.userCode = purseInfoData.count > 25 ? purseInfoData[purseInfoData.startIndex + 25] : nil
        self.disRate = purseInfoData.count > 26 ? purseInfoData[purseInfoData.startIndex + 26] : nil
        self.balMax = purseInfoData.count >= 31 ? purseInfoData.bigEndianInt(start: 27, length: 4) : nil
        self.bra = purseInfoData.count >= 33 ? purseInfoData.sliceHexString(start: 31, length: 2) : nil
        self.mmax = purseInfoData.count >= 37 ? purseInfoData.bigEndianInt(start: 33, length: 4) : nil
        self.tcode = purseInfoData.count > 37 ? purseInfoData[purseInfoData.startIndex + 37] : nil
        self.ccode = purseInfoData.count > 38 ? purseInfoData[purseInfoData.startIndex + 38] : nil
        self.rfu = purseInfoData.count >= 47 ? purseInfoData.sliceHexString(start: 39, length: 8) : nil
    }

    var resultFields: [ResultField] {
        var fields: [ResultField] = []
        if let cardType {
            fields.append(ResultField(title: "Card Type", value: KSX6924CardType.lookup(cardType)))
        }
        if let algorithm {
            fields.append(ResultField(title: "Algorithm", value: KSX6924Algorithm.lookup(algorithm)))
        }
        if let idCenter {
            fields.append(ResultField(title: "ID Center", value: KSX6924IDCenter.lookup(idCenter)))
        }
        if let userCode {
            fields.append(ResultField(title: "User Type", value: KSX6924UserCode.lookup(userCode)))
        }
        if let disRate {
            fields.append(ResultField(title: "Discount", value: KSX6924DisRate.lookup(disRate)))
        }
        if let expiryDate {
            fields.append(ResultField(title: "Expiry Date", value: KSX6924DateFormatting.formatBCDDateForDisplay(expiryDate) ?? ""))
        }
        if let balMax {
            fields.append(ResultField(title: "Max Balance", value: formatCurrency(amount: Decimal(balMax), code: "KRW", fractionDigits: 0)))
        }
        if let mmax {
            fields.append(ResultField(title: "Max Transaction", value: formatCurrency(amount: Decimal(mmax), code: "KRW", fractionDigits: 0)))
        }
        if let tcode {
            fields.append(ResultField(title: "Telecom", value: KSX6924TCode.lookup(tcode)))
        }
        if let ccode {
            fields.append(ResultField(title: "Credit Card", value: KSX6924CCode.lookup(ccode)))
        }
        return fields
    }

    var rawDataFields: [RawDataField] {
        var fields: [RawDataField] = [
            RawDataField(title: "Raw Purse Info", value: rawData.hexString),
            RawDataField(title: "Length", value: "\(rawData.count) bytes")
        ]
        if let cardType {
            fields.append(RawDataField(title: "Card Type", value: String(format: "0x%02X → %@", cardType, KSX6924CardType.lookup(cardType))))
        }
        if let algorithm {
            fields.append(RawDataField(title: "Algorithm", value: String(format: "0x%02X → %@", algorithm, KSX6924Algorithm.lookup(algorithm))))
        }
        if let vk {
            fields.append(RawDataField(title: "VK", value: String(format: "0x%02X", vk)))
        }
        if let idCenter {
            fields.append(RawDataField(title: "ID Center", value: String(format: "0x%02X → %@", idCenter, KSX6924IDCenter.lookup(idCenter))))
        }
        if let csn {
            fields.append(RawDataField(title: "CSN (BCD)", value: csn))
        }
        if let idtr {
            fields.append(RawDataField(title: "IDTR (BCD)", value: idtr))
        }
        if let issueDate {
            fields.append(RawDataField(title: "Issue Date (BCD)", value: issueDate))
        }
        if let expiryDate {
            fields.append(RawDataField(title: "Expiry Date (BCD)", value: expiryDate))
        }
        if let userCode {
            fields.append(RawDataField(title: "User Code", value: String(format: "0x%02X → %@", userCode, KSX6924UserCode.lookup(userCode))))
        }
        if let disRate {
            fields.append(RawDataField(title: "Discount Rate", value: String(format: "0x%02X → %@", disRate, KSX6924DisRate.lookup(disRate))))
        }
        if let balMax {
            fields.append(RawDataField(title: "Max Balance", value: "\(balMax)"))
        }
        if let bra {
            fields.append(RawDataField(title: "BRA (BCD)", value: bra))
        }
        if let mmax {
            fields.append(RawDataField(title: "Max Transaction", value: "\(mmax)"))
        }
        if let tcode {
            fields.append(RawDataField(title: "T-Code", value: String(format: "0x%02X → %@", tcode, KSX6924TCode.lookup(tcode))))
        }
        if let ccode {
            fields.append(RawDataField(title: "C-Code", value: String(format: "0x%02X → %@", ccode, KSX6924CCode.lookup(ccode))))
        }
        if let rfu {
            fields.append(RawDataField(title: "RFU", value: rfu))
        }
        return fields
    }

    private static func parseBCDDate(_ data: Data, offset: Int) -> String? {
        guard data.count >= offset + 4 else { return nil }
        let startIdx = data.startIndex + offset
        let hex = data[startIdx..<(startIdx + 4)].map { String(format: "%02X", $0) }.joined()
        guard hex.count == 8 else { return nil }
        let year = String(hex.prefix(4))
        let month = String(hex.dropFirst(4).prefix(2))
        let day = String(hex.suffix(2))
        guard let monthInt = Int(month), let dayInt = Int(day), (1...12).contains(monthInt), (1...31).contains(dayInt) else {
            return nil
        }
        return "\(year)-\(month)-\(day)"
    }
}

private struct BERTLVNode {
    let tag: [UInt8]
    let value: Data

    var isConstructed: Bool {
        guard let first = tag.first else { return false }
        return (first & 0x20) != 0
    }
}

private func findTLVValue(tag targetTag: [UInt8], in data: Data) -> Data? {
    parseBERTLVs(in: data).lazy.compactMap { node -> Data? in
        if node.tag == targetTag {
            return node.value
        }
        if node.isConstructed {
            return findTLVValue(tag: targetTag, in: node.value)
        }
        return nil
    }.first
}

private func parseBERTLVs(in data: Data) -> [BERTLVNode] {
    var nodes: [BERTLVNode] = []
    var index = data.startIndex

    while index < data.endIndex {
        let tagStart = index
        index = data.index(after: index)

        if data[tagStart] & 0x1F == 0x1F {
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if byte & 0x80 == 0 {
                    break
                }
            }
        }

        let tagEnd = index
        guard index < data.endIndex else { break }

        let firstLengthByte = data[index]
        index = data.index(after: index)

        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let byteCount = Int(firstLengthByte & 0x7F)
            guard byteCount > 0, data.distance(from: index, to: data.endIndex) >= byteCount else { break }
            var accumulated = 0
            for _ in 0..<byteCount {
                accumulated = (accumulated << 8) | Int(data[index])
                index = data.index(after: index)
            }
            length = accumulated
        }

        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else { break }
        let valueEnd = data.index(index, offsetBy: length)
        nodes.append(BERTLVNode(tag: Array(data[tagStart..<tagEnd]), value: Data(data[index..<valueEnd])))
        index = valueEnd
    }

    return nodes
}

private struct CalypsoCardNumber {
    let sourceBytes: String
    let decimal: String
    let paddedDecimal: String
    let formatted: String
}

private struct CalypsoRecordProbeResult {
    let title: String
    let description: String
    let command: Data
    let response: NFCISO7816ResponseAPDU
}

private struct NiceBestContractEntry {
    let index: Int
    let tariffKey: Int
    let tariffStructure: String
    let tariffPriority: String
    let contractPointer: Int
}

private struct NiceContractSummary {
    let contractType: String
    let provider: String
    let linkedTariffID: String
    let serialNumber: String
    let saleDate: String?
    let status: String?
    let validityStartDate: String?
    let validityEndDate: String?
    let passengerClass: String?
    let validityJourneys: String?
    let journeyOrigin: String?
    let journeyDestination: String?
    let journeyVia: String?
}

private struct NiceTicketLabel {
    let displayName: String
    let apkProductFamily: String?
}

private struct NiceEventSummary {
    let sourceTitle: String
    let eventDateStamp: String
    let eventTimeStamp: String
    let mainBitmap: String
    let eventCode: String?
    let eventCodeMode: String?
    let eventCodeType: String?
    let eventCodeResult: String?
    let eventServiceProvider: String
    let eventLocationID: String?
    let eventRouteNumber: String?
    let eventJourneyRun: String?
}

extension NFCTransitReader {
    private func decodeFeliCaSnapshot(from tag: any NFCFeliCaTag) async throws -> TransitCardSnapshot {
        let scannedAt = Date()
        let rawIDm = tag.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(rawIDm)
        let systemCodeBytes = tag.currentSystemCode.hexString.uppercased()
        let systemCodeCandidates = tag.currentSystemCode.systemCodeCandidates.map { $0.uppercased() }
        let requestedSystemCodes = (try? await tag.requestSystemCodes()) ?? []
        let allSystemCodes = Array(Set((systemCodeCandidates + requestedSystemCodes).map { $0.uppercased() })).sorted()
        let (_, pmmData, _) = try await tag.polling(
            systemCode: tag.currentSystemCode,
            requestCode: .noRequest,
            timeSlot: .max1
        )
        let pmm = pmmData.hexString.uppercased()
        guard let profile = FeliCaCardProfile.matching(candidates: allSystemCodes) else {
            return TransitCardSnapshot(
                technology: "FeliCa",
                cardFamily: "Unsupported FeliCa Card",
                identifierLabel: "IDm",
                identifierValue: formattedIDm,
                rawIdentifierValue: rawIDm,
                pmm: pmm,
                systemCode: systemCodeCandidates.first,
                selectedAID: nil,
                balanceText: nil,
                balanceDetail: "No balance decoder is configured for this FeliCa system code.",
                realSerialNumber: nil,
                resultFields: [],
                rawSections: [
                    RawDataSection(
                        title: "Tag",
                        fields: [
                            RawDataField(title: "Technology", value: "FeliCa"),
                            RawDataField(title: "IDm", value: formattedIDm),
                            RawDataField(title: "PMm", value: pmm),
                            RawDataField(title: "Current System Code Bytes", value: systemCodeBytes),
                            RawDataField(title: "System Code Candidates", value: systemCodeCandidates.joined(separator: ", ")),
                            RawDataField(title: "Requested System Codes", value: requestedSystemCodes.isEmpty ? "Unavailable" : requestedSystemCodes.joined(separator: ", "))
                        ]
                    )
                ],
                scannedAt: scannedAt
            )
        }

        let readResult = try await tag.readWithoutEncryption(
            serviceCodeList: [profile.serviceCodeLittleEndian],
            blockList: [Data([0x80, 0x00])]
        )
        let block = readResult.2.first
        let parsedBalance = block.flatMap { profile.parseBalance($0, scannedAt) }
        let detectedBrand = profile.detectedBrand(using: allSystemCodes)

        var rawSections: [RawDataSection] = [
            RawDataSection(
                title: "Tag",
                fields: [
                    RawDataField(title: "Technology", value: "FeliCa"),
                    RawDataField(title: "IDm", value: formattedIDm),
                    RawDataField(title: "PMm", value: pmm),
                    RawDataField(title: "System Code", value: profile.systemCode),
                    RawDataField(title: "Current System Code Bytes", value: systemCodeBytes),
                    RawDataField(title: "System Code Candidates", value: systemCodeCandidates.joined(separator: ", ")),
                    RawDataField(title: "Requested System Codes", value: requestedSystemCodes.isEmpty ? "Unavailable" : requestedSystemCodes.joined(separator: ", "))
                ]
            ),
            RawDataSection(
                title: "Read Without Encryption",
                fields: [
                    RawDataField(title: "Service Code", value: profile.serviceCode),
                    RawDataField(title: "Status Flag 1", value: String(readResult.0)),
                    RawDataField(title: "Status Flag 2", value: String(readResult.1)),
                    RawDataField(title: "Block Count", value: String(readResult.2.count)),
                    RawDataField(title: "Block 0", value: block?.hexString ?? "Unavailable")
                ]
            )
        ]

        if let parsedBalance {
            var fields = [RawDataField(title: "Decoder", value: parsedBalance.detail)]
            fields.append(contentsOf: parsedBalance.rawFields)
            rawSections.append(RawDataSection(title: "Decoded Balance", fields: fields))
        }

        if profile.displayName == "Japan Transit IC" {
            rawSections.append(
                RawDataSection(
                    title: "Card Type Detection",
                    fields: [
                        RawDataField(title: "Detected Type", value: detectedBrand),
                        RawDataField(title: "Note", value: "Some Japanese transit cards share the common system code 0003, so exact brand detection is only possible when the card also exposes a unique extra system code.")
                    ]
                )
            )
        }

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: detectedBrand,
            identifierLabel: "IDm",
            identifierValue: formattedIDm,
            rawIdentifierValue: rawIDm,
            pmm: pmm,
            systemCode: profile.systemCode,
            selectedAID: nil,
            balanceText: parsedBalance?.formatted,
            balanceDetail: parsedBalance?.detail,
            realSerialNumber: nil,
            resultFields: profile.resultFields(forIDm: formattedIDm, detectedBrand: detectedBrand),
            rawSections: rawSections,
            scannedAt: scannedAt
        )
    }

    private func decodeISO7816Snapshot(from tag: any NFCISO7816Tag) async throws -> TransitCardSnapshot {
        let scannedAt = Date()
        let selectedAID = tag.initialSelectedAID.uppercased()

        if CalypsoCardProfile.matches(aid: selectedAID) {
            return try await decodeCalypsoSnapshot(from: tag, selectedAID: selectedAID, scannedAt: scannedAt)
        }

        let initialSelectResponse = try? await sendISO7816Command(.selectByName(selectedAID), to: tag)
        let configInfo = initialSelectResponse.flatMap {
            KSX6924ConfigDFInfo(fciPayload: $0.payload ?? Data(), selectedAID: selectedAID)
        }

        let applicationAID = configInfo?.mainApplicationAID ?? selectedAID
        let profile = KSX6924CardProfile.matching(aid: applicationAID, configInfo: configInfo)

        let selectResponse: NFCISO7816ResponseAPDU?
        if applicationAID == selectedAID {
            selectResponse = initialSelectResponse
        } else {
            guard NFCISO7816AccessPolicy.isAllowed(aid: applicationAID) else {
                throw NFCTestError.unsupportedCard
            }
            selectResponse = try? await sendISO7816Command(.selectByName(applicationAID), to: tag)
        }

        let balanceResponse = try await sendISO7816Command(.ksx6924Balance, to: tag)
        let cardInfoResponse = try? await sendISO7816Command(.ksx6924CardInfo, to: tag)
        let purseInfo = selectResponse.flatMap { KSX6924PurseInfo(fciPayload: $0.payload ?? Data()) }
        let cardInfoPayload = cardInfoResponse?.payload ?? Data()
        let parsedCardInfo = KSX6924CardInfo(payload: cardInfoPayload, purseInfo: purseInfo, configInfo: configInfo)

        let payload = balanceResponse.payload ?? Data()
        let parsedBalance = profile.parseBalance(payload)

        var rawSections: [RawDataSection] = [
            RawDataSection(
                title: "Tag",
                fields: [
                    RawDataField(title: "Technology", value: "ISO7816"),
                    RawDataField(title: "UID", value: tag.identifier.hexString),
                    RawDataField(title: "Selected AID", value: selectedAID),
                    RawDataField(title: "Application AID", value: applicationAID),
                    RawDataField(title: "Historical Bytes", value: tag.historicalBytes?.hexString ?? "Unavailable"),
                    RawDataField(title: "Application Data", value: tag.applicationData?.hexString ?? "Unavailable")
                ]
            ),
            RawDataSection(
                title: "Balance APDU",
                fields: [
                    RawDataField(title: "Command", value: NFCISO7816APDU.ksx6924BalanceCommand.hexString),
                    RawDataField(title: "Response Payload", value: payload.hexString),
                    RawDataField(title: "SW1SW2", value: balanceResponse.statusWords)
                ]
            )
        ]

        if let parsedBalance {
            var fields = [RawDataField(title: "Decoder", value: parsedBalance.detail)]
            fields.append(contentsOf: parsedBalance.rawFields)
            rawSections.append(RawDataSection(title: "Decoded Balance", fields: fields))
        }

        if let cardInfoResponse {
            rawSections.append(
                RawDataSection(
                    title: "Card Info APDU",
                    fields: [
                        RawDataField(title: "Command", value: NFCISO7816APDU.ksx6924CardInfoCommand.hexString),
                        RawDataField(title: "Response Payload", value: cardInfoPayload.hexString),
                        RawDataField(title: "SW1SW2", value: cardInfoResponse.statusWords)
                    ]
                )
            )
        }

        if let purseInfoRawFields = parsedCardInfo.purseInfoRawFields {
            rawSections.append(RawDataSection(title: "Purse Info (Tag B0)", fields: purseInfoRawFields))
        }

        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: profile.displayName,
            identifierLabel: parsedCardInfo.cardNumber == nil ? "UID" : "Card Number",
            identifierValue: parsedCardInfo.cardNumber ?? tag.identifier.hexString,
            rawIdentifierValue: tag.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: parsedBalance?.formatted,
            balanceDetail: parsedBalance?.detail,
            realSerialNumber: nil,
            resultFields: parsedCardInfo.resultFields,
            rawSections: rawSections,
            scannedAt: scannedAt
        )
    }

    private func decodeCalypsoSnapshot(
        from tag: any NFCISO7816Tag,
        selectedAID: String,
        scannedAt: Date
    ) async throws -> TransitCardSnapshot {
        let profile = CalypsoCardProfile.matching(aid: selectedAID)
        let applicationAID = profile.applicationAID(for: selectedAID)
        let shouldReselect = NFCISO7816AccessPolicy.exactAIDs.contains(applicationAID)
        let selectResponse = shouldReselect ? (try? await sendISO7816Command(.selectByName(applicationAID), to: tag)) : nil
        let secureSessionResponse = try? await sendISO7816Command(.custom(commandData: Data([0x94, 0xA4, 0x08, 0x00, 0x02, 0x20, 0x00])), to: tag)

        let probeResponses = try await readISO7816Commands(profile.probeTargets.map(\.apdu), to: tag)
        let probeResults = Array(zip(profile.probeTargets, probeResponses))
        let fciPayload = probeResults.first(where: { $0.0.title == "GET DATA FCI Template" })?.1.payload
        let calypsoCardNumber = fciPayload.flatMap(parseCalypsoCardNumber)
        let exactRecordProbes = try await readCalypsoRecordProbes(on: tag)
        let bestContractPayload = exactRecordProbes.first(where: { $0.title == "Best Contracts" })?.response.payload ?? Data()
        let bestContracts = parseNiceBestContracts(from: bestContractPayload)
        let environmentPayload = exactRecordProbes.first(where: { $0.title == "Environment Record" })?.response.payload
        let contractBySlot = Dictionary(
            uniqueKeysWithValues: exactRecordProbes.compactMap { result -> (Int, NiceContractSummary)? in
                guard result.title.hasPrefix("Contract Summary Record "),
                      let index = Int(String(result.title.suffix(1))),
                      result.response.statusWords == "9000",
                      let payload = result.response.payload,
                      !payload.allSatisfy({ $0 == 0 })
                else { return nil }

                let bestContract = bestContracts.first(where: { $0.contractPointer == index || $0.index == index })
                    ?? NiceBestContractEntry(index: index, tariffKey: 0, tariffStructure: "Unknown", tariffPriority: "Unknown", contractPointer: index)
                guard let summary = parseNiceContractSummary(from: payload, bestContract: bestContract) else { return nil }
                return (index, summary)
            }
        )

        let primaryBestContract = bestContracts.first
        let primarySlot = primaryBestContract?.contractPointer ?? primaryBestContract?.index
        let primaryContract = primarySlot.flatMap { contractBySlot[$0] }
        let remainingTickets = primarySlot.flatMap { slot in
            exactRecordProbes.first(where: { $0.title == "Ticket Detail Record \(slot)" })?.response.payload.flatMap(parseNiceRemainingTickets)
        }
        let cardExpiryDate = environmentPayload.flatMap(parseNiceCardExpiryDate)
        let eventSummary = exactRecordProbes.compactMap { probe -> NiceEventSummary? in
            guard probe.title.hasPrefix("Event Record"),
                  probe.response.statusWords == "9000",
                  let payload = probe.response.payload,
                  !payload.allSatisfy({ $0 == 0 }) else { return nil }
            return parseNiceEventSummary(from: payload, sourceTitle: probe.title)
        }.first

        var rawSections: [RawDataSection] = [
            RawDataSection(
                title: "Tag",
                fields: [
                    RawDataField(title: "Technology", value: "ISO7816"),
                    RawDataField(title: "UID", value: tag.identifier.hexString),
                    RawDataField(title: "Selected AID", value: selectedAID),
                    RawDataField(title: "Application AID", value: applicationAID),
                    RawDataField(title: "Historical Bytes", value: tag.historicalBytes?.hexString ?? "Unavailable"),
                    RawDataField(title: "Application Data", value: tag.applicationData?.hexString ?? "Unavailable")
                ]
            )
        ]

        if let selectResponse {
            rawSections.append(
                RawDataSection(
                    title: "Select Application APDU",
                    fields: [
                        RawDataField(title: "Command", value: NFCISO7816APDU.selectCommandData(aid: applicationAID).hexString),
                        RawDataField(title: "Response Payload", value: (selectResponse.payload ?? Data()).hexString),
                        RawDataField(title: "SW1SW2", value: selectResponse.statusWords)
                    ]
                )
            )
        }

        if let secureSessionResponse {
            rawSections.append(
                RawDataSection(
                    title: "Secure Calypso Session",
                    fields: [
                        RawDataField(title: "Command", value: "94A40800022000"),
                        RawDataField(title: "Response Payload", value: (secureSessionResponse.payload ?? Data()).hexString),
                        RawDataField(title: "SW1SW2", value: secureSessionResponse.statusWords),
                        RawDataField(title: "Interpretation", value: "Select the Calypso environment file before secure record reads.")
                    ]
                )
            )
        }

        for (target, response) in probeResults {
            rawSections.append(
                RawDataSection(
                    title: target.title,
                    fields: [
                        RawDataField(title: "Command", value: target.commandData.hexString),
                        RawDataField(title: "Response Payload", value: (response.payload ?? Data()).hexString),
                        RawDataField(title: "SW1SW2", value: response.statusWords),
                        RawDataField(title: "Interpretation", value: target.description)
                    ]
                )
            )
        }

        for probe in exactRecordProbes {
            rawSections.append(
                RawDataSection(
                    title: probe.title,
                    fields: [
                        RawDataField(title: "Command", value: probe.command.hexString),
                        RawDataField(title: "Response Payload", value: (probe.response.payload ?? Data()).hexString),
                        RawDataField(title: "SW1SW2", value: probe.response.statusWords),
                        RawDataField(title: "Interpretation", value: probe.description)
                    ]
                )
            )
        }

        var resultFields: [ResultField] = []
        if let cardNumber = calypsoCardNumber?.formatted {
            resultFields.append(ResultField(title: "Card Number", value: cardNumber))
        }
        resultFields.append(ResultField(title: "Product Type", value: "Ticket / Contract Card"))
        if !contractBySlot.isEmpty {
            resultFields.append(ResultField(title: "Loaded Tickets", value: String(contractBySlot.count)))
        }
        if let primaryContract {
            let ticketLabel = niceTicketLabel(for: primaryContract)
            resultFields.append(ResultField(title: "Ticket", value: ticketLabel.displayName))
            if let apkProductFamily = ticketLabel.apkProductFamily {
                resultFields.append(ResultField(title: "Ticket Family", value: apkProductFamily))
            }
            resultFields.append(ResultField(title: "Contract Serial Number", value: primaryContract.serialNumber))
            resultFields.append(ResultField(title: "Product Code", value: primaryContract.linkedTariffID))
            if let saleDate = primaryContract.saleDate {
                resultFields.append(ResultField(title: "Sold At", value: saleDate))
            }
        }
        if let remainingTickets {
            resultFields.append(ResultField(title: "Remaining Trips", value: String(remainingTickets)))
        }
        if let cardExpiryDate {
            resultFields.append(ResultField(title: "Card Valid Until", value: cardExpiryDate))
        }
        if let validityEndDate = primaryContract?.validityEndDate {
            resultFields.append(ResultField(title: "Valid Until", value: validityEndDate))
        }
        if let eventSummary {
            resultFields.append(ResultField(title: "Last Ticket Event", value: "\(eventSummary.eventDateStamp) \(eventSummary.eventTimeStamp)"))
            if let eventRouteNumber = eventSummary.eventRouteNumber {
                resultFields.append(ResultField(title: "Route", value: eventRouteNumber))
            }
        }
        resultFields.append(ResultField(title: "Ticket Status", value: remainingTickets.map { "Remaining trips: \($0)" } ?? "Contract decoded"))

        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: "Lignes d'Azur card",
            identifierLabel: "UID",
            identifierValue: tag.identifier.hexString,
            rawIdentifierValue: tag.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: nil,
            balanceDetail: nil,
            realSerialNumber: nil,
            resultFields: resultFields,
            rawSections: rawSections,
            scannedAt: scannedAt
        )
    }

    private func sendISO7816Command(_ apdu: NFCISO7816APDU, to tag: any NFCISO7816Tag) async throws -> NFCISO7816ResponseAPDU {
        let result = try await tag.sendCommand(apdu: apdu)
        return NFCISO7816ResponseAPDU(statusWord1: result.1, statusWord2: result.2, payload: result.0)
    }

    private func readISO7816Commands(_ commands: [NFCISO7816APDU], to tag: any NFCISO7816Tag) async throws -> [NFCISO7816ResponseAPDU] {
        var responses: [NFCISO7816ResponseAPDU] = []
        responses.reserveCapacity(commands.count)
        for command in commands {
            responses.append(try await sendISO7816Command(command, to: tag))
        }
        return responses
    }

    private func readCalypsoRecordProbes(on tag: any NFCISO7816Tag) async throws -> [CalypsoRecordProbeResult] {
        let probes: [(String, String, NFCISO7816APDU, Data)] = [
            ("Environment Record", "Secure Nice environment read from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x3C, 0x1D])), Data([0x94, 0xB2, 0x01, 0x3C, 0x1D])),
            ("Best Contracts", "Secure Nice best-contract list from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0xF4, 0x1D])), Data([0x94, 0xB2, 0x01, 0xF4, 0x1D])),
            ("Event Record 1", "Secure Nice event record from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x44, 0x1D])), Data([0x94, 0xB2, 0x01, 0x44, 0x1D])),
            ("Contract Summary Record 1", "Primary loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x01, 0x4C, 0x1D])),
            ("Ticket Detail Record 1", "Primary remaining-trip detail from secure record family 0x54.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x54, 0x1D])), Data([0x94, 0xB2, 0x01, 0x54, 0x1D])),
            ("Contract Summary Record 2", "Loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x02, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x02, 0x4C, 0x1D])),
            ("Contract Summary Record 3", "Loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x03, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x03, 0x4C, 0x1D])),
            ("Contract Summary Record 4", "Loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x04, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x04, 0x4C, 0x1D]))
        ]

        var results: [CalypsoRecordProbeResult] = []
        for (title, description, apdu, commandData) in probes {
            let response = try await sendISO7816Command(apdu, to: tag)
            results.append(CalypsoRecordProbeResult(title: title, description: description, command: commandData, response: response))
        }
        return results
    }

    private func formatFeliCaIDm(_ idm: String) -> String {
        let clean = idm.uppercased()
        guard clean.count == 16 else { return clean }
        return stride(from: 0, to: 16, by: 4).map { index in
            let start = clean.index(clean.startIndex, offsetBy: index)
            let end = clean.index(start, offsetBy: 4)
            return String(clean[start..<end])
        }.joined(separator: " ")
    }
}

extension NFCFeliCaTag {
    func polling(systemCode: Data, requestCode: NFCFeliCaPollingRequestCode, timeSlot: NFCFeliCaPollingTimeSlot) async throws -> (Data, Data, Error?) {
        try await withCheckedThrowingContinuation { continuation in
            self.polling(systemCode: systemCode, requestCode: requestCode, timeSlot: timeSlot) { idm, pmm, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (idm, pmm, error))
                }
            }
        }
    }

    func requestSystemCodes() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            self.requestSystemCode { result in
                switch result {
                case .success(let systemCodes):
                    continuation.resume(returning: systemCodes.map(\.hexString).map { $0.uppercased() })
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private func formatKoreanCardNumber(_ hex: String) -> String {
    let clean = hex.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in
        let start = clean.index(clean.startIndex, offsetBy: index)
        let end = clean.index(start, offsetBy: 4)
        return String(clean[start..<end])
    }.joined(separator: " ")
}

private func parseCalypsoCardNumber(from fciPayload: Data) -> CalypsoCardNumber? {
    guard let serialData = findTLVValue(tag: [0xC7], in: fciPayload), serialData.count >= 4 else { return nil }
    let tail = serialData.suffix(4)
    let decimal = String(tail.reduce(0) { ($0 << 8) | UInt64($1) })
    let padded = decimal.count >= 10 ? decimal : String(repeating: "0", count: 10 - decimal.count) + decimal
    let formatted = "\(padded.prefix(1)) \(padded.dropFirst(1).prefix(3)) \(padded.dropFirst(4).prefix(3)) \(padded.suffix(3))"
    return CalypsoCardNumber(sourceBytes: Data(tail).hexString, decimal: decimal, paddedDecimal: padded, formatted: formatted)
}

private func parseNiceBestContracts(from payload: Data) -> [NiceBestContractEntry] {
    let bits = payload.binaryString
    guard bits.count >= 4 else { return [] }
    let contractCount = Int(bits.prefix(4), radix: 2) ?? 0
    let body = String(bits.dropFirst(4))
    var entries: [NiceBestContractEntry] = []
    for index in 0..<contractCount {
        let start = index * 24
        let end = start + 24
        guard body.count >= end else { break }
        let entryBits = body.bitSubstring(start: start, length: 24)
        entries.append(
            NiceBestContractEntry(
                index: index + 1,
                tariffKey: Int(entryBits.bitSubstring(start: 3, length: 4), radix: 2) ?? 0,
                tariffStructure: String(Int(entryBits.bitSubstring(start: 7, length: 8), radix: 2) ?? 0, radix: 16).uppercased(),
                tariffPriority: String(Int(entryBits.bitSubstring(start: 15, length: 4), radix: 2) ?? 0, radix: 16).uppercased(),
                contractPointer: Int(entryBits.bitSubstring(start: 19, length: 5), radix: 2) ?? 0
            )
        )
    }
    return entries
}

private func parseNiceContractSummary(from payload: Data, bestContract: NiceBestContractEntry) -> NiceContractSummary? {
    let bits = payload.binaryString
    guard bits.count >= 63 else { return nil }
    let bitmap = String(bits.bitSubstring(start: 0, length: 7).reversed())
    let provider = bits.bitSubstring(start: 7, length: 8).binaryDecimalString
    let linkedTariffID = bits.bitSubstring(start: 15, length: 16).binaryDecimalString
    let serialNumber = bits.bitSubstring(start: 31, length: 32).binaryDecimalString
    let saleDate = bits.count >= 102 ? formatCalypsoDay(bits.bitSubstring(start: 88, length: 14)) : nil
    var cursor = 63
    var passengerClass: String?
    var validityStartDate: String?
    var validityEndDate: String?
    var status: String?
    if bitmap.character(at: 3) == "1", bits.count >= cursor + 8 {
        passengerClass = bits.bitSubstring(start: cursor, length: 8).binaryDecimalString
        cursor += 8
    }
    if bitmap.character(at: 4) == "1", bits.count >= cursor + 2 {
        let validityBitmap = String(bits.bitSubstring(start: cursor, length: 2).reversed())
        cursor += 2
        if validityBitmap.character(at: 0) == "1", bits.count >= cursor + 14 {
            validityStartDate = formatCalypsoDay(bits.bitSubstring(start: cursor, length: 14))
            cursor += 14
        }
        if validityBitmap.character(at: 1) == "1", bits.count >= cursor + 14 {
            validityEndDate = formatCalypsoDay(bits.bitSubstring(start: cursor, length: 14))
            cursor += 14
        }
    }
    if bitmap.character(at: 5) == "1", bits.count >= cursor + 8 {
        status = bits.bitSubstring(start: cursor, length: 8).binaryHexString
        cursor += 8
    }
    var validityJourneys: String?
    var journeyOrigin: String?
    var journeyDestination: String?
    var journeyVia: String?
    if bestContract.tariffStructure == "17", bits.count >= cursor + 64 {
        validityJourneys = bits.bitSubstring(start: cursor, length: 16).binaryDecimalString
        journeyOrigin = bits.bitSubstring(start: cursor + 16, length: 16).binaryDecimalString
        journeyDestination = bits.bitSubstring(start: cursor + 32, length: 16).binaryDecimalString
        journeyVia = bits.bitSubstring(start: cursor + 48, length: 16).binaryDecimalString
    }
    return NiceContractSummary(contractType: bestContract.tariffStructure, provider: provider, linkedTariffID: linkedTariffID, serialNumber: serialNumber, saleDate: saleDate, status: status, validityStartDate: validityStartDate, validityEndDate: validityEndDate, passengerClass: passengerClass, validityJourneys: validityJourneys, journeyOrigin: journeyOrigin, journeyDestination: journeyDestination, journeyVia: journeyVia)
}

private func parseNiceRemainingTickets(from payload: Data) -> Int? {
    guard payload.count >= 3 else { return nil }
    return Int(payload[2])
}

private func parseNiceCardExpiryDate(from payload: Data) -> String? {
    let bits = payload.binaryString
    guard bits.count >= 59 else { return nil }
    return formatCalypsoDay(bits.bitSubstring(start: 45, length: 14))
}

private func niceTicketLabel(for contract: NiceContractSummary) -> NiceTicketLabel {
    switch contract.linkedTariffID {
    case "191":
        return NiceTicketLabel(displayName: "N Voyage Multi", apkProductFamily: "MULTI Voyages")
    case "99":
        return NiceTicketLabel(displayName: "Consigne", apkProductFamily: nil)
    default:
        break
    }
    switch contract.contractType.uppercased() {
    case "46":
        return NiceTicketLabel(displayName: "N Voyage Multi", apkProductFamily: "MULTI Voyages")
    default:
        return NiceTicketLabel(displayName: "Contract type \(contract.contractType)", apkProductFamily: nil)
    }
}

private func parseNiceEventSummary(from payload: Data, sourceTitle: String) -> NiceEventSummary? {
    let bits = payload.binaryString
    guard bits.count >= 53 else { return nil }
    let eventDateStamp = formatCalypsoDay(bits.bitSubstring(start: 0, length: 14)) ?? bits.bitSubstring(start: 0, length: 14)
    let eventTimeStamp = formatCompactTime(bits.bitSubstring(start: 14, length: 11)) ?? bits.bitSubstring(start: 14, length: 11)
    let mainBitmap = bits.bitSubstring(start: 25, length: 28)
    let reversedBitmap = String(mainBitmap.reversed())
    var cursor = 53
    var eventCode: String?
    var eventCodeMode: String?
    var eventCodeType: String?
    var eventCodeResult: String?
    if reversedBitmap.character(at: 2) == "1", bits.count >= cursor + 8 {
        let eventCodeBits = bits.bitSubstring(start: cursor, length: 8)
        eventCode = eventCodeBits.binaryDecimalString
        let paddedCode = eventCodeBits.leftPadded(to: 8, with: "0")
        eventCodeMode = String(paddedCode.prefix(4))
        eventCodeType = String(paddedCode.suffix(4))
        cursor += 8
    }
    if reversedBitmap.character(at: 3) == "1", bits.count >= cursor + 8 {
        eventCodeResult = bits.bitSubstring(start: cursor, length: 8).binaryDecimalString
        cursor += 8
    }
    guard bits.count >= cursor + 8 else { return nil }
    let eventServiceProvider = bits.bitSubstring(start: cursor, length: 8).binaryDecimalString
    cursor += 8
    var eventLocationID: String?
    if reversedBitmap.character(at: 8) == "1", bits.count >= cursor + 24 {
        eventLocationID = bits.bitSubstring(start: cursor, length: 24).binaryDecimalString
        cursor += 24
    }
    var eventRouteNumber: String?
    if reversedBitmap.character(at: 11) == "1", bits.count >= cursor + 16 {
        eventRouteNumber = bits.bitSubstring(start: cursor, length: 16).binaryDecimalString
        cursor += 16
    }
    var eventJourneyRun: String?
    if reversedBitmap.character(at: 13) == "1", bits.count >= cursor + 16 {
        eventJourneyRun = bits.bitSubstring(start: cursor, length: 16).binaryDecimalString
    }
    return NiceEventSummary(sourceTitle: sourceTitle, eventDateStamp: eventDateStamp, eventTimeStamp: eventTimeStamp, mainBitmap: mainBitmap, eventCode: eventCode, eventCodeMode: eventCodeMode, eventCodeType: eventCodeType, eventCodeResult: eventCodeResult, eventServiceProvider: eventServiceProvider, eventLocationID: eventLocationID, eventRouteNumber: eventRouteNumber, eventJourneyRun: eventJourneyRun)
}

private func formatCalypsoDay(_ bits: String) -> String? {
    guard let value = Int(bits, radix: 2) else { return nil }
    let reference = Date(timeIntervalSince1970: 852_073_200)
    let date = reference.addingTimeInterval(TimeInterval(value * 86_400))
    return KSX6924DateFormatting.formatRawDateForDisplay(date)
}

private func formatCompactTime(_ bits: String) -> String? {
    guard let value = Int(bits, radix: 2) else { return nil }
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let seconds = value % 60
    guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}

private extension NFCISO7816ResponseAPDU {
    var statusWords: String {
        String(format: "%02X%02X", statusWord1, statusWord2)
    }
}

private extension String {
    func leftPadded(to length: Int, with character: Character) -> String {
        guard count < length else { return self }
        return String(repeating: String(character), count: length - count) + self
    }

    func bitSubstring(start: Int, length: Int) -> String {
        guard start >= 0, length >= 0, count >= start + length else { return "" }
        let from = index(startIndex, offsetBy: start)
        let to = index(from, offsetBy: length)
        return String(self[from..<to])
    }

    func character(at offset: Int) -> Character? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }

    var binaryDecimalString: String {
        String(Int(self, radix: 2) ?? 0)
    }

    var binaryHexString: String {
        String(format: "%02X", Int(self, radix: 2) ?? 0)
    }
}
