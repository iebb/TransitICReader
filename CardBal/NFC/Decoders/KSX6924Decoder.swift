import Foundation
import CoreNFC
import os

struct KSX6924Decoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let aid = iso.initialSelectedAID
        let can = aid.hasPrefix("A0000000014B4F52") || aid == "A0000004520001" || aid.hasPrefix("D4100000") || aid.hasPrefix("D41065")
        let logger = os.Logger(subsystem: "ad.neko.cardbal", category: "KSX6924")
        logger.error("[KSX6924] canDecode evaluation: AID=\(aid, privacy: .public), Result=\(can ? 1 : 0)")
        return can
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        let selectedAID = iso.initialSelectedAID
        
        let logger = os.Logger(subsystem: "ad.neko.cardbal", category: "KSX6924")
        logger.error("[KSX6924] Starting decode for AID: \(selectedAID, privacy: .public)")
        
        let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: selectedAID), expectedResponseLength: 256)
        logger.error("[KSX6924_APDU] TX Select AID: \(selectedAID, privacy: .public)")
        let initialResponse = try await iso.sendCommand(apdu: selectApdu)
        logger.error("[KSX6924_APDU] RX Select AID: SW=\(String(format: "%02X%02X", initialResponse.1, initialResponse.2)), Data=\(initialResponse.0.hexString)")
        
        let initialSelectResponse = NFCISO7816ResponseAPDU(statusWord1: initialResponse.1, statusWord2: initialResponse.2, payload: initialResponse.0)
        
        let configInfo = KSX6924ConfigDFInfo(fciPayload: initialSelectResponse.payload ?? Data(), selectedAID: selectedAID)
        let applicationAID = configInfo?.mainApplicationAID ?? selectedAID
        
        if applicationAID != selectedAID {
            let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: applicationAID), expectedResponseLength: 256)
            logger.error("[KSX6924_APDU] TX Select App AID: \(applicationAID, privacy: .public)")
            let res = try await iso.sendCommand(apdu: selectApdu)
            logger.error("[KSX6924_APDU] RX Select App AID: SW=\(String(format: "%02X%02X", res.1, res.2)), Data=\(res.0.hexString)")
        }
        
        let balanceApdu = NFCISO7816APDU(instructionClass: 0x90, instructionCode: 0x4C, p1Parameter: 0x00, p2Parameter: 0x00, data: Data(), expectedResponseLength: 4)
        logger.error("[KSX6924_APDU] TX Get Balance")
        let balanceResponse = try await iso.sendCommand(apdu: balanceApdu)
        logger.error("[KSX6924_APDU] RX Get Balance: SW=\(String(format: "%02X%02X", balanceResponse.1, balanceResponse.2)), Data=\(balanceResponse.0.hexString)")
        
        let infoApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: 0x01, p2Parameter: 0x0C, data: Data(), expectedResponseLength: 256)
        logger.error("[KSX6924_APDU] TX Get Info (P1:01, P2:0C)")
        let infoResponse = try? await iso.sendCommand(apdu: infoApdu)
        if let infoRes = infoResponse {
            logger.error("[KSX6924_APDU] RX Get Info: SW=\(String(format: "%02X%02X", infoRes.1, infoRes.2)), Data=\(infoRes.0.hexString)")
        }

        let purseRecordResponse = await readRecord(
            recordNumber: 1,
            p2: (UInt8(2) << 3) | 0x04,
            from: iso
        )
        let purseRecordPayload = purseRecordResponse.flatMap { response in
            isReadable(response) ? response.data : nil
        }
        
        let profile = KSX6924CardProfile.matching(aid: applicationAID)
        let selectedPurseInfo = KSX6924PurseInfo(fciPayload: initialSelectResponse.payload ?? Data())
        let recordPurseInfo = purseRecordPayload.flatMap { KSX6924PurseInfo(fciPayload: $0) }
        let purseInfo = recordPurseInfo ?? selectedPurseInfo
        let parsedCardInfo = KSX6924CardInfo(payload: infoResponse?.0 ?? Data(), purseInfo: purseInfo, configInfo: configInfo)
        let isUMoney = isUMoneyCardNumber(parsedCardInfo.cardNumber)
        let developerModeEnabled = UserDefaults.standard.bool(forKey: DeveloperModePreferences.enabledKey)
        let parsedBalance = isUMoney
            ? ksx6924BalanceParser(data: balanceResponse.0, currencyCode: "MNT")
            : profile.parseBalance(balanceResponse.0)
        
        var transactions: [String] = []
        var transitHistory: [String] = []
        let isNAMANE = profile.displayName == "NAMANE"
        
        for sfi in profile.targetSFIs {
            logger.error("[KSX6924] Target SFI for \(profile.displayName): \(sfi)")
            
            // Try standard P2 (SFI in P2) and alternate P2 (SFI in P1)
            for p2 in [(sfi << 3) | 4, UInt8(0x00)] {
                var tempRaw: [String] = []
                var foundViaRecord = false
                
                for i in 1...20 {
                    let le = 256
                    let recApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: UInt8(i), p2Parameter: p2, data: Data(), expectedResponseLength: le)
                    logger.error("[KSX6924_APDU] TX Read Record SFI:\(sfi) P2:\(String(format: "%02X", p2)) Rec:\(i)")
                    guard var res = try? await iso.sendCommand(apdu: recApdu) else { break }
                    logger.error("[KSX6924_APDU] RX Read Record: SW=\(String(format: "%02X%02X", res.1, res.2)), DataLen=\(res.0.count)")
                    
                    if res.1 == 0x6C {
                        let newLe = Int(res.2)
                        let retryApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: UInt8(i), p2Parameter: p2, data: Data(), expectedResponseLength: newLe)
                        guard let resRetry = try? await iso.sendCommand(apdu: retryApdu) else { break }
                        res = resRetry
                    }
                    
                    if res.1 == 0x90, res.2 == 0x00, res.0.count >= 16 {
                        tempRaw.append(res.0.hexString.uppercased())
                        foundViaRecord = true
                    } else if res.1 == 0x6A {
                        break
                    }
                }
                
                if !foundViaRecord && p2 != 0x00 {
                    let binApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB0, p1Parameter: sfi | 0x80, p2Parameter: 0x00, data: Data(), expectedResponseLength: 256)
                    logger.error("[KSX6924_APDU] TX Read Binary SFI:\(sfi)")
                    if let res = try? await iso.sendCommand(apdu: binApdu) {
                        logger.error("[KSX6924_APDU] RX Read Binary: SW=\(String(format: "%02X%02X", res.1, res.2)), DataLen=\(res.0.count)")
                        if res.1 == 0x90, res.2 == 0x00, res.0.count >= 32 {
                            let strideLen = (sfi == 3) ? 52 : (isNAMANE ? 14 : 40)
                            for i in 0..<(res.0.count / strideLen) {
                                let block = res.0.subdata(in: (i*strideLen)..<((i+1)*strideLen))
                                if !block.allSatisfy({ $0 == 0x00 || $0 == 0xFF }) {
                                    tempRaw.append(block.hexString.uppercased())
                                }
                            }
                        }
                    }
                }
                
                if !tempRaw.isEmpty {
                    let isTransit = (sfi == 1 || sfi == 2 || sfi == 3)
                    if isTransit {
                        transitHistory.append(contentsOf: tempRaw)
                    } else {
                        transactions.append(contentsOf: tempRaw)
                    }
                    logger.error("[KSX6924] SUCCESS: Found \(tempRaw.count) raw blocks in SFI \(sfi)")
                    break
                }
            }
        }

        let developerBlocks: [RawDataField]
        if developerModeEnabled {
            developerBlocks = await readAllReadableBlocks(from: iso, logger: logger)
        } else {
            developerBlocks = []
        }
        
        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "ISO7816"),
                RawDataField(title: "UID", value: iso.identifier.hexString),
                RawDataField(title: "Application AID", value: applicationAID)
            ]),
            RawDataSection(title: "Balance APDU", fields: [
                RawDataField(title: "Payload", value: balanceResponse.0.hexString),
                RawDataField(title: "SW1SW2", value: String(format: "%02X%02X", balanceResponse.1, balanceResponse.2))
            ])
        ]
        
        if let purseInfo = parsedCardInfo.purseInfo {
            var purseFields = purseInfo.rawFields(currencyCode: isUMoney ? "MNT" : "KRW", isUMoney: isUMoney)
            if let purseRecordPayload {
                purseFields.insert(
                    RawDataField(title: "SFI 02 Record 1", value: purseRecordPayload.hexString.uppercased()),
                    at: 0
                )
            }
            rawSections.append(RawDataSection(title: "Purse Info (Tag B0)", fields: purseFields))
        }

        if developerModeEnabled {
            rawSections.append(RawDataSection(
                title: "Developer Readable Blocks",
                fields: [RawDataField(title: "Readable Block Count", value: String(developerBlocks.count))] + developerBlocks
            ))
        }

        var familyName = profile.displayName // e.g. "T-money", "EZL / Cashbee"
        var brandName = familyName
        var balanceText = parsedBalance.formatted
        var balanceDetail = parsedBalance.detail
        
        if isUMoney {
            familyName = "U-Money"
            brandName = "U-Money"
        } else if let type = parsedCardInfo.purseInfo?.cardType, (type & 0xB0) == 0xB0 {
            familyName = "T-money" 
            brandName = "Climate Card"
            balanceText = "N/A"
            balanceDetail = "Climate Card (Unlimited Pass)"
        }

        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: familyName,
            identifierLabel: "UID",
            identifierValue: iso.identifier.hexString,
            rawIdentifierValue: iso.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: balanceText,
            balanceDetail: balanceDetail,
            realSerialNumber: parsedCardInfo.cardNumber,
            region: brandName,
            resultFields: parsedCardInfo.resultFields(brand: isUMoney ? .umoney : ICCardBrand.from(family: familyName)),
            rawSections: rawSections,
            rawTransactions: transactions,
            rawTransitHistory: transitHistory,
            scannedAt: scannedAt
        )
    }

    static func isUMoneyCardNumber(_ cardNumber: String?) -> Bool {
        guard let cardNumber else { return false }
        return cardNumber.filter(\.isNumber).hasPrefix("16")
    }

    private static func readAllReadableBlocks(
        from tag: NFCISO7816Tag,
        logger: os.Logger
    ) async -> [RawDataField] {
        var blocks: [RawDataField] = []

        for sfi in UInt8(1)...UInt8(30) {
            let p2 = (sfi << 3) | 0x04

            // ISO 7816 record EFs are sequential. Stop at the first unreadable
            // record in each SFI, while allowing the full UInt8 record range.
            for recordValue in 1...255 {
                let recordNumber = UInt8(recordValue)
                guard let response = await readRecord(
                    recordNumber: recordNumber,
                    p2: p2,
                    from: tag
                ) else {
                    break
                }
                guard isReadable(response) else { break }
                blocks.append(RawDataField(
                    title: String(format: "SFI %02d Record %03d", sfi, recordNumber),
                    value: response.data.hexString.uppercased()
                ))
            }

            // Short-EF addressing exposes the first binary block for an SFI.
            // This is read-only and complements record-oriented EFs above.
            if let response = await readBinary(sfi: sfi, from: tag), isReadable(response) {
                blocks.append(RawDataField(
                    title: String(format: "SFI %02d Binary 0000", sfi),
                    value: response.data.hexString.uppercased()
                ))
            }
        }

        logger.error("[KSX6924_DEV] Captured \(blocks.count) readable blocks across SFIs 1-30")
        return blocks
    }

    private static func readRecord(
        recordNumber: UInt8,
        p2: UInt8,
        from tag: NFCISO7816Tag
    ) async -> (data: Data, sw1: UInt8, sw2: UInt8)? {
        let apdu = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xB2,
            p1Parameter: recordNumber,
            p2Parameter: p2,
            data: Data(),
            expectedResponseLength: 256
        )
        guard var response = try? await tag.sendCommand(apdu: apdu) else { return nil }
        if response.1 == 0x6C {
            let expectedLength = response.2 == 0 ? 256 : Int(response.2)
            let retry = NFCISO7816APDU(
                instructionClass: 0x00,
                instructionCode: 0xB2,
                p1Parameter: recordNumber,
                p2Parameter: p2,
                data: Data(),
                expectedResponseLength: expectedLength
            )
            guard let retried = try? await tag.sendCommand(apdu: retry) else { return nil }
            response = retried
        }
        return (response.0, response.1, response.2)
    }

    private static func readBinary(
        sfi: UInt8,
        from tag: NFCISO7816Tag
    ) async -> (data: Data, sw1: UInt8, sw2: UInt8)? {
        let apdu = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xB0,
            p1Parameter: sfi | 0x80,
            p2Parameter: 0x00,
            data: Data(),
            expectedResponseLength: 256
        )
        guard var response = try? await tag.sendCommand(apdu: apdu) else { return nil }
        if response.1 == 0x6C {
            let expectedLength = response.2 == 0 ? 256 : Int(response.2)
            let retry = NFCISO7816APDU(
                instructionClass: 0x00,
                instructionCode: 0xB0,
                p1Parameter: sfi | 0x80,
                p2Parameter: 0x00,
                data: Data(),
                expectedResponseLength: expectedLength
            )
            guard let retried = try? await tag.sendCommand(apdu: retry) else { return nil }
            response = retried
        }
        return (response.0, response.1, response.2)
    }

    private static func isReadable(_ response: (data: Data, sw1: UInt8, sw2: UInt8)) -> Bool {
        (response.sw1 == 0x90 && response.sw2 == 0x00)
            || (response.sw1 == 0x62 && response.sw2 == 0x82 && !response.data.isEmpty)
    }

    static func parseSingleTransaction(_ block: Data, sfi: UInt8, recordIndex: Int, isNAMANE: Bool, logger: os.Logger) -> TransitTransaction? {
        parseSingleTransaction(
            block,
            sfi: sfi,
            recordIndex: recordIndex,
            brand: isNAMANE ? .namane : .tmoney,
            logger: logger
        )
    }

    static func parseSingleTransaction(_ block: Data, sfi: UInt8, recordIndex: Int, brand: ICCardBrand, logger: os.Logger) -> TransitTransaction? {
        if block.allSatisfy({ $0 == 0x00 }) || block.allSatisfy({ $0 == 0xFF }) { return nil }
        let isNAMANE = brand == .namane
        
        if block.count >= 14 {
            // New Layout (40+) or Compact (14+ bytes)
            // Offset 0: Type
            // Offset 1: Unknown
            // Offset 2-5: Balance (4 BE)
            // Offset 6-9: NTEP / Record ID (4 BE)
            // Offset 10-13: Amount (4 BE)
            
            let balanceVal = block.bigEndianInt(start: 2, length: 4)
            let balance = Decimal(balanceVal)
            let ntep = block.bigEndianInt(start: 6, length: 4)
            let fareVal = block.bigEndianInt(start: 10, length: 4)
            let fare = Decimal(fareVal)
            
            let type = block[0]
            let isTopup = type == 0x02
            let signedAmount = isTopup ? fare : -fare
            var typeStr = isTopup ? "Top-up" : "Payment"
            if fareVal == 0 { typeStr = "Entry" }
            let category: TransactionCategory = isTopup ? .topUp : (fareVal == 0 ? .tapOn : .payment)
            
            var foundDate: Date?
            var displayTime = (isNAMANE || (!isNAMANE && (sfi == 4 || sfi == 14))) ? "Record #\(ntep)" : "N/A"
            
            // Optional: IDSAM and NTSAM if available (40+ layout)
            var idsam: String?
            var ntsam: Int?
            
            if block.count >= 25 {
                idsam = block.subdata(in: 14..<min(22, block.count)).hexString
                ntsam = block.count >= 25 ? Int(block.bigEndianInt(start: 22, length: 4)) : nil
            }
            
            if block.count >= 33 {
                let h = block.subdata(in: 26..<33).hexString
                if h != "00000000000000" && h.hasPrefix("20") {
                    var components = DateComponents()
                    components.year = Int(h.prefix(4))
                    components.month = Int(h.dropFirst(4).prefix(2))
                    components.day = Int(h.dropFirst(6).prefix(2))
                    components.hour = Int(h.dropFirst(8).prefix(2))
                    components.minute = Int(h.dropFirst(10).prefix(2))
                    components.second = Int(h.dropFirst(12).prefix(2))
                    
                    if let yr = components.year, yr >= 2020, yr <= 2030,
                       let mo = components.month, mo >= 1, mo <= 12,
                       let dy = components.day, dy >= 1, dy <= 31 {
                        foundDate = CardDateFormatting.date(
                            year: components.year,
                            month: components.month,
                            day: components.day,
                            hour: components.hour,
                            minute: components.minute,
                            second: components.second,
                            brand: brand
                        )
                        displayTime = String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
                    }
                }
            }
            
            return TransitTransaction(date: foundDate, time: displayTime, amount: signedAmount, terminalID: idsam ?? block.prefix(2).hexString, type: typeStr, category: category, balanceAfter: balance, rawData: block.hexString, recordNumber: Int(ntep), ntsam: ntsam)
        }
        return nil
    }

    static func parseTransitHistory(_ block: Data, sfi: UInt8, recordIndex: Int, isNAMANE: Bool, logger: os.Logger) -> TransitTransaction? {
        parseTransitHistory(
            block,
            sfi: sfi,
            recordIndex: recordIndex,
            brand: isNAMANE ? .namane : .tmoney,
            logger: logger
        )
    }

    static func parseTransitHistory(_ block: Data, sfi: UInt8, recordIndex: Int, brand: ICCardBrand, logger: os.Logger) -> TransitTransaction? {
        logger.error("[KSX6924_TH] Parsing Record \(recordIndex) from SFI \(sfi): \(block.hexString)")
        if block.allSatisfy({ $0 == 0x00 }) || block.allSatisfy({ $0 == 0xFF }) { 
            return nil 
        }
        // T-money SFI 3 Transit Record (52 bytes)
        if block.count >= 52 {
            let record = block.count == 52 ? block : block.subdata(in: 0..<52)
            let tripState = record[2]
            let fareLayout = KoreanTransitHistoryFareLayout.decode(record)
            let timestamp = KoreanTransitTimestampDecoder.decode(record, brand: brand)
            let distanceM = record.bigEndianInt(start: 19, length: 2)
            let stationToken = record.subdata(in: 5..<9).hexString.uppercased()
            let transportModeHex = record.subdata(in: 9..<11).hexString.uppercased()
            let transportModeCode = record.bigEndianInt(start: 9, length: 2)
            let locationCode = stationToken + transportModeHex
            let transportMode = brand.isKorean
                ? KOTRISTransportModeCatalog.bundled?.mode(for: transportModeCode)
                : nil
            let stationAlias = brand.isKorean
                ? KoreanStationAliasCatalog.bundled?.location(
                    for: locationCode,
                    eventRaw: Int(tripState)
                )
                : nil
            let stationDisplay = stationAlias?.localizedDisplayName ?? String(
                format: NSLocalizedString("korean_station_token_format", comment: "Unknown Korean station-token display"),
                stationToken
            )
            let transportModeDisplay: String
            if let transportMode {
                transportModeDisplay = "\(transportMode.nameKo) · \(transportMode.transportClass.displayName)"
            } else {
                transportModeDisplay = String(
                    format: NSLocalizedString("korean_unmapped_transport_mode_format", comment: "Unmapped Korean transport-mode display"),
                    transportModeHex,
                    transportModeCode
                )
            }

            var typeStr: String
            var cat: TransactionCategory = .unknown

            if tripState == 0x00 {
                typeStr = NSLocalizedString("tap_on", comment: "tap-on")
                switch transportMode?.transportClass {
                case .rail: cat = .trainOn
                case .bus: cat = .busOn
                case .taxi, .none: cat = .unknown
                }
            } else if tripState == 0x01 {
                typeStr = NSLocalizedString("tap_off", comment: "tap-off")
                switch transportMode?.transportClass {
                case .rail: cat = .trainOff
                case .bus: cat = .busOff
                case .taxi, .none: cat = .unknown
                }
            } else {
                typeStr = String(
                    format: NSLocalizedString("korean_flagged_event_format", comment: "Unknown Korean transit event byte"),
                    tripState
                )
            }

            let distKm = Double(distanceM) / 1000.0
            let details = distKm > 0 ? String(format: " (%.1f km)", distKm) : ""

            let tx = TransitTransaction(
                date: timestamp?.date,
                time: timestamp?.timeString,
                amount: Decimal(-(fareLayout?.selectedAmount ?? 0)),
                terminalID: locationCode,
                type: typeStr + details,
                category: cat,
                balanceAfter: nil,
                location: "\(stationDisplay) · \(transportModeDisplay)",
                entryStation: tripState == 0x00 ? stationDisplay : nil,
                exitStation: tripState == 0x01 ? stationDisplay : nil,
                entryStationCode: tripState == 0x00 ? locationCode : nil,
                exitStationCode: tripState == 0x01 ? locationCode : nil,
                rawData: record.hexString,
                recordNumber: recordIndex,
                distance: distKm > 0 ? distKm : nil
            )
            return tx
        }
        
        // Legacy/Generic (16-32 bytes)
        if block.count >= 18 {
            let balance = Decimal(block.bigEndianInt(start: 14, length: 4))
            let cost = Decimal(block.bigEndianInt(start: 10, length: 4))
            
            var foundDate: Date?
            var displayTime = "Record #\(recordIndex)"
            if block.count >= 9 {
                let h = block.subdata(in: 2..<9).hexString
                if h != "00000000000000" && h.hasPrefix("20") {
                    var components = DateComponents()
                    components.year = Int(h.prefix(4))
                    components.month = Int(h.dropFirst(4).prefix(2))
                    components.day = Int(h.dropFirst(6).prefix(2))
                    components.hour = Int(h.dropFirst(8).prefix(2))
                    components.minute = Int(h.dropFirst(10).prefix(2))
                    components.second = Int(h.dropFirst(12).prefix(2))
                    
                    if let yr = components.year, yr >= 2020, yr <= 2030,
                       let mo = components.month, mo >= 1, mo <= 12,
                       let dy = components.day, dy >= 1, dy <= 31 {
                        foundDate = CardDateFormatting.date(
                            year: components.year,
                            month: components.month,
                            day: components.day,
                            hour: components.hour,
                            minute: components.minute,
                            second: components.second,
                            brand: brand
                        )
                        displayTime = String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
                    }
                }
            }
            
            var details = ""
            if block.count >= 24 {
                let km = Int(block[22]) * 256 + Int(block[23])
                if km > 0 {
                    details = " (\(km) km)"
                }
            }
            
            let tx = TransitTransaction(date: foundDate, time: displayTime, amount: -cost, terminalID: block.prefix(2).hexString, type: "Transit" + details, balanceAfter: balance, rawData: block.hexString)
            return tx
        }
        return nil
    }

}

