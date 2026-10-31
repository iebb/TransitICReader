import Foundation

struct CalypsoDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let aid = iso.initialSelectedAID.uppercased()
        if CalypsoCardProfile.matches(aid: aid) || CalypsoProtocol.selectionAIDs.contains(aid) { return true }
        return await CalypsoProtocol.canSelect { command in
            guard let apdu = CardAPDU(data: command) else { throw NFCTestError.unsupportedCard }
            return try await iso.sendCommand(apdu: apdu)
        }
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag,
              let result = await CalypsoProtocol.read(initialAID: iso.initialSelectedAID, exchange: { command in
                  guard let apdu = CardAPDU(data: command) else { throw NFCTestError.unsupportedCard }
                  return try await iso.sendCommand(apdu: apdu)
              }, progress: { sfi in
                  // ICC and contracts are card details, the event log is the
                  // card's transaction history and counters hold the balance.
                  switch sfi {
                  case 2, 9: ScanProgress.report(.details)
                  case 8: ScanProgress.report(.transactions)
                  case 10: ScanProgress.report(.balance)
                  default: break
                  }
              }), result.hasDecodedData else { throw NFCTestError.unsupportedCard }
        let uid = iso.identifier.hexString
        let uidSerial = iso.identifier.count <= 8
            ? String(iso.identifier.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }) : nil
        let serial = result.serial ?? uidSerial
        var fields = result.fields.map { ResultField(title: $0.0, value: $0.1) }
        if let serial { fields.insert(ResultField(title: "Card Number", value: serial), at: 0) }
        let records = result.records.map { record in
            RawDataSection(title: String(format: "Calypso SFI %02X Record %d", record.sfi, record.number), fields: [
                RawDataField(title: "Payload", value: record.payload.hexString),
                RawDataField(title: "SW1SW2", value: "9000")
            ])
        }
        return TransitCardSnapshot(
            technology: "ISO7816", cardFamily: result.family, identifierLabel: "UID", identifierValue: uid,
            rawIdentifierValue: uid, pmm: nil, systemCode: nil, selectedAID: result.selectedAID,
            balanceText: result.balanceText, balanceDetail: result.network == .generic ? "Public Calypso records; network not identified" : "Public contracts and travel records",
            realSerialNumber: serial, region: result.family, resultFields: fields,
            rawSections: [RawDataSection(title: "Application", fields: [RawDataField(title: "AID", value: result.selectedAID)])] + records,
            rawTransactions: result.rawHistories, rawTransitHistory: [], scannedAt: scannedAt
        )
    }
}
