import Foundation
import CoreNFC

struct CalypsoDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let aid = iso.initialSelectedAID.uppercased()
        return CalypsoCardProfile.matches(aid: aid) || aid == "315449432E494341"
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }

        let selectedAID = iso.initialSelectedAID.uppercased()

        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Identification", fields: [
                RawDataField(title: "Technology", value: "ISO7816"),
                RawDataField(title: "UID", value: iso.identifier.hexString),
                RawDataField(title: "Application AID", value: selectedAID),
                RawDataField(title: "Application Data", value: iso.applicationData?.hexString ?? "Unavailable")
            ])
        ]

        let uidDecimal = iso.identifier.reduce(0) { ($0 << 8) | UInt64($1) }
        let cardNumber = formatCalypsoCardNumber(String(uidDecimal))

        let secureSessionCommand = Data([0x94, 0xA4, 0x08, 0x00, 0x02, 0x20, 0x00])
        let secureSessionResponse = await sendRawISOCommand(secureSessionCommand, to: iso)
        rawSections.append(RawDataSection(title: "Secure Calypso Session", fields: [
            RawDataField(title: "Command", value: secureSessionCommand.hexString),
            RawDataField(title: "Response Payload", value: secureSessionResponse.0.hexString),
            RawDataField(title: "SW1SW2", value: String(format: "%02X%02X", secureSessionResponse.1, secureSessionResponse.2)),
            RawDataField(title: "Interpretation", value: "Select the Calypso environment file before secure record reads.")
        ]))

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
            }
        }

        let exactRecordProbes = await readCalypsoRecordProbes(on: iso)
        for probe in exactRecordProbes {
            rawSections.append(RawDataSection(title: probe.title, fields: [
                RawDataField(title: "Command", value: probe.command.hexString),
                RawDataField(title: "SFI", value: String(probe.sfi)),
                RawDataField(title: "Record", value: String(probe.recordNumber)),
                RawDataField(title: "Expected Length", value: String(probe.expectedLength)),
                RawDataField(title: "Response Payload", value: probe.response.0.hexString),
                RawDataField(title: "SW1SW2", value: String(format: "%02X%02X", probe.response.1, probe.response.2)),
                RawDataField(title: "Interpretation", value: probe.description)
            ]))
        }

        let bestContractPayload = exactRecordProbes.first(where: { $0.title == "Best Contracts" })?.response.0 ?? Data()
        let bestContracts = parseNiceBestContracts(from: bestContractPayload)
        let environmentPayload = exactRecordProbes.first(where: { $0.title == "Environment Record" })?.response.0
        let contractBySlot = Dictionary(
            uniqueKeysWithValues: exactRecordProbes.compactMap { result -> (Int, NiceContractSummary)? in
                guard result.title.hasPrefix("Contract Summary Record "),
                      let index = Int(String(result.title.suffix(1))),
                      result.response.1 == 0x90,
                      result.response.2 == 0x00,
                      !result.response.0.allSatisfy({ $0 == 0 })
                else { return nil }

                let bestContract = bestContracts.first(where: { $0.contractPointer == index || $0.index == index })
                    ?? NiceBestContractEntry(index: index, tariffKey: 0, tariffStructure: "Unknown", tariffPriority: "Unknown", contractPointer: index)
                guard let summary = parseNiceContractSummary(from: result.response.0, bestContract: bestContract) else { return nil }
                return (index, summary)
            }
        )

        let primaryBestContract = bestContracts.first
        let primarySlot = primaryBestContract?.contractPointer ?? primaryBestContract?.index
        let primaryContract = primarySlot.flatMap { contractBySlot[$0] }
        let ticketDetailsBySlot = Dictionary(
            uniqueKeysWithValues: exactRecordProbes.compactMap { result -> (Int, Int)? in
                guard result.title.hasPrefix("Ticket Detail Record "),
                      let index = Int(String(result.title.suffix(1))),
                      result.response.1 == 0x90,
                      result.response.2 == 0x00,
                      !result.response.0.allSatisfy({ $0 == 0 }),
                      let remaining = parseNiceRemainingTickets(from: result.response.0)
                else { return nil }
                return (index, remaining)
            }
        )
        let primaryRemainingTrips = primarySlot.flatMap { ticketDetailsBySlot[$0] }
        let activeRemainingTrips = ticketDetailsBySlot
            .sorted { $0.key < $1.key }
            .first { $0.value > 0 }?
            .value
        let remainingTrips = activeRemainingTrips ?? primaryRemainingTrips
        let cardExpiryDate = environmentPayload.flatMap(parseNiceCardExpiryDate)
        let eventSummary = exactRecordProbes.compactMap { probe -> NiceEventSummary? in
            guard probe.title.hasPrefix("Event Record"),
                  probe.response.1 == 0x90,
                  probe.response.2 == 0x00,
                  !probe.response.0.allSatisfy({ $0 == 0 }) else { return nil }
            return parseNiceEventSummary(from: probe.response.0, sourceTitle: probe.title)
        }.first

        var resultFields: [ResultField] = []
        resultFields.append(ResultField(title: "Card Number", value: cardNumber))
        resultFields.append(ResultField(title: "Product Type", value: "Ticket / Contract Card"))
        if !contractBySlot.isEmpty {
            resultFields.append(ResultField(title: "Loaded Tickets", value: String(contractBySlot.count)))
        }
        let primaryTicket = primaryContract.map { contract -> String in
            let ticketLabel = niceTicketLabel(for: contract)
            resultFields.append(ResultField(title: "Ticket", value: ticketLabel.displayName))
            if let apkProductFamily = ticketLabel.apkProductFamily {
                resultFields.append(ResultField(title: "Ticket Family", value: apkProductFamily))
            }
            resultFields.append(ResultField(title: "Contract Serial Number", value: contract.serialNumber))
            resultFields.append(ResultField(title: "Product Code", value: contract.linkedTariffID))
            if let saleDate = contract.saleDate {
                resultFields.append(ResultField(title: "Sold At", value: saleDate))
            }
            if let validityEndDate = contract.validityEndDate {
                resultFields.append(ResultField(title: "Valid Until", value: validityEndDate))
            }
            return ticketLabel.displayName
        }
        if let remainingTrips {
            resultFields.append(ResultField(title: "Remaining Trips", value: String(remainingTrips)))
        }
        if let cardExpiryDate {
            resultFields.append(ResultField(title: "Card Valid Until", value: cardExpiryDate))
        }
        if let eventSummary {
            resultFields.append(ResultField(title: "Last Ticket Event", value: "\(eventSummary.eventDateStamp) \(eventSummary.eventTimeStamp)"))
            if let eventRouteNumber = eventSummary.eventRouteNumber {
                resultFields.append(ResultField(title: "Route", value: eventRouteNumber))
            }
        }
        if primaryContract != nil || remainingTrips != nil {
            resultFields.append(ResultField(title: "Ticket Status", value: remainingTrips.map { "Remaining trips: \($0)" } ?? "Contract decoded"))
        }
        let balanceText = remainingTrips.map { "\($0) trips" }
        let balanceDetail = primaryTicket.map { ticket in
            if let remainingTrips {
                return "\(ticket): \(remainingTrips) remaining trip\(remainingTrips == 1 ? "" : "s")"
            }
            return ticket
        } ?? "Calypso card recognized."

        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: "Lignes d'Azur card",
            identifierLabel: "UID",
            identifierValue: iso.identifier.hexString,
            rawIdentifierValue: iso.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: selectedAID,
            balanceText: balanceText,
            balanceDetail: balanceDetail,
            realSerialNumber: String(uidDecimal),
            region: "Nice, France",
            resultFields: resultFields,
            rawSections: rawSections,
            rawTransactions: [],
            rawTransitHistory: [],
            scannedAt: scannedAt
        )
    }

    private static func formatCalypsoCardNumber(_ decimal: String) -> String {
        guard !decimal.isEmpty else { return decimal }
        var remainder = decimal
        var groups: [String] = []
        let firstCount = remainder.count % 3 == 0 ? 3 : remainder.count % 3
        groups.append(String(remainder.prefix(firstCount)))
        remainder.removeFirst(firstCount)
        while !remainder.isEmpty {
            groups.append(String(remainder.prefix(3)))
            remainder.removeFirst(min(3, remainder.count))
        }
        return groups.joined(separator: " ")
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

    private static func sendRawISOCommand(_ command: Data, to tag: NFCISO7816Tag) async -> (Data, UInt8, UInt8) {
        guard let apdu = NFCISO7816APDU(data: command) else { return (Data(), 0x00, 0x00) }
        return (try? await sendISOCommand(apdu, to: tag)) ?? (Data(), 0x00, 0x00)
    }

    private static func readCalypsoRecordProbes(on tag: NFCISO7816Tag) async -> [CalypsoRecordProbeResult] {
        let probes: [(String, String, UInt8, UInt8, UInt8)] = [
            ("Environment Record", "Secure Nice environment read from the initial working decoder.", 0x07, 1, 0x1D),
            ("Best Contracts", "Secure Nice best-contract list from the initial working decoder.", 0x1E, 1, 0x1D),
            ("Event Record 1", "Secure Nice event record from the initial working decoder.", 0x08, 1, 0x1D),
            ("Contract Summary Record 1", "Primary loaded-ticket summary from secure record family 0x4C.", 0x09, 1, 0x1D),
            ("Ticket Detail Record 1", "Primary remaining-trip detail from secure record family 0x54.", 0x0A, 1, 0x1D),
            ("Contract Summary Record 2", "Loaded-ticket summary from secure record family 0x4C.", 0x09, 2, 0x1D),
            ("Ticket Detail Record 2", "Remaining-trip detail from secure record family 0x54.", 0x0A, 2, 0x1D),
            ("Contract Summary Record 3", "Loaded-ticket summary from secure record family 0x4C.", 0x09, 3, 0x1D),
            ("Ticket Detail Record 3", "Remaining-trip detail from secure record family 0x54.", 0x0A, 3, 0x1D),
            ("Contract Summary Record 4", "Loaded-ticket summary from secure record family 0x4C.", 0x09, 4, 0x1D),
            ("Ticket Detail Record 4", "Remaining-trip detail from secure record family 0x54.", 0x0A, 4, 0x1D)
        ]

        var results: [CalypsoRecordProbeResult] = []
        for (title, description, sfi, recordNumber, expectedLength) in probes {
            let command = calypsoReadRecordCommand(sfi: sfi, recordNumber: recordNumber, expectedLength: expectedLength)
            let response = await sendRawISOCommand(command, to: tag)
            results.append(CalypsoRecordProbeResult(title: title, description: description, command: command, sfi: sfi, recordNumber: recordNumber, expectedLength: expectedLength, response: response))
        }
        return results
    }

    private static func calypsoReadRecordCommand(sfi: UInt8, recordNumber: UInt8, expectedLength: UInt8) -> Data {
        Data([0x94, 0xB2, recordNumber, (sfi << 3) | 0x04, expectedLength])
    }
}