struct KoreanTransitHistoryFareLayout {
    enum Variant: Equatable {
        case primary22
        case regional36
        case base40
        case unresolved
    }

    let variant: Variant
    let selectedAmount: Int?
    let selectedAmountHex: String?

    static func decode(_ data: Data) -> KoreanTransitHistoryFareLayout? {
        guard data.count >= 42 else { return nil }

        let primaryAmount = data.bigEndianInt(start: 22, length: 2)
        let regionalAmount = data.bigEndianInt(start: 36, length: 2)
        let baseFare = data.bigEndianInt(start: 40, length: 2)

        let primary = (Variant.primary22, primaryAmount, data.subdata(in: 22..<24).hexString.uppercased())
        let regional = (Variant.regional36, regionalAmount, data.subdata(in: 36..<38).hexString.uppercased())
        let base = (Variant.base40, baseFare, data.subdata(in: 40..<42).hexString.uppercased())
        let profile = KoreanTransitOperatorFieldProfile.forRecord(data)
        let candidates = profile?.usesMybiFieldLayout == true
            ? [base, regional, primary]
            : [primary, base, regional]
        let selection = candidates.first { isPlausibleFare($0.1) }

        return KoreanTransitHistoryFareLayout(
            variant: selection?.0 ?? .unresolved,
            selectedAmount: selection?.1,
            selectedAmountHex: selection?.2
        )
    }

