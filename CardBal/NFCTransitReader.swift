import CoreNFC
import Foundation
import os
import SwiftUI

@MainActor
final class NFCTransitReader: NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    private let logger = Logger(subsystem: "sm.nekoko.CardBal", category: "NFC")
    @Published private(set) var latestSnapshot: TransitCardSnapshot?
    @Published private(set) var statusMessage = "Ready to scan."
    @Published private(set) var isScanning = false

    private var session: NFCTagReaderSession?

    func startScanning() {
        guard NFCTagReaderSession.readingAvailable else {
            statusMessage = "NFC not available."
            return
        }
        session = NFCTagReaderSession(pollingOption: [.iso18092, .iso14443], delegate: self, queue: nil)
        session?.alertMessage = "Hold card to back of iPhone."
        isScanning = true
        session?.begin()
    }

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}
    
    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            self.isScanning = false
            self.statusMessage = "Session invalidated."
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        session.connect(to: tag) { error in
            if error != nil { session.invalidate(); return }
            Task { @MainActor in
                do {
                    let snapshot: TransitCardSnapshot
                    switch tag {
                    case .feliCa(let feliCa):
                        snapshot = try await self.decodeFeliCaSnapshot(from: feliCa)
                    case .iso7816(let iso7816):
                        snapshot = try await self.decodeISO7816Snapshot(from: iso7816)
                    default:
                        session.invalidate(errorMessage: "Unsupported tag type.")
                        return
                    }
                    self.latestSnapshot = snapshot
                    self.statusMessage = "Read successful."
                    session.invalidate()
                } catch {
                    session.invalidate(errorMessage: "Read failed.")
                }
            }
        }
    }

    private func decodeFeliCaSnapshot(from tag: any NFCFeliCaTag) async throws -> TransitCardSnapshot {
        let idm = tag.currentIDm.hexString
        let sys = tag.currentSystemCode.hexString
        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: "FeliCa Card",
            identifierLabel: "IDm",
            identifierValue: idm,
            rawIdentifierValue: idm,
            systemCode: sys,
            selectedAID: nil,
            balanceText: "N/A",
            balanceDetail: "Basic FeliCa info.",
            resultFields: [ResultField(title: "System Code", value: sys)],
            rawSections: [],
            scannedAt: Date()
        )
    }

    private func decodeISO7816Snapshot(from tag: any NFCISO7816Tag) async throws -> TransitCardSnapshot {
        let aid = tag.initialSelectedAID.uppercased()
        let uid = tag.identifier.hexString
        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: "Smart Card",
            identifierLabel: "UID",
            identifierValue: uid,
            rawIdentifierValue: uid,
            systemCode: nil,
            selectedAID: aid,
            balanceText: "N/A",
            balanceDetail: "Basic ISO7816 info.",
            resultFields: [ResultField(title: "AID", value: aid)],
            rawSections: [],
            scannedAt: Date()
        )
    }
}
