import Foundation
import CoreNFC

struct JapaneseICDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }

        var primarySnapshot: TransitCardSnapshot?
        for profile in FeliCaProfile.all {
            let scBytes = Data(hexString: profile.systemCode)
            _ = try? await feliCa.polling(systemCode: scBytes, requestCode: .systemCode, timeSlot: .max1)

            if let readResult = try? await feliCa.readWithoutEncryption(
                serviceCodeList: [profile.serviceCodeLittleEndian],
                blockList: [Data([0x80, 0x00])]
            ), let block = readResult.2.first {
                if let parsed = profile.parseBalance(block, scannedAt) {
                    primarySnapshot = await createSnapshot(feliCa: feliCa, profile: profile, parsedBalance: parsed, scannedAt: scannedAt)
                    break
                }
            }
        }

        if let snapshot = primarySnapshot {
            return snapshot
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

        // For Japanese 0003-compatible cards, read only the 4 standard services:
        //   008B — balance (already read above via profile)
        //   090F — transaction log
        //   108F — transit gate activity
        //   10CB — entry/exit event log
        let suicaStyleFamilies = ["Japan Transit IC", "IruCa", "PASPY", "SAPICA"]
        var transactions: [String] = []
        var transitHistory: [String] = []
        if suicaStyleFamilies.contains(profile.displayName) {
             transactions = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0x0F, 0x09]))   // 090F
             let gateHistory = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0x8F, 0x10])) // 108F
             let entryExit = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0xCB, 0x10]))   // 10CB
             transitHistory = gateHistory + entryExit
        } else if profile.displayName == "Octopus" {
             transactions = await readOctopusRawTransactions(feliCa: feliCa)
        }
        
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
            rawTransactions: transactions,
            rawTransitHistory: transitHistory,
            scannedAt: scannedAt
        )
    }

    /// Generic reader for a FeliCa service — reads up to 20 blocks, stops at empty.
    private static func readServiceRecords(feliCa: NFCFeliCaTag, serviceCode: Data) async -> [String] {
        var results: [String] = []
        for i in 0..<20 {
            let blockList = [Data([0x80, UInt8(i)])]
            guard let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [serviceCode], blockList: blockList),
                  let block = readResult.2.first else { break }
            guard block.count >= 16 else { break }
            if block[0] == 0 && block[1] == 0 { break }
            results.append(block.hexString.uppercased())
        }
        return results
    }

    private static func readOctopusRawTransactions(feliCa: NFCFeliCaTag) async -> [String] {
        let serviceCode = Data([0x17, 0x01]) // Service 0117 (Little-Endian)
        var results: [String] = []
        // Octopus history usually starts from block 1. Block 0 is the current balance.
        for i in 1..<11 {
            let blockList = [Data([0x80, UInt8(i)])]
            guard let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [serviceCode], blockList: blockList),
                  let block = readResult.2.first else { break }
            guard block.count >= 16 else { break }
            results.append(block.hexString.uppercased())
        }
        return results
    }

    static func decodeTransaction(block: Data, context: [Data], index: Int, family: String, kind: RawHistoryKind = .transactions, relatedContext: [Data] = []) -> TransitTransaction? {
        guard block.count >= 16 else { return nil }
        
        let brand = ICCardBrand.from(family: family)
        if brand == .octopus {
            // Octopus Transaction Record (16-byte block from 0x0117)
            // Balance After is at offset 10-13 (Big Endian)
            let rawBalAfter = block.bigEndianInt(start: 10, length: 4)
            // We need to find or guess the scan timestamp since Octopus records don't have human-readable dates inside the block easily.
            // But we can at least show the balance and the calculated transaction amount if context is available.
            let balAfter = Decimal(rawBalAfter) / 10
            
            var amount: Decimal = 0
            if index + 1 < context.count {
                let prevBlock = context[index + 1]
                if prevBlock.count >= 14 {
                    let prevRawBal = prevBlock.bigEndianInt(start: 10, length: 4)
                    let diff = Int(rawBalAfter) - Int(prevRawBal)
                    amount = Decimal(diff) / 10
                }
            }
            
            let isTopup = amount > 0
            return TransitTransaction(
                date: nil,
                amount: amount,
                terminalID: nil,
                type: isTopup ? "Transaction / Top-up" : "Transaction",
                category: isTopup ? .topUp : .payment,
                balanceAfter: balAfter,
                rawData: block.hexString.uppercased()
            )
        }

        if kind == .transit {
            return decodeTransitActivity(block: block, relatedContext: relatedContext)
        }

        // --- Existing Japanese IC Logic (Suica/PASMO) ---
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
        
        var cat: TransactionCategory = .unknown
        if consoleType == 199 || consoleType == 200 || processType == 70 || processType == 198 || processType == 203 {
            cat = .purchase
        } else if processType == 13 || processType == 15 {
            cat = .bus
        } else if amount != 0 {
            cat = (typeStr == NSLocalizedString("top_up", comment: "")) ? .topUp : .payment
        }

        return TransitTransaction(
            date: date,
            time: timeStr,
            amount: amount,
            terminalID: terminalName,
            type: typeStr == NSLocalizedString("top_up", comment: "") ? typeStr : usageName,
            category: cat,
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

    private static func decodeTransitActivity(block: Data, relatedContext: [Data]) -> TransitTransaction? {
        guard block.count >= 16 else { return nil }

        let activityCode = block[0]
        let subtypeCode = block[1]
        let stationCode = Int(block[2]) << 8 | Int(block[3])
        let deviceNumber = Int(block[4]) << 8 | Int(block[5])
        let rawDate = Int(block[6]) << 8 | Int(block[7])
        let year = (rawDate >> 9) & 0x7F
        let month = (rawDate >> 5) & 0x0F
        let day = rawDate & 0x1F
        let hour = bcdToInt(block[8])
        let minute = bcdToInt(block[9])
        let amount = Int(block[10]) | (Int(block[11]) << 8)
        let passFare = Int(block[12]) | (Int(block[13]) << 8)
        let passLineCode = Int(block[14])
        let passStationCode = Int(block[15])

        var components = DateComponents()
        components.year = 2000 + year
        components.month = month
        components.day = day
        if hour >= 0 && minute >= 0 {
            components.hour = hour
            components.minute = minute
        }

        let inferredStation = inferTransitStation(code: stationCode, date: Calendar.current.date(from: components), relatedContext: relatedContext)
        let resolvedStationCode = inferredStation?.fullCode ?? stationCode
        let stationName = inferredStation?.stationName ?? StationResolver.shared.resolve(stationCode) ?? "Station \(String(format: "%04X", stationCode))"
        let timestamp = hour >= 0 && minute >= 0 ? String(format: "%02d:%02d", hour, minute) : nil
        let subtype = transitSubtypeLabel(for: subtypeCode)
        let terminalName = "Gate Device \(String(format: "%04d", deviceNumber))"

        let passStationFullCode = (passLineCode << 8) | passStationCode
        let inferredPassStation = passStationFullCode == 0 ? nil : inferTransitStation(code: passStationFullCode, date: Calendar.current.date(from: components), relatedContext: relatedContext)
        let passStationName: String? = passStationFullCode == 0 ? nil : (inferredPassStation?.stationName ?? StationResolver.shared.resolve(passStationFullCode) ?? "Station \(String(format: "%04X", passStationFullCode))")

        var locationParts = [stationName]
        if let passStationName {
            locationParts.append("Pass: \(passStationName)")
        }
        if passFare > 0 {
            locationParts.append("Pass Fare \(passFare)")
        }
        let location = locationParts.joined(separator: " | ")

        switch activityCode {
        case 0xA0, 0xA2:
            return TransitTransaction(
                date: Calendar.current.date(from: components),
                time: timestamp,
                amount: Decimal(amount),
                terminalID: terminalName,
                type: activityCode == 0xA2 ? "Discount Entry" : "Entry",
                category: .trainOn,
                balanceAfter: nil,
                location: location,
                entryStation: stationName,
                exitStation: nil,
                entryStationCode: String(format: "0x%05X", resolvedStationCode),
                exitStationCode: nil,
                regionCode: inferredStation?.regionCode,
                rawData: block.hexString.uppercased(),
                recordNumber: deviceNumber
            )
        case 0x20:
            return TransitTransaction(
                date: Calendar.current.date(from: components),
                time: timestamp,
                amount: Decimal(amount),
                terminalID: terminalName,
                type: "Exit",
                category: .trainOff,
                balanceAfter: nil,
                location: location,
                entryStation: nil,
                exitStation: stationName,
                entryStationCode: nil,
                exitStationCode: String(format: "0x%05X", resolvedStationCode),
                regionCode: inferredStation?.regionCode,
                rawData: block.hexString.uppercased(),
                recordNumber: deviceNumber
            )
        default:
            return TransitTransaction(
                date: Calendar.current.date(from: components),
                time: timestamp,
                amount: Decimal(amount),
                terminalID: terminalName,
                type: subtype.isEmpty ? "Transit Activity" : "Transit Activity (\(subtype))",
                category: .train,
                balanceAfter: nil,
                location: location,
                entryStation: nil,
                exitStation: nil,
                entryStationCode: resolvedStationCode == 0 ? nil : String(format: "0x%05X", resolvedStationCode),
                exitStationCode: nil,
                regionCode: inferredStation?.regionCode,
                rawData: block.hexString.uppercased(),
                recordNumber: deviceNumber
            )
        }
    }

    private struct InferredTransitStation {
        let fullCode: Int
        let regionCode: Int
        let stationName: String
    }

    private static func inferTransitStation(code: Int, date: Date?, relatedContext: [Data]) -> InferredTransitStation? {
        let directName = StationResolver.shared.resolve(code)
        if let directName {
            return InferredTransitStation(fullCode: code, regionCode: code >> 16, stationName: directName)
        }

        var bestMatch: (distance: TimeInterval, fullCode: Int, stationName: String)?
        for block in relatedContext {
            guard let candidate = inferCandidateStation(from: block, targetLowCode: code, targetDate: date) else {
                continue
            }
            if let currentBest = bestMatch {
                if candidate.distance < currentBest.distance {
                    bestMatch = candidate
                }
            } else {
                bestMatch = candidate
            }
        }

        guard let bestMatch else { return nil }
        return InferredTransitStation(fullCode: bestMatch.fullCode, regionCode: bestMatch.fullCode >> 16, stationName: bestMatch.stationName)
    }

    private static func inferCandidateStation(from block: Data, targetLowCode: Int, targetDate: Date?) -> (distance: TimeInterval, fullCode: Int, stationName: String)? {
        guard block.count >= 16 else { return nil }

        let rawDate = Int(block[4]) << 8 | Int(block[5])
        let year = (rawDate >> 9) & 0x7F
        let month = (rawDate >> 5) & 0x0F
        let day = rawDate & 0x1F

        var components = DateComponents()
        components.year = 2000 + year
        components.month = month
        components.day = day
        let candidateDate = Calendar.current.date(from: components)

        if let targetDate, let candidateDate {
            let delta = abs(candidateDate.timeIntervalSince(targetDate))
            if delta > 3 * 24 * 60 * 60 {
                return nil
            }
        }

        let regionFull = Int(block[15])
        let area = (regionFull >> 6) & 0x03
        let entryLow = Int(block[6]) << 8 | Int(block[7])
        let exitLow = Int(block[8]) << 8 | Int(block[9])

        let candidates = [entryLow, exitLow].filter { $0 == targetLowCode }
        guard !candidates.isEmpty else { return nil }

        let fullCode = (area << 16) | targetLowCode
        guard let stationName = StationResolver.shared.resolve(fullCode) else { return nil }
        let distance: TimeInterval
        if let candidateDate, let targetDate {
            distance = abs(candidateDate.timeIntervalSince(targetDate))
        } else {
            distance = 0
        }
        return (distance: distance, fullCode: fullCode, stationName: stationName)
    }

    private static func bcdToInt(_ value: UInt8) -> Int {
        let high = Int((value >> 4) & 0x0F)
        let low = Int(value & 0x0F)
        guard high < 10, low < 10 else { return -1 }
        return high * 10 + low
    }

    private static func transitSubtypeLabel(for code: UInt8) -> String {
        switch code {
        case 0x00: return "Standard"
        case 0x04: return "Discount"
        case 0x08: return "Transfer"
        default: return String(format: "%02X", code)
        }
    }

}

// MARK: - Profiles handled by FeliCaProfiles.swift