    private static func isPlausibleFare(_ value: Int) -> Bool {
        (1...10_000).contains(value)
    }

}

private struct KSX6924CardProfile {
    let displayName: String
    let aid: String
    let targetSFIs: [UInt8]
    let sfiParsers: [UInt8: (Data, UInt8, Int, Bool, os.Logger) -> TransitTransaction?]
    let parseBalance: (Data) -> ParsedBalance

    static func matching(aid: String) -> KSX6924CardProfile {
        let normalized = aid.uppercased()
        if normalized.hasPrefix("D410000003") { 
            return KSX6924CardProfile(displayName: "T-money", aid: normalized, targetSFIs: [3, 4], 
                sfiParsers: [
                    3: KSX6924Decoder.parseTransitHistory,
                    4: KSX6924Decoder.parseSingleTransaction
                ],
                parseBalance: ksx6924BalanceParser) 
        }
        if normalized.hasPrefix("D410000014") { 
            return KSX6924CardProfile(displayName: "EZL / Cashbee", aid: normalized, targetSFIs: [3, 4], 
                sfiParsers: [
                    3: KSX6924Decoder.parseTransitHistory,
                    4: KSX6924Decoder.parseSingleTransaction
                ],
                parseBalance: ksx6924BalanceParser) 
        }
        if normalized.hasPrefix("D410000029") { 
            return KSX6924CardProfile(displayName: "NAMANE", aid: normalized, targetSFIs: [14], 
                sfiParsers: [14: NAMANEDecoder.parseNAMANELog],
                parseBalance: ksx6924BalanceParser) 
        }
        // if normalized.hasPrefix("D410000030") { return KSX6924CardProfile(displayName: "MOIBA", aid: normalized, targetSFIs: [4], sfiParsers: [4: KSX6924Decoder.parseSingleTransaction], parseBalance: ksx6924BalanceParser) }
        // if normalized.hasPrefix("D410650990") { return KSX6924CardProfile(displayName: "K-Cash", aid: normalized, targetSFIs: [4], sfiParsers: [4: KSX6924Decoder.parseSingleTransaction], parseBalance: ksx6924BalanceParser) }
        return KSX6924CardProfile(displayName: "KS X 6924", aid: normalized, targetSFIs: [4], 
            sfiParsers: [4: KSX6924Decoder.parseSingleTransaction],
            parseBalance: ksx6924BalanceParser)
    }
}

