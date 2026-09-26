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

    private enum ScanPhase { case regular, octopus, mainland }
    private var phase: ScanPhase = .regular
    private var pendingOctopus: TransitCardSnapshot?
    private var restartForMainland = false
    private var secondSideTimeout: Task<Void, Never>?
    private var isReadingTag = false
    private var latestStatusKind: StatusKind = .idle
    private var session: NFCTagReaderSession?

    var isNFCAvailable: Bool { NFCTagReaderSession.readingAvailable }

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
        guard !isScanning else { return }
        phase = .regular
        beginScanning(options: options)
    }

    /// Pairing is explicit: RF discovery does not prove that two protocols are
    /// on the same physical card, nor that they have two independent purses.
    func startDualOctopusScanning() {
        guard !isScanning else { return }
        phase = .octopus
        beginScanning(options: [.iso18092])
    }

    private func beginScanning(options: NFCTagReaderSession.PollingOption) {
        guard isNFCAvailable else {
            updateStatus("NFC reading is not available.", kind: .error)
            return
        }
        let newSession: NFCTagReaderSession?
        if #available(iOS 26.4, *), phase != .regular {
            newSession = NFCTagReaderSession(configuration: dualConfiguration(), delegate: self, queue: nil)
        } else {
            newSession = NFCTagReaderSession(pollingOption: options, delegate: self, queue: nil)
        }
        guard let newSession else {
            if let pendingOctopus { latestSnapshot = pendingOctopus }
            resetScan()
            updateStatus("Unable to start session.", kind: .error)
            return
        }
        self.session = newSession
        isScanning = true
        let message = phase == .mainland
            ? String(localized: "Hold the same Octopus card near your iPhone to read its mainland side.")
            : phase == .octopus
                ? String(localized: "Hold one dual Octopus card near your iPhone. Keep the same card for both reads.")
                : String(localized: "Hold your iPhone near a transit card.")
        newSession.alertMessage = message
        updateStatus(message, kind: .idle)
        newSession.begin()
        if phase == .mainland { scheduleSecondSideTimeout(for: newSession) }
    }

    @available(iOS 26.4, *)
    private func dualConfiguration() -> NFCTagReaderSession.Configuration {
        NFCTagReaderSession.Configuration(
            pollingOption: phase == .mainland ? [.iso14443] : [.iso18092],
            iso7816SelectIdentifiers: [CityUnionDecoder.applicationAID, TUnionDecoder.applicationAID],
            feliCaSystemCodes: ["8008"]
        )
    }

    private func restartPolling(_ session: NFCTagReaderSession) {
        if #available(iOS 26.4, *), phase != .regular {
            session.restartPolling(configuration: dualConfiguration())
        } else {
            session.restartPolling()
        }
    }

    private func scheduleSecondSideTimeout(for session: NFCTagReaderSession) {
        secondSideTimeout?.cancel()
        secondSideTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.session === session, self.phase == .mainland else { return }
            self.finishPartial(session: session)
        }
    }

    private func resetScan() {
        secondSideTimeout?.cancel()
        secondSideTimeout = nil
        pendingOctopus = nil
        restartForMainland = false
        phase = .regular
        isScanning = false
    }

    private func updateStatus(_ message: String, kind: StatusKind) {
        statusMessage = message
        latestStatusKind = kind
        logger.log("Status: \(message, privacy: .public)")
    }

    private func finish(with snapshot: TransitCardSnapshot, session: NFCTagReaderSession) {
        guard self.session === session else { return }
        latestSnapshot = snapshot
        updateStatus("Read successful: \(snapshot.cardFamily)", kind: .success)
        self.session = nil
        resetScan()
        session.invalidate()
    }

    private func finishPartial(session: NFCTagReaderSession, alreadyInvalidated: Bool = false) {
        guard self.session === session, let pendingOctopus else { return }
        latestSnapshot = pendingOctopus
        updateStatus(String(localized: "Octopus side saved. The mainland side was not read; scan both sides again to add it."), kind: .success)
        self.session = nil
        resetScan()
        if !alreadyInvalidated { session.invalidate() }
    }

    private func fail(_ message: String, session: NFCTagReaderSession) {
        guard self.session === session else { return }
        if pendingOctopus != nil {
            finishPartial(session: session)
            return
        }
        updateStatus(message, kind: .error)
        self.session = nil
        resetScan()
        session.invalidate(errorMessage: message)
    }

    private func accept(_ snapshot: TransitCardSnapshot, session: NFCTagReaderSession) {
        guard self.session === session else { return }
        switch phase {
        case .regular:
            finish(with: snapshot, session: session)
        case .octopus:
            guard snapshot.applicationSnapshots.contains(where: \.isOctopus) else {
                fail(String(localized: "This is not a supported Octopus card."), session: session)
                return
            }
            pendingOctopus = snapshot
            phase = .mainland
            let message = String(localized: "Hold the same Octopus card near your iPhone to read its mainland side.")
            updateStatus(message, kind: .idle)
            session.alertMessage = message
            if #available(iOS 26.4, *) {
                restartPolling(session)
                scheduleSecondSideTimeout(for: session)
            } else {
                // Only start the next reader after the old one has invalidated.
                restartForMainland = true
                session.invalidate()
            }
        case .mainland:
            guard let pendingOctopus,
                  snapshot.applicationSnapshots.contains(where: { $0.isTUnion || $0.isCityUnion }),
                  let combined = TransitCardSnapshot.combining([pendingOctopus, snapshot]) else {
                finishPartial(session: session)
                return
            }
            finish(with: combined, session: session)
        }
    }
}

