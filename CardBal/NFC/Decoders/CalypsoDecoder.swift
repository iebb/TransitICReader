import Foundation
import CoreNFC

struct CalypsoDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let aid = iso.initialSelectedAID.uppercased()
        return aid.hasPrefix("A000000291") || aid.hasPrefix("A000000404") || aid == "315449432E494341"
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }

        let selectedAID = iso.initialSelectedAID.uppercased()
        var selectPayloads: [Data] = []
        if let applicationData = iso.applicationData, !applicationData.isEmpty {
            selectPayloads.append(applicationData)
        }
        if !selectedAID.isEmpty {
            let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: selectedAID), expectedResponseLength: 256)
            if let response = try? await iso.sendCommand(apdu: selectApdu), response.1 == 0x90 {
                selectPayloads.append(response.0)
            }
        }

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
        var mediaSerialNumber: String?
        var mediaUnicity = "2"
        for payload in selectPayloads {
            if let parsed = parseCalypsoCardNumber(from: payload) {
                cardNumber = cardNumber ?? parsed.formatted
                mediaSerialNumber = mediaSerialNumber ?? parsed.mediaSerialNumber
                mediaUnicity = parsed.mediaUnicity ?? mediaUnicity
            }
        }

        let getDataProbes: [(String, UInt16)] = [
            ("Traceability", 0xD020),
            ("Application AID", 0x004F),
            ("FCI Template", 0x006F),
            ("FCP Template", 0x0062)
        ]
        for probe in getDataProbes {
            if let resp = try? await iso.sendCommand(apdu: .getData(tag: probe.1)), resp.1 == 0x90 {
                rawSections.append(RawDataSection(title: probe.0, fields: [
                    RawDataField(title: "Payload", value: resp.0.hexString)
                ]))
                if let parsed = parseCalypsoCardNumber(from: resp.0) {
                    cardNumber = cardNumber ?? parsed.formatted
                    mediaSerialNumber = mediaSerialNumber ?? parsed.mediaSerialNumber
                    mediaUnicity = parsed.mediaUnicity ?? mediaUnicity
                }
            }
        }

        for probe in recordProbes {
            let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: UInt8(probe.2), p2Parameter: UInt8(probe.1), data: Data(), expectedResponseLength: 256)
            if let resp = try? await sendISOCommand(apdu, to: iso), resp.1 == 0x90 {
                rawSections.append(RawDataSection(title: probe.0, fields: [
                    RawDataField(title: "Payload", value: resp.0.hexString)
                ]))
            }
        }

        var resultFields: [ResultField] = []
        if let cn = cardNumber {
            resultFields.append(ResultField(title: "Card Number", value: cn))
        }
        if let mediaSerialNumber {
            resultFields.append(ResultField(title: "Media Serial Number", value: mediaSerialNumber))
            resultFields.append(ResultField(title: "Media Unicity", value: mediaUnicity))
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
            balanceDetail: "Calypso card recognized. Use Check Online for stored ticket details.",
            realSerialNumber: mediaSerialNumber,
            region: "Nice, France",
            resultFields: resultFields,
            rawSections: rawSections,
            rawTransactions: [],
            rawTransitHistory: [],
            scannedAt: scannedAt
        )
    }

    private static func parseCalypsoCardNumber(from fciPayload: Data) -> CalypsoCardNumber? {
        let serialData: Data
        if let c7 = findTLVValue(tag: [0xC7], in: fciPayload) {
            serialData = c7
        } else if let d020 = findTLVValue(tag: [0xD0, 0x20], in: fciPayload) {
            serialData = d020
        } else if (4...16).contains(fciPayload.count) {
            serialData = fciPayload
        } else {
            return nil
        }
        guard serialData.count >= 4 else { return nil }
        let tail = serialData.suffix(4)
        let rawDecimal = String(tail.reduce(0) { ($0 << 8) | UInt64($1) })
        let decimal = rawDecimal.trimmingLeadingZeros(defaultValue: "0")
        let padded = decimal.count >= 10 ? decimal : String(repeating: "0", count: 10 - decimal.count) + decimal
        let formatted = "\(padded.prefix(1)) \(padded.dropFirst(1).prefix(3)) \(padded.dropFirst(4).prefix(3)) \(padded.suffix(3))"
        let unicity = serialData.count >= 5 ? String(serialData[serialData.count - 5]) : nil
        return CalypsoCardNumber(formatted: formatted, mediaSerialNumber: decimal, mediaUnicity: unicity)
    }

    private static func sendISOCommand(_ apdu: NFCISO7816APDU, to tag: NFCISO7816Tag) async throws -> (Data, UInt8, UInt8) {
        let response = try await tag.sendCommand(apdu: apdu)
        if response.1 == 0x6C {
            let retry = NFCISO7816APDU(
                instructionClass: apdu.instructionClass,
                instructionCode: apdu.instructionCode,
                p1Parameter: apdu.p1Parameter,
                p2Parameter: apdu.p2Parameter,
                data: apdu.data ?? Data(),
                expectedResponseLength: Int(response.2)
            )
            return try await tag.sendCommand(apdu: retry)
        }
        return response
    }
}

private struct CalypsoCardNumber {
    let formatted: String
    let mediaSerialNumber: String
    let mediaUnicity: String?
}

private extension String {
    func trimmingLeadingZeros(defaultValue: String) -> String {
        let trimmed = drop { $0 == "0" }
        return trimmed.isEmpty ? defaultValue : String(trimmed)
    }
}