private func ksx6924BalanceParser(data: Data) -> ParsedBalance {
    ksx6924BalanceParser(data: data, currencyCode: "KRW")
}

private func ksx6924BalanceParser(data: Data, currencyCode: String) -> ParsedBalance {
    guard data.count >= 4 else { return ParsedBalance(formatted: "Error", detail: "Short data", rawFields: []) }
    let balance = data.bigEndianInt(start: 0, length: 4)
    return ParsedBalance(
        formatted: formatCurrency(amount: Decimal(balance), code: currencyCode, fractionDigits: 0),
        detail: "Parsed as a 4-byte big-endian integer.",
        rawFields: [RawDataField(title: "Stored Value", value: String(balance))]
    )
}

private struct KSX6924ConfigDFInfo {
    let mainApplicationAID: String?
    let serial: String?
    init?(fciPayload: Data, selectedAID: String) {
        guard selectedAID == "A0000004520001" else { return nil }
        self.mainApplicationAID = findTLVValue(tag: [0x4F], in: fciPayload)?.hexString
        self.serial = findTLVValue(tag: [0x12], in: fciPayload).map { formatKoreanCardNumber($0.hexString) }
    }
}

private struct KSX6924CardInfo {
    let cardNumber: String?
    let issueDate: String?
    let purseInfo: KSX6924PurseInfo?
    init(payload: Data, purseInfo: KSX6924PurseInfo?, configInfo: KSX6924ConfigDFInfo?) {
        self.purseInfo = purseInfo
        self.cardNumber = purseInfo?.serial ?? configInfo?.serial ?? (payload.count >= 16 ? formatKoreanCardNumber(payload.sliceHexString(start: 8, length: 8)) : nil)
        self.issueDate = purseInfo?.issueDate ?? (payload.count >= 25 ? Self.formatIssueDate(payload.subdata(in: 21..<25)) : nil)
    }
    func resultFields(brand: ICCardBrand) -> [ResultField] {
        var fields: [ResultField] = []
        if let cardNumber { fields.append(ResultField(title: "Card Number", value: cardNumber)) }
        if let issueDate { fields.append(ResultField(title: "Issue Date", value: KSX6924DateFormatting.formatBCDDateForDisplay(issueDate) ?? issueDate)) }
        if let purseInfo {
            fields.append(contentsOf: purseInfo.resultFields(brand: brand))
        }
        return fields
    }
    private static func formatIssueDate(_ bytes: Data) -> String? {
        let hex = bytes.hexString
        guard hex.count == 8 else { return nil }
        return "\(hex.prefix(4))-\(hex.dropFirst(4).prefix(2))-\(hex.suffix(2))"
    }
}

