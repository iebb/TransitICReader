import Foundation
import CoreNFC

struct JapaneseICDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        // 0. Ensure we are in the correct system for Transit IC (0003) or Octopus (8008)
        // This is critical for cards with multiple system codes (like Hayakaken/Suica).
        _ = try? await feliCa.polling(systemCode: Data([0x00, 0x03]), requestCode: .systemCode, timeSlot: .max1)
        
        // 1. Try Rail/Transit IC (Service 008B)
        if let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [Data([0x8B, 0x00])], blockList: [Data([0x80, 0x00])]),
           let block = readResult.2.first {
            let profile = FeliCaProfile.all[0] // Transit IC
            if let parsed = profile.parseBalance(block, scannedAt) {
                return await createSnapshot(feliCa: feliCa, profile: profile, parsedBalance: parsed, scannedAt: scannedAt)
            }
        }
        
        // 2. Try Octopus (Service 0117)
        _ = try? await feliCa.polling(systemCode: Data([0x80, 0x08]), requestCode: .systemCode, timeSlot: .max1)
        if let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [Data([0x17, 0x01])], blockList: [Data([0x80, 0x00])]),
           let block = readResult.2.first {
            let profile = FeliCaProfile.all[1] // Octopus
            if let parsed = profile.parseBalance(block, scannedAt) {
                return await createSnapshot(feliCa: feliCa, profile: profile, parsedBalance: parsed, scannedAt: scannedAt)
            }
        }
        
        throw NFCTestError.unsupportedCard
    }
    
    private static func createSnapshot(feliCa: NFCFeliCaTag, profile: FeliCaProfile, parsedBalance: ParsedBalance, scannedAt: Date) async -> TransitCardSnapshot {
        let feliCaTag = feliCa as NFCFeliCaTag
        let idm = feliCaTag.currentIDm.hexString.uppercased()
        let formattedIDm = formatFeliCaIDm(idm)
        
        let systemCodes = (try? await feliCaTag.requestSystemCode().map { $0.hexString.uppercased() }) ?? [profile.systemCode]
        let detectedBrand = profile.detectedBrand(using: systemCodes)
        
        var resultFields: [ResultField] = []
        if profile.displayName == "Japan Transit IC" {
            resultFields.append(ResultField(title: "Detected Type", value: detectedBrand))
        }
        resultFields.append(ResultField(title: "Card Number (IDm)", value: formattedIDm))
        
        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "FeliCa"),
                RawDataField(title: "IDm", value: formattedIDm),
                RawDataField.systemCodeRow(systemCodes)
            ])
        ]
        
        var fields = [RawDataField(title: "Decoder", value: parsedBalance.detail)]
        fields.append(contentsOf: parsedBalance.rawFields)
        rawSections.append(RawDataSection(title: "Decoded Balance", fields: fields))

        return TransitCardSnapshot(
            technology: "FeliCa",
            cardFamily: detectedBrand,
            identifierLabel: "IDm",
            identifierValue: formattedIDm,
            rawIdentifierValue: idm,
            pmm: "Unavailable",
            systemCode: profile.systemCode,
            selectedAID: nil,
            balanceText: parsedBalance.formatted,
            balanceDetail: parsedBalance.detail,
            realSerialNumber: nil,
            region: nil,
            resultFields: resultFields,
            rawSections: rawSections,
            transactions: (profile.displayName == "Japan Transit IC") ? (await readSuicaTransactions(feliCa: feliCa)) : [],
            transitHistory: [],
            scannedAt: scannedAt
        )
    }

    private static func readSuicaTransactions(feliCa: NFCFeliCaTag) async -> [TransitTransaction] {
        var txs: [TransitTransaction] = []
        let serviceCode = Data([0x0F, 0x09]) // Service 090F (Little-Endian)
        
        var results: [Data] = []
        
        // Read block by block until fail or empty (0x00 0x00)
        // Most transit cards store 10-20, but some might have more.
        for i in 0..<20 {
            let blockList = [Data([0x80, UInt8(i)])]
            guard let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [serviceCode], blockList: blockList) else {
                break // Stop on read error
            }
            
            let block = readResult.2[0]
            guard block.count >= 16 else { break }
            
            // Suica/PASMO uses 00 00 as uninitialized/placeholder
            if block[0] == 0 && block[1] == 0 {
                break 
            }
            
            results.append(block)
        }
        
        for i in 0..<results.count {
            let block = results[i]
            
            let balance = Int(block[10]) | (Int(block[11]) << 8)
            
            // Date parsing
            let rawDate = Int(block[4]) << 8 | Int(block[5])
            let year = (rawDate >> 9) & 0x7F
            let month = (rawDate >> 5) & 0x0F
            let day = rawDate & 0x1F
            
            var components = DateComponents()
            components.year = 2000 + year
            components.month = month
            components.day = day
            
            // To calculate amount, we need the NEXT record (which is older)
            var amount: Decimal = 0
            var typeStr = "Usage"
            
            if i + 1 < results.count {
                let prevBlock = results[i + 1]
                let prevBalance = Int(prevBlock[10]) | (Int(prevBlock[11]) << 8)
                let diff = balance - prevBalance
                amount = Decimal(abs(diff))
                typeStr = diff > 0 ? "Top-up" : "Consumption"
            }
            
            var location: String?
            var entryStation: String?
            var exitStation: String?
            var timeStr: String?
            
            let consoleType = block[0]
            let processType = block[1]
            
            let regionFull = Int(block[15])
            let r1 = (regionFull >> 6) & 0x03
            let r2 = (regionFull >> 4) & 0x03
            let area = r1 // Use bits 7-6 for the 18/20-bit address prefix
            
            let terminalName = Localizer.localize("suica_terminal_\(consoleType)")
            let usageName = Localizer.localize("suica_process_\(processType)")
            
            // Goods Time Parsing (Bytes 6-7)
            if consoleType == 199 || consoleType == 200 || processType == 70 || processType == 198 || processType == 203 {
                let timeData = Int(block[6]) << 8 | Int(block[7])
                let hour = (timeData >> 11) & 0x1F
                let minute = (timeData >> 5) & 0x3F
                let second = (timeData & 0x1F) * 2
                components.hour = hour
                components.minute = minute
                components.second = second
                
                timeStr = String(format: "%02d:%02d:%02d", hour, minute, second)
                location = timeStr
            } else {
                let entryLow = Int(block[6]) << 8 | Int(block[7])
                let exitLow = Int(block[8]) << 8 | Int(block[9])
                
                if entryLow != 0 || exitLow != 0 {
                    if processType == 13 || processType == 15 {
                        let operatorName = BusResolver.shared.resolve(entryLow) ?? "Bus Operator \(String(format: "%04X", entryLow))"
                        let stopName = exitLow == 0 ? "N/A" : "Station \(String(format: "%04X", exitLow))"
                        entryStation = "\(operatorName) [0x\(String(format: "%04X", entryLow))]"
                        exitStation = stopName == "N/A" ? "N/A" : "\(stopName) [0x\(String(format: "%04X", exitLow))]"
                        location = "\(operatorName) (\(stopName))"
                    } else {
                        let fullEntryCode = (area << 16) | entryLow
                        let fullExitCode = (area << 16) | exitLow
                        
                        let resolvedEntry = StationResolver.shared.resolve(fullEntryCode)
                        let resolvedExit = exitLow != 0 ? StationResolver.shared.resolve(fullExitCode) : nil
                        
                        // Main journey display: only show if at least entry is resolved
                        if let entry = resolvedEntry {
                            entryStation = "\(entry) \(area)-[0x\(String(format: "%04X", entryLow))]"
                            if let exit = resolvedExit {
                                exitStation = "\(exit) \(area)-[0x\(String(format: "%04X", exitLow))]"
                                location = "\(entry) → \(exit)"
                            } else if exitLow != 0 {
                                location = "\(entry) → unknown"
                            } else {
                                location = "In: \(entry)"
                            }
                        }
                    }
                }
            }
            
            let date = Calendar.current.date(from: components)
            
            txs.append(TransitTransaction(
                date: date,
                time: timeStr,
                amount: amount,
                terminalID: terminalName,
                type: typeStr == "Top-up" ? NSLocalizedString("top_up", comment: "Top-up") : usageName,
                balanceAfter: Decimal(balance),
                location: location,
                entryStation: entryStation,
                exitStation: exitStation,
                rawData: block.hexString.uppercased(),
                recordNumber: Int(block[13]) << 8 | Int(block[14])
            ))
        }
        return txs
    }
}

// MARK: - Profiles handled by FeliCaProfiles.swift