private struct CalypsoRecordProbeResult {
    let title: String
    let description: String
    let command: Data
    let sfi: UInt8
    let recordNumber: UInt8
    let expectedLength: UInt8
    let response: (Data, UInt8, UInt8)
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
        entries.append(
            NiceBestContractEntry(
                index: index + 1,
                tariffKey: Int(entryBits.bitSubstring(start: 3, length: 4), radix: 2) ?? 0,
                tariffStructure: String(Int(entryBits.bitSubstring(start: 7, length: 8), radix: 2) ?? 0, radix: 16).uppercased(),
                tariffPriority: String(Int(entryBits.bitSubstring(start: 15, length: 4), radix: 2) ?? 0, radix: 16).uppercased(),
                contractPointer: Int(entryBits.bitSubstring(start: 19, length: 5), radix: 2) ?? 0
            )
        )
    }
    return entries
}

private func parseNiceContractSummary(from payload: Data, bestContract: NiceBestContractEntry) -> NiceContractSummary? {
    let bits = payload.binaryString
    guard bits.count >= 63 else { return nil }
    let bitmap = String(bits.bitSubstring(start: 0, length: 7).reversed())
    let provider = bits.bitSubstring(start: 7, length: 8).binaryDecimalText
    let linkedTariffID = bits.bitSubstring(start: 15, length: 16).binaryDecimalText
    let serialNumber = bits.bitSubstring(start: 31, length: 32).binaryDecimalText
    let saleDate = bits.count >= 102 ? formatCalypsoDay(bits.bitSubstring(start: 88, length: 14)) : nil
    var cursor = 63
    var passengerClass: String?
    var validityStartDate: String?
    var validityEndDate: String?
    var status: String?
    if bitmap.character(at: 3) == "1", bits.count >= cursor + 8 {
        passengerClass = bits.bitSubstring(start: cursor, length: 8).binaryDecimalText
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
        status = bits.bitSubstring(start: cursor, length: 8).binaryHexText
        cursor += 8
    }
    var validityJourneys: String?
    var journeyOrigin: String?
    var journeyDestination: String?
    var journeyVia: String?
    if bestContract.tariffStructure == "17", bits.count >= cursor + 64 {
        validityJourneys = bits.bitSubstring(start: cursor, length: 16).binaryDecimalText
        journeyOrigin = bits.bitSubstring(start: cursor + 16, length: 16).binaryDecimalText
        journeyDestination = bits.bitSubstring(start: cursor + 32, length: 16).binaryDecimalText
        journeyVia = bits.bitSubstring(start: cursor + 48, length: 16).binaryDecimalText
    }
    return NiceContractSummary(contractType: bestContract.tariffStructure, provider: provider, linkedTariffID: linkedTariffID, serialNumber: serialNumber, saleDate: saleDate, status: status, validityStartDate: validityStartDate, validityEndDate: validityEndDate, passengerClass: passengerClass, validityJourneys: validityJourneys, journeyOrigin: journeyOrigin, journeyDestination: journeyDestination, journeyVia: journeyVia)
}