private struct KSX6924PurseInfo {
    let rawData: Data
    let serial: String
    let cardType: UInt8
    let algorithm: UInt8
    let keyVersion: UInt8
    let issuerID: UInt8
    let usageAuthenticationID: String
    let issueDate: String?
    let expiryDate: String?
    let userCode: UInt8
    let discountRate: UInt8
    let maximumBalance: Int
    let branchCode: String
    let singleTransactionLimit: Int
    let telecomCode: UInt8
    let creditCompanyCode: UInt8
    let reserved: Data

    init?(fciPayload: Data) {
        guard let purseData = findTLVValue(tag: [0xB0], in: fciPayload), purseData.count >= 47 else { return nil }
        self.rawData = purseData
        self.cardType = purseData[0]
        self.algorithm = purseData[1]
        self.keyVersion = purseData[2]
        self.issuerID = purseData[3]
        self.serial = formatKoreanCardNumber(purseData.sliceHexString(start: 4, length: 8))
        self.usageAuthenticationID = purseData.subdata(in: 12..<17).hexString.uppercased()
        self.issueDate = Self.bcdDate(purseData.subdata(in: 17..<21))
        self.expiryDate = Self.bcdDate(purseData.subdata(in: 21..<25))
        self.userCode = purseData[25]
        self.discountRate = purseData[26]
        self.maximumBalance = purseData.bigEndianInt(start: 27, length: 4)
        self.branchCode = purseData.subdata(in: 31..<33).hexString.uppercased()
        self.singleTransactionLimit = purseData.bigEndianInt(start: 33, length: 4)
        self.telecomCode = purseData[37]
        self.creditCompanyCode = purseData[38]
        self.reserved = purseData.subdata(in: 39..<47)
    }