extension NFCTransitReader: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        logger.log("NFC session active.")
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            guard self.session === session else { return }
            if self.restartForMainland {
                self.restartForMainland = false
                self.session = nil
                self.beginScanning(options: [.iso14443])
                return
            }
            if self.pendingOctopus != nil {
                self.finishPartial(session: session, alreadyInvalidated: true)
                return
            }
            self.session = nil
            self.resetScan()
            if (error as NSError).code == 200 {
                self.updateStatus("Ready to scan.", kind: .idle)
            } else {
                self.updateStatus("Session invalidated: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor in
            guard self.session === session, self.isScanning, !self.isReadingTag, !tags.isEmpty else { return }
            // Multiple discoveries may be different physical cards. Never pair
            // them merely because they arrived in the same delegate callback.
            guard tags.count == 1, let tag = tags.first else {
                session.alertMessage = String(localized: "Present only one transit card.")
                self.restartPolling(session)
                return
            }
            self.isReadingTag = true
            defer { self.isReadingTag = false }
            self.secondSideTimeout?.cancel()
            do {
                try await session.connect(to: tag)
                let decoders: [TransitCardDecoder.Type] = phase == .mainland
                    ? [ChineseTransitDecoder.self]
                    : phase == .octopus ? [JapaneseICDecoder.self] : [
                        ChineseTransitDecoder.self, CalypsoDecoder.self, KSX6924Decoder.self,
                        EdyDecoder.self, WAONDecoder.self, NanacoDecoder.self, JapaneseICDecoder.self
                    ]
                var snapshot: TransitCardSnapshot?
                for decoder in decoders {
                    if await decoder.canDecode(tag: tag) {
                        snapshot = try? await decoder.decode(tag: tag, scannedAt: Date())
                        if snapshot != nil { break }
                    }
                }
                    if let detectedSnapshot = snapshot,
                       detectedSnapshot.technology == "FeliCa",
                       detectedSnapshot.systemCode == "0003",
                       case .feliCa(let feliCa) = tag {

                        let isEnhanced = isEnhancedFeliCaDecodingEnabled
                        if isEnhanced {
                            let storageIdentifier = "FeliCa|\(detectedSnapshot.rawIdentifierValue)"
                            let alreadyDecoded = checkIfCardAlreadyEnhanced?(storageIdentifier) ?? false
                            if !alreadyDecoded {
                                self.updateStatus("Retrieving real serial number...", kind: .idle)
                                if let sn = try? await performEnhancedFeliCaHandshake(tag: feliCa) {
                                    let systemCodes = (try? await feliCa.requestSystemCode().map { $0.hexString.uppercased() }) ?? [detectedSnapshot.systemCode ?? "0003"]
                                    let detectedBrand = FeliCaProfile.all[0].detectedBrand(using: systemCodes, realSN: sn)

                                    var updatedFields = detectedSnapshot.resultFields
                                    if let index = updatedFields.firstIndex(where: { $0.title == "Detected Type" }) {
                                        updatedFields[index] = ResultField(title: "Detected Type", value: detectedBrand)
                                    }

                                    snapshot = TransitCardSnapshot(
                                        technology: detectedSnapshot.technology,
                                        cardFamily: detectedBrand,
                                        identifierLabel: detectedSnapshot.identifierLabel,
                                        identifierValue: detectedSnapshot.identifierValue,
                                        rawIdentifierValue: detectedSnapshot.rawIdentifierValue,
                                        pmm: detectedSnapshot.pmm,
                                        systemCode: detectedSnapshot.systemCode,
                                        selectedAID: detectedSnapshot.selectedAID,
                                        balanceText: detectedSnapshot.balanceText,
                                        balanceDetail: detectedSnapshot.balanceDetail,
                                        realSerialNumber: sn,
                                        region: detectedSnapshot.region,
                                        resultFields: updatedFields,
                                        rawSections: detectedSnapshot.rawSections,
                                        rawTransactions: detectedSnapshot.rawTransactions,
                                        rawTransitHistory: detectedSnapshot.rawTransitHistory,
                                        scannedAt: detectedSnapshot.scannedAt
                                    )
                                }
                            }
                        }
                    }

                if let snapshot {
                    self.accept(snapshot, session: session)
                } else {
                    self.fail("Could not read any supported transit card data.", session: session)
                }
            } catch {
                self.fail(error.localizedDescription, session: session)
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
