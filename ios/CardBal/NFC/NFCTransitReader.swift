#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import CoreNFC
#endif
import UIKit
import Foundation
import os
import SwiftUI

@MainActor
final class NFCTransitReader: NSObject, ObservableObject {
    private var latestStatusKind: StatusKind = .idle
    private let logger = Logger(subsystem: "ad.neko.cardbal", category: "NFC")

    @Published private(set) var latestSnapshot: TransitCardSnapshot?
    @Published private(set) var statusMessage = String(localized: "Ready to scan.")
    @Published private(set) var isScanning = false

    var isEnhancedFeliCaDecodingEnabled = false
    var checkIfCardAlreadyEnhanced: ((String) -> Bool)?

    #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
    private enum ScanPhase { case regular, octopus, mainland }
    private var phase: ScanPhase = .regular
    private var readsCompanionProtocol = false
    private var pendingPrimary: TransitCardSnapshot?
    private var restartForCompanion = false
    private var secondSideTimeout: Task<Void, Never>?
    private var isReadingTag = false
    private var session: NFCTagReaderSession?

    #endif

    @Published private(set) var externalReaderNames: [String] = []
    @Published var selectedExternalReaderName = UserDefaults.standard.string(forKey: "selectedExternalReaderName") {
        didSet {
            UserDefaults.standard.set(selectedExternalReaderName, forKey: "selectedExternalReaderName")
            updateStatus(String(localized: "Ready to scan."), kind: .idle)
        }
    }
    @Published var prefersExternalReader = UserDefaults.standard.bool(forKey: "prefersExternalReader") {
        didSet {
            UserDefaults.standard.set(prefersExternalReader, forKey: "prefersExternalReader")
            updateStatus(String(localized: "Ready to scan."), kind: .idle)
        }
    }
    private let externalReader = ExternalCardReader()
    private var externalScanTask: Task<Void, Never>?

    override init() {
        super.init()
        externalReader.observeReaders { [weak self] names in
            Task { @MainActor in self?.externalReaderNames = names }
        }
    }

    var requiresExternalReader: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        return UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
    var usesExternalReader: Bool { requiresExternalReader || prefersExternalReader }
    var isNFCAvailable: Bool {
        if usesExternalReader {
            return (try? ExternalReaderSelection.choose(preferred: selectedExternalReaderName, available: externalReaderNames)) != nil
        }
        #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
        return NFCTagReaderSession.readingAvailable
        #else
        return false
        #endif
    }

    func startScanning(options: CardPollingOption = [.iso18092, .iso14443, .iso15693]) {
        guard !isScanning else { return }
        if usesExternalReader {
            isScanning = true
            updateStatus(String(localized: "Reading card on external reader…"), kind: .idle)
            externalScanTask = Task { [weak self] in
                guard let self else { return }
                defer { self.isScanning = false; self.externalScanTask = nil }
                do {
                    let snapshot = try await self.externalReader.scan(readerName: self.selectedExternalReaderName, options: options)
                    try Task.checkCancellation()
                    self.latestSnapshot = snapshot
                    self.updateStatus(String(localized: "Read successful: ") + snapshot.cardFamily, kind: .success)
                } catch is CancellationError {
                    self.updateStatus(String(localized: "Scan cancelled."), kind: .idle)
                } catch {
                    let message = (error as? NFCTestError) != nil
                        ? String(localized: "Could not read any supported transit card data.") : error.localizedDescription
                    self.updateStatus(message, kind: .error)
                }
            }
            return
        }
        #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
        var nativeOptions: NFCTagReaderSession.PollingOption = []
        if options.contains(.iso18092) { nativeOptions.insert(.iso18092) }
        if options.contains(.iso14443) { nativeOptions.insert(.iso14443) }
        if options.contains(.iso15693) { nativeOptions.insert(.iso15693) }
        startInternalScanning(options: nativeOptions)
        #else
        updateStatus(ExternalReaderError.noReader.localizedDescription, kind: .error)
        #endif
    }

    func cancelExternalScan() { externalScanTask?.cancel() }

    var showsScanStatus: Bool { isScanning || latestStatusKind == .error }

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

    private func updateStatus(_ message: String, kind: StatusKind) {
        statusMessage = Localizer.localize(message)
        latestStatusKind = kind
        logger.log("Status: \(message, privacy: .public)")
    }


