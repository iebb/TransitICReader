import CoreNFC
import Foundation
import os
import SwiftUI

struct RawDataSection: Identifiable {
    let id = UUID()
    let title: String
    let fields: [RawDataField]
}

struct RawDataField: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct TransitCardSnapshot: Identifiable {
    let id = UUID()
    let cardFamily: String
    let technology: String
    let identifierLabel: String
    let rawIdentifierValue: String
    let identifierValue: String
    let systemCode: String?
    let selectedAID: String?
    let balanceText: String?
    let balanceDetail: String?
    let resultFields: [ResultField]
    let scannedAt: Date
    let rawSections: [RawDataSection]
}

struct ResultField: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

@MainActor
final class NFCTransitReader: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "sm.nekoko.CardBal", category: "NFC")
    @Published private(set) var latestSnapshot: TransitCardSnapshot?
    @Published private(set) var statusMessage = "Ready to scan."
    @Published private(set) var isScanning = false

    var isNFCAvailable: Bool {
        NFCTagReaderSession.readingAvailable
    }

    var statusSymbol: String {
        switch latestStatusKind {
        case .idle:
            return "dot.radiowaves.left.and.right"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var statusColor: Color {
        switch latestStatusKind {
        case .idle:
            return .secondary
        case .success:
            return .green
        case .error:
            return .orange
        }
    }

    private var latestStatusKind: StatusKind = .idle
    private var session: NFCTagReaderSession?

    func beginScanning() {
        guard isNFCAvailable else {
            updateStatus("NFC tag reading is not available on this device.", kind: .error)
            return
        }

        guard let session = NFCTagReaderSession(pollingOption: [.iso18092, .iso14443], delegate: self, queue: nil) else {
            updateStatus("Unable to start the NFC reader session.", kind: .error)
            return
        }

        session.alertMessage = "Hold your iPhone near a supported transit card."
        self.session = session
        isScanning = true
        updateStatus("Scanning for FeliCa and ISO7816 transit cards...", kind: .idle)
        session.begin()
    }

    private func updateStatus(_ message: String, kind: StatusKind) {
        statusMessage = message
        latestStatusKind = kind
        logger.log("Status: \(message, privacy: .public)")
        print("CardBal Status: \(message)")
    }

    private func finish(with snapshot: TransitCardSnapshot, session: NFCTagReaderSession) {
        latestSnapshot = snapshot
        updateStatus("Read \(snapshot.cardFamily) successfully.", kind: .success)
        session.alertMessage = snapshot.balanceText.map { "Balance: \($0)" } ?? "Card read completed."
        session.invalidate()
    }

    private func fail(_ message: String, session: NFCTagReaderSession, restart: Bool = false) {
        updateStatus(message, kind: .error)
        session.alertMessage = message
        if restart {
            session.restartPolling()
        } else {
            session.invalidate()
        }
    }

    private func decodeFeliCaSnapshot(from tag: any NFCFeliCaTag) async throws -> TransitCardSnapshot {
        let scannedAt = Date()
        let systemCodeBytes = tag.currentSystemCode.hexString
        let systemCodeCandidates = tag.currentSystemCode.systemCodeCandidates
        let requestedSystemCodes = (try? await requestSystemCodes(from: tag)) ?? []
        let allSystemCodes = Array(Set((systemCodeCandidates + requestedSystemCodes).map { $0.uppercased() })).sorted()
        let profile = FeliCaCardProfile.matching(candidates: allSystemCodes)

        guard let profile else {
            let rawIDm = tag.currentIDm.hexString
            let formattedIDm = formatFeliCaIDm(tag.currentIDm.hexString)
            return TransitCardSnapshot(
                cardFamily: "Unsupported FeliCa Card",
                technology: "FeliCa",
                identifierLabel: "IDm",
                rawIdentifierValue: rawIDm,
                identifierValue: formattedIDm,
                systemCode: systemCodeCandidates.first,
                selectedAID: nil,
                balanceText: nil,
                balanceDetail: "No balance decoder is configured for this FeliCa system code.",
                resultFields: [],
                scannedAt: scannedAt,
                rawSections: [
                    RawDataSection(
                        title: "Tag",
                        fields: [
                            RawDataField(title: "Technology", value: "FeliCa"),
                            RawDataField(title: "IDm", value: formattedIDm),
                            RawDataField(title: "Current System Code Bytes", value: systemCodeBytes),
                            RawDataField(title: "System Code Candidates", value: systemCodeCandidates.joined(separator: ", ")),
                            RawDataField(title: "Requested System Codes", value: requestedSystemCodes.isEmpty ? "Unavailable" : requestedSystemCodes.joined(separator: ", "))
                        ]
                    )
                ]
            )
        }

        let readResult = try await readWithoutEncryption(
            from: tag,
            serviceCodeList: [profile.serviceCodeLittleEndian],
            blockList: [Data([0x80, 0x00])]
        )

        let block = readResult.blocks.first
        let parsedBalance = block.flatMap { profile.parseBalance($0, scannedAt) }
        let rawIDm = tag.currentIDm.hexString
        let formattedIDm = formatFeliCaIDm(rawIDm)
        let detectedBrand = profile.detectedBrand(using: allSystemCodes)

        var rawSections: [RawDataSection] = [
            RawDataSection(
                title: "Tag",
                fields: [
                    RawDataField(title: "Technology", value: "FeliCa"),
                    RawDataField(title: "IDm", value: formattedIDm),
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
                    RawDataField(title: "Status Flag 1", value: String(readResult.status.statusFlag1)),
                    RawDataField(title: "Status Flag 2", value: String(readResult.status.statusFlag2)),
                    RawDataField(title: "Block Count", value: String(readResult.blocks.count)),
                    RawDataField(title: "Block 0", value: block?.hexString ?? "Unavailable")
                ]
            )
        ]

        if let parsedBalance {
            rawSections.append(
                RawDataSection(
                    title: "Decoded Balance",
                    fields: parsedBalance.rawFields
                )
            )
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
            cardFamily: detectedBrand,
            technology: "FeliCa",
            identifierLabel: "IDm",
            rawIdentifierValue: rawIDm,
            identifierValue: formattedIDm,
            systemCode: profile.systemCode,
            selectedAID: nil,
            balanceText: parsedBalance?.formatted,
            balanceDetail: parsedBalance?.detail,
            resultFields: profile.resultFields(forIDm: formattedIDm, detectedBrand: detectedBrand),
            scannedAt: scannedAt,
            rawSections: rawSections
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
            KSX6924ConfigDFInfo(
                fciPayload: $0.payload ?? Data(),
                selectedAID: selectedAID
            )
        }

        let applicationAID = configInfo?.mainApplicationAID ?? selectedAID
        let profile = KSX6924CardProfile.matching(aid: applicationAID, configInfo: configInfo)

        let selectResponse: NFCISO7816ResponseAPDU?
        if applicationAID == selectedAID {
            selectResponse = initialSelectResponse
        } else {
            guard NFCISO7816AccessPolicy.isAllowed(aid: applicationAID) else {
                throw NFCTransitReaderFailure.missingISO7816Entitlement(aid: applicationAID)
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
            rawSections.append(
                RawDataSection(
                    title: "Decoded Balance",
                    fields: parsedBalance.rawFields
                )
            )
        }

        if let initialSelectResponse {
            var initialSelectFields = [
                RawDataField(title: "Command", value: NFCISO7816APDU.selectCommandData(aid: selectedAID).hexString),
                RawDataField(title: "Response Payload", value: (initialSelectResponse.payload ?? Data()).hexString),
                RawDataField(title: "SW1SW2", value: initialSelectResponse.statusWords)
            ]
            if let configInfo {
                if let mainApplicationAID = configInfo.mainApplicationAID {
                    initialSelectFields.append(RawDataField(title: "Main Application AID", value: mainApplicationAID))
                }
                if let serial = configInfo.serial {
                    initialSelectFields.append(RawDataField(title: "Config DF Serial", value: serial))
                }
            }
            rawSections.append(
                RawDataSection(
                    title: applicationAID == selectedAID ? "Select AID APDU" : "Initial Select AID APDU",
                    fields: initialSelectFields
                )
            )
        }

        if let selectResponse {
            var selectFields = [
                RawDataField(title: "Command", value: NFCISO7816APDU.selectCommandData(aid: applicationAID).hexString),
                RawDataField(title: "Response Payload", value: (selectResponse.payload ?? Data()).hexString),
                RawDataField(title: "SW1SW2", value: selectResponse.statusWords)
            ]
            if let purseInfo {
                selectFields.append(RawDataField(title: "Purse Info Bytes", value: purseInfo.rawData.hexString))
                selectFields.append(RawDataField(title: "Parsed Serial", value: purseInfo.serial))
                if let issueDate = purseInfo.issueDate {
                    selectFields.append(RawDataField(title: "Parsed Issue Date", value: issueDate))
                }
            }
            rawSections.append(
                RawDataSection(
                    title: applicationAID == selectedAID ? "Select AID APDU" : "Application Select AID APDU",
                    fields: selectFields
                )
            )
        }

        if let cardInfoResponse {
            var infoFields = [
                RawDataField(title: "Command", value: NFCISO7816APDU.ksx6924CardInfoCommand.hexString),
                RawDataField(title: "Response Payload", value: cardInfoPayload.hexString),
                RawDataField(title: "SW1SW2", value: cardInfoResponse.statusWords)
            ]

            if cardInfoPayload.count > 29 {
                infoFields.append(RawDataField(title: "Issuer Byte", value: String(format: "0x%02X", cardInfoPayload[7])))
                infoFields.append(RawDataField(title: "Card Number Bytes", value: cardInfoPayload.sliceHexString(start: 8, length: 8)))
                infoFields.append(RawDataField(title: "Card Number Tail Bytes", value: cardInfoPayload.sliceHexString(start: 13, length: 3)))
                infoFields.append(RawDataField(title: "Issue Date Bytes", value: cardInfoPayload.sliceHexString(start: 21, length: 4)))
                infoFields.append(RawDataField(title: "Card Type Byte", value: String(format: "0x%02X", cardInfoPayload[29])))
            }

            rawSections.append(
                RawDataSection(
                    title: "Card Info APDU",
                    fields: infoFields
                )
            )
        }

        return TransitCardSnapshot(
            cardFamily: profile.displayName,
            technology: "ISO7816",
            identifierLabel: "UID",
            rawIdentifierValue: tag.identifier.hexString,
            identifierValue: tag.identifier.hexString,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: parsedBalance?.formatted,
            balanceDetail: parsedBalance?.detail,
            resultFields: parsedCardInfo.resultFields,
            scannedAt: scannedAt,
            rawSections: rawSections
        )
    }

    private func decodeCalypsoSnapshot(
        from tag: any NFCISO7816Tag,
        selectedAID: String,
        scannedAt: Date
    ) async throws -> TransitCardSnapshot {
        let profile = CalypsoCardProfile.matching(aid: selectedAID)
        let applicationAID = profile.applicationAID(for: selectedAID)
        logger.log("Calypso selected AID: \(selectedAID, privacy: .public)")
        logger.log("Calypso application AID: \(applicationAID, privacy: .public)")
        print("CardBal Calypso selectedAID=\(selectedAID) applicationAID=\(applicationAID)")
        let shouldReselect = NFCISO7816AccessPolicy.exactAIDs.contains(applicationAID)
        let selectResponse = shouldReselect ? (try? await sendISO7816Command(.selectByName(applicationAID), to: tag)) : nil
        let secureSessionResponse = try? await sendISO7816Command(.custom(commandData: Data([0x94, 0xA4, 0x08, 0x00, 0x02, 0x20, 0x00])), to: tag)

        let probeTargets = profile.probeTargets
        let probeResponses = try await readISO7816Commands(probeTargets.map(\.apdu), to: tag)
        let probeResults = Array(zip(probeTargets, probeResponses))
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
                else {
                    return nil
                }

                let bestContract = bestContracts.first(where: { $0.contractPointer == index || $0.index == index })
                    ?? NiceBestContractEntry(index: index, tariffKey: 0, tariffStructure: "Unknown", tariffPriority: "Unknown", contractPointer: index)
                guard let summary = parseNiceContractSummary(from: payload, bestContract: bestContract) else {
                    return nil
                }
                return (index, summary)
            }
        )
        let primaryBestContract = bestContracts.first
        let primarySlot = primaryBestContract?.contractPointer ?? primaryBestContract?.index
        let primaryContract = primarySlot.flatMap { contractBySlot[$0] }
        let remainingTickets = primarySlot.flatMap { slot in
            exactRecordProbes
                .first(where: { $0.title == "Ticket Detail Record \(slot)" })?
                .response
                .payload
                .flatMap(parseNiceRemainingTickets)
        }
        let cardExpiryDate = environmentPayload.flatMap(parseNiceCardExpiryDate)
        let eventSummary = exactRecordProbes.compactMap { probe -> NiceEventSummary? in
            guard probe.title.hasPrefix("Event Record"),
                  probe.response.statusWords == "9000",
                  let payload = probe.response.payload,
                  !payload.allSatisfy({ $0 == 0 })
            else {
                return nil
            }
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
        } else {
            rawSections.append(
                RawDataSection(
                    title: "Select Application APDU",
                    fields: [
                        RawDataField(title: "Command", value: "Skipped"),
                        RawDataField(title: "Reason", value: "Using the card's already selected Calypso app to avoid an extra iPhone entitlement check."),
                        RawDataField(title: "Application AID", value: applicationAID)
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
            logger.log("Calypso probe \(target.title, privacy: .public) cmd=\(target.commandData.hexString, privacy: .public) sw=\(response.statusWords, privacy: .public) payload=\((response.payload ?? Data()).hexString, privacy: .public)")
            print("CardBal Calypso probe title=\(target.title) cmd=\(target.commandData.hexString) sw=\(response.statusWords) payload=\((response.payload ?? Data()).hexString)")
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

        if !bestContracts.isEmpty {
            rawSections.append(
                RawDataSection(
                    title: "Best Contract Decode",
                    fields: bestContracts.flatMap { entry in
                        [
                            RawDataField(title: "Entry \(entry.index) Pointer", value: String(entry.contractPointer)),
                            RawDataField(title: "Entry \(entry.index) Contract Slot", value: String(entry.contractPointer)),
                            RawDataField(title: "Entry \(entry.index) Counter Slot", value: String(entry.contractPointer)),
                            RawDataField(title: "Entry \(entry.index) Type", value: entry.tariffStructure),
                            RawDataField(title: "Entry \(entry.index) Priority", value: entry.tariffPriority),
                            RawDataField(title: "Entry \(entry.index) Tariff Key", value: String(entry.tariffKey))
                        ]
                    }
                )
            )
        }

        if let primaryContract {
            let ticketLabel = niceTicketLabel(for: primaryContract)
            var fields: [RawDataField] = [
                RawDataField(title: "Ticket Name", value: ticketLabel.displayName),
                RawDataField(title: "Contract Type", value: primaryContract.contractType),
                RawDataField(title: "Provider", value: primaryContract.provider),
                RawDataField(title: "Linked Tariff ID", value: primaryContract.linkedTariffID),
                RawDataField(title: "Serial Number", value: primaryContract.serialNumber)
            ]
            if let saleDate = primaryContract.saleDate {
                fields.append(RawDataField(title: "Sale Date", value: saleDate))
                fields.append(RawDataField(title: "Sale Date Source", value: "Contract summary bits 88-101 as a 14-bit Calypso day count"))
            }
            if let apkProductFamily = ticketLabel.apkProductFamily {
                fields.append(RawDataField(title: "APK Product Family", value: apkProductFamily))
                fields.append(RawDataField(title: "APK Source", value: "buy_ticket_with_account_products in the Nice app resources"))
            }
            if let status = primaryContract.status {
                fields.append(RawDataField(title: "Status", value: status))
            }
            if let validityStartDate = primaryContract.validityStartDate {
                fields.append(RawDataField(title: "Start Date", value: validityStartDate))
            }
            if let validityEndDate = primaryContract.validityEndDate {
                fields.append(RawDataField(title: "End Date", value: validityEndDate))
            }
            if let passengerClass = primaryContract.passengerClass {
                fields.append(RawDataField(title: "Passenger Class", value: passengerClass))
            }
            if let validityJourneys = primaryContract.validityJourneys {
                fields.append(RawDataField(title: "Validity Journeys", value: validityJourneys))
            }
            if let journeyOrigin = primaryContract.journeyOrigin {
                fields.append(RawDataField(title: "Journey Origin", value: journeyOrigin))
            }
            if let journeyDestination = primaryContract.journeyDestination {
                fields.append(RawDataField(title: "Journey Destination", value: journeyDestination))
            }
            if let journeyVia = primaryContract.journeyVia {
                fields.append(RawDataField(title: "Journey Via", value: journeyVia))
            }
            rawSections.append(RawDataSection(title: "Ticket Decode", fields: fields))
        }

        if let environmentPayload, let cardExpiryDate {
            rawSections.append(
                RawDataSection(
                    title: "Card Validity Decode",
                    fields: [
                        RawDataField(title: "Source", value: "Environment Record"),
                        RawDataField(title: "Source Payload", value: environmentPayload.hexString),
                        RawDataField(title: "Bit Range", value: "45-58"),
                        RawDataField(title: "Decoded Date", value: cardExpiryDate),
                        RawDataField(title: "Formula", value: "Interpret environment bits 45-58 as a 14-bit Calypso day count from 1997-01-01.")
                    ]
                )
            )
        }

        if let eventSummary {
            var fields: [RawDataField] = [
                RawDataField(title: "Source", value: eventSummary.sourceTitle),
                RawDataField(title: "Event Date", value: eventSummary.eventDateStamp),
                RawDataField(title: "Event Time", value: eventSummary.eventTimeStamp),
                RawDataField(title: "Service Provider", value: eventSummary.eventServiceProvider),
                RawDataField(title: "Main Bitmap", value: eventSummary.mainBitmap)
            ]
            if let eventCode = eventSummary.eventCode {
                fields.append(RawDataField(title: "Event Code", value: eventCode))
            }
            if let eventCodeMode = eventSummary.eventCodeMode {
                fields.append(RawDataField(title: "Event Mode", value: eventCodeMode))
            }
            if let eventCodeType = eventSummary.eventCodeType {
                fields.append(RawDataField(title: "Event Type", value: eventCodeType))
            }
            if let eventCodeResult = eventSummary.eventCodeResult {
                fields.append(RawDataField(title: "Event Result", value: eventCodeResult))
            }
            if let eventLocationID = eventSummary.eventLocationID {
                fields.append(RawDataField(title: "Location ID", value: eventLocationID))
            }
            if let eventRouteNumber = eventSummary.eventRouteNumber {
                fields.append(RawDataField(title: "Route Number", value: eventRouteNumber))
            }
            if let eventJourneyRun = eventSummary.eventJourneyRun {
                fields.append(RawDataField(title: "Journey Run", value: eventJourneyRun))
            }
            rawSections.append(RawDataSection(title: "Event Decode", fields: fields))
        }

        let ticketStatus: String
        if let remainingTickets {
            ticketStatus = "Remaining trips: \(remainingTickets)"
        } else if primaryContract != nil {
            ticketStatus = "Contract decoded, counter still unavailable"
        } else if eventSummary != nil {
            ticketStatus = "Ticket event decoded"
        } else {
            ticketStatus = "Ticket records not decoded yet"
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
        resultFields.append(ResultField(title: "Ticket Status", value: ticketStatus))

        return TransitCardSnapshot(
            cardFamily: "Lignes d'Azur card",
            technology: "ISO7816",
            identifierLabel: "UID",
            rawIdentifierValue: tag.identifier.hexString,
            identifierValue: tag.identifier.hexString,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: nil,
            balanceDetail: nil,
            resultFields: resultFields,
            scannedAt: scannedAt,
            rawSections: rawSections
            + (calypsoCardNumber.map { cardNumber in
                [
                    RawDataSection(
                        title: "Card Number Decode",
                        fields: [
                            RawDataField(title: "Source Tag", value: "C7"),
                            RawDataField(title: "Source Bytes", value: cardNumber.sourceBytes),
                            RawDataField(title: "Stored Decimal", value: cardNumber.decimal),
                            RawDataField(title: "Padded Decimal", value: cardNumber.paddedDecimal),
                            RawDataField(title: "Formatted", value: cardNumber.formatted),
                            RawDataField(title: "Formula", value: "Take the last 4 bytes of tag C7 as a big-endian integer, decimal-encode it, left-pad to 10 digits, then format as X XXX XXX XXX.")
                        ]
                    )
                ]
            } ?? [])
        )
    }

    private func readWithoutEncryption(
        from tag: any NFCFeliCaTag,
        serviceCodeList: [Data],
        blockList: [Data]
    ) async throws -> (status: NFCFeliCaStatusFlag, blocks: [Data]) {
        try await withCheckedThrowingContinuation { continuation in
            tag.readWithoutEncryption(serviceCodeList: serviceCodeList, blockList: blockList) { result in
                switch result {
                case let .success((status, blocks)):
                    continuation.resume(returning: (status: status, blocks: blocks))
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requestSystemCodes(from tag: any NFCFeliCaTag) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            tag.requestSystemCode { result in
                switch result {
                case let .success(systemCodes):
                    let formatted = systemCodes.map(\.hexString).map { $0.uppercased() }
                    continuation.resume(returning: formatted)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendISO7816Command(
        _ apdu: NFCISO7816APDU,
        to tag: any NFCISO7816Tag
    ) async throws -> NFCISO7816ResponseAPDU {
        let result = try await tag.sendCommand(apdu: apdu)
        return NFCISO7816ResponseAPDU(statusWord1: result.1, statusWord2: result.2, payload: result.0)
    }

    private func readISO7816Commands(
        _ commands: [NFCISO7816APDU],
        to tag: any NFCISO7816Tag
    ) async throws -> [NFCISO7816ResponseAPDU] {
        var responses: [NFCISO7816ResponseAPDU] = []
        responses.reserveCapacity(commands.count)

        for command in commands {
            responses.append(try await sendISO7816Command(command, to: tag))
        }

        return responses
    }
}

extension NFCTransitReader: NFCTagReaderSessionDelegate {
    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in
            self.isScanning = false
            self.session = nil

            let readerError = error as NSError
            if let code = NFCReaderError.Code(rawValue: readerError.code),
               [.readerSessionInvalidationErrorUserCanceled, .readerSessionInvalidationErrorSessionTimeout].contains(code) {
                if self.latestStatusKind == .idle {
                    self.updateStatus("Scan cancelled.", kind: .idle)
                }
                return
            }

            self.updateStatus("NFC session ended: \(error.localizedDescription)", kind: .error)
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else {
            Task { @MainActor in
                self.fail("No NFC tag was detected.", session: session)
            }
            return
        }

        if tags.count > 1 {
            Task { @MainActor in
                self.fail("More than one card was detected. Present only one card.", session: session, restart: true)
            }
            return
        }

        Task {
            do {
                try await session.connect(to: tag)

                let snapshot: TransitCardSnapshot
                switch tag {
                case let .feliCa(feliCaTag):
                    snapshot = try await self.decodeFeliCaSnapshot(from: feliCaTag)
                case let .iso7816(iso7816Tag):
                    snapshot = try await self.decodeISO7816Snapshot(from: iso7816Tag)
                default:
                    await MainActor.run {
                        self.fail("This card type is not supported by the current reader.", session: session)
                    }
                    return
                }

                await MainActor.run {
                    self.finish(with: snapshot, session: session)
                }
            } catch {
                await MainActor.run {
                    if let failure = error as? NFCTransitReaderFailure {
                        self.fail(failure.localizedDescription, session: session)
                    } else {
                        let nsError = error as NSError
                        if nsError.localizedDescription.contains("Missing required entitlement") {
                            self.fail("This card requires an ISO7816 AID that is not yet allowed in CardBal's NFC settings.", session: session)
                        } else {
                            self.fail("Failed to read the card. Try holding it steady near the top edge of the iPhone.", session: session)
                        }
                    }
                }
            }
        }
    }
}

private enum StatusKind {
    case idle
    case success
    case error
}

private enum NFCTransitReaderFailure: LocalizedError {
    case missingISO7816Entitlement(aid: String)

    var errorDescription: String? {
        switch self {
        case let .missingISO7816Entitlement(aid):
            return "This card exposes app AID \(aid), but that AID is not in CardBal's iPhone NFC allowlist yet."
        }
    }
}

private struct ParsedBalance {
    let formatted: String
    let detail: String
    let rawFields: [RawDataField]
}

private struct KSX6924CardInfo {
    let cardNumber: String?
    let issueDate: String?

    init(payload: Data, purseInfo: KSX6924PurseInfo?, configInfo: KSX6924ConfigDFInfo?) {
        self.cardNumber = purseInfo?.serial
            ?? configInfo?.serial
            ?? (payload.count >= 16 ? formatKoreanCardNumber(payload.sliceHexString(start: 8, length: 8)) : nil)
        self.issueDate = purseInfo?.issueDate ?? (payload.count >= 25 ? Self.formatIssueDate(payload[21...24]) : nil)
    }

    var resultFields: [ResultField] {
        var fields: [ResultField] = []
        if let cardNumber {
            fields.append(ResultField(title: "Card Number", value: cardNumber))
        }
        if let issueDate {
            fields.append(ResultField(title: "Issue Date", value: issueDate))
        }
        return fields
    }

    private static func formatIssueDate(_ bytes: Data.SubSequence) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        guard hex.count == 8 else { return hex }
        let year = String(hex.prefix(4))
        let month = String(hex.dropFirst(4).prefix(2))
        let day = String(hex.suffix(2))
        if let monthInt = Int(month), let dayInt = Int(day), (1...12).contains(monthInt), (1...31).contains(dayInt) {
            return "\(year)-\(month)-\(day)"
        }
        return hex
    }
}

private struct KSX6924ConfigDFInfo {
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

private struct KSX6924PurseInfo {
    let rawData: Data
    let serial: String
    let issueDate: String?

    init?(fciPayload: Data) {
        guard let purseInfoData = findTLVValue(tag: [0xB0], in: fciPayload), purseInfoData.count >= 21 else {
            return nil
        }

        self.rawData = purseInfoData
        let csn = purseInfoData.sliceHexString(start: 4, length: 8)
        self.serial = formatKoreanCardNumber(csn)

        if purseInfoData.count >= 21 {
            self.issueDate = Self.parseBCDDate(purseInfoData[17...20])
        } else {
            self.issueDate = nil
        }
    }

    private static func parseBCDDate(_ bytes: Data.SubSequence) -> String? {
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
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

private func formatKoreanCardNumber(_ hex: String) -> String {
    let clean = hex.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in
        let start = clean.index(clean.startIndex, offsetBy: index)
        let end = clean.index(start, offsetBy: 4)
        return String(clean[start..<end])
    }.joined(separator: " ")
}

private func formatFeliCaIDm(_ hex: String) -> String {
    let clean = hex.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in
        let start = clean.index(clean.startIndex, offsetBy: index)
        let end = clean.index(start, offsetBy: 4)
        return String(clean[start..<end])
    }.joined(separator: " ")
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

private func parseCalypsoCardNumber(from fciPayload: Data) -> CalypsoCardNumber? {
    guard let serialData = findTLVValue(tag: [0xC7], in: fciPayload), serialData.count >= 4 else {
        return nil
    }

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
        let tariffKey = Int(entryBits.bitSubstring(start: 3, length: 4), radix: 2) ?? 0
        let tariffStructure = String(Int(entryBits.bitSubstring(start: 7, length: 8), radix: 2) ?? 0, radix: 16).uppercased()
        let tariffPriority = String(Int(entryBits.bitSubstring(start: 15, length: 4), radix: 2) ?? 0, radix: 16).uppercased()
        let contractPointer = Int(entryBits.bitSubstring(start: 19, length: 5), radix: 2) ?? 0

        entries.append(
            NiceBestContractEntry(
                index: index + 1,
                tariffKey: tariffKey,
                tariffStructure: tariffStructure,
                tariffPriority: tariffPriority,
                contractPointer: contractPointer
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

    return NiceContractSummary(
        contractType: bestContract.tariffStructure,
        provider: provider,
        linkedTariffID: linkedTariffID,
        serialNumber: serialNumber,
        saleDate: saleDate,
        status: status,
        validityStartDate: validityStartDate,
        validityEndDate: validityEndDate,
        passengerClass: passengerClass,
        validityJourneys: validityJourneys,
        journeyOrigin: journeyOrigin,
        journeyDestination: journeyDestination,
        journeyVia: journeyVia
    )
}

private func parseNiceRemainingTickets(from payload: Data) -> Int? {
    guard payload.count >= 3 else { return nil }
    return Int(payload[2])
}

private func parseNiceCardExpiryDate(from payload: Data) -> String? {
    let bits = payload.binaryString
    guard bits.count >= 59 else { return nil }
    let candidate = bits.bitSubstring(start: 45, length: 14)
    return formatCalypsoDay(candidate)
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

    return NiceEventSummary(
        sourceTitle: sourceTitle,
        eventDateStamp: eventDateStamp,
        eventTimeStamp: eventTimeStamp,
        mainBitmap: mainBitmap,
        eventCode: eventCode,
        eventCodeMode: eventCodeMode,
        eventCodeType: eventCodeType,
        eventCodeResult: eventCodeResult,
        eventServiceProvider: eventServiceProvider,
        eventLocationID: eventLocationID,
        eventRouteNumber: eventRouteNumber,
        eventJourneyRun: eventJourneyRun
    )
}

private func formatCalypsoDay(_ bits: String) -> String? {
    guard let value = Int(bits, radix: 2) else { return nil }
    let reference = Date(timeIntervalSince1970: 852_073_200)
    let date = reference.addingTimeInterval(TimeInterval(value * 86_400))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "fr_FR")
    formatter.dateFormat = "dd/MM/yy"
    return formatter.string(from: date)
}

private func formatCompactTime(_ bits: String) -> String? {
    guard let value = Int(bits, radix: 2) else { return nil }
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let seconds = value % 60
    guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds) else {
        return nil
    }
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}

private extension NFCTransitReader {
    func readCalypsoRecordProbes(on tag: any NFCISO7816Tag) async throws -> [CalypsoRecordProbeResult] {
        let probes: [(String, String, NFCISO7816APDU, Data)] = [
            ("Environment Record", "Secure Nice environment read from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x3C, 0x1D])), Data([0x94, 0xB2, 0x01, 0x3C, 0x1D])),
            ("Best Contracts", "Secure Nice best-contract list from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0xF4, 0x1D])), Data([0x94, 0xB2, 0x01, 0xF4, 0x1D])),
            ("Supplemental Record 1", "Secure supplemental contract data from record family 0xEC.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0xEC, 0x1D])), Data([0x94, 0xB2, 0x01, 0xEC, 0x1D])),
            ("Supplemental Record 2", "Secure supplemental contract data from record family 0xEC.", .custom(commandData: Data([0x94, 0xB2, 0x02, 0xEC, 0x1D])), Data([0x94, 0xB2, 0x02, 0xEC, 0x1D])),
            ("Supplemental Record 3", "Secure supplemental contract data from record family 0xEC.", .custom(commandData: Data([0x94, 0xB2, 0x03, 0xEC, 0x1D])), Data([0x94, 0xB2, 0x03, 0xEC, 0x1D])),
            ("Event Record 1", "Secure Nice event record from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x44, 0x1D])), Data([0x94, 0xB2, 0x01, 0x44, 0x1D])),
            ("Event Record 2", "Secure Nice event record from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x02, 0x44, 0x1D])), Data([0x94, 0xB2, 0x02, 0x44, 0x1D])),
            ("Event Record 3", "Secure Nice event record from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x03, 0x44, 0x1D])), Data([0x94, 0xB2, 0x03, 0x44, 0x1D])),
            ("Event Record 4", "Secure Nice event record from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x04, 0x44, 0x1D])), Data([0x94, 0xB2, 0x04, 0x44, 0x1D])),
            ("Event Record 5", "Secure Nice event record from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x05, 0x44, 0x1D])), Data([0x94, 0xB2, 0x05, 0x44, 0x1D])),
            ("Event Record 6", "Secure Nice event record from the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x06, 0x44, 0x1D])), Data([0x94, 0xB2, 0x06, 0x44, 0x1D])),
            ("Contract Summary Record 1", "Primary loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x01, 0x4C, 0x1D])),
            ("Unknown Record 1", "Secure record family 0x34 as seen in the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x34, 0x1D])), Data([0x94, 0xB2, 0x01, 0x34, 0x1D])),
            ("Unknown Record 2", "Secure record family 0x34 as seen in the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x02, 0x34, 0x1D])), Data([0x94, 0xB2, 0x02, 0x34, 0x1D])),
            ("Unknown Record 3", "Secure record family 0x34 as seen in the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x03, 0x34, 0x1D])), Data([0x94, 0xB2, 0x03, 0x34, 0x1D])),
            ("Ticket Detail Record 1", "Primary remaining-trip detail from secure record family 0x54.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x54, 0x1D])), Data([0x94, 0xB2, 0x01, 0x54, 0x1D])),
            ("Contract Summary Record 2", "Loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x02, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x02, 0x4C, 0x1D])),
            ("Contract Summary Record 3", "Loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x03, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x03, 0x4C, 0x1D])),
            ("Contract Summary Record 4", "Loaded-ticket summary from secure record family 0x4C.", .custom(commandData: Data([0x94, 0xB2, 0x04, 0x4C, 0x1D])), Data([0x94, 0xB2, 0x04, 0x4C, 0x1D])),
            ("Ticket Detail Record 4", "Secure ticket-detail record from family 0x6C.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x6C, 0x1D])), Data([0x94, 0xB2, 0x01, 0x6C, 0x1D])),
            ("Ticket Detail Record 3", "Secure ticket-detail record from family 0x64.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x64, 0x1D])), Data([0x94, 0xB2, 0x01, 0x64, 0x1D])),
            ("Ticket Detail Record 2", "Secure ticket-detail record from family 0x5C.", .custom(commandData: Data([0x94, 0xB2, 0x01, 0x5C, 0x1D])), Data([0x94, 0xB2, 0x01, 0x5C, 0x1D])),
            ("Unknown Record 4", "Secure record family 0x34 as seen in the Android trace.", .custom(commandData: Data([0x94, 0xB2, 0x04, 0x34, 0x1D])), Data([0x94, 0xB2, 0x04, 0x34, 0x1D]))
        ]

        var results: [CalypsoRecordProbeResult] = []
        for (title, description, apdu, commandData) in probes {
            let response = try await sendISO7816Command(apdu, to: tag)
            logger.log("Calypso exact probe \(title, privacy: .public) cmd=\(commandData.hexString, privacy: .public) sw=\(response.statusWords, privacy: .public) payload=\((response.payload ?? Data()).hexString, privacy: .public)")
            print("CardBal Calypso exactProbe title=\(title) cmd=\(commandData.hexString) sw=\(response.statusWords) payload=\((response.payload ?? Data()).hexString)")
            results.append(CalypsoRecordProbeResult(title: title, description: description, command: commandData, response: response))
        }
        return results
    }
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
        guard let cardNumberTitle else { return [] }
        fields.append(ResultField(title: cardNumberTitle, value: idm))
        return fields
    }

}

private struct KSX6924CardProfile {
    let displayName: String
    let aid: String
    let parseBalance: (Data) -> ParsedBalance?

    static let configDFAID = "A0000004520001"

    static func matching(aid: String, configInfo: KSX6924ConfigDFInfo? = nil) -> KSX6924CardProfile {
        if let profile = all.first(where: { $0.aid == aid.uppercased() }) {
            return profile
        }

        return unknown(aid: aid)
    }

    private static let all: [KSX6924CardProfile] = [
        KSX6924CardProfile(
            displayName: "T-money",
            aid: "D4100000030001",
            parseBalance: ksx6924BalanceParser
        ),
        KSX6924CardProfile(
            displayName: "EZL / Cashbee",
            aid: "D4100000140001",
            parseBalance: ksx6924BalanceParser
        ),
        KSX6924CardProfile(
            displayName: "NAMANE",
            aid: "D410000029000001",
            parseBalance: ksx6924BalanceParser
        ),
        KSX6924CardProfile(
            displayName: "MOIBA",
            aid: "D4100000300001",
            parseBalance: ksx6924BalanceParser
        ),
        KSX6924CardProfile(
            displayName: "K-Cash",
            aid: "D4106509900020",
            parseBalance: ksx6924BalanceParser
        )
    ]

    private static func unknown(aid: String) -> KSX6924CardProfile {
        KSX6924CardProfile(displayName: "ISO7816 Transit Card", aid: aid.uppercased(), parseBalance: ksx6924BalanceParser)
    }
}

private enum NFCISO7816AccessPolicy {
    static let exactAIDs: Set<String> = [
        "A0000004520001",
        "D4100000030001",
        "D4100000140001",
        "D410000029000001",
        "D4100000300001",
        "D4106509900020"
    ]

    static func isAllowed(aid: String) -> Bool {
        let normalized = aid.uppercased()
        return exactAIDs.contains(normalized) || CalypsoCardProfile.supportedPrefixes.contains { normalized.hasPrefix($0) }
    }
}

private struct CalypsoProbeTarget {
    let title: String
    let description: String
    let apdu: NFCISO7816APDU
    let commandData: Data
}

private struct CalypsoCardProfile {
    let displayName: String
    let aidPrefixes: [String]
    let probeTargets: [CalypsoProbeTarget]

    static func matches(aid: String) -> Bool {
        let normalized = aid.uppercased()
        return all.contains { profile in
            profile.aidPrefixes.contains { normalized.hasPrefix($0) }
        }
    }

    static func matching(aid: String) -> CalypsoCardProfile {
        let normalized = aid.uppercased()
        return all.first(where: { profile in
            profile.aidPrefixes.contains { normalized.hasPrefix($0) }
        }) ?? all[0]
    }

    static let supportedPrefixes: [String] = [
        "A000000291",
        "A000000404"
    ]

    func applicationAID(for selectedAID: String) -> String {
        let normalized = selectedAID.uppercased()
        if aidPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return normalized
        }
        return aidPrefixes[0]
    }

    private static let all: [CalypsoCardProfile] = [
        CalypsoCardProfile(
            displayName: "Calypso Card",
            aidPrefixes: supportedPrefixes,
            probeTargets: commonProbeTargets
        )
    ]

    private static let commonProbeTargets: [CalypsoProbeTarget] = [
        CalypsoProbeTarget(
            title: "GET DATA AID",
            description: "Calypso GET DATA tag 004F, often returns the DF name / application identifier.",
            apdu: .getData(tag: 0x004F),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0x004F)
        ),
        CalypsoProbeTarget(
            title: "GET DATA FCI Template",
            description: "Calypso GET DATA tag 006F, often returns an FCI template.",
            apdu: .getData(tag: 0x006F),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0x006F)
        ),
        CalypsoProbeTarget(
            title: "GET DATA FCP Template",
            description: "Calypso GET DATA tag 0062, often returns file control parameters.",
            apdu: .getData(tag: 0x0062),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0x0062)
        ),
        CalypsoProbeTarget(
            title: "GET DATA EF List",
            description: "Calypso GET DATA tag C030, referenced by the Nice Android source for EF discovery.",
            apdu: .getData(tag: 0xC030),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0xC030)
        ),
        CalypsoProbeTarget(
            title: "GET DATA Traceability",
            description: "Calypso GET DATA tag D020, referenced by the Nice Android source for traceability data.",
            apdu: .getData(tag: 0xD020),
            commandData: NFCISO7816APDU.getDataCommandData(tag: 0xD020)
        ),
        CalypsoProbeTarget(
            title: "Environment Record 1",
            description: "Calypso public example record: SFI 07, record 1.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x07),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x07)
        ),
        CalypsoProbeTarget(
            title: "Environment Record 2",
            description: "Optional follow-up record in the same SFI, often holder-related on some cards.",
            apdu: .readRecord(recordNumber: 2, sfi: 0x07),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 2, sfi: 0x07)
        ),
        CalypsoProbeTarget(
            title: "SFI 01 Record 1",
            description: "Additional public record probe for applications that store environment data in low SFIs.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x01),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x01)
        ),
        CalypsoProbeTarget(
            title: "SFI 02 Record 1",
            description: "Additional public record probe for applications that store contracts or counters in SFI 02.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x02),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x02)
        ),
        CalypsoProbeTarget(
            title: "SFI 08 Record 1",
            description: "Additional public record probe for alternate environment locations.",
            apdu: .readRecord(recordNumber: 1, sfi: 0x08),
            commandData: NFCISO7816APDU.readRecordCommandData(recordNumber: 1, sfi: 0x08)
        )
    ]
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
        let tagData = Array(data[tagStart..<tagEnd])
        nodes.append(BERTLVNode(tag: tagData, value: Data(data[index..<valueEnd])))
        index = valueEnd
    }

    return nodes
}

private let ksx6924BalanceParser: (Data) -> ParsedBalance? = { payload in
    guard payload.count >= 4 else { return nil }
    let balance = payload.bigEndianInt(start: 0, length: 4)
    return ParsedBalance(
        formatted: formatCurrency(amount: Decimal(balance), code: "KRW", fractionDigits: 0),
        detail: "Parsed as a 4-byte big-endian stored-value balance from the KS X 6924 balance APDU.",
        rawFields: [
            RawDataField(title: "Balance Bytes", value: payload.sliceHexString(start: 0, length: 4)),
            RawDataField(title: "Stored Value", value: String(balance)),
            RawDataField(title: "Formula", value: "b0<<24 | b1<<16 | b2<<8 | b3")
        ]
    )
}

private func octopusOffset(for date: Date) -> Int {
    let changeDate = ISO8601DateFormatter().date(from: "2017-10-01T00:00:00+08:00") ?? .distantPast
    return date >= changeDate ? 500 : 350
}

private func formatCurrency(amount: Decimal, code: String, fractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: amount as NSDecimalNumber) ?? "\(code) \(amount)"
}

private extension NFCISO7816ResponseAPDU {
    var statusWords: String {
        String(format: "%02X%02X", statusWord1, statusWord2)
    }
}

private extension NFCISO7816APDU {
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

    static func selectByName(_ aid: String) -> NFCISO7816APDU {
        NFCISO7816APDU(data: selectCommandData(aid: aid))!
    }

    static func selectFile(fileID: String) -> NFCISO7816APDU? {
        NFCISO7816APDU(data: selectFileCommandData(fileID: fileID))
    }

    static func readRecord(recordNumber: UInt8, sfi: UInt8) -> NFCISO7816APDU {
        NFCISO7816APDU(data: readRecordCommandData(recordNumber: recordNumber, sfi: sfi))!
    }

    static func readBinary(offset: UInt16, expectedLength: Int) -> NFCISO7816APDU {
        NFCISO7816APDU(data: readBinaryCommandData(offset: offset, expectedLength: expectedLength))!
    }

    static func getData(tag: UInt16) -> NFCISO7816APDU {
        NFCISO7816APDU(data: getDataCommandData(tag: tag))!
    }

    static func custom(commandData: Data) -> NFCISO7816APDU {
        NFCISO7816APDU(data: commandData)!
    }

    static func readRecordCommandData(recordNumber: UInt8, sfi: UInt8) -> Data {
        let p2 = UInt8((sfi << 3) | 0x04)
        return Data([0x00, 0xB2, recordNumber, p2, 0x00])
    }

    static func getDataCommandData(tag: UInt16) -> Data {
        let p1 = UInt8((tag >> 8) & 0xFF)
        let p2 = UInt8(tag & 0xFF)
        return Data([0x00, 0xCA, p1, p2, 0x00])
    }

    static func readBinaryCommandData(offset: UInt16, expectedLength: Int) -> Data {
        let p1 = UInt8((offset >> 8) & 0x7F)
        let p2 = UInt8(offset & 0xFF)
        return Data([0x00, 0xB0, p1, p2, UInt8(clamping: expectedLength)])
    }

    static func selectCommandData(aid: String) -> Data {
        let aidData = Data(hex: aid)
        return Data([0x00, 0xA4, 0x04, 0x00, UInt8(aidData.count)]) + aidData
    }

    static func selectFileCommandData(fileID: String) -> Data {
        let fileData = Data(hex: fileID)
        return Data([0x00, 0xA4, 0x00, 0x02, UInt8(fileData.count)]) + fileData
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var text = hex
        if text.count % 2 != 0 {
            text = "0" + text
        }
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            let byte = UInt8(text[index..<next], radix: 16) ?? 0
            append(byte)
            index = next
        }
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    var binaryString: String {
        map { String($0, radix: 2).leftPadded(to: 8, with: "0") }.joined()
    }

    var systemCodeCandidates: [String] {
        guard count == 2 else { return [hexString] }
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