    func resultFields(brand: ICCardBrand) -> [ResultField] {
        let currencyCode = brand.region.currencyCode
        var fields = [
            ResultField(title: "Card Type", value: KSX6924CardType.lookup(cardType)),
            ResultField(title: "Encryption Algorithm", value: KSX6924Algorithm.lookup(algorithm)),
            ResultField(title: "Key Version", value: String(keyVersion)),
            ResultField(title: "Issuer ID", value: issuerDisplay(isUMoney: brand == .umoney)),
            ResultField(title: "Card Usage Authentication ID", value: usageAuthenticationID)
        ]
        if let expiryDate {
            fields.append(ResultField(
                title: "Expiry Date",
                value: KSX6924DateFormatting.formatBCDDateForDisplay(expiryDate) ?? expiryDate
            ))
        }
        fields.append(contentsOf: [
            ResultField(title: "User Category", value: KSX6924UserCode.lookup(userCode)),
            ResultField(title: "Discount Type", value: KSX6924DisRate.lookup(discountRate)),
            ResultField(title: "Maximum Balance", value: formatCurrency(amount: Decimal(maximumBalance), code: currencyCode)),
            ResultField(title: "Branch Code", value: branchCode),
            ResultField(title: "Single Transaction Limit", value: formatCurrency(amount: Decimal(singleTransactionLimit), code: currencyCode)),
            ResultField(title: "Telecom Code", value: auxiliaryCodeDisplay(telecomCode, isUMoney: brand == .umoney, koreanLookup: KSX6924TCode.lookup)),
            ResultField(title: "Credit Company Code", value: auxiliaryCodeDisplay(creditCompanyCode, isUMoney: brand == .umoney, koreanLookup: KSX6924CCode.lookup))
        ])
        return fields
    }

