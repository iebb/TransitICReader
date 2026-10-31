import Foundation

enum OctopusOnlineDecoder {
    static func decode(card: any FeliCaCard, block: Data, pmm: Data, scannedAt: Date,
                       store: OctopusMetadataStore = .shared,
                       onlineEnabled: Bool = OctopusOnlinePreferences.isEnabled,
                       client: OctopusEnquiryClient = OctopusEnquiryClient()) async -> TransitCardSnapshot {
        let idm = card.currentIDm
        let identity = idm.hexString.uppercased()
        let systemCodes = (try? await card.requestSystemCode().map { $0.hexString.uppercased() }) ?? ["8008"]
        var currentBlock = block
        var metadata = store.metadata(for: identity)
        var usedOnline = false
        var enquiryFailed = false
        if metadata == nil && onlineEnabled {
            defer { client.close() }
            do {
                let (result, opcodes) = try await client.enquire { command in
                    try await exchange(command, card: card, idm: idm)
                }
                // Enquiry may update card metadata. Re-poll and read the public
                // purse again before comparing it with the server amount.
                _ = try await card.polling(systemCode: Data([0x80, 0x08]), requestCode: .systemCode, timeSlot: .max1)
                guard card.currentIDm == idm else { throw OctopusProtocolError.invalidResponse }
                let response = try await card.readWithoutEncryption(serviceCodeList: [Data([0x17, 1])], blockList: [Data([0x80, 0])])
                guard response.0 == 0, response.1 == 0, response.2.count == 1,
                      response.2[0].count == 16 else { throw OctopusProtocolError.invalidResponse }
                currentBlock = response.2[0]
                metadata = OctopusCardMetadata.calibrated(result: result, rawValue: currentBlock.bigEndianInt(start: 0, length: 4), opcodes: opcodes)
                if let metadata {
                    store.save(metadata, for: identity)
                    usedOnline = true
                } else { enquiryFailed = true }
            } catch {
                enquiryFailed = true
            }
        }
        let raw = currentBlock.bigEndianInt(start: 0, length: 4)
        let balance = metadata.map { formatCurrency(amount: Decimal(raw - $0.offset) / 10, code: "HKD", fractionDigits: 1) }
        let detail = metadata == nil ? "An online enquiry is needed to determine this card's balance offset."
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
                  bytes[3] <= 1, bytes[4] == 0 else { throw OctopusProtocolError.invalidData }
            let (pmm, system) = try await card.polling(systemCode: Data(bytes[1...2]), requestCode: bytes[3] == 1 ? .systemCode : .noRequest, timeSlot: .max1)
            guard card.currentIDm == idm, pmm.count == 8, bytes[3] == 0 || system.count == 2 else {
                throw OctopusProtocolError.invalidResponse
            }
            return Data([bytes[3] == 0 ? 18 : 20, 1]) + idm + pmm + (bytes[3] == 1 ? system : Data())
        }
        // Authenticated packet fields are opaque and need not contain a plaintext IDm.
        let response = try await card.sendFeliCaCommand(commandPacket: command)
        guard response.count < 255 else { throw OctopusProtocolError.invalidResponse }
        return Data([UInt8(response.count + 1)]) + response
    }
}
