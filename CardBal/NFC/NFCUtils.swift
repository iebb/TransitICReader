import Foundation
import CoreNFC
import os
import SwiftUI

// MARK: - Models

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
    let region: String?
    let resultFields: [ResultField]
    let rawSections: [RawDataSection]
    let scannedAt: Date
}

enum StatusKind {
    case idle
    case success
    case error
}

enum NFCTestError: Error {
    case unsupportedCard
}

enum NFCISO7816AccessPolicy {
    static let exactAIDs: Set<String> = [
        "A0000004520001", "D4100000030001", "D4100000140001", "D410000029000001", "D4100000300001", "D4106509900020", "A000000632010105"
    ]

    static let ksx6924AllowedPrefixes: [String] = [
        "D410000003",
        "D410000014",
        "D410000029",
        "D410000030",
        "D410650990"
    ]

    static func isAllowed(aid: String) -> Bool {
        let normalized = aid.uppercased()
        return exactAIDs.contains(normalized)
            || ksx6924AllowedPrefixes.contains { normalized.hasPrefix($0) }
            || CalypsoCardProfile.supportedPrefixes.contains { normalized.hasPrefix($0) }
    }
}

// MARK: - NFCTransitReader

@MainActor
final class NFCTransitReader: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "ad.neko.cardbal", category: "NFC")

    @Published private(set) var latestSnapshot: TransitCardSnapshot?
    @Published private(set) var statusMessage = "Ready to scan."
    @Published private(set) var isScanning = false

    private var latestStatusKind: StatusKind = .idle
    private var session: NFCTagReaderSession?

    private let decoders: [TransitCardDecoder.Type] = [
        TUnionDecoder.self,
        KSX6924Decoder.self,
        EdyDecoder.self,
        WAONDecoder.self,
        NanacoDecoder.self,
        JapaneseICDecoder.self,
        CalypsoDecoder.self
    ]

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

    func startScanning(options: NFCTagReaderSession.PollingOption = [.iso18092, .iso14443, .iso15693]) {
        beginScanning(options: options)
    }

    func beginScanning(options: NFCTagReaderSession.PollingOption = [.iso18092, .iso14443, .iso15693]) {
        guard isNFCAvailable else {
            updateStatus("NFC reading is not available.", kind: .error)
            return
        }

        guard let session = NFCTagReaderSession(pollingOption: options, delegate: self, queue: nil) else {
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

    private func mergeDualModeSnapshots(feliCa: TransitCardSnapshot, iso7816: TransitCardSnapshot) -> TransitCardSnapshot {
        var mergedResults = feliCa.resultFields
        mergedResults.append(contentsOf: iso7816.resultFields)
        
        var mergedRaw = feliCa.rawSections
        mergedRaw.append(contentsOf: iso7816.rawSections)
        
        let dualBalance = "\(feliCa.balanceText ?? "No balance") / \(iso7816.balanceText ?? "No balance")"
        let dualDetail = "FeliCa: \(feliCa.balanceDetail ?? "")\n\nISO7816: \(iso7816.balanceDetail ?? "")"
        
        return TransitCardSnapshot(
            technology: "Dual Mode",
            cardFamily: "\(feliCa.cardFamily) + \(iso7816.cardFamily)",
            identifierLabel: "Dual Mode UID",
            identifierValue: feliCa.identifierValue,
            rawIdentifierValue: feliCa.rawIdentifierValue,
            pmm: feliCa.pmm,
            systemCode: feliCa.systemCode,
            selectedAID: iso7816.selectedAID,
            balanceText: dualBalance,
            balanceDetail: dualDetail,
            realSerialNumber: feliCa.realSerialNumber ?? iso7816.realSerialNumber,
            region: feliCa.region ?? iso7816.region,
            resultFields: mergedResults,
            rawSections: mergedRaw,
            scannedAt: feliCa.scannedAt
        )
    }
}

// MARK: - Delegate

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
        Task {
            var feliCaSnapshot: TransitCardSnapshot?
            var iso7816Snapshot: TransitCardSnapshot?
            let scannedAt = Date()
            
            logger.debug("Detected \(tags.count) tags.")
            for tag in tags {
                do {
                    try await session.connect(to: tag)
                    
                    for decoder in decoders {
                        if await decoder.canDecode(tag: tag) {
                            do {
                                let snapshot = try await decoder.decode(tag: tag, scannedAt: scannedAt)
                                if snapshot.technology == "FeliCa" {
                                    feliCaSnapshot = snapshot
                                } else {
                                    iso7816Snapshot = snapshot
                                }
                                break // Found a successful decoder for this tag
                            } catch NFCTestError.unsupportedCard {
                                // This decoder couldn't actually handle it, try the next one
                                continue
                            } catch {
                                logger.error("Fatal error in decoder \(decoder): \(error.localizedDescription)")
                                throw error
                            }
                        }
                    }
                } catch {
                    logger.error("Failed to decode tag: \(error.localizedDescription)")
                }
            }

            await MainActor.run {
                let finalSnapshot: TransitCardSnapshot?
                if let feliCa = feliCaSnapshot, let iso7816 = iso7816Snapshot {
                    finalSnapshot = self.mergeDualModeSnapshots(feliCa: feliCa, iso7816: iso7816)
                } else {
                    finalSnapshot = feliCaSnapshot ?? iso7816Snapshot
                }

                if let finalSnapshot {
                    self.finish(with: finalSnapshot, session: session)
                } else {
                    self.fail("Could not read any supported transit card data.", session: session)
                }
            }
        }
    }
}

// MARK: - Helpers & Extensions

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

func formatFeliCaIDm(_ idm: String) -> String {
    let clean = idm.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in
        let start = clean.index(clean.startIndex, offsetBy: index)
        let end = clean.index(start, offsetBy: 4)
        return String(clean[start..<end])
    }.joined(separator: " ")
}

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
    
    func sliceHexString(start: Int, length: Int) -> String {
        guard start >= 0, length > 0, count >= start + length else { return "Unavailable" }
        return self[start..<(start + length)].map { String(format: "%02X", $0) }.joined()
    }
    
    func bigEndianInt(start: Int, length: Int) -> Int {
        guard start >= 0, length > 0, count >= start + length else { return 0 }
        return self[start..<(start + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
}


struct BERTLVNode {
    let tag: [UInt8]
    let value: Data
    var isConstructed: Bool {
        guard let first = tag.first else { return false }
        return (first & 0x20) != 0
    }
}

func findTLVValue(tag targetTag: [UInt8], in data: Data) -> Data? {
    parseBERTLVs(in: data).lazy.compactMap { node -> Data? in
        if node.tag == targetTag { return node.value }
        if node.isConstructed { return findTLVValue(tag: targetTag, in: node.value) }
        return nil
    }.first
}

func parseBERTLVs(in data: Data) -> [BERTLVNode] {
    var nodes: [BERTLVNode] = []
    var index = data.startIndex
    while index < data.endIndex {
        let tagStart = index
        index = data.index(after: index)
        if data[tagStart] & 0x1F == 0x1F {
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if byte & 0x80 == 0 { break }
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
                accumulated = (accumulated << 8) | Int(data[index]); index = data.index(after: index)
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

extension String {
    func binaryDecimalString() -> String { String(Int(self, radix: 2) ?? 0) }
}
