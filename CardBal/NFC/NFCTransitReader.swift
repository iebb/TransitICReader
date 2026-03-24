import CoreNFC
import Foundation
import os
import SwiftUI

@MainActor
final class NFCTransitReader: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "ad.neko.cardbal", category: "NFC")

    @Published private(set) var latestSnapshot: TransitCardSnapshot?
    @Published private(set) var statusMessage = "Ready to scan."
    @Published private(set) var isScanning = false

    var isEnhancedFeliCaDecodingEnabled = false
    var checkIfCardAlreadyEnhanced: ((String) -> Bool)?

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
        print("[READER] Starting session with options: \(options)")
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
        logger.log("Status: \(message, privacy: .public)")
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
            transactions: feliCa.transactions + iso7816.transactions,
            transitHistory: feliCa.transitHistory + iso7816.transitHistory,
            scannedAt: feliCa.scannedAt
        )
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
        let msgDet = "[READER] Detected \(tags.count) tag(s)"
        os_log("%{public}@", msgDet)
        if tags.count > 1 {
            session.alertMessage = "More than 1 card detected. Please keep only 1."
            session.restartPolling()
            return
        }
        
        guard let tag = tags.first else { return }
        NSLog("[READER] Processing tag: \(tag)")

        Task {
            do {
                try await session.connect(to: tag)
                
                let scannedAt = Date()
                var snapshot: TransitCardSnapshot?
                
                // Try each decoder
                for decoder in decoders {
                    if await decoder.canDecode(tag: tag) {
                        snapshot = try? await decoder.decode(tag: tag, scannedAt: scannedAt)
                        if snapshot != nil { break }
                    }
                }
                
                // Enhanced Handshake for FeliCa (Japan Transit IC)
                if let feliCaSnapshot = snapshot, 
                   feliCaSnapshot.technology == "FeliCa", 
                   feliCaSnapshot.systemCode == "0003",
                   case .feliCa(let feliCa) = tag {
                    
                    let isEnhanced = await MainActor.run { isEnhancedFeliCaDecodingEnabled }
                    if isEnhanced {
                        let storageIdentifier = "FeliCa|\(feliCaSnapshot.rawIdentifierValue)"
                        let alreadyDecoded = await MainActor.run { checkIfCardAlreadyEnhanced?(storageIdentifier) ?? false }
                        if !alreadyDecoded {
                            await MainActor.run { self.updateStatus("Retrieving real serial number...", kind: .idle) }
                            if let sn = try? await performEnhancedFeliCaHandshake(tag: feliCa) {
                                // Re-create snapshot with SN
                                snapshot = TransitCardSnapshot(
                                    technology: feliCaSnapshot.technology,
                                    cardFamily: feliCaSnapshot.cardFamily,
                                    identifierLabel: feliCaSnapshot.identifierLabel,
                                    identifierValue: feliCaSnapshot.identifierValue,
                                    rawIdentifierValue: feliCaSnapshot.rawIdentifierValue,
                                    pmm: feliCaSnapshot.pmm,
                                    systemCode: feliCaSnapshot.systemCode,
                                    selectedAID: feliCaSnapshot.selectedAID,
                                    balanceText: feliCaSnapshot.balanceText,
                                    balanceDetail: feliCaSnapshot.balanceDetail,
                                    realSerialNumber: sn,
                                    region: feliCaSnapshot.region,
                                    resultFields: feliCaSnapshot.resultFields,
                                    rawSections: feliCaSnapshot.rawSections,
                                    transactions: feliCaSnapshot.transactions,
                                    transitHistory: feliCaSnapshot.transitHistory,
                                    scannedAt: feliCaSnapshot.scannedAt
                                )
                            }
                        }
                    }
                }

                if let snapshot = snapshot {
                    await MainActor.run { self.finish(with: snapshot, session: session) }
                } else {
                    await MainActor.run { self.fail("Unsupported card type.", session: session) }
                }
            } catch {
                await MainActor.run { self.fail("Failed to connect to card.", session: session) }
            }
        }
    }
}

extension NFCTransitReader {
    private func performEnhancedFeliCaHandshake(tag: any NFCFeliCaTag) async throws -> String? {
        guard let authServerURL = URL(string: "https://felica-auth.nyaa.ws/mutual-authentication") else {
            return nil
        }

        let idm = tag.currentIDm.hexString.uppercased()
        let (_, pmmData) = try await tag.polling(
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
}

extension NFCFeliCaTag {
    func polling(systemCode: Data, requestCode: NFCFeliCaPollingRequestCode, timeSlot: NFCFeliCaPollingTimeSlot) async throws -> (Data, Data) {
        try await withCheckedThrowingContinuation { continuation in
            self.polling(systemCode: systemCode, requestCode: requestCode, timeSlot: timeSlot) { idm, pmm, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (idm, pmm))
                }
            }
        }
    }
}
