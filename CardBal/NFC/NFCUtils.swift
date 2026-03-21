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
    var systemCodeCandidates: [String] {
        guard count == 2 else { return [hexString.uppercased()] }
        return [
            String(format: "%02X%02X", self[0], self[1]),
            String(format: "%02X%02X", self[1], self[0])
        ]
    }
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

    var isEnhancedFeliCaDecodingEnabled = false
    var checkIfCardAlreadyEnhanced: ((String) -> Bool)?

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

extension NFCTransitReader {
    private func decodeFeliCaSnapshot(from tag: any NFCFeliCaTag) async throws -> TransitCardSnapshot {
        let scannedAt = Date()
        let idm = tag.currentIDm.hexString.uppercased()
        let (_, pmmData, _) = try await tag.polling(
            systemCode: tag.currentSystemCode,
            requestCode: .noRequest,
            timeSlot: .max1
        )
        let pmm = pmmData.hexString.uppercased()

        let profiles: [String: (String, String)] = [
            "0003": ("Japan Transit IC", "008B"),
            "8008": ("Octopus", "0117"),
            "DE80": ("IruCa", "008B"),
            "865E": ("SAPICA", "008B"),
            "8592": ("PASPY", "008B")
        ]

        let systemCodes = tag.currentSystemCode.systemCodeCandidates
        var matchedProfile: (String, String, String)?
        for systemCode in systemCodes {
            if let profile = profiles[systemCode] {
                matchedProfile = (profile.0, systemCode, profile.1)
                break
            }
        }

        guard let profile = matchedProfile else {
            return TransitCardSnapshot(
                technology: "FeliCa",
                cardFamily: "FeliCa Card",
                identifierLabel: "IDm",
                identifierValue: formatFeliCaIDm(idm),
                rawIdentifierValue: idm,
                pmm: pmm,
                systemCode: systemCodes.first,
                selectedAID: nil,
                balanceText: nil,
                balanceDetail: "Unsupported system code.",
                realSerialNumber: nil,
                resultFields: [],
                rawSections: [],
                scannedAt: scannedAt
            )
        }

        let serviceData = Data(hexString: profile.2)
        let readResult = try await tag.readWithoutEncryption(
            serviceCodeList: [Data([serviceData[1], serviceData[0]])],
            blockList: [Data([0x80, 0x00])]
        )

        let block = readResult.2.first
        var balanceText: String?
        var balanceDetail: String?

        if profile.1 == "0003" || profile.1 == "DE80" || profile.1 == "865E" || profile.1 == "8592" {
            if let block, block.count >= 13 {
                let balance = Int(block[11]) | (Int(block[12]) << 8)
                balanceText = formatCurrency(amount: Decimal(balance), code: "JPY", fractionDigits: 0)
                balanceDetail = "Balance: ¥\(balance)"
            }
        } else if profile.1 == "8008" {
            if let block, block.count >= 4 {
                let rawStored = block.bigEndianInt(start: 0, length: 4)
                let value = Decimal(rawStored - octopusOffset(for: scannedAt)) / 10
                balanceText = formatCurrency(amount: value, code: "HKD", fractionDigits: 1)
                balanceDetail = "Balance: $\(value)"
            }
        }

        var realSerialNumber: String?
        let storageIdentifier = "FeliCa|\(idm)"
        if isEnhancedFeliCaDecodingEnabled && profile.1 == "0003" {
            let alreadyDecoded = checkIfCardAlreadyEnhanced?(storageIdentifier) ?? false
            if !alreadyDecoded {
                await MainActor.run {
                    self.updateStatus("Retrieving real serial number...", kind: .idle)
                }
                realSerialNumber = try? await performEnhancedFeliCaHandshake(tag: tag)
            }
        }

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: profile.0,
            identifierLabel: "IDm",
            identifierValue: formatFeliCaIDm(idm),
            rawIdentifierValue: idm,
            pmm: pmm,
            systemCode: profile.1,
            selectedAID: nil,
            balanceText: balanceText,
            balanceDetail: balanceDetail,
            realSerialNumber: realSerialNumber,
            resultFields: [ResultField(title: "IDm", value: formatFeliCaIDm(idm))],
            rawSections: [],
            scannedAt: scannedAt
        )
    }

    private func decodeISO7816Snapshot(from tag: any NFCISO7816Tag) async throws -> TransitCardSnapshot {
        let aid = tag.initialSelectedAID.uppercased()
        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: "ISO7816 Card",
            identifierLabel: "UID",
            identifierValue: tag.identifier.hexString,
            rawIdentifierValue: tag.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: aid,
            balanceText: nil,
            balanceDetail: nil,
            realSerialNumber: nil,
            resultFields: [],
            rawSections: [],
            scannedAt: Date()
        )
    }

    private func formatFeliCaIDm(_ idm: String) -> String {
        idm
    }
}

