import Foundation

struct JapaneseICDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .feliCa = tag else { return false }
        return true
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .feliCa(let feliCa) = tag else { throw NFCTestError.unsupportedCard }

        var primarySnapshot: TransitCardSnapshot?
        for profile in FeliCaProfile.all {
            let scBytes = Data(hexString: profile.systemCode)
            guard let selected = try? await feliCa.polling(systemCode: scBytes, requestCode: .systemCode, timeSlot: .max1) else { continue }
            let isKMT = profile.systemCode == KMTCardFormat.systemCode
            if isKMT && !KMTCardFormat.isSelectedSystem(selected.1) { continue }

            ScanProgress.report(.balance)
            if let readResult = try? await feliCa.readWithoutEncryption(
                serviceCodeList: [profile.serviceCodeLittleEndian],
                blockList: [Data([0x80, 0x00])]
            ), readResult.0 == 0, readResult.1 == 0, let block = readResult.2.first {
                if isKMT && KMTCardFormat.validatedRead(
                    selectedSystem: selected.1, status1: readResult.0,
                    status2: readResult.1, blocks: readResult.2
                ) == nil { continue }
                if profile.systemCode == "8008" {
                    guard readResult.2.count == 1, block.count == 16 else { continue }
                    return await OctopusOnlineDecoder.decode(card: feliCa, block: block, pmm: selected.0, scannedAt: scannedAt)
                }
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
    
    private static func createSnapshot(feliCa: FeliCaCard, profile: FeliCaProfile, parsedBalance: ParsedBalance, scannedAt: Date) async -> TransitCardSnapshot {
        let feliCaTag = feliCa as FeliCaCard
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
        var serialNumber: String?
        if profile.systemCode == KMTCardFormat.systemCode {
            ScanProgress.report(.details)
            if let identifierBlock = await readKMTBlock(feliCa: feliCa, service: KMTCardFormat.identifierService, index: 0) {
                serialNumber = KMTCardFormat.identifier(identifierBlock)
                if let serialNumber { resultFields.append(ResultField(title: "KMT Card Number", value: serialNumber)) }
                rawSections.append(RawDataSection(title: "KMT Identifier", fields: [
                    RawDataField(title: "Raw Block", value: identifierBlock.hexString.uppercased())
                ]))
            }
            ScanProgress.report(.transactions)
            for index in 0..<KMTCardFormat.historyReadLimit {
                guard let block = await readKMTBlock(feliCa: feliCa, service: KMTCardFormat.historyService, index: index) else { break }
                if KMTCardFormat.isHistoryBlock(block) { transactions.append(block.hexString.uppercased()) }
            }
            rawSections.append(RawDataSection(title: "KMT History", fields: [
                RawDataField(title: "History", value: "Preserved as raw records; dates are not verified.")
            ]))
        } else if suicaStyleFamilies.contains(profile.displayName) {
             ScanProgress.report(.transactions)
             transactions = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0x0F, 0x09]))   // 090F
             ScanProgress.report(.activity)
             let gateHistory = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0x8F, 0x10])) // 108F
             let entryExit = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0xCB, 0x10]))   // 10CB
             transitHistory = gateHistory + entryExit
        } else if profile.displayName == "OKICA" {
             ScanProgress.report(.transactions)
             transactions = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0x8F, 0x02]))   // 028F
             ScanProgress.report(.activity)
             let gateHistory = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0x0F, 0x05]), maxBlocks: 3, stopAtEmptyPrefix: false) // 050F
             let sfEntry = await readServiceRecords(feliCa: feliCa, serviceCode: Data([0x0B, 0x06]), maxBlocks: 2, stopAtEmptyPrefix: false)     // 060B
             transitHistory = gateHistory + sfEntry
        } else if profile.displayName == "Ryuto" {
             ScanProgress.report(.transactions)
             transactions = await readServiceRecords(feliCa: feliCa, serviceCode: RyutoCardFormat.service, stopAtEmptyPrefix: false)
        }
        
        var snapshot = TransitCardSnapshot(
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
            realSerialNumber: serialNumber,
            region: nil,
            resultFields: resultFields,
            rawSections: rawSections,
            rawTransactions: transactions,
            rawTransitHistory: transitHistory,
            scannedAt: scannedAt
        )
        if profile.systemCode == "8008" {
            snapshot.applications = [TransitApplication(snapshot: snapshot)]
        }
        return snapshot
    }

    private static func readKMTBlock(feliCa: FeliCaCard, service: Data, index: Int) async -> Data? {
        guard let response = try? await feliCa.readWithoutEncryption(
            serviceCodeList: [service], blockList: [Data([0x80, UInt8(index)])]
        ) else { return nil }
        return KMTCardFormat.validatedRead(
            selectedSystem: Data([0x90, 0xB7]), status1: response.0,
            status2: response.1, blocks: response.2
        )
    }

    /// Generic reader for a FeliCa service — reads up to 20 blocks, stops at empty.
    private static func readServiceRecords(
        feliCa: FeliCaCard,
        serviceCode: Data,
        maxBlocks: Int = 20,
        stopAtEmptyPrefix: Bool = true
    ) async -> [String] {
        var results: [String] = []
        for i in 0..<maxBlocks {
            let blockList = [Data([0x80, UInt8(i)])]
            guard let readResult = try? await feliCa.readWithoutEncryption(serviceCodeList: [serviceCode], blockList: blockList),
                  readResult.0 == 0, readResult.1 == 0, let block = readResult.2.first else { break }
            guard block.count >= 16 else { break }
            if stopAtEmptyPrefix && block[0] == 0 && block[1] == 0 { break }
            results.append(block.hexString.uppercased())
        }
        return results
    }

    static func decodeTransaction(block: Data, context: [Data], index: Int, family: String, kind: RawHistoryKind = .transactions, relatedContext: [Data] = []) -> TransitTransaction? {
        // KMT's history epoch is not verified. Preserve its raw blocks without
        // interpreting them as Japanese IC records or fabricating dates/fares.
        if KMTCardFormat.matchesFamily(family) { return nil }
        if family.caseInsensitiveCompare("Ryuto") == .orderedSame {
            guard kind == .transactions, let record = RyutoCardFormat.decode(block) else { return nil }
            let formatter = DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
            formatter.dateFormat = "HH:mm"
            return TransitTransaction(date: record.date, time: formatter.string(from: record.date), amount: Decimal(record.amount),
                terminalID: nil, type: record.isTopUp ? "Top-up" : "Bus", category: record.isTopUp ? .topUp : .bus,
                balanceAfter: Decimal(record.balance), location: record.isTopUp ? nil : "Bus stop \(record.boardingStop) → \(record.alightingStop)",
                entryStation: record.isTopUp ? nil : "Bus stop \(record.boardingStop)",
                exitStation: record.isTopUp ? nil : "Bus stop \(record.alightingStop)", rawData: block.hexString)
        }
        let brand = ICCardBrand.from(family: family)
        switch brand {
        case .edy:
            return decodeEdyHistory(block: block)
        case .waon:
            return decodeWAONHistory(block: block)
        case .nanaco:
            return decodeNanacoHistory(block: block)
        default:
            break
        }

        guard block.count >= 16 else { return nil }

        if brand == .okica {
            guard kind == .transactions else { return nil }
            return decodeOKICAHistory(block: block, context: context, index: index)
        }

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
        let stationFieldMode = japaneseStationFieldMode(consoleType: consoleType, processType: processType)
        
        if isJapanesePurchaseLike(consoleType: consoleType, processType: processType) {
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
                if stationFieldMode == .bus {
                    let operatorName = BusResolver.shared.resolve(entryLow) ?? "Bus Operator \(String(format: "%04X", entryLow))"
                    let stopName = exitLow == 0 ? "N/A" : "Station \(String(format: "%04X", exitLow))"
                    entryStation = operatorName
                    exitStation = stopName
                    location = "\(operatorName) (\(stopName))"
                } else if stationFieldMode == .rail {
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
        let entryCodeHex = stationFieldMode == .rail && entryStation != nil ? String(format: "0x%05X", (area << 16) | (Int(block[6]) << 8 | Int(block[7]))) : nil
        let exitCodeHex = stationFieldMode == .rail && exitStation != nil ? String(format: "0x%05X", (area << 16) | (Int(block[8]) << 8 | Int(block[9]))) : nil

        var cat: TransactionCategory = .unknown
        if isJapanesePurchaseLike(consoleType: consoleType, processType: processType) {
            cat = .purchase
        } else if stationFieldMode == .bus {
            cat = .bus
        } else if stationFieldMode == .rail {
            cat = .train
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

    private static func decodeOKICAHistory(block: Data, context: [Data], index: Int) -> TransitTransaction? {
        guard block.count >= 16 else { return nil }

        let usageCode = UInt32(block[0]) << 24
            | UInt32(block[1]) << 16
            | UInt32(block[2]) << 8
            | UInt32(block[3])
        let rawDate = Int(block[4]) << 8 | Int(block[5])
        let year = 2000 + ((rawDate >> 9) & 0x7F)
        let month = (rawDate >> 5) & 0x0F
        let day = rawDate & 0x1F
        let date = makeJSTDate(year: year, month: month, day: day, hour: 0, minute: 0)

        let balance = Int(block[10]) | (Int(block[11]) << 8)
        let previousBalance: Int? = {
            guard index + 1 < context.count, context[index + 1].count >= 12 else { return nil }
            let previous = context[index + 1]
            return Int(previous[10]) | (Int(previous[11]) << 8)
        }()
        let amount = previousBalance.map { abs(balance - $0) } ?? 0
        let recordNumber = Int(block[13]) << 8 | Int(block[14])

        let (type, category): (String, TransactionCategory) = switch usageCode {
        case 0x16010002: ("Yui Rail", .train)
        case 0x08020000: ("Yui Rail Top-up", .topUp)
        case 0x08480000, 0x08480400: ("Point Top-up", .topUp)
        case 0x051F0000: ("Bus Top-up", .topUp)
        case 0x050F000F: ("Bus", .bus)
        case 0x08070000: ("New Card Issuance", .adjustment)
        case 0x1F1F0000: ("Top-up Machine", .topUp)
        default: (String(format: "OKICA Transaction %08X", usageCode), .unknown)
        }

        let entryCode = Int(block[6]) << 8 | Int(block[7])
        let exitCode = Int(block[8]) << 8 | Int(block[9])
        let entry = okicaLocation(code: entryCode)
        let exit = okicaLocation(code: exitCode)
        let location = [entry?.name, exit?.name]
            .compactMap { $0 }
            .joined(separator: " → ")

        return TransitTransaction(
            date: date,
            amount: Decimal(amount),
            terminalID: nil,
            type: type,
            category: category,
            balanceAfter: Decimal(balance),
            location: location.isEmpty ? nil : location,
            entryStation: entry?.name,
            exitStation: exit?.name,
            entryStationCode: entry?.stationCode,
            exitStationCode: exit?.stationCode,
            regionCode: entry?.stationCode == nil && exit?.stationCode == nil ? nil : 3,
            rawData: block.hexString.uppercased(),
            recordNumber: recordNumber
        )
    }

    private static func okicaLocation(code: Int) -> (name: String, stationCode: String?)? {
        guard code != 0 else { return nil }

        if (code & 0xFF00) == 0xDC00 {
            let fullCode = 0x30000 | code
            let name = StationResolver.shared.resolve(fullCode) ?? "Station \(String(format: "%04X", code))"
            return (name, String(format: "0x%05X", fullCode))
        }

        let busOperators = [
            0x0B01: "Naha Bus",
            0x0B02: "Ryukyu Bus Kotsu",
            0x0B03: "Okinawa Bus",
            0x0B04: "Toyo Bus"
        ]
        if let operatorName = busOperators[code] {
            return (operatorName, nil)
        }

        return ("Location \(String(format: "%04X", code))", nil)
    }

    private enum JapaneseStationFieldMode {
        case rail
        case bus
    }

    private static let japaneseRailProcessTypes: Set<UInt8> = [1, 4, 5, 19, 132, 133]
    private static let japanesePurchaseProcessTypes: Set<UInt8> = [70, 72, 73, 74, 75, 198, 203]

    private static func japaneseStationFieldMode(consoleType: UInt8, processType: UInt8) -> JapaneseStationFieldMode? {
        if isJapanesePurchaseLike(consoleType: consoleType, processType: processType) {
            return nil
        }
        if processType == 13 || processType == 15 {
            return .bus
        }
        if japaneseRailProcessTypes.contains(processType) {
            return .rail
        }
        return nil
    }

    private static func isJapanesePurchaseLike(consoleType: UInt8, processType: UInt8) -> Bool {
        consoleType == 199 || consoleType == 200 || japanesePurchaseProcessTypes.contains(processType)
    }

    private static func decodeEdyHistory(block: Data) -> TransitTransaction? {
        guard block.count >= 16 else { return nil }

        let typeByte = block[0]
        let sequentialNumber = block.bigEndianInt(start: 2, length: 2)
        let timestampRaw = UInt32(block.bigEndianInt(start: 4, length: 4))
        let amount = UInt32(block.bigEndianInt(start: 8, length: 4))
        let balance = UInt32(block.bigEndianInt(start: 12, length: 4))

        let elapsedDays = Int(timestampRaw >> 17)
        let elapsedSeconds = Int(timestampRaw & 0x1FFFF)
        guard let date = dateFromElapsedDays(sinceYear: 2000, elapsedDays: elapsedDays, elapsedSeconds: elapsedSeconds) else {
            return nil
        }

        let (type, category) = edyTransactionType(typeByte)
        let timeText = String(format: "%02d:%02d:%02d", elapsedSeconds / 3600, (elapsedSeconds % 3600) / 60, elapsedSeconds % 60)
        return TransitTransaction(
            date: date,
            time: timeText,
            amount: Decimal(amount),
            terminalID: nil,
            type: type,
            category: category,
            balanceAfter: Decimal(balance),
            rawData: block.hexString.uppercased(),
            recordNumber: sequentialNumber
        )
    }

    private static func decodeWAONHistory(block: Data) -> TransitTransaction? {
        guard block.count >= 29 else { return nil }

        let sequentialNumber = Int(block[13]) | (Int(block[14]) << 8)
        let typeByte = block[17]

        let packed = block.subdata(in: 18..<29)
        let year = 2005 + Int(readMSBPackedBits(packed, offset: 0, length: 5))
        let month = Int(readMSBPackedBits(packed, offset: 5, length: 4))
        let day = Int(readMSBPackedBits(packed, offset: 9, length: 5))
        let hour = Int(readMSBPackedBits(packed, offset: 14, length: 5))
        let minute = Int(readMSBPackedBits(packed, offset: 19, length: 6))

        let balance = readMSBPackedBits(packed, offset: 25, length: 18)
        let usageAmount = readMSBPackedBits(packed, offset: 43, length: 18)
        let chargeAmount = readMSBPackedBits(packed, offset: 61, length: 17)

        guard let date = makeJSTDate(year: year, month: month, day: day, hour: hour, minute: minute) else {
            return nil
        }

        let (type, category, amountValue) = waonTransactionType(typeByte, usageAmount: usageAmount, chargeAmount: chargeAmount)
        let deviceNumber = formatUTF8OrHex(block.subdata(in: 0..<13))
        let timeText = String(format: "%02d:%02d", hour, minute)

        return TransitTransaction(
            date: date,
            time: timeText,
            amount: Decimal(amountValue),
            terminalID: deviceNumber,
            type: type,
            category: category,
            balanceAfter: Decimal(balance),
            rawData: block.hexString.uppercased(),
            recordNumber: sequentialNumber
        )
    }

    private static func decodeNanacoHistory(block: Data) -> TransitTransaction? {
        guard block.count >= 16 else { return nil }

        let typeByte = block[0]
        let amount = UInt32(block.bigEndianInt(start: 1, length: 4))
        let balance = UInt32(block.bigEndianInt(start: 5, length: 4))
        let dateBits = UInt32(block.bigEndianInt(start: 9, length: 4))
        let sequentialNumber = block.bigEndianInt(start: 13, length: 2)

        let year = 2000 + Int((dateBits >> 21) & 0x7FF)
        let month = Int((dateBits >> 17) & 0x0F)
        let day = Int((dateBits >> 12) & 0x1F)
        let hour = Int((dateBits >> 6) & 0x3F)
        let minute = Int(dateBits & 0x3F)

        let date = makeJSTDate(year: year, month: month, day: day, hour: hour, minute: minute)
        let fallbackTimeText = String(format: "%04d-%02d-%02d %02d:%02d", year, month, day, hour, minute)
        let timeText = String(format: "%02d:%02d", hour, minute)

        let (type, category) = nanacoTransactionType(typeByte)
        return TransitTransaction(
            date: date,
            time: date == nil ? fallbackTimeText : timeText,
            amount: Decimal(amount),
            terminalID: nil,
            type: type,
            category: category,
            balanceAfter: Decimal(balance),
            rawData: block.hexString.uppercased(),
            recordNumber: sequentialNumber
        )
    }

    private static func edyTransactionType(_ typeByte: UInt8) -> (String, TransactionCategory) {
        switch typeByte {
        case 0x20:
            return ("Payment", .payment)
        case 0x02:
            return ("Top-up", .topUp)
        case 0x04:
            return ("Edy Gift", .topUp)
        default:
            return (String(format: "Transaction %02X", typeByte), .unknown)
        }
    }

    private static func readMSBPackedBits(_ data: Data, offset: Int, length: Int) -> UInt32 {
        var value: UInt32 = 0
        for bitIndex in offset..<(offset + length) {
            let byte = data[bitIndex / 8]
            let bit = (byte >> UInt8(7 - (bitIndex % 8))) & 0x01
            value = (value << 1) | UInt32(bit)
        }
        return value
    }

    private static func waonTransactionType(_ typeByte: UInt8, usageAmount: UInt32, chargeAmount: UInt32) -> (String, TransactionCategory, UInt32) {
        switch typeByte {
        case 0x04:
            return ("Payment", .payment, usageAmount)
        case 0x0C, 0x10:
            return ("Top-up", .topUp, chargeAmount)
        // Retain the existing unknown category and amount handling for these named operations.
        case 0x08:
            return ("Return", .unknown, max(usageAmount, chargeAmount))
        case 0x18:
            return ("Point Download", .unknown, max(usageAmount, chargeAmount))
        case 0x28:
            return ("Refund", .unknown, max(usageAmount, chargeAmount))
        case 0x1C, 0x20, 0x30:
            return ("Auto Charge", .unknown, max(usageAmount, chargeAmount))
        case 0x3C:
            return ("Move to New Card", .unknown, max(usageAmount, chargeAmount))
        case 0x7C:
            return ("Point Exchange", .unknown, max(usageAmount, chargeAmount))
        default:
            return (String(format: "Transaction %02X", typeByte), .unknown, max(usageAmount, chargeAmount))
        }
    }

    private static func nanacoTransactionType(_ typeByte: UInt8) -> (String, TransactionCategory) {
        switch typeByte {
        case 0x47:
            return ("Payment", .payment)
        case 0x5C, 0x6F, 0x70:
            return ("Top-up", .topUp)
        case 0x83:
            return ("Points Redemption", .topUp)
        case 0x35:
            return ("Transfer", .adjustment)
        default:
            return (String(format: "Transaction %02X", typeByte), .unknown)
        }
    }

    private static func dateFromElapsedDays(sinceYear year: Int, elapsedDays: Int, elapsedSeconds: Int) -> Date? {
        guard elapsedDays >= 0, (0..<86400).contains(elapsedSeconds) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        components.timeZone = TimeZone(identifier: "Asia/Tokyo")

        let calendar = Calendar(identifier: .gregorian)
        guard let baseDate = calendar.date(from: components),
              let dayDate = calendar.date(byAdding: .day, value: elapsedDays, to: baseDate),
              let finalDate = calendar.date(byAdding: .second, value: elapsedSeconds, to: dayDate) else {
            return nil
        }

        return finalDate
    }

    private static func makeJSTDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "Asia/Tokyo")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        guard let date = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard actual.year == year, actual.month == month, actual.day == day, actual.hour == hour, actual.minute == minute else { return nil }
        return date
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
        guard japaneseStationFieldMode(consoleType: block[0], processType: block[1]) == .rail else { return nil }

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