    #if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
    private func startInternalScanning(options: NFCTagReaderSession.PollingOption = [.iso18092, .iso14443, .iso15693]) {
        guard !isScanning else { return }
        phase = .regular
        readsCompanionProtocol = options.contains([.iso18092, .iso14443])
        beginScanning(options: options)
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
            if let pendingPrimary { latestSnapshot = pendingPrimary }
            resetScan()
            updateStatus("Unable to start session.", kind: .error)
            return
        }
        self.session = newSession
        isScanning = true
        let message = phase == .regular
            ? String(localized: "Hold your iPhone near a transit card.")
            : String(localized: "Keep the same card near your iPhone while reading finishes.")
        newSession.alertMessage = Localizer.localize(message)
        updateStatus(message, kind: .idle)
        newSession.begin()
        if phase != .regular { scheduleSecondSideTimeout(for: newSession) }
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
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self, self.session === session, self.phase != .regular else { return }
            self.finishPartial(session: session)
        }
    }

    private func resetScan() {
        secondSideTimeout?.cancel()
        secondSideTimeout = nil
        pendingPrimary = nil
        restartForCompanion = false
        phase = .regular
        readsCompanionProtocol = false
        isScanning = false
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
        guard self.session === session, let pendingPrimary else { return }
        latestSnapshot = pendingPrimary
        updateStatus("Read successful: \(pendingPrimary.cardFamily)", kind: .success)
        self.session = nil
        resetScan()
        if !alreadyInvalidated { session.invalidate() }
    }

    private func fail(_ message: String, session: NFCTagReaderSession) {
        guard self.session === session else { return }
        if pendingPrimary != nil {
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
        let hasOctopus = snapshot.applicationSnapshots.contains(where: \.isOctopus)
        let hasMainland = snapshot.applicationSnapshots.contains(where: { $0.isTUnion || $0.isCityUnion })
        switch phase {
        case .regular:
            guard readsCompanionProtocol, hasOctopus != hasMainland,
                  !snapshot.applicationSnapshots.contains(where: \.isMacauPass) else {
                finish(with: snapshot, session: session)
                return
            }
            // The ordinary scan reads either interface first, then checks the
            // other protocol while the user keeps the same physical card in place.
            pendingPrimary = snapshot
            phase = hasOctopus ? .mainland : .octopus
            let message = String(localized: "Keep the same card near your iPhone while reading finishes.")
            updateStatus(message, kind: .idle)
            session.alertMessage = Localizer.localize(message)
            if #available(iOS 26.4, *) {
                restartPolling(session)
                scheduleSecondSideTimeout(for: session)
            } else {
                // Only start the next reader after the old one has invalidated.
                restartForCompanion = true
                session.invalidate()
            }
        case .octopus, .mainland:
            guard let pendingPrimary,
                  phase == .octopus ? hasOctopus : hasMainland,
                  let combined = TransitCardSnapshot.combining([pendingPrimary, snapshot]) else {
                finishPartial(session: session)
                return
            }
            finish(with: combined, session: session)
        }
    }
    #endif
}

#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
extension NFCTransitReader: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        logger.log("NFC session active.")
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            guard self.session === session else { return }
            if self.restartForCompanion {
                self.restartForCompanion = false
                self.session = nil
                self.beginScanning(options: self.phase == .mainland ? [.iso14443] : [.iso18092])
                return
            }
            if self.pendingPrimary != nil {
                self.finishPartial(session: session, alreadyInvalidated: true)
                return
            }
            self.session = nil
            self.resetScan()
            if (error as NSError).code == 200 {
                self.updateStatus(String(localized: "Ready to scan."), kind: .idle)
            } else {
                self.updateStatus("Session invalidated: \(error.localizedDescription)", kind: .error)
            }
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task { @MainActor in
            guard self.session === session, self.isScanning, !self.isReadingTag, !tags.isEmpty else { return }
            // One dual-protocol card may be reported once per technology.
            // Start with its FeliCa interface and discover ISO afresh after the
            // protocol switch. Two discoveries of the same type remain ambiguous.
            let felicaTags = tags.filter { if case .feliCa = $0 { return true }; return false }
            let isoTags = tags.filter { if case .iso7816 = $0 { return true }; return false }
            let dualDiscovery = self.phase == .regular && self.readsCompanionProtocol
                && tags.count == 2 && felicaTags.count == 1 && isoTags.count == 1
            guard (tags.count == 1 || dualDiscovery),
                  let tag = dualDiscovery ? felicaTags.first : tags.first else {
                session.alertMessage = String(localized: "Present only one transit card.")
                self.restartPolling(session)
                return
            }
            self.isReadingTag = true
            defer { self.isReadingTag = false }
            self.secondSideTimeout?.cancel()
            do {
                try await session.connect(to: tag)
                guard let cardTag = CardTag(tag) else {
                    self.fail("Could not read any supported transit card data.", session: session)
                    return
                }
                let decoders: [TransitCardDecoder.Type] = phase == .mainland
                    ? [ChineseTransitDecoder.self]
                    : phase == .octopus ? [JapaneseICDecoder.self] : [
                        CEPASDecoder.self, MacauPassDecoder.self, ClipperDecoder.self, ClipperUltralightDecoder.self,
                        StoredValueDecoder.self, TianfuTongDecoder.self, ChineseTransitDecoder.self, CalypsoDecoder.self, KSX6924Decoder.self,
                        EdyDecoder.self, WAONDecoder.self, NanacoDecoder.self, JapaneseICDecoder.self
                    ]
                var snapshot: TransitCardSnapshot?
                for decoder in decoders {
                    if await decoder.canDecode(tag: cardTag) {
                        snapshot = try? await decoder.decode(tag: cardTag, scannedAt: Date())
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

                if dualDiscovery && snapshot?.applicationSnapshots.contains(where: \.isOctopus) != true {
                    session.alertMessage = String(localized: "Present only one transit card.")
                    self.restartPolling(session)
                } else if let snapshot {
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
        let (pmmData, _) = try await tag.polling(
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

#endif