extension NFCTransitReader {
    private func performEnhancedFeliCaHandshake(tag: any NFCFeliCaTag) async throws -> String? {
        guard let authServerURL = URL(string: "https://felica-auth.nyaa.ws/mutual-authentication") else {
            return nil
        }

        let idm = tag.currentIDm.hexString.uppercased()
        let (_, pmmData, _) = try await tag.polling(
            systemCode: Data(hexString: "0003"),
            requestCode: .noRequest,
            timeSlot: .max1
        )
        let pmm = pmmData.hexString.uppercased()

        let payload: [String: Any] = [
            "idm": idm,
            "pmm": pmm,
            "system_code": 0x0003,
            "areas": [0x0000, 0x0040, 0x0800, 0x0FC0, 0x1000],
            "services": [0x0048, 0x0088, 0x0810, 0x08C8, 0x090C, 0x1008, 0x1048, 0x108C, 0x10C8]
        ]

        var currentPayload = payload
        var sessionID: String?

        while true {
            var request = URLRequest(url: authServerURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: currentPayload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            if let receivedSessionID = json["session_id"] as? String {
                sessionID = receivedSessionID
            }

            let step = json["step"] as? String
            if step == "auth1" || step == "auth2" {
                guard let commandInfo = json["command"] as? [String: Any],
                      let frameHex = commandInfo["frame"] as? String else {
                    return nil
                }

                let frameData = Data(hexString: frameHex)
                let cardResponse = try await tag.sendFeliCaCommand(commandPacket: frameData)
                currentPayload = [
                    "session_id": sessionID ?? "",
                    "card_response": cardResponse.hexString.uppercased()
                ]
            } else if step == "complete" {
                if let result = json["result"] as? [String: Any],
                   let issueIDHex = result["issue_id"] as? String ?? result["idi"] as? String {
                    return formatFeliCaIDi(Data(hexString: issueIDHex))
                }
                return nil
            } else {
                return nil
            }
        }
    }

    private func formatFeliCaIDi(_ data: Data) -> String {
        guard data.count >= 8 else { return data.hexString }

        let issuerHex = data.subdata(in: 0..<2).hexString.uppercased()
        let remainder = data.subdata(in: 2..<4).hexString.uppercased()
        let issuer: String
        switch issuerHex {
        case "0102": issuer = "JH"
        case "0103": issuer = "JE"
        case "0104": issuer = "JC"
        case "0105": issuer = "JW"
        case "0107": issuer = "JK"
        case "0252": issuer = "PB"
        case "0387": issuer = "TP"
        case "04AD": issuer = "SU"
        case "05D5": issuer = "NR"
        case "05D7": issuer = "FC"
        default: issuer = issuerHex
        }

        let value = (Int(data[4]) << 8) | Int(data[5])
        let datePart = String(format: "%02d%02d%02d", (value >> 9) & 0x3F, (value >> 5) & 0x0F, value & 0x1F)
        let tail = String(format: "%05d", (Int(data[6]) << 8) | Int(data[7]))
        return "\(issuer)\(remainder)\(datePart)\(tail)"
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
}
