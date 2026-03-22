import Foundation
import CoreNFC

struct CalypsoDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let aid = iso.initialSelectedAID
        return aid.hasPrefix("A000000291") || aid.hasPrefix("A000000404") || aid == "3154494TIC.ICA" || aid == "315449432E494341"
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        
        let selectedAID = iso.initialSelectedAID
        let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: selectedAID), expectedResponseLength: 256)
        let initialResponse = try? await iso.sendCommand(apdu: selectApdu)
        let initialSelectResponse = initialResponse.map { NFCISO7816ResponseAPDU(statusWord1: $0.1, statusWord2: $0.2, payload: $0.0) }
        // For Nice Calypso, we use specific SFIs discovered from Android app.
        
        let secureSessionResponse = try? await iso.sendCommand(apdu: NFCISO7816APDU(instructionClass: 0x94, instructionCode: 0xA4, p1Parameter: 0x08, p2Parameter: 0x00, data: Data([0x20, 0x00]), expectedResponseLength: 256))
        
        let recordProbes = [
            ("Environment", 0x3C, 0x01),
            ("Best Contracts", 0xF4, 0x01),
            ("Event 1", 0x44, 0x01),
            ("Contract 1", 0x4C, 0x01),
            ("Ticket 1", 0x54, 0x01)
        ]
        
        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Identification", fields: [
                RawDataField(title: "Technology", value: "ISO7816"),
                RawDataField(title: "UID", value: iso.identifier.hexString),
                RawDataField(title: "Application AID", value: selectedAID)
            ])
        ]
        
        var cardNumber: String?
        if let fci = initialSelectResponse?.payload {
            cardNumber = parseCalypsoCardNumber(from: fci)?.formatted
        }
        
        for probe in recordProbes {
            let p2 = (UInt8(probe.1)) | 0x04
            let apdu = NFCISO7816APDU(instructionClass: 0x94, instructionCode: 0xB2, p1Parameter: UInt8(probe.2), p2Parameter: p2, data: Data(), expectedResponseLength: 256)
            if let resp = try? await iso.sendCommand(apdu: apdu), resp.1 == 0x90 {
                rawSections.append(RawDataSection(title: probe.0, fields: [
                    RawDataField(title: "Payload", value: resp.0.hexString)
                ]))
            }
        }
        
        var resultFields: [ResultField] = []
        if let cn = cardNumber {
            resultFields.append(ResultField(title: "Card Number", value: cn))
        }
        resultFields.append(ResultField(title: "Product Type", value: "Ticket / Contract Card"))
        
        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: "Lignes d'Azur card",
            identifierLabel: "UID",
            identifierValue: iso.identifier.hexString,
            rawIdentifierValue: iso.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: selectedAID,
            balanceText: nil,
            balanceDetail: "Calypso card recognized. Secure data reading requires specific keys.",
            realSerialNumber: nil,
            region: "Nice, France",
            resultFields: resultFields,
            rawSections: rawSections,
            scannedAt: scannedAt
        )
    }
    
    private static func parseCalypsoCardNumber(from fciPayload: Data) -> CalypsoCardNumber? {
        guard let serialData = findTLVValue(tag: [0xC7], in: fciPayload), serialData.count >= 4 else { return nil }
        let tail = serialData.suffix(4)
        let decimal = String(tail.reduce(0) { ($0 << 8) | UInt64($1) })
        let padded = decimal.count >= 10 ? decimal : String(repeating: "0", count: 10 - decimal.count) + decimal
        let formatted = "\(padded.prefix(1)) \(padded.dropFirst(1).prefix(3)) \(padded.dropFirst(4).prefix(3)) \(padded.suffix(3))"
        return CalypsoCardNumber(formatted: formatted)
    }
}

private struct CalypsoCardNumber {
    let formatted: String
}
