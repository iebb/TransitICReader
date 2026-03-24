import Foundation
import CoreNFC

struct JapaneseICDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }
        
        for profile in FeliCaProfile.all {
            let scBytes = Data(hexString: profile.systemCode)
            _ = try? await feliCa.polling(systemCode: scBytes, requestCode: .systemCode, timeSlot: .max1)
            
            if let readResult = try? await feliCa.readWithoutEncryption(
                serviceCodeList: [profile.serviceCodeLittleEndian],
                blockList: [Data([0x80, 0x00])]
            ), let block = readResult.2.first {
                if let parsed = profile.parseBalance(block, scannedAt) {
                    return await createSnapshot(feliCa: feliCa, profile: profile, parsedBalance: parsed, scannedAt: scannedAt)
                }
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

        let suicaStyleFamilies = ["Japan Transit IC", "IruCa", "PASPY", "SAPICA"]
        let history = suicaStyleFamilies.contains(profile.displayName) ? (await readSuicaRawTransactions(feliCa: feliCa)) : []
        
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
            rawTransactions: history,
            rawTransitHistory: [],
            scannedAt: scannedAt
        )
    }

    private static func readSuicaRawTransactions(feliCa: NFCFeliCaTag) async -> [String] {
        let serviceCode = Data([0x0F, 0x09]) // Service 090F (Little-Endian)
        var results: [String] = []
        for i in 0..<20 {
            let blockList = [Data([0x80, UInt8(i)])]
            guard let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [serviceCode], blockList: blockList) else { break }
            let block = readResult.2[0]
            guard block.count >= 16 else { break }
            if block[0] == 0 && block[1] == 0 { break }
            results.append(block.hexString.uppercased())
        }
        return results
    }

    static func decodeTransaction(block: Data, context: [Data], index: Int, family: String) -> TransitTransaction? {
        guard block.count >= 16 else { return nil }
        
        let balance = Int(block[10]) | (Int(block[11]) << 8)
        let rawDate = Int(block[4]) << 8 | Int(block[5])
        let year = (rawDate >> 9) & 0x7F
        let month = (rawDate >> 5) & 0x0F
        let day = rawDate & 0x1F
        
        var components = DateComponents()
        components.year = 2000 + year
        components.month = month
        components.day = day
        
        var amount: Decimal = 0
        var typeStr = "Usage"
        
        if index + 1 < context.count {
            let prevBlock = context[index + 1]
            if prevBlock.count >= 12 {
                let prevBalance = Int(prevBlock[10]) | (Int(prevBlock[11]) << 8)
                let diff = balance - prevBalance
                amount = Decimal(abs(diff))
                typeStr = diff > 0 ? NSLocalizedString("top_up", comment: "") : NSLocalizedString("spending", comment: "")
            }
        }
        
        var location: String?
        var entryStation: String?
        var exitStation: String?
        var timeStr: String?
        
        let consoleType = block[0]
        let processType = block[1]
        let regionFull = Int(block[15])
        let r1 = (regionFull >> 6) & 0x03
        let area = r1 
        
        let terminalName = Localizer.localize("suica_terminal_\(consoleType)")
        let usageName = Localizer.localize("suica_process_\(processType)")
        
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
                    entryStation = operatorName
                    exitStation = stopName
                    location = "\(operatorName) (\(stopName))"
                } else {
                    let fullEntryCode = (area << 16) | entryLow
                    let fullExitCode = (area << 16) | exitLow
                    let entry = StationResolver.shared.resolve(fullEntryCode) ?? "Station \(String(format: "%X%04X", area, entryLow))"
                    let exit = exitLow != 0 ? (StationResolver.shared.resolve(fullExitCode) ?? "Station \(String(format: "%X%04X", area, exitLow))") : nil
                    entryStation = entry
                    if let exit = exit {
                        exitStation = exit
                        location = "\(entry) → \(exit)"
                    } else {
                        location = entry
                    }
                }
            }
        }
        
        let date = Calendar.current.date(from: components)
        let entryCodeHex = (entryStation != nil) ? String(format: "0x%05X", (area << 16) | (Int(block[6]) << 8 | Int(block[7]))) : nil
        let exitCodeHex = (exitStation != nil) ? String(format: "0x%05X", (area << 16) | (Int(block[8]) << 8 | Int(block[9]))) : nil
        
        return TransitTransaction(
            date: date,
            time: timeStr,
            amount: amount,
            terminalID: terminalName,
            type: typeStr == NSLocalizedString("top_up", comment: "") ? typeStr : usageName,
            balanceAfter: Decimal(balance),
            location: location,
            entryStation: entryStation,
            exitStation: exitStation,
            entryStationCode: entryCodeHex,
            exitStationCode: exitCodeHex,
            regionCode: area,
            rawData: block.hexString.uppercased(),
            recordNumber: Int(block[13]) << 8 | Int(block[14])
        )
    }
}

// MARK: - Profiles handled by FeliCaProfiles.swift

