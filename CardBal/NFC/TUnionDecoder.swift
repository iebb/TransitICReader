import Foundation
import CoreNFC

struct TUnionDecoder {
    static func decode(tag: NFCISO7816Tag, applicationAID: String, selectedAID: String, initialSelectResponse: NFCISO7816ResponseAPDU?, scannedAt: Date) async throws -> TransitCardSnapshot {
        let isTUnion = applicationAID == "A000000632010105"
        guard isTUnion else { throw NFCTestError.unsupportedCard }
        
        // T-Union Balance Command: 80 5C 00 02 04
        let balanceResponse = try await tag.sendCommand(apdu: NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x5C, p1Parameter: 0x00, p2Parameter: 0x02, data: Data(), expectedResponseLength: 4))
        let payload = balanceResponse.0
        
        var resultFields: [ResultField] = []
        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "ISO7816"),
                RawDataField(title: "UID", value: tag.identifier.hexString),
                RawDataField(title: "Selected AID", value: selectedAID),
                RawDataField(title: "Application AID", value: applicationAID)
            ]),
            RawDataSection(title: "Balance APDU", fields: [
                RawDataField(title: "Command", value: "805C000204"),
                RawDataField(title: "Response Payload", value: payload.hexString),
                RawDataField(title: "SW1SW2", value: String(format: "%02X%02X", balanceResponse.1, balanceResponse.2))
            ])
        ]
        
        let parsedBalance = parseTUnionBalance(payload)
        var realSN: String?
        var cardFamily = "T-Union"
        
        // T-Union cards can store metadata in multiple SFIs depending on the region/manufacturer.
        let metadataProbes: [(title: String, sfi: UInt8, p2: UInt8)] = [
            ("SFI 15", 0x15, 0xAC), // File 15 (Common)
            ("SFI 05", 0x05, 0x2C), // File 05 (Alternative)
            ("SFI 11", 0x11, 0x8C), // File 17 (Some local cards)
            ("SFI 01", 0x01, 0x0C)  // File 01 (Legacy/Early)
        ]
        
        for probe in metadataProbes {
            // Probe common records (Rec 1 is most common for metadata)
            for recNo in UInt8(1)...UInt8(2) {
                let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: recNo, p2Parameter: probe.p2, data: Data(), expectedResponseLength: 0)
                if let response = try? await tag.sendCommand(apdu: apdu), response.1 == 0x90 {
                    let info = response.0
                    rawSections.append(RawDataSection(title: "Card Info APDU (\(probe.title) Rec \(recNo))", fields: [
                        RawDataField(title: "Response", value: info.hexString),
                        RawDataField(title: "SW1SW2", value: String(format: "%02X%02X", response.1, response.2))
                    ]))
                    
                    if let extracted = extractCAN(from: info) {
                        if realSN == nil {
                            realSN = extracted
                            cardFamily = TUnionCityDatabase.lookupCardName(for: extracted) ?? "T-Union"
                            resultFields.append(ResultField(title: "Card Number", value: formatTUnionCardNumber(extracted)))
                            
                            // Try to parse dates if it looks like standard File 15 record 1
                            if info.count >= 30 {
                                let startDate = info.sliceHexString(start: 22, length: 4)
                                let expiryDate = info.sliceHexString(start: 26, length: 4)
                                if let start = formatChinaBCDDate(startDate) {
                                    resultFields.append(ResultField(title: "Valid From", value: start))
                                }
                                if let expiry = formatChinaBCDDate(expiryDate) {
                                    resultFields.append(ResultField(title: "Valid Until", value: expiry))
                                }
                            }
                            
                            if info.count >= 8 {
                                let issuer = info.sliceHexString(start: 0, length: 8)
                                resultFields.append(ResultField(title: "Issuer ID", value: issuer))
                            }
                        }
                    }
                }
            }
        }
        
        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: cardFamily,
            identifierLabel: "CAN",
            identifierValue: realSN ?? tag.identifier.hexString,
            rawIdentifierValue: tag.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: selectedAID,
            balanceText: parsedBalance?.formatted,
            balanceDetail: parsedBalance?.detail,
            realSerialNumber: realSN,
            resultFields: resultFields,
            rawSections: rawSections,
            scannedAt: scannedAt
        )
    }
    
    private static func extractCAN(from data: Data) -> String? {
        let hex = data.hexString.uppercased()
        
        // Strategy 1: Standard offset 12 (bytes), 10 bytes BCD.
        if data.count >= 22 {
            let start = 12 * 2
            let end = min(start + 20, hex.count)
            let range = hex.index(hex.startIndex, offsetBy: start)..<hex.index(hex.startIndex, offsetBy: end)
            let candidate = String(hex[range])
            if let clean = validateAndCleanCAN(candidate) { return clean }
        }
        
        // Strategy 2: Pattern search for known T-Union prefixes (310x, 311x, 314x, etc.)
        let knownPrefixes = ["3104", "3105", "3110", "3140", "3101", "3102", "3106", "3107"]
        for prefix in knownPrefixes {
            if let range = hex.range(of: prefix) {
                let startIndex = hex.distance(from: hex.startIndex, to: range.lowerBound)
                let end = min(startIndex + 20, hex.count)
                let subRange = hex.index(hex.startIndex, offsetBy: startIndex)..<hex.index(hex.startIndex, offsetBy: end)
                let candidate = String(hex[subRange])
                if let clean = validateAndCleanCAN(candidate) { return clean }
            }
        }
        
        return nil
    }
    
    private static func validateAndCleanCAN(_ hexCandidate: String) -> String? {
        // Strip hex padding (F)
        var clean = hexCandidate.replacingOccurrences(of: "F", with: "")
        
        // Handle leading zero padding (some cards have a leading 0 in the 10-byte/9-byte field)
        if clean.count == 20 && clean.hasPrefix("0") {
            clean = String(clean.dropFirst())
        }
        
        // T-Union numbers (CAN) are 16-19 digits.
        if clean.count >= 16 && clean.count <= 19 {
            // Must be all digits
            let digitSet = CharacterSet.decimalDigits
            if clean.rangeOfCharacter(from: digitSet.inverted) == nil {
                return clean
            }
        }
        return nil
    }
    
    private static func parseTUnionBalance(_ payload: Data) -> ParsedBalance? {
        // T-Union balance is a 4-byte big-endian integer in cents
        guard payload.count >= 4 else { return nil }
        let balanceCents = Int32(bigEndian: payload.withUnsafeBytes { $0.load(as: Int32.self) })
        let amount = Double(balanceCents) / 100.0
        
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        
        let balanceText = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)元"
        return ParsedBalance(
            formatted: balanceText,
            detail: "Parsed from T-Union purse (big-endian 4-byte integer)",
            rawFields: [
                RawDataField(title: "Raw Value", value: String(balanceCents)),
                RawDataField(title: "Converted Amount", value: String(amount))
            ]
        )
    }

    private static func formatTUnionCardNumber(_ hex: String) -> String {
        let clean = hex.uppercased()
        return stride(from: 0, to: clean.count, by: 4).map { index in
            let start = clean.index(clean.startIndex, offsetBy: index)
            let end = clean.index(start, offsetBy: 4, limitedBy: clean.endIndex) ?? clean.endIndex
            return String(clean[start..<end])
        }.joined(separator: " ")
    }

    private static func formatChinaBCDDate(_ bcd: String) -> String? {
        guard bcd.count == 8 else { return nil }
        let year = bcd.prefix(4)
        let month = bcd.dropFirst(4).prefix(2)
        let day = bcd.suffix(2)
        return "\(year)-\(month)-\(day)"
    }
}

struct TUnionCityDatabase {
    private static let cardNames: [String: String] = {
        guard let url = Bundle.main.url(forResource: "TUnionCardNames", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }()
    
    private static let sortedEntries: [(prefix: String, name: String)] = {
        cardNames.map { (prefix: $0.key, name: $0.value) }.sorted { $0.prefix.count > $1.prefix.count }
    }()

    static func lookupCardName(for value: String) -> String? {
        for entry in sortedEntries {
            if value.hasPrefix(entry.prefix) { return entry.name }
        }
        return nil
    }
}
