import Foundation

enum OctopusOnlineDecoder {
    static func decode(card: any FeliCaCard, block: Data, pmm: Data, scannedAt: Date,
                       store: OctopusMetadataStore = .shared,
                       onlineEnabled: Bool = OctopusOnlinePreferences.isEnabled,
                       allowsCardUpdates: Bool = OctopusOnlinePreferences.allowsCardUpdates,
                       client: OctopusEnquiryClient = OctopusEnquiryClient()) async -> TransitCardSnapshot {
        let idm = card.currentIDm
        let identity = idm.hexString.uppercased()
        let systemCodes = (try? await card.requestSystemCode().map { $0.hexString.uppercased() }) ?? ["8008"]
        var currentBlock = block
        var metadata = store.metadata(for: identity)
        var usedOnline = false
        var enquiryFailed = false
        var skippedCardUpdates = 0
        octopusDebugLog("Octopus card IDm \(DebugLog.shortened(idm)), purse raw \(block.bigEndianInt(start: 0, length: 4))")
        if let metadata {
            octopusDebugLog("Online enquiry not needed: metadata already saved (offset \(metadata.offset), card number \(DebugLog.shortened(metadata.cardNumber)))")
        } else if !onlineEnabled {
            octopusDebugLog("Online enquiry not run: Octopus Online is off in Settings")
        } else if !client.isConfigured {
            octopusDebugLog("Online enquiry not run: no enquiry endpoint configured in this build")
        }
        // Without a configured endpoint the build offers no online enquiry at all.
        if metadata == nil && onlineEnabled && client.isConfigured {
            defer { client.close() }
            defer { skippedCardUpdates = client.skippedCardUpdates }
            ScanProgress.report(.octopusOnline)
            var step = "enquiry"
            do {
                let (result, opcodes) = try await client.enquire(allowsCardUpdates: allowsCardUpdates) { command in
                    try await exchange(command, card: card, idm: idm)
                }
                // Enquiry may update card metadata. Re-poll and read the public
                // purse again before comparing it with the server amount.
                step = "re-poll after enquiry"
                _ = try await card.polling(systemCode: Data([0x80, 0x08]), requestCode: .systemCode, timeSlot: .max1)
                guard card.currentIDm == idm else {
                    octopusDebugLog("Re-poll after enquiry: IDm changed to \(DebugLog.shortened(card.currentIDm))")
                    throw OctopusProtocolError.invalidResponse
                }
                step = "purse read after enquiry"
                let response = try await card.readWithoutEncryption(serviceCodeList: [Data([0x17, 1])], blockList: [Data([0x80, 0])])
                guard response.0 == 0, response.1 == 0, response.2.count == 1,
                      response.2[0].count == 16 else {
                    octopusDebugLog("Purse read after enquiry: status flags \(DebugLog.hex(UInt8(truncatingIfNeeded: response.0))) "
                                    + "\(DebugLog.hex(UInt8(truncatingIfNeeded: response.1))), \(response.2.count) blocks")
                    throw OctopusProtocolError.invalidResponse
                }
                currentBlock = response.2[0]
                let rawValue = currentBlock.bigEndianInt(start: 0, length: 4)
                octopusDebugLog("Result: " + OctopusCardMetadata.resultSummary(result, rawValue: rawValue))
                switch OctopusCardMetadata.calibration(result: result, rawValue: rawValue, opcodes: opcodes) {
                case .success(let calibrated):
                    metadata = calibrated
                    store.save(calibrated, for: identity)
                    usedOnline = true
                    octopusDebugLog("Outcome: calibrated (offset \(calibrated.offset), card number \(DebugLog.shortened(calibrated.cardNumber)), status \"\(calibrated.serviceStatus)\")")
                case .failure(let failure):
                    enquiryFailed = true
                    octopusDebugLog("Outcome: failed, calibration rejected: \(failure)")
                }
            } catch {
                enquiryFailed = true
                // The client has already logged its own failures.
                octopusDebugLog("Outcome: failed during \(step)" + (step == "enquiry" ? "" : ": " + DebugLog.describe(error)))
            }
            if client.skippedCardUpdates > 0 { octopusDebugLog("Skipped card updates: \(client.skippedCardUpdates)") }
            if enquiryFailed { ScanProgress.report(.octopusUnavailable) }
        }
        let raw = currentBlock.bigEndianInt(start: 0, length: 4)
        let balance = metadata.map { formatCurrency(amount: Decimal(raw - $0.offset) / 10, code: "HKD", fractionDigits: 1) }
        let detail: String? = metadata == nil
            ? (client.isConfigured ? "An online enquiry is needed to determine this card's balance offset." : nil)
            : usedOnline ? "Online balance checked against the public purse."
            : "Balance decoded using this card's saved offset."
        var resultFields = [ResultField(title: "Card Number (IDm)", value: formatFeliCaIDm(identity))]
        var rawFields = [RawDataField(title: "Raw Stored", value: String(raw)),
                         RawDataField(title: "Raw Block", value: currentBlock.hexString)]
        if let metadata {
            resultFields.append(ResultField(title: "Octopus Number", value: metadata.cardNumber))
            rawFields += [RawDataField(title: "Balance Offset", value: String(metadata.offset)),
                          RawDataField(title: "Enquiry Status", value: metadata.serviceStatus)]
        } else {
            rawFields += [RawDataField(title: "Candidate Balance (offset 350)", value: formatCurrency(amount: Decimal(raw - 350) / 10, code: "HKD", fractionDigits: 1)),
                          RawDataField(title: "Candidate Balance (offset 500)", value: formatCurrency(amount: Decimal(raw - 500) / 10, code: "HKD", fractionDigits: 1))]
            if enquiryFailed { rawFields.append(RawDataField(title: "Online Enquiry", value: "Unavailable")) }
        }
        if skippedCardUpdates > 0 {
            rawFields.append(RawDataField(title: "Skipped Card Updates", value: String(skippedCardUpdates)))
        }
        var snapshot = TransitCardSnapshot(
            technology: "FeliCa", cardFamily: "Octopus", identifierLabel: "IDm",
            identifierValue: formatFeliCaIDm(identity), rawIdentifierValue: identity, pmm: pmm.hexString,
            systemCode: "8008", selectedAID: nil, balanceText: balance, balanceDetail: detail,
            realSerialNumber: metadata?.cardNumber, region: nil, resultFields: resultFields,
            rawSections: [RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"), RawDataField(title: "IDm", value: formatFeliCaIDm(identity)),
                RawDataField.systemCodeRow(systemCodes)
            ]), RawDataSection(title: "Decoded Balance", fields: rawFields)],
            rawTransactions: [], rawTransitHistory: [], scannedAt: scannedAt)
        snapshot.applications = [TransitApplication(snapshot: snapshot)]
        return snapshot
    }

    static func exchange(_ command: Data, card: any FeliCaCard, idm: Data) async throws -> Data {
        guard let opcode = command.first else { throw OctopusProtocolError.invalidData }
        if opcode == 0 {
            let bytes = Array(command)
            guard bytes.count == 5, [Data([0x80, 0x08]), Data([0xFF, 0xFF])].contains(Data(bytes[1...2])),
                  bytes[3] <= 1, bytes[4] == 0 else {
                octopusDebugLog("Relay: polling request refused (\(bytes.count) bytes; only 8008 or FFFF, one slot)")
                throw OctopusProtocolError.invalidData
            }
            // Core NFC polling rejects wildcard (FF) bytes, so FFFF polls 8008, Octopus's only system.
            let (pmm, system) = try await card.polling(systemCode: Data([0x80, 0x08]), requestCode: bytes[3] == 1 ? .systemCode : .noRequest, timeSlot: .max1)
            guard card.currentIDm == idm, pmm.count == 8, bytes[3] == 0 || system.count == 2 else {
                octopusDebugLog("Relay: polling reply refused (" + (card.currentIDm == idm ? "PMm \(pmm.count) bytes, system code \(system.count) bytes" : "IDm changed") + ")")
                throw OctopusProtocolError.invalidResponse
            }
            return Data([bytes[3] == 0 ? 18 : 20, 1]) + idm + pmm + (bytes[3] == 1 ? system : Data())
        }
        // Authenticated packet fields are opaque and need not contain a plaintext IDm.
        var response = try await card.sendFeliCaCommand(commandPacket: command)
        // Core NFC is documented to drop the length byte, but on a real Octopus card (iOS 27.2) the
        // reply arrived with it. Accept both so the relay sends the service a single length byte.
        let reply = Array(response)
        if reply.count >= 2, Int(reply[0]) == reply.count, reply[1] == opcode &+ 1 {
            octopusDebugLog("Relay: card reply came with its length byte; removed it")
            response = Data(reply.dropFirst())
        }
        guard response.count < 255 else {
            octopusDebugLog("Relay: card reply too long (\(response.count) bytes)")
            throw OctopusProtocolError.invalidResponse
        }
        return Data([UInt8(response.count + 1)]) + response
    }
}