    func rawFields(currencyCode: String, isUMoney: Bool) -> [RawDataField] {
        [
            RawDataField(title: "Raw Payload", value: rawData.hexString.uppercased()),
            RawDataField(title: "Card Type", value: "\(KSX6924CardType.lookup(cardType)) · \(hexByte(cardType))"),
            RawDataField(title: "Encryption Algorithm", value: "\(KSX6924Algorithm.lookup(algorithm)) · \(hexByte(algorithm))"),
            RawDataField(title: "Key Version", value: "\(keyVersion) · \(hexByte(keyVersion))"),
            RawDataField(title: "Issuer ID", value: issuerDisplay(isUMoney: isUMoney)),
            RawDataField(title: "Card Number", value: serial),
            RawDataField(title: "Card Usage Authentication ID", value: usageAuthenticationID),
            RawDataField(title: "Issue Date", value: issueDate ?? "Invalid BCD date"),
            RawDataField(title: "Expiry Date", value: expiryDate ?? "Invalid BCD date"),
            RawDataField(title: "User Category", value: "\(KSX6924UserCode.lookup(userCode)) · \(hexByte(userCode))"),
            RawDataField(title: "Discount Type", value: "\(KSX6924DisRate.lookup(discountRate)) · \(hexByte(discountRate))"),
            RawDataField(title: "Maximum Balance", value: "\(formatCurrency(amount: Decimal(maximumBalance), code: currencyCode)) · \(rawData.subdata(in: 27..<31).hexString.uppercased())"),
            RawDataField(title: "Branch Code", value: branchCode),
            RawDataField(title: "Single Transaction Limit", value: "\(formatCurrency(amount: Decimal(singleTransactionLimit), code: currencyCode)) · \(rawData.subdata(in: 33..<37).hexString.uppercased())"),
            RawDataField(title: "Telecom Code", value: auxiliaryCodeDisplay(telecomCode, isUMoney: isUMoney, koreanLookup: KSX6924TCode.lookup)),
            RawDataField(title: "Credit Company Code", value: auxiliaryCodeDisplay(creditCompanyCode, isUMoney: isUMoney, koreanLookup: KSX6924CCode.lookup)),
            RawDataField(title: "Reserved", value: reserved.hexString.uppercased())
        ]
    }