private func parseNiceRemainingTickets(from payload: Data) -> Int? {
    guard payload.count >= 3 else { return nil }
    return Int(payload[2])
}

private func parseNiceCardExpiryDate(from payload: Data) -> String? {
    let bits = payload.binaryString
    guard bits.count >= 59 else { return nil }
    return formatCalypsoDay(bits.bitSubstring(start: 45, length: 14))
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
        eventCode = eventCodeBits.binaryDecimalText
        let paddedCode = eventCodeBits.leftPadded(to: 8, with: "0")
        eventCodeMode = String(paddedCode.prefix(4))
        eventCodeType = String(paddedCode.suffix(4))
        cursor += 8
    }
    if reversedBitmap.character(at: 3) == "1", bits.count >= cursor + 8 {
        eventCodeResult = bits.bitSubstring(start: cursor, length: 8).binaryDecimalText
        cursor += 8
    }
    guard bits.count >= cursor + 8 else { return nil }
    let eventServiceProvider = bits.bitSubstring(start: cursor, length: 8).binaryDecimalText
    cursor += 8
    var eventLocationID: String?
    if reversedBitmap.character(at: 8) == "1", bits.count >= cursor + 24 {
        eventLocationID = bits.bitSubstring(start: cursor, length: 24).binaryDecimalText
        cursor += 24
    }
    var eventRouteNumber: String?
    if reversedBitmap.character(at: 11) == "1", bits.count >= cursor + 16 {
        eventRouteNumber = bits.bitSubstring(start: cursor, length: 16).binaryDecimalText
        cursor += 16
    }
    var eventJourneyRun: String?
    if reversedBitmap.character(at: 13) == "1", bits.count >= cursor + 16 {
        eventJourneyRun = bits.bitSubstring(start: cursor, length: 16).binaryDecimalText
    }
    return NiceEventSummary(sourceTitle: sourceTitle, eventDateStamp: eventDateStamp, eventTimeStamp: eventTimeStamp, mainBitmap: mainBitmap, eventCode: eventCode, eventCodeMode: eventCodeMode, eventCodeType: eventCodeType, eventCodeResult: eventCodeResult, eventServiceProvider: eventServiceProvider, eventLocationID: eventLocationID, eventRouteNumber: eventRouteNumber, eventJourneyRun: eventJourneyRun)
}

private func formatCalypsoDay(_ bits: String) -> String? {
    guard let value = Int(bits, radix: 2) else { return nil }
    let reference = Date(timeIntervalSince1970: 852_073_200)
    let date = reference.addingTimeInterval(TimeInterval(value * 86_400))
    return KSX6924DateFormatting.formatRawDateForDisplay(date)
}

private func formatCompactTime(_ bits: String) -> String? {
    guard let value = Int(bits, radix: 2) else { return nil }
    let hours = value / 3600
    let minutes = (value % 3600) / 60
    let seconds = value % 60
    guard (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds) else { return nil }
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}

private extension String {
    func trimmingLeadingZeros(defaultValue: String) -> String {
        let trimmed = drop { $0 == "0" }
        return trimmed.isEmpty ? defaultValue : String(trimmed)
    }

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

    var binaryDecimalText: String {
        String(Int(self, radix: 2) ?? 0)
    }

    var binaryHexText: String {
        String(format: "%02X", Int(self, radix: 2) ?? 0)
    }
}

private extension Data {
    var binaryString: String {
        map { String($0, radix: 2).leftPadded(to: 8, with: "0") }.joined()
    }
}
