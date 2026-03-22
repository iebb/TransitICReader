import Foundation
import CoreNFC

struct TUnionDecoder {
    static func decode(tag: NFCISO7816Tag, applicationAID: String, selectedAID: String, initialSelectResponse: NFCISO7816ResponseAPDU?, scannedAt: Date) async throws -> TransitCardSnapshot {
        let isTUnion = applicationAID == "A000000632010105"
        guard isTUnion else { throw NFCTestError.unsupportedCard }
        
        print("[TUnion] Decoding. AID=\(applicationAID), Selected=\(selectedAID)")
        
        // T-Union Balance Command: 80 5C 00 02 04
        let apdu = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x5C, p1Parameter: 0x00, p2Parameter: 0x02, data: Data(), expectedResponseLength: 4)
        let balanceResponse = try await tag.sendCommand(apdu: apdu)
        let payload = balanceResponse.0
        
        print("[TUnion] Balance Payload: \(payload.hexString), SW: \(String(format: "%02X%02X", balanceResponse.1, balanceResponse.2))")
        
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
        var brandRegion = "T-Union Cities"
        var issuingCity: String?
        
        // Octopus T-Union (嶺南通·八达通) and some others store the CAN in the FCI Tag 9F0C!
        if let fci = initialSelectResponse?.payload {
            print("[TUnion] Checking FCI for metadata...")
            
            // Try to find 9F0C tag (Application Meta)
            if let meta = findTUnionTag([0x9F, 0x0C], in: fci) {
                // T-Union_Master logic:
                // CARD NUMBER: offset 10 (decimal), length 10 bytes BCD (with optional leading 0)
                // CITY ID: offset 2 (decimal), length 2 bytes (Hex-like string in GBT JSON)
                if meta.count >= 20 {
                    let cnData = meta.subdata(in: 10..<20)
                    if let extracted = validateAndCleanCAN(cnData.hexString) {
                        realSN = extracted
                        brandRegion = TUnionCityDatabase.lookupCardName(for: extracted) ?? "T-Union Cities"
                    }
                }
                if meta.count >= 4 {
                    let cityId = meta.subdata(in: 2..<4).hexString.uppercased()
                    issuingCity = TUnionCityDatabase.lookupCityName(for: cityId)
                    print("[TUnion] City ID found: \(cityId) (\(issuingCity ?? "Unknown"))")
                }
            }
            
            // Fallback: Pattern search whole FCI if Tag parsing didn't find the number
            if realSN == nil {
                if let extracted = extractCAN(from: fci) {
                    realSN = extracted
                    brandRegion = TUnionCityDatabase.lookupCardName(for: extracted) ?? "T-Union Cities"
                }
            }
            
            if let sn = realSN {
                resultFields.append(ResultField(title: "Card Number", value: formatTUnionCardNumber(sn)))
                resultFields.append(ResultField(title: "Region", value: brandRegion))
                if let city = issuingCity {
                    resultFields.append(ResultField(title: "Issuing City", value: city))
                }
                rawSections.append(RawDataSection(title: "Found in FCI", fields: [
                    RawDataField(title: "Payload", value: fci.hexString)
                ]))
            }
        }
        
