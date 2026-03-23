import Foundation
import CoreNFC

struct TUnionDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        return iso.initialSelectedAID == "A000000632010105"
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        let selectedAID = iso.initialSelectedAID
        let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: selectedAID), expectedResponseLength: 256)
        let initialResponse = try? await iso.sendCommand(apdu: selectApdu)
        let applicationAID = selectedAID
        let initialSelectResponse = initialResponse.map { NFCISO7816ResponseAPDU(statusWord1: $0.1, statusWord2: $0.2, payload: $0.0) }
        
        print("[TUnion] Decoding. AID=\(applicationAID), Selected=\(selectedAID)")
        
        // T-Union Balance: Probe multiple indices (0x01, 0x02) and handle composite results
        var balancePayloads: [UInt8: Data] = [:]
        
        // Final Strategy: Based on diagnostic logs, Shanghai cards provide:
        // P1=0x00, P2=0x02 -> Primary Purse (32.00)
        // P1=0x01, P2=0x02 -> Negative Balance / Debt (8.00)
        
        print("[TUnion] Reading Primary Purse (P1=00, P2=02)...")
        let apdu00 = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x5C, p1Parameter: 0x00, p2Parameter: 0x02, data: Data(), expectedResponseLength: 4)
        if let resp = try? await iso.sendCommand(apdu: apdu00), resp.1 == 0x90 {
            balancePayloads[0x02] = resp.0
            print("[TUnion]   Success: \(resp.0.hexString)")
        }

        print("[TUnion] Reading Negative Balance (P1=01, P2=02)...")
        let apdu01 = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x5C, p1Parameter: 0x01, p2Parameter: 0x02, data: Data(), expectedResponseLength: 4)
        if let resp = try? await iso.sendCommand(apdu: apdu01), resp.1 == 0x90 {
            balancePayloads[0x82] = resp.0
            print("[TUnion]   Success: \(resp.0.hexString)")
        }
        
        var resultFields: [ResultField] = []
        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "ISO7816"),
                RawDataField(title: "UID", value: iso.identifier.hexString),
                RawDataField(title: "Selected AID", value: selectedAID),
                RawDataField(title: "Application AID", value: applicationAID)
            ])
        ]
        
        for (p2, payload) in balancePayloads.sorted(by: { $0.key < $1.key }) {
            let label = (p2 == 0x82) ? "Balance 1" : "Balance 0"
            let p1 = (p2 == 0x82) ? "01" : "00"
            let realP2 = (p2 == 0x82) ? "02" : String(format: "%02X", p2)
            
            rawSections.append(RawDataSection(title: label, fields: [
                RawDataField(title: "Command", value: "805C\(p1)\(realP2)04"),
                RawDataField(title: "Response Payload", value: payload.hexString)
            ]))
        }
        
        let parsedBalance = parseTUnionBalances(balancePayloads)
        var realSN: String?
        var cardFamily = "T-Union"
        var brandRegion = "T-Union Cities"
        var issuingCity: String?
        var cardTypeStr: String?
        var issueDateStr: String?
        var expiryDateStr: String?
        
        // Octopus T-Union (嶺南通·八达通) and some others store the CAN in the FCI Tag 9F0C!
        if let fci = initialSelectResponse?.payload {
            print("[TUnion] Checking FCI for metadata...")
            
            // Try to find 9F0C tag (Application Meta) - Primary metadata source
            if let meta = findTUnionTag([0x9F, 0x0C], in: fci) {
                print("[TUnion] Meta tag 9F0C found, size: \(meta.count)")
                
                // Offset 0 (len 1): Card Type BCD
                if meta.count >= 1 {
                    cardTypeStr = decodeTUnionCardType(meta[0])
                }
                
                // Offset 2 (len 2): City ID (发卡地)
                if meta.count >= 4 {
                    let cityIdSubdata = meta.subdata(in: 2..<4)
                    let cityId = cityIdSubdata.hexString.uppercased()
                    let cityName = TUnionCityDatabase.lookupCityName(for: cityId)
                    issuingCity = cityName ?? "City \(cityId)"
                    print("[TUnion] City ID found: \(cityId) (\(issuingCity ?? "Unknown"))")
                }
                
                // Add App Metadata to raw sections
                rawSections.append(RawDataSection(title: "App Metadata (9F0C)", fields: [
                    RawDataField(title: "Full Payload", value: meta.hexString),
                    RawDataField(title: "Raw City ID", value: meta.subdata(in: 2..<4).hexString.uppercased())
                ]))
                
                // Offset 10 (len 10): Card Number (CAN)
                if meta.count >= 20 {
                    let cnData = meta.subdata(in: 10..<20)
                    if let extracted = validateAndCleanCAN(cnData.hexString) {
                        realSN = extracted
                        brandRegion = TUnionCityDatabase.lookupCardName(for: extracted) ?? "T-Union Cities"
                    }
                }
                
                // Offset 20 (0x14, len 4): Issue Date BCD (签发日期)
                if meta.count >= 24 {
                    issueDateStr = formatChinaBCDDate(meta.subdata(in: 20..<24).hexString)
                }
                
                // Offset 24 (0x18, len 4): Expiry Date BCD (到期日期)
                if meta.count >= 28 {
                    expiryDateStr = formatChinaBCDDate(meta.subdata(in: 24..<28).hexString)
                }
            }
            
            // Card info tag 9F08 / 9F00 - Secondary source?
            if realSN == nil {
                if let cardInfo = findTUnionTag([0x9F, 0x00], in: fci) ?? findTUnionTag([0x9F, 0x08], in: fci) {
                    if cardInfo.count >= 28 {
                        if expiryDateStr == nil {
                            expiryDateStr = formatChinaBCDDate(cardInfo.subdata(in: 24..<28).hexString)
                        }
                    }
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
                resultFields.append(ResultField(title: "Brand", value: brandRegion))
                if let type = cardTypeStr {
                    resultFields.append(ResultField(title: "Card Type", value: type))
                }
                if let city = issuingCity {
                    resultFields.append(ResultField(title: "Issuing City", value: city))
                }
                if let issue = issueDateStr {
                    resultFields.append(ResultField(title: "Issue Date", value: issue))
                }
                if let expiry = expiryDateStr {
                    resultFields.append(ResultField(title: "Expiry Date", value: expiry))
                }
                
                rawSections.append(RawDataSection(title: "Found in FCI", fields: [
                    RawDataField(title: "Payload", value: fci.hexString)
                ]))
            }
        }
        
        // Transaction History: SFI 0x18 is the standard for T-Union/PBOC
        let transactions = await readTUnionTransactions(iso: iso)
        
        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: "China T-Union",
            identifierLabel: "UID",
            identifierValue: iso.identifier.hexString,
            rawIdentifierValue: iso.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: parsedBalance.formatted,
            balanceDetail: "CNY balance for T-Union card.",
            realSerialNumber: realSN,
            region: brandRegion,
            resultFields: resultFields,
            rawSections: rawSections + parsedBalance.rawSections,
            transactions: transactions,
            scannedAt: scannedAt
        )
    }

    private static func readTUnionTransactions(iso: NFCISO7816Tag) async -> [TransitTransaction] {
        var txs: [TransitTransaction] = []
        let sfi: UInt8 = 0x18
        let p2 = (sfi << 3) | 0x04
        
        for recNo in UInt8(1)...UInt8(10) {
            let apdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: recNo, p2Parameter: p2, data: Data(), expectedResponseLength: 0)
            guard let resp = try? await iso.sendCommand(apdu: apdu), resp.1 == 0x90 else { break }
            let data = resp.0
            guard data.count >= 23 else { continue }
            
            // PBOC Transaction Record (standard 23 bytes)
            // 0-1: Counter, 2-4: Overdraft, 5-8: Amount, 9: Type, 10-15: Terminal, 16-19: Date (BCD), 20-22: Time (BCD)
            let amountVal = Int32(bigEndian: data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: Int32.self) })
            let typeByte = data[9]
            let dateBCD = data.subdata(in: 16..<20).hexString
            let timeBCD = data.subdata(in: 20..<23).hexString
            
            let typeStr = (typeByte == 0x01 || typeByte == 0x05) ? "Top-up" : "Consumption"
            let amount = Decimal(amountVal) / 100
            
            let dateStr = dateBCD + timeBCD
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMddHHmmss"
            let date = fmt.date(from: dateStr)
            
            txs.append(TransitTransaction(
                date: date,
                amount: amount,
                terminalID: data.subdata(in: 10..<16).hexString.uppercased(),
                type: typeStr,
                balanceAfter: nil,
                location: nil
            ))
        }
        return txs
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
    
    private static func parseTUnionBalances(_ payloads: [UInt8: Data]) -> (formatted: String, rawSections: [RawDataSection]) {
        var registerFields: [RawDataField] = []
        
        // Extract Purse (P1=0x00, P2=0x02)
        let purse: Int32 = payloads[0x02].flatMap { d in
             guard d.count >= 4 else { return nil }
             return Int32(bigEndian: d.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: Int32.self) })
        } ?? 0
        
        // Extract Debt (P1=0x01, P2=0x02) stored in virtual index 0x82
        let debt: Int32 = payloads[0x82].flatMap { d in
             guard d.count >= 4 else { return nil }
             return Int32(bigEndian: d.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: Int32.self) })
        } ?? 0

        // Rule: Final = Purse - Debt
        let selectedCents = purse - debt
        
        registerFields.append(RawDataField(title: "Balance 0", value: "\(Double(purse)/100.0) CNY"))
        registerFields.append(RawDataField(title: "Balance 1", value: "\(Double(debt)/100.0) CNY"))
        registerFields.append(RawDataField(title: "Final Balance (B0 - B1)", value: "\(Double(selectedCents)/100.0) CNY"))
        
        let amount = Double(selectedCents) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        let balanceText = formatter.string(from: NSNumber(value: amount)) ?? "\(amount)元"
        
        return (
            formatted: balanceText,
            rawSections: [RawDataSection(title: "Parsed Registers", fields: registerFields)]
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
    
    private static func decodeTUnionCardType(_ type: UInt8) -> String {
        return "Type \(String(format: "%02X", type))"
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
