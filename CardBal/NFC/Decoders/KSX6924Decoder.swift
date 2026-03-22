import Foundation
import CoreNFC

struct KSX6924Decoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let aid = iso.initialSelectedAID
        return aid.hasPrefix("A0000000014B4F52") || aid == "A0000004520001" || aid.hasPrefix("D4100000") || aid.hasPrefix("D41065")
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        let selectedAID = iso.initialSelectedAID
        
        let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: selectedAID), expectedResponseLength: 256)
        let initialResponse = try? await iso.sendCommand(apdu: selectApdu)
        let initialSelectResponse = initialResponse.map { NFCISO7816ResponseAPDU(statusWord1: $0.1, statusWord2: $0.2, payload: $0.0) }
        
        let configInfo = initialSelectResponse.flatMap { KSX6924ConfigDFInfo(fciPayload: $0.payload ?? Data(), selectedAID: selectedAID) }
        let applicationAID = configInfo?.mainApplicationAID ?? selectedAID
        
        if applicationAID != selectedAID {
            let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: applicationAID), expectedResponseLength: 256)
            _ = try? await iso.sendCommand(apdu: selectApdu)
        }
        
        let balanceApdu = NFCISO7816APDU(instructionClass: 0x90, instructionCode: 0x4C, p1Parameter: 0x00, p2Parameter: 0x00, data: Data(), expectedResponseLength: 4)
        let balanceResponse = try await iso.sendCommand(apdu: balanceApdu)
        
        let infoApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xB2, p1Parameter: 0x01, p2Parameter: 0x0C, data: Data(), expectedResponseLength: 256)
        let infoResponse = try? await iso.sendCommand(apdu: infoApdu)
        
        let profile = KSX6924CardProfile.matching(aid: applicationAID)
        let purseInfo = (initialSelectResponse?.payload).flatMap { KSX6924PurseInfo(fciPayload: $0) }
        let parsedCardInfo = KSX6924CardInfo(payload: infoResponse?.0 ?? Data(), purseInfo: purseInfo, configInfo: configInfo)
        
        let parsedBalance = profile.parseBalance(balanceResponse.0)
        
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

        return TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: profile.displayName,
            identifierLabel: "UID",
            identifierValue: iso.identifier.hexString,
            rawIdentifierValue: iso.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: parsedBalance?.formatted,
            balanceDetail: parsedBalance?.detail,
            realSerialNumber: parsedCardInfo.cardNumber,
            region: nil,
            resultFields: parsedCardInfo.resultFields,
            rawSections: rawSections,
            scannedAt: scannedAt
        )
    }
}

private struct KSX6924CardProfile {
    let displayName: String
    let aid: String
    let parseBalance: (Data) -> ParsedBalance?

    static func matching(aid: String) -> KSX6924CardProfile {
        let normalized = aid.uppercased()
        
        // Climate Card (Gi-hu-dong-haeng)
        if normalized == "D4100000030006" {
            return KSX6924CardProfile(displayName: "Climate Card", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        
        if normalized.hasPrefix("D410000003") {
            return KSX6924CardProfile(displayName: "T-money", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410000014") {
            return KSX6924CardProfile(displayName: "EZL / Cashbee", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410000029") {
            return KSX6924CardProfile(displayName: "NAMANE", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410000030") {
            return KSX6924CardProfile(displayName: "MOIBA", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        if normalized.hasPrefix("D410650990") {
            return KSX6924CardProfile(displayName: "K-Cash", aid: normalized, parseBalance: ksx6924BalanceParser)
        }
        
        return KSX6924CardProfile(displayName: "KS X 6924", aid: normalized, parseBalance: ksx6924BalanceParser)
    }
}

private func ksx6924BalanceParser(data: Data) -> ParsedBalance? {
    guard data.count >= 4 else { return nil }
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
    
    init(payload: Data, purseInfo: KSX6924PurseInfo?, configInfo: KSX6924ConfigDFInfo?) {
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
    return stride(from: 0, to: 16, by: 4).map { index in
        let start = clean.index(clean.startIndex, offsetBy: index)
        let end = clean.index(start, offsetBy: 4)
        return String(clean[start..<end])
    }.joined(separator: " ")
}

extension Data {
    init(hexString: String) {
        var data = Data()
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count % 2 != 0 { text = "0" + text }
        var status = text.startIndex
        while status < text.endIndex {
            let nextIndex = text.index(status, offsetBy: 2)
            if let byte = UInt8(text[status..<nextIndex], radix: 16) { data.append(byte) }
            status = nextIndex
        }
        self = data
    }
}
