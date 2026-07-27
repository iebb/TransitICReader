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
        
        let profile = KSX6924CardProfile.matching(aid: applicationAID)
        let purseInfo = KSX6924PurseInfo(fciPayload: initialSelectResponse.payload ?? Data())
        let parsedCardInfo = KSX6924CardInfo(payload: infoResponse?.0 ?? Data(), purseInfo: purseInfo, configInfo: configInfo)
        
        let parsedBalance = profile.parseBalance(balanceResponse.0)
        
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
        
        if let purseRaw = parsedCardInfo.purseInfoRawFields {
            rawSections.append(RawDataSection(title: "Purse Info (Tag B0)", fields: purseRaw))
        }

        var familyName = profile.displayName // e.g. "T-money", "EZL / Cashbee"
        var brandName = familyName
        var balanceText = parsedBalance.formatted
        var balanceDetail = parsedBalance.detail
        
        if let type = parsedCardInfo.purseInfo?.cardType, (type & 0xB0) == 0xB0 {
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
            resultFields: parsedCardInfo.resultFields,
            rawSections: rawSections,
            rawTransactions: transactions,
            rawTransitHistory: transitHistory,
            scannedAt: scannedAt
        )
    }

    static func parseSingleTransaction(_ block: Data, sfi: UInt8, recordIndex: Int, isNAMANE: Bool, logger: os.Logger) -> TransitTransaction? {
        if block.allSatisfy({ $0 == 0x00 }) || block.allSatisfy({ $0 == 0xFF }) { return nil }
        
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
                            brand: .tmoney
                        )
                        displayTime = String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
                    }
                }
            }
            
            return TransitTransaction(date: foundDate, time: displayTime, amount: signedAmount, terminalID: idsam ?? block.prefix(2).hexString, type: typeStr, balanceAfter: balance, rawData: block.hexString, recordNumber: Int(ntep), ntsam: ntsam)
        }
        return nil
    }

    static func parseTransitHistory(_ block: Data, sfi: UInt8, recordIndex: Int, isNAMANE: Bool, logger: os.Logger) -> TransitTransaction? {
        logger.error("[KSX6924_TH] Parsing Record \(recordIndex) from SFI \(sfi): \(block.hexString)")
        if block.allSatisfy({ $0 == 0x00 }) || block.allSatisfy({ $0 == 0xFF }) { 
            return nil 
        }
        // T-money SFI 3 Transit Record (52 bytes)
        if block.count >= 52 {
            let record = block.count == 52 ? block : block.subdata(in: 0..<52)
            let tripState = record[2]
            let fareLayout = KoreanTransitHistoryFareLayout.decode(record)
            let timestamp = KoreanTransitTimestampDecoder.decode(record)
            let distanceM = record.bigEndianInt(start: 19, length: 2)
            let stationToken = record.subdata(in: 5..<9).hexString.uppercased()
            let transportModeHex = record.subdata(in: 9..<11).hexString.uppercased()
            let transportModeCode = record.bigEndianInt(start: 9, length: 2)
            let locationCode = stationToken + transportModeHex
            let transportMode = KOTRISTransportModeCatalog.bundled?.mode(for: transportModeCode)
            let stationAlias = KoreanStationAliasCatalog.bundled?.location(
                for: locationCode,
                eventRaw: Int(tripState)
            )
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
                            brand: .tmoney
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
    let primaryAmount: Int
    let primaryAmountHex: String
    let regionalAmount: Int
    let regionalAmountHex: String
    let baseFare: Int
    let baseFareHex: String

    static func decode(_ data: Data) -> KoreanTransitHistoryFareLayout? {
        guard data.count >= 42 else { return nil }

        let primaryAmount = data.bigEndianInt(start: 22, length: 2)
        let regionalAmount = data.bigEndianInt(start: 36, length: 2)
        let baseFare = data.bigEndianInt(start: 40, length: 2)

        let primary = (Variant.primary22, primaryAmount, data.subdata(in: 22..<24).hexString.uppercased())
        let regional = (Variant.regional36, regionalAmount, data.subdata(in: 36..<38).hexString.uppercased())
        let base = (Variant.base40, baseFare, data.subdata(in: 40..<42).hexString.uppercased())
        let profile = KoreanTransitOperatorFieldProfile.forRecord(data)
        let candidates = profile?.usesOpaqueCounters == true
            ? [base, regional, primary]
            : [primary, base, regional]
        let selection = candidates.first { isPlausibleFare($0.1) }

        return KoreanTransitHistoryFareLayout(
            variant: selection?.0 ?? .unresolved,
            selectedAmount: selection?.1,
            selectedAmountHex: selection?.2,
            primaryAmount: primaryAmount,
            primaryAmountHex: data.subdata(in: 22..<24).hexString.uppercased(),
            regionalAmount: regionalAmount,
            regionalAmountHex: data.subdata(in: 36..<38).hexString.uppercased(),
            baseFare: baseFare,
            baseFareHex: data.subdata(in: 40..<42).hexString.uppercased()
        )
    }

    private static func isPlausibleFare(_ value: Int) -> Bool {
        (1...10_000).contains(value)
    }

    var variantDisplayName: String {
        switch variant {
        case .primary22:
            return NSLocalizedString("korean_fare_layout_primary22", comment: "Korean transit fare stored at bytes 22-23")
        case .regional36:
            return NSLocalizedString("korean_fare_layout_regional36", comment: "Korean transit fare stored at bytes 36-37")
        case .base40:
            return NSLocalizedString("korean_fare_layout_base40", comment: "Korean transit fare stored at bytes 40-41")
        case .unresolved:
            return NSLocalizedString("korean_fare_layout_unresolved", comment: "Korean transit fare layout is unresolved")
        }
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
    guard data.count >= 4 else { return ParsedBalance(formatted: "Error", detail: "Short data", rawFields: []) }
    let balance = data.bigEndianInt(start: 0, length: 4)
    return ParsedBalance(
        formatted: formatCurrency(amount: Decimal(balance), code: "KRW", fractionDigits: 0),
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
    let purseInfoFields: [ResultField]?
    let purseInfoRawFields: [RawDataField]?
    let purseInfo: KSX6924PurseInfo?
    init(payload: Data, purseInfo: KSX6924PurseInfo?, configInfo: KSX6924ConfigDFInfo?) {
        self.purseInfo = purseInfo
        self.cardNumber = purseInfo?.serial ?? configInfo?.serial ?? (payload.count >= 16 ? formatKoreanCardNumber(payload.sliceHexString(start: 8, length: 8)) : nil)
        self.issueDate = purseInfo?.issueDate ?? (payload.count >= 25 ? Self.formatIssueDate(payload.subdata(in: 21..<25)) : nil)
        self.purseInfoFields = purseInfo?.resultFields
        self.purseInfoRawFields = purseInfo?.purseInfoRawFields
    }
    var resultFields: [ResultField] {
        var fields: [ResultField] = []
        if let cardNumber { fields.append(ResultField(title: "Card Number", value: cardNumber)) }
        if let issueDate { fields.append(ResultField(title: "Issue Date", value: KSX6924DateFormatting.formatBCDDateForDisplay(issueDate) ?? issueDate)) }
        if let purseInfoFields { fields.append(contentsOf: purseInfoFields) }
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
    let cardType: UInt8?
    let issueDate: String?
    init?(fciPayload: Data) {
        guard let purseData = findTLVValue(tag: [0xB0], in: fciPayload), purseData.count >= 21 else { return nil }
        self.rawData = purseData
        self.cardType = purseData[0]
        self.serial = formatKoreanCardNumber(purseData.sliceHexString(start: 4, length: 8))
        let dateHex = purseData.subdata(in: 17..<21).hexString
        self.issueDate = "\(dateHex.prefix(4))-\(dateHex.dropFirst(4).prefix(2))-\(dateHex.suffix(2))"
    }
    var resultFields: [ResultField] {
        var fields: [ResultField] = []
        if let cardType { fields.append(ResultField(title: "Card Type", value: KSX6924CardType.lookup(cardType))) }
        return fields
    }
    var purseInfoRawFields: [RawDataField]? { [RawDataField(title: "Raw Payload", value: rawData.hexString)] }
}

private func formatKoreanCardNumber(_ hex: String) -> String {
    let clean = hex.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in String(clean[clean.index(clean.startIndex, offsetBy: index)..<clean.index(clean.startIndex, offsetBy: index+4)]) }.joined(separator: " ")
}