    private func issuerDisplay(isUMoney: Bool) -> String {
        if isUMoney {
            return hexByte(issuerID)
        }
        return "\(KSX6924IDCenter.lookup(issuerID)) · \(hexByte(issuerID))"
    }

    private func auxiliaryCodeDisplay(
        _ value: UInt8,
        isUMoney: Bool,
        koreanLookup: (UInt8) -> String
    ) -> String {
        if isUMoney, value != 0 {
            return hexByte(value)
        }
        return "\(koreanLookup(value)) · \(hexByte(value))"
    }

    private func hexByte(_ value: UInt8) -> String {
        String(format: "0x%02X", value)
    }

    private static func bcdDate(_ data: Data) -> String? {
        guard data.count == 4,
              data.allSatisfy({ ($0 >> 4) <= 9 && ($0 & 0x0F) <= 9 }) else {
            return nil
        }
        let hex = data.hexString
        return "\(hex.prefix(4))-\(hex.dropFirst(4).prefix(2))-\(hex.suffix(2))"
    }
}

private func formatKoreanCardNumber(_ hex: String) -> String {
    let clean = hex.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in String(clean[clean.index(clean.startIndex, offsetBy: index)..<clean.index(clean.startIndex, offsetBy: index+4)]) }.joined(separator: " ")
}