        // Deep Scan: T-Union cards vary by region. Exhaustively probe SFIs if not found in FCI.
        if realSN == nil {
            for sfi in UInt8(1)...UInt8(31) {
                if realSN != nil { break }
                
                // Try READ RECORD (Linear Fixed Files)
                for recNo in UInt8(1)...UInt8(3) {
                    let p2 = (sfi << 3) | 0x04
                    let probeApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: recNo, p2Parameter: p2, data: Data(), expectedResponseLength: 256)
                    
                    if let response = try? await tag.sendCommand(apdu: probeApdu) {
                        if response.1 == 0x90 {
                            let info = response.0
                            print("[TUnion] Probed SFI \(String(format: "%02X", sfi)) Rec \(recNo): \(info.hexString)")
                            if let extracted = extractCAN(from: info) {
                                if realSN == nil {
                                    realSN = extracted
                                    brandRegion = TUnionCityDatabase.lookupCardName(for: extracted) ?? "T-Union Cities"
                                    resultFields.append(ResultField(title: "Card Number", value: formatTUnionCardNumber(extracted)))
                                    resultFields.append(ResultField(title: "Region", value: brandRegion))
                                    rawSections.append(RawDataSection(title: "Found in SFI \(String(format: "%02X", sfi))", fields: [
                                        RawDataField(title: "Source", value: "Read Record \(recNo)"),
                                        RawDataField(title: "Payload", value: info.hexString)
                                    ]))
                                }
                            }
                        } else if response.1 == 0x69 && response.2 == 0x81 {
                            let readBinary = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB0, p1Parameter: sfi | 0x80, p2Parameter: 0x00, data: Data(), expectedResponseLength: 64)
                            if let binResp = try? await tag.sendCommand(apdu: readBinary), binResp.1 == 0x90 {
                                let info = binResp.0
                                print("[TUnion] Probed SFI \(String(format: "%02X", sfi)) Binary: \(info.hexString)")
                                if let extracted = extractCAN(from: info) {
                                    if realSN == nil {
                                        realSN = extracted
                                        brandRegion = TUnionCityDatabase.lookupCardName(for: extracted) ?? "T-Union Cities"
                                        resultFields.append(ResultField(title: "Card Number", value: formatTUnionCardNumber(extracted)))
                                        resultFields.append(ResultField(title: "Region", value: brandRegion))
                                    }
                                }
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

    private static func findTUnionTag(_ tag: [UInt8], in data: Data) -> Data? {
        var i = 0
        let bytes = [UInt8](data)
        while i < bytes.count {
            // Check for tag match
            var tagMatch = true
            for (j, byte) in tag.enumerated() {
                if i + j >= bytes.count || bytes[i + j] != byte {
                    tagMatch = false
                    break
                }
            }
            
            if tagMatch {
                let lengthIndex = i + tag.count
                if lengthIndex < bytes.count {
                    let length = Int(bytes[lengthIndex])
                    let contentStart = lengthIndex + 1
                    let contentEnd = contentStart + length
                    if contentEnd <= bytes.count {
                        return data.subdata(in: contentStart..<contentEnd)
                    }
                }
            }
            
            // If it's a constructed tag (0x6F, 0xA5), enter it
            if bytes[i] == 0x6F || bytes[i] == 0xA5 {
                i += 2 // Skip tag and length and enter
                continue
            }
            
            i += 1
        }
        return nil
    }
    
    private static func extractCAN(from data: Data) -> String? {
        let hex = data.hexString.uppercased()
        
        // Known T-Union prefixes.
        // Special case for Octopus T-Union: It's often BCD with a leading zero-nibble.
        // e.g. 031048500...
        let prefixes = ["3104", "3101", "3105", "3110", "3140", "3102", "3106", "3107", "3180", "4131"]
        let bcdZeroPrefixes = prefixes.map { "0\($0)" }
        
        let allSearchPrefixes = prefixes + bcdZeroPrefixes
        
        for prefix in allSearchPrefixes {
            if let range = hex.range(of: prefix) {
                let startIndex = hex.distance(from: hex.startIndex, to: range.lowerBound)
                
                // If it starts with 0 (BCD padding), we want 20 chars total to get 19 digits.
                let isZeroPadded = prefix.hasPrefix("0")
                let length = isZeroPadded ? 20 : 19
                
                let end = min(startIndex + length, hex.count)
                let subRange = hex.index(hex.startIndex, offsetBy: startIndex)..<hex.index(hex.startIndex, offsetBy: end)
                let candidate = String(hex[subRange])
                if let clean = validateAndCleanCAN(candidate) { return clean }
            }
        }
        return nil
    }
    
    private static func validateAndCleanCAN(_ hexCandidate: String) -> String? {
        var clean = hexCandidate.replacingOccurrences(of: "F", with: "")
        
        // Strip leading zero if it was meant for BCD padding
        if clean.count == 20 && clean.hasPrefix("0") {
            clean = String(clean.dropFirst())
        }
        
        if clean.count >= 16 && clean.count <= 19 {
            let digitSet = CharacterSet.decimalDigits
            if clean.rangeOfCharacter(from: digitSet.inverted) == nil {
                if clean.allSatisfy({ $0 == "0" }) {
                    return nil
                }
                return clean
            }
        }
        return nil
    }
    
    private static func parseTUnionBalance(_ payload: Data) -> ParsedBalance? {
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
    
    private static let cityCodes: [String: String] = {
        guard let url = Bundle.main.url(forResource: "TUnionCityCodes", withExtension: "json"),
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
    
    static func lookupCityName(for cityId: String) -> String? {
        return cityCodes[cityId]
    }
}
