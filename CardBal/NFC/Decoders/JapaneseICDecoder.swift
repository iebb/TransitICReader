import Foundation
import CoreNFC

struct JapaneseICDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        try await decodeExtended(tag: tag, scannedAt: scannedAt, shouldReadAll: false)
    }

    static func decodeExtended(tag: NFCTag, scannedAt: Date, shouldReadAll: Bool) async throws -> TransitCardSnapshot {
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
            if shouldReadAll {
                let result = await deepProbeFeliCa(feliCa: feliCa)
                
                var updatedSections = snapshot.rawSections
                if let analysis = result.analysisSection {
                    updatedSections.append(analysis)
                }

                // Append only unique records to avoid duplicates with Suica/Octopus standard paths
                let existing = Set(snapshot.rawTransactions)
                let newUnique = result.allRecords.filter { !existing.contains($0) }
                
                return TransitCardSnapshot(
                    technology: snapshot.technology,
                    cardFamily: snapshot.cardFamily,
                    identifierLabel: snapshot.identifierLabel,
                    identifierValue: snapshot.identifierValue,
                    rawIdentifierValue: snapshot.rawIdentifierValue,
                    pmm: snapshot.pmm,
                    systemCode: snapshot.systemCode,
                    selectedAID: snapshot.selectedAID,
                    balanceText: snapshot.balanceText,
                    balanceDetail: snapshot.balanceDetail,
                    realSerialNumber: snapshot.realSerialNumber,
                    region: snapshot.region,
                    resultFields: snapshot.resultFields,
                    rawSections: updatedSections,
                    rawTransactions: snapshot.rawTransactions + newUnique,
                    rawTransitHistory: snapshot.rawTransitHistory,
                    scannedAt: snapshot.scannedAt
                )
            }
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

        let suicaStyleFamilies = ["Japan Transit IC", "IruCa", "PASPY", "SAPICA"]
        var history: [String] = []
        if suicaStyleFamilies.contains(profile.displayName) {
             history = await readSuicaRawTransactions(feliCa: feliCa)
        } else if profile.displayName == "Octopus" {
             history = await readOctopusRawTransactions(feliCa: feliCa)
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

    static func decodeTransaction(block: Data, context: [Data], index: Int, family: String) -> TransitTransaction? {
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

    struct DeepProbeResult {
        let allRecords: [String]
        let analysisSection: RawDataSection?
    }

    private static func deepProbeFeliCa(feliCa: NFCFeliCaTag) async -> DeepProbeResult {
        var allRecords: [String] = []
        var probedServices: [String] = []
        
        print("[DeepScan] Starting exhaustive FeliCa probe...")
        guard let systemCodes = try? await feliCa.requestSystemCode() else { 
            print("[DeepScan] Failed to request system codes.")
            return DeepProbeResult(allRecords: [], analysisSection: nil)
        }
        
        print("[DeepScan] Found \(systemCodes.count) system codes: \(systemCodes.map { $0.hexString.uppercased() })")
        
        for sc in systemCodes {
             print("[DeepScan] Polling system \(sc.hexString.uppercased())...")
             _ = try? await feliCa.polling(systemCode: sc, requestCode: .systemCode, timeSlot: .max1)
             
             var services = (try? await feliCa.searchServiceCode()) ?? []
             print("[DeepScan] SearchServiceCode (0x0A) found \(services.count) services.")
             
             for serviceData in services {
                  let svcHex = serviceData.hexString.uppercased()
                  print("[DeepScan] Probing service \(svcHex)...")
                  
                  var serviceRecords: [String] = []
                  for i in 0..<20 {
                       let bList = [Data([0x80, UInt8(i)])]
                       guard let r = try? await feliCa.readWithoutEncryption(serviceCodeList: [serviceData], blockList: bList),
                             let blk = r.2.first, blk.count >= 16 else { break }
                             
                       serviceRecords.append(blk.hexString.uppercased())
                  }
                  
                  if serviceRecords.isEmpty {
                      probedServices.append("\(svcHex): No Read Access")
                  } else {
                      let activeCount = serviceRecords.filter { !$0.allSatisfy { $0 == "0" } }.count
                      probedServices.append("\(svcHex): \(serviceRecords.count) blocks (\(activeCount) non-zero)")
                      // Tag for later extraction in analysis section
                      allRecords.append(contentsOf: serviceRecords.map { "S_" + svcHex + "_" + $0 })
                  }
             }
        }
        
        var section: RawDataSection?
        if !probedServices.isEmpty {
            var fields: [RawDataField] = []
            for entry in probedServices {
                // entries are formatted like "svcHex: status" or "svcHex: count blocks..."
                let parts = entry.components(separatedBy: ": ")
                let svcHex = parts[0]
                let status = parts.count > 1 ? parts[1] : ""
                
                fields.append(RawDataField(title: "Service \(svcHex)", value: status))
                
                // Add first record hex if available for quick inspection
                let found = allRecords.filter { $0.hasPrefix("S_" + svcHex) } // Tagged below
                for (idx, rec) in found.prefix(2).enumerated() {
                    let hex = rec.replacingOccurrences(of: "S_" + svcHex + "_", with: "")
                    fields.append(RawDataField(title: "  Record \(idx)", value: hex))
                }
            }
            section = RawDataSection(title: "Deep Scan Analysis", fields: fields)
        }
        
        // Finalize allRecords without tags
        let cleanRecords = allRecords.map { r in 
            if r.contains("_") { return r.components(separatedBy: "_").last! }
            return r
        }
        
        print("[DeepScan] Finished. Found \(cleanRecords.count) total activity records.")
        return DeepProbeResult(allRecords: cleanRecords, analysisSection: section)
    }
}

extension NFCFeliCaTag {
    func searchServiceCode() async throws -> [Data] {
        var results: [Data] = []
        let idm = self.currentIDm
        
        // Loop through service indices 0...255 (typical discovery range)
        for i in 0..<256 {
            let indexBytes = Data([UInt8(i & 0xFF), UInt8((i >> 8) & 0xFF)])
            var cmd = Data([0x0A]) // Command 0x0A: Search Service Code
            cmd.append(idm)
            cmd.append(indexBytes)
            
            guard let response = try? await self.sendFeliCaCommand(commandPacket: cmd) else { break }
            // FeliCa response packet: [Length, ResponseCode (0x0B), IDm(8), ServiceCode(2), ...]
            guard response.count >= 12, response[1] == 0x0B else { break }
            
            // Service Code is at offset 10-11 (LE)
            let sc = response.subdata(in: 10..<12)
            if sc == Data([0xFF, 0xFF]) { break } // Search complete
            
            results.append(sc)
            // Limit to avoid infinite loop or super long scan
            if results.count > 100 { break }
        }
        return results
    }
}

// MARK: - Profiles handled by FeliCaProfiles.swift

