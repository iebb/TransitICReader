import Foundation
import CoreNFC
import SQLite3

struct ChineseTransitDecoder: TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        if ["A00000000386980701", TUnionDecoder.applicationAID].contains(iso.initialSelectedAID.uppercased()) { return true }
        if await PBOCApplicationReader.select(iso, aid: "A00000000386980701") != nil { return true }
        return await PBOCApplicationReader.select(iso, aid: TUnionDecoder.applicationAID) != nil
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        var snapshots: [TransitCardSnapshot] = []
        // Both applications belong to this same connected ISO 7816 tag. Each
        // decoder explicitly selects its AID, independently of initialSelectedAID.
        if let local = try? await CityUnionDecoder.decode(tag: tag, scannedAt: scannedAt) { snapshots.append(local) }
        if let national = try? await TUnionDecoder.decode(tag: tag, scannedAt: scannedAt) { snapshots.append(national) }
        guard let result = TransitCardSnapshot.combining(snapshots) else { throw NFCTestError.unsupportedCard }
        return result
    }
}

enum PBOCApplicationReader {
    static func select(_ iso: NFCISO7816Tag, aid: String) async -> Data? {
        await command(iso, cla: 0, ins: 0xA4, p1: 4, p2: 0, data: Data(hexString: aid), length: 256)
    }

    static func command(_ iso: NFCISO7816Tag, cla: UInt8 = 0, ins: UInt8, p1: UInt8, p2: UInt8,
                        data: Data = Data(), length: Int) async -> Data? {
        let apdu = NFCISO7816APDU(instructionClass: cla, instructionCode: ins, p1Parameter: p1,
                                 p2Parameter: p2, data: data, expectedResponseLength: length)
        guard let response = try? await iso.sendCommand(apdu: apdu) else { return nil }
        if response.1 == 0x90 && response.2 == 0 { return response.0 }
        guard response.1 == 0x6C else { return nil }
        let retry = NFCISO7816APDU(instructionClass: cla, instructionCode: ins, p1Parameter: p1,
                                  p2Parameter: p2, data: data, expectedResponseLength: response.2 == 0 ? 256 : Int(response.2))
        guard let corrected = try? await iso.sendCommand(apdu: retry), corrected.1 == 0x90, corrected.2 == 0 else { return nil }
        return corrected.0
    }

    static func binary(_ iso: NFCISO7816Tag, sfi: UInt8, length: Int) async -> Data? {
        await command(iso, ins: 0xB0, p1: 0x80 | sfi, p2: 0, length: length)
    }

    static func records(_ iso: NFCISO7816Tag, sfi: Int, length: Int,
                        kind: TransitApplicationRecord.Kind, indices: [Int] = Array(1...30)) async -> [TransitApplicationRecord] {
        var result: [TransitApplicationRecord] = []
        for index in indices {
            guard let payload = await command(iso, ins: 0xB2, p1: UInt8(index), p2: UInt8((sfi << 3) | 4), length: length),
                  payload.count >= length else { break }
            let data = length == 23 ? Data(payload.prefix(23)) : payload
            let record = TransitApplicationRecord(kind: kind, sfi: sfi, index: index, hex: data.hexString.uppercased())
            if record.hasContent { result.append(record) }
        }
        return result
    }

    static func shanghaiAuxiliary(_ iso: NFCISO7816Tag) async -> [TransitApplicationRecord] {
        var result = await records(iso, sfi: 0x07, length: 16, kind: .auxiliary)
        result += await records(iso, sfi: 0x11, length: 16, kind: .auxiliary, indices: [1, 2])
        result += await records(iso, sfi: 0x14, length: 16, kind: .auxiliary, indices: [4, 5])
        result += await records(iso, sfi: 0x10, length: 16, kind: .auxiliary, indices: [2])
        return result
    }
}

struct CityUnionDecoder: TransitCardDecoder {
    static let applicationAID = "A00000000386980701"
    private static let shanghaiCityCode = 0x2000

    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let selectedAID = iso.initialSelectedAID.uppercased()
        if selectedAID == applicationAID { return true }
        return await selectApplication(iso: iso) != nil
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        let initialSelectedAID = iso.initialSelectedAID.uppercased()
        guard let selectResponse = await selectApplication(iso: iso) else { throw NFCTestError.unsupportedCard }

        var rawSections: [RawDataSection] = [
            RawDataSection(title: "Tag", fields: [
                RawDataField(title: "Technology", value: "ISO7816"),
                RawDataField(title: "UID", value: iso.identifier.hexString),
                RawDataField(title: "Initial Selected AID", value: initialSelectedAID.isEmpty ? "Unavailable" : initialSelectedAID),
                RawDataField(title: "Application AID", value: applicationAID),
                RawDataField(title: "Select SW1SW2", value: String(format: "%02X%02X", selectResponse.1, selectResponse.2))
            ])
        ]

        let balancePayloads = await readBalances(iso: iso)
        let parsedBalance = parseBalance(balancePayloads[0])
        rawSections.append(RawDataSection(
            title: "Balance Registers",
            fields: balancePayloads.sorted { $0.key < $1.key }.map { index, payload in
                RawDataField(title: "Balance \(index)", value: payload.hexString)
            }
        ))

        let cardInfo = await readFile15(iso: iso)
        let metadata = parseCardInfo(cardInfo)
        if let cardInfo {
            rawSections.append(RawDataSection(title: "Card Info File 0x15", fields: [
                RawDataField(title: "Payload", value: cardInfo.hexString),
                RawDataField(title: "City", value: metadata.cityDisplay ?? "Unavailable"),
                RawDataField(title: "Serial", value: metadata.serial ?? "Unavailable")
            ]))
        }

        var resultFields: [ResultField] = [
            ResultField(title: "Brand", value: metadata.cityDisplay ?? "City Union")
        ]
        if let serial = metadata.serial {
            resultFields.append(ResultField(title: "Card Number", value: serial))
        }
        if let city = metadata.cityDisplay {
            resultFields.append(ResultField(title: "Issuing City", value: city))
        }
        if let issue = metadata.issueDate {
            resultFields.append(ResultField(title: "Issue Date", value: issue))
        }
        if let expiry = metadata.expiryDate {
            resultFields.append(ResultField(title: "Expiry Date", value: expiry))
        }

        _ = await selectApplication(iso: iso)
        var records = await PBOCApplicationReader.records(iso, sfi: 0x18, length: 23, kind: .transaction)
        let cityCode = cardInfo.flatMap { $0.count >= 4 ? $0.subdata(in: 2..<4).hexString.uppercased() : nil }
        if cityCode == "2000" {
            records += await PBOCApplicationReader.records(iso, sfi: 0x06, length: 23, kind: .transaction)
            records += await PBOCApplicationReader.records(iso, sfi: 0x10, length: 23, kind: .transaction)
            records += await PBOCApplicationReader.shanghaiAuxiliary(iso)
        }
        let transactionLog = records.filter { $0.kind == .transaction }.map(\.hex)
        let transitHistory = transactionLog.filter(isTransitRecord)
        guard parsedBalance.formatted != nil || cardInfo != nil || !records.isEmpty else { throw NFCTestError.unsupportedCard }

        var snapshot = TransitCardSnapshot(
            technology: "ISO7816",
            cardFamily: "City Union",
            identifierLabel: "UID",
            identifierValue: iso.identifier.hexString,
            rawIdentifierValue: iso.identifier.hexString,
            pmm: nil,
            systemCode: nil,
            selectedAID: applicationAID,
            balanceText: parsedBalance.formatted,
            balanceDetail: parsedBalance.detail,
            realSerialNumber: metadata.serial,
            region: metadata.cityDisplay ?? "City Union",
            resultFields: resultFields,
            rawSections: rawSections + parsedBalance.rawSections,
            rawTransactions: transactionLog,
            rawTransitHistory: transitHistory,
            scannedAt: scannedAt
        )
        snapshot.applications = [TransitApplication(snapshot: snapshot, cityCode: cityCode, records: records)]
        return snapshot
    }

    private static func readBalances(iso: NFCISO7816Tag) async -> [Int: Data] {
        var payloads: [Int: Data] = [:]
        for index in 0...3 {
            let apdu = NFCISO7816APDU(
                instructionClass: 0x80,
                instructionCode: 0x5C,
                p1Parameter: UInt8(index),
                p2Parameter: 0x02,
                data: Data(),
                expectedResponseLength: 4
            )
            if let response = try? await iso.sendCommand(apdu: apdu),
               response.1 == 0x90,
               response.2 == 0x00,
               response.0.count >= 4 {
                payloads[index] = response.0
            }
        }
        return payloads
    }

    private static func selectApplication(iso: NFCISO7816Tag) async -> (Data, UInt8, UInt8)? {
        let selectApdu = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xA4,
            p1Parameter: 0x04,
            p2Parameter: 0x00,
            data: Data(hexString: applicationAID),
            expectedResponseLength: 256
        )
        guard let response = try? await iso.sendCommand(apdu: selectApdu),
              response.1 == 0x90,
              response.2 == 0x00 else {
            return nil
        }
        return response
    }

    private static func readTransactionLog(iso: NFCISO7816Tag) async -> [String] {
        var records: [String] = []
        let p2 = (UInt8(0x18) << 3) | 0x04
        for recordNumber in UInt8(1)...UInt8(30) {
            guard let data = await readRecord(iso: iso, recordNumber: recordNumber, p2: p2) else { break }
            guard data.count >= 23 else { continue }
            guard data.contains(where: { $0 != 0x00 }) else { continue }
            records.append(Data(data.prefix(23)).hexString.uppercased())
        }
        return records
    }

    private static func isTransitRecord(_ raw: String) -> Bool {
        let data = Data(hexString: raw)
        guard data.count >= 23 else { return false }
        switch data[9] {
        case 0x06, 0x09:
            return true
        default:
            return false
        }
    }

    static func decodeTransitRecord(data: Data, index: Int, auxiliary: [TransitApplicationRecord] = []) -> TransitTransaction? {
        guard data.count >= 23 else { return nil }

        // City Union stores China PBOC trip records in file 0x18:
        // 0-1 sequence, 2-4 reserved/overdraft, 5-8 fare, 9 type,
        // 10-15 terminal/station, 16-22 BCD timestamp.
        let amountCents = Int(bigEndianUInt32(data, at: 5))
        let typeByte = data[9]
        let terminalID = data.subdata(in: 10..<16).hexString.uppercased()
        let dateBCD = data.subdata(in: 16..<20).hexString
        let timeBCD = data.subdata(in: 20..<23).hexString
        guard amountCents != 0 || (dateBCD + timeBCD) != "00000000000000" else { return nil }

        let decodedType = decodeTransitType(typeByte)
        let amount = Decimal(amountCents) / 100
        let cityID = String(terminalID.prefix(4))
        let cityName = CityUnionStationDatabase.cityName(cityID)
        let date = CardDateFormatting.parseCompactDateTime(dateBCD + timeBCD, format: "yyyyMMddHHmmss", brand: .tUnion)
        let station = [UInt8(0x06), 0x09].contains(typeByte)
            ? CityUnionStationDatabase.lookup(terminalID: terminalID, date: date) : nil
        let terminalLabel = "Terminal \(terminalID)"
        let place = station?.name ?? terminalLabel
        let location = cityName.map { "\($0) • \(place)" } ?? place
        let directions = Set(auxiliary.compactMap { record -> Bool? in
            let payload = record.data
            guard cityID == "2000", payload.count == 16, payload[0] != 0, payload[1] != 0,
                  payload.subdata(in: 6..<9) == data.subdata(in: 13..<16),
                  payload.subdata(in: 1..<6) == data.subdata(in: 17..<22) else { return nil }
            if record.sfi == 0x11 && record.index == 1 || record.sfi == 0x14 && record.index == 4 { return true }
            if record.sfi == 0x11 && record.index == 2 || record.sfi == 0x14 && record.index == 5 { return false }
            return nil
        })
        let entry = station != nil && directions == [true]
        let exit = station != nil && directions == [false]
        let isBus = station?.type == "BRT" || station?.type == "公交"
        let category: TransactionCategory = entry ? (isBus ? .busOn : .trainOn)
            : exit ? (isBus ? .busOff : .trainOff) : (station != nil && isBus ? .bus : decodedType.category)

        return TransitTransaction(
            date: date,
            time: formatBCDTime(timeBCD),
            amount: decodedType.isCredit ? amount : -amount,
            terminalID: terminalID,
            type: entry ? "Entry" : exit ? "Exit" : decodedType.label,
            category: category,
            balanceAfter: nil,
            location: location,
            entryStation: entry ? station?.name : nil,
            exitStation: exit ? station?.name : nil,
            entryStationCode: entry ? station?.stationKey : nil,
            exitStationCode: exit ? station?.stationKey : nil,
            rawData: data.hexString.uppercased(),
            recordNumber: index + 1
        )
    }

    private static func readFile15(iso: NFCISO7816Tag) async -> Data? {
        if let data = await PBOCApplicationReader.binary(iso, sfi: 0x15, length: 30),
           data.contains(where: { $0 != 0 }) { return data }
        for path in [[0x1001, 0x0015], [0x0015]] {
            if await selectPath(path, iso: iso),
               let data = await readBinary(iso: iso),
               data.contains(where: { $0 != 0x00 }) {
                return data
            }
        }

        let sfiRead = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xB0,
            p1Parameter: 0x80 | 0x15,
            p2Parameter: 0x00,
            data: Data(),
            expectedResponseLength: -1
        )
        if let response = try? await iso.sendCommand(apdu: sfiRead),
           response.1 == 0x90,
           response.2 == 0x00,
           response.0.contains(where: { $0 != 0x00 }) {
            return response.0
        }

        return nil
    }

    private static func selectPath(_ path: [Int], iso: NFCISO7816Tag) async -> Bool {
        for fileID in path {
            let data = Data([UInt8((fileID >> 8) & 0xFF), UInt8(fileID & 0xFF)])
            let apdu = NFCISO7816APDU(
                instructionClass: 0x00,
                instructionCode: 0xA4,
                p1Parameter: 0x00,
                p2Parameter: 0x00,
                data: data,
                expectedResponseLength: 256
            )
            guard let response = try? await iso.sendCommand(apdu: apdu),
                  response.1 == 0x90,
                  response.2 == 0x00 else {
                return false
            }
        }
        return true
    }

    private static func readBinary(iso: NFCISO7816Tag) async -> Data? {
        let apdu = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xB0,
            p1Parameter: 0x00,
            p2Parameter: 0x00,
            data: Data(),
            expectedResponseLength: -1
        )
        guard let response = try? await iso.sendCommand(apdu: apdu) else { return nil }
        if response.1 == 0x90, response.2 == 0x00 { return response.0 }
        if response.1 == 0x6C {
            let retry = NFCISO7816APDU(
                instructionClass: 0x00,
                instructionCode: 0xB0,
                p1Parameter: 0x00,
                p2Parameter: 0x00,
                data: Data(),
                expectedResponseLength: Int(response.2)
            )
            if let retryResponse = try? await iso.sendCommand(apdu: retry),
               retryResponse.1 == 0x90,
               retryResponse.2 == 0x00 {
                return retryResponse.0
            }
        }
        return nil
    }

    private static func readRecord(iso: NFCISO7816Tag, recordNumber: UInt8, p2: UInt8) async -> Data? {
        let apdu = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xB2,
            p1Parameter: recordNumber,
            p2Parameter: p2,
            data: Data(),
            expectedResponseLength: -1
        )
        guard let response = try? await iso.sendCommand(apdu: apdu) else { return nil }
        if response.1 == 0x90, response.2 == 0x00 { return response.0 }
        if response.1 == 0x6C {
            let retry = NFCISO7816APDU(
                instructionClass: 0x00,
                instructionCode: 0xB2,
                p1Parameter: recordNumber,
                p2Parameter: p2,
                data: Data(),
                expectedResponseLength: Int(response.2)
            )
            if let retryResponse = try? await iso.sendCommand(apdu: retry),
               retryResponse.1 == 0x90,
               retryResponse.2 == 0x00 {
                return retryResponse.0
            }
        }
        return nil
    }

    private static func parseBalance(_ payload: Data?) -> (formatted: String?, detail: String, rawSections: [RawDataSection]) {
        guard let payload, payload.count >= 4 else {
            return (nil, "City Union balance register was unavailable.", [])
        }
        let cents = Int(bigEndianUInt32(payload, at: 0) & 0x7FFF_FFFF)
        let amount = Decimal(cents) / 100
        return (
            formatCurrency(amount: amount, code: "CNY", fractionDigits: 2),
            "CNY balance for City Union card.",
            [RawDataSection(title: "Parsed Balance", fields: [
                RawDataField(title: "Balance", value: formatCurrency(amount: amount, code: "CNY", fractionDigits: 2)),
                RawDataField(title: "Raw Cents", value: String(cents))
            ])]
        )
    }

    private static func parseCardInfo(_ data: Data?) -> (serial: String?, cityDisplay: String?, issueDate: String?, expiryDate: String?) {
        guard let data else { return (nil, nil, nil, nil) }
        let cityCode = data.count >= 4 ? Int(bigEndianUInt16(data, at: 2)) : nil
        let cityDisplay = cityCode.map(cityName)
        let serial: String?
        if data.count >= 20 {
            let number = cityCode == shanghaiCityCode
                ? bigEndianUInt32(data, at: 16) : littleEndianUInt32(data, at: 16)
            serial = number == 0 ? nil : String(number)
        } else {
            serial = nil
        }
        let issueDate = data.count >= 24 ? formatBCDDate(data.subdata(in: 20..<24).hexString) : nil
        let expiryDate = data.count >= 28 ? formatBCDDate(data.subdata(in: 24..<28).hexString) : nil
        return (serial, cityDisplay, issueDate, expiryDate)
    }

    private static func cityName(_ code: Int) -> String {
        let hex = String(format: "%04X", code)
        return CityUnionStationDatabase.cityName(hex) ?? "City-Union City \(hex)"
    }

    private static func formatBCDDate(_ bcd: String) -> String? {
        guard bcd.count == 8, bcd != "00000000" else { return nil }
        return "\(bcd.prefix(4))-\(bcd.dropFirst(4).prefix(2))-\(bcd.suffix(2))"
    }

    private static func formatBCDTime(_ bcd: String) -> String? {
        guard bcd.count == 6, bcd != "000000" else { return nil }
        return "\(bcd.prefix(2)):\(bcd.dropFirst(2).prefix(2)):\(bcd.suffix(2))"
    }

    private static func decodeTransitType(_ type: UInt8) -> (label: String, category: TransactionCategory, isCredit: Bool) {
        switch type {
        case 0x02:
            return ("City Union Top-up", .topUp, true)
        case 0x06:
            return ("City Union Transit", .train, false)
        case 0x09:
            return ("City Union Composite Transit", .train, false)
        case 0x04:
            return ("City Union Adjustment", .adjustment, false)
        case 0x05:
            return ("City Union Refund", .refund, true)
        default:
            return ("City Union Transaction \(String(format: "%02X", type))", .unknown, false)
        }
    }

    private static func bigEndianUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return data[offset..<(offset + 2)].reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    private static func bigEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { result, entry in
            result | (UInt32(entry.element) << UInt32(entry.offset * 8))
        }
    }
}

struct TUnionDecoder: TransitCardDecoder {
    static let applicationAID = "A000000632010105"
    static func canDecode(tag: NFCTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        return await PBOCApplicationReader.select(iso, aid: applicationAID) != nil
    }

    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        let selectedAID = applicationAID
        let selectApdu = NFCISO7816APDU(instructionClass: 0x00, instructionCode: 0xA4, p1Parameter: 0x04, p2Parameter: 0x00, data: Data(hexString: selectedAID), expectedResponseLength: 256)
        guard let initialResponse = try? await iso.sendCommand(apdu: selectApdu),
              initialResponse.1 == 0x90, initialResponse.2 == 0 else { throw NFCTestError.unsupportedCard }
        let applicationAID = selectedAID
        let initialSelectResponse = NFCISO7816ResponseAPDU(statusWord1: initialResponse.1, statusWord2: initialResponse.2, payload: initialResponse.0)
        
        print("[TUnion] Decoding. AID=\(applicationAID), Selected=\(selectedAID)")
        
        // T-Union Balance: Probe multiple indices (0x01, 0x02) and handle composite results
        var balancePayloads: [UInt8: Data] = [:]
        
        // Final Strategy: Based on diagnostic logs, Shanghai cards provide:
        // P1=0x00, P2=0x02 -> Primary Purse (32.00)
        // P1=0x01, P2=0x02 -> Negative Balance / Debt (8.00)
        
        print("[TUnion] Reading Primary Purse (P1=00, P2=02)...")
        let apdu00 = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x5C, p1Parameter: 0x00, p2Parameter: 0x02, data: Data(), expectedResponseLength: 4)
        if let resp = try? await iso.sendCommand(apdu: apdu00), resp.1 == 0x90, resp.2 == 0, resp.0.count == 4 {
            balancePayloads[0x02] = resp.0
            print("[TUnion]   Success: \(resp.0.hexString)")
        }

        print("[TUnion] Reading Negative Balance (P1=01, P2=02)...")
        let apdu01 = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x5C, p1Parameter: 0x01, p2Parameter: 0x02, data: Data(), expectedResponseLength: 4)
        if let resp = try? await iso.sendCommand(apdu: apdu01), resp.1 == 0x90, resp.2 == 0, resp.0.count == 4 {
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
        var brandRegion = "T-Union Cities"
        var issuingCity: String?
        var metadataCityCode: String?
        var cardTypeStr: String?
        var issueDateStr: String?
        var expiryDateStr: String?
        
        // Octopus T-Union (嶺南通·八达通) and some others store the CAN in the FCI Tag 9F0C!
        if let fci = initialSelectResponse.payload {
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
                    metadataCityCode = cityId
                    let cityName = TUnionCityDatabase.lookupCityName(for: cityId)
                    issuingCity = cityName ?? "City \(cityId)"
                    print("[TUnion] City ID found: \(cityId) (\(issuingCity ?? "Unknown"))")
                }
                
                // Add App Metadata to raw sections
                rawSections.append(RawDataSection(title: "App Metadata (9F0C)", fields: [
                    RawDataField(title: "Full Payload", value: meta.hexString),
                    RawDataField(
                        title: "Raw City ID",
                        value: meta.count >= 4
                            ? meta.subdata(in: 2..<4).hexString.uppercased()
                            : "Unavailable"
                    )
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
        
        let file15 = await PBOCApplicationReader.binary(iso, sfi: 0x15, length: 30)
        let file17 = await PBOCApplicationReader.binary(iso, sfi: 0x17, length: 60)
        let cityCode = file15.flatMap { $0.count >= 4 ? $0.subdata(in: 2..<4).hexString.uppercased() : nil } ?? metadataCityCode
        for (name, payload) in [("15", file15), ("17", file17)] {
            if let payload { rawSections.append(RawDataSection(title: "File \(name)", fields: [RawDataField(title: "Payload", value: payload.hexString)])) }
        }
        if realSN == nil, let file15, file15.count >= 28 {
            if let number = validateAndCleanCAN(file15.subdata(in: 10..<20).hexString) {
                realSN = number
                brandRegion = TUnionCityDatabase.lookupCardName(for: number) ?? brandRegion
                resultFields.append(ResultField(title: "Card Number", value: formatTUnionCardNumber(number)))
                resultFields.append(ResultField(title: "Brand", value: brandRegion))
            }
        }
        if let cityCode, issuingCity == nil {
            resultFields.append(ResultField(title: "Issuing City", value: TUnionCityDatabase.lookupCityName(for: cityCode) ?? cityCode))
        }
        let extended = NFCISO7816APDU(instructionClass: 0x80, instructionCode: 0x5C, p1Parameter: 5, p2Parameter: 2, data: Data(), expectedResponseLength: 16)
        if let response = try? await iso.sendCommand(apdu: extended), response.1 == 0x90, response.2 == 0, response.0.count == 16 {
            rawSections.append(RawDataSection(title: "Extended Balance", fields: [
                RawDataField(title: "Command", value: "805C050210"),
                RawDataField(title: "Payload", value: response.0.hexString)
            ]))
        }
        var records = await PBOCApplicationReader.records(iso, sfi: 0x18, length: 23, kind: .transaction)
        if cityCode == "2900" {
            records += await PBOCApplicationReader.records(iso, sfi: 0x06, length: 23, kind: .transaction)
            records += await PBOCApplicationReader.shanghaiAuxiliary(iso)
        }
        records += await PBOCApplicationReader.records(iso, sfi: 0x1E, length: 48, kind: .transit)
        let transactions = records.filter { $0.kind == .transaction }.map(\.hex)
        let travelHistory = records.filter { $0.kind == .transit }.map(\.hex)
        guard parsedBalance.formatted != nil || realSN != nil || !records.isEmpty else { throw NFCTestError.unsupportedCard }
        
        var snapshot = TransitCardSnapshot(
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
            rawTransactions: transactions,
            rawTransitHistory: travelHistory,
            scannedAt: scannedAt
        )
        snapshot.applications = [TransitApplication(snapshot: snapshot, cityCode: cityCode, records: records)]
        return snapshot
    }

    private static func readTUnionTransactions(iso: NFCISO7816Tag) async -> [String] {
        var txs: [String] = []
        let p2 = (UInt8(0x18) << 3) | 0x04
        for recNo in UInt8(1)...UInt8(10) {
            guard let data = await readRecord(iso: iso, recordNumber: recNo, p2: p2) else { break }
            guard data.count >= 23 else { continue }
            guard data.contains(where: { $0 != 0x00 }) else { continue }
            txs.append(data.hexString.uppercased())
        }
        return txs
    }

    private static func readTUnionTravelHistory(iso: NFCISO7816Tag) async -> [String] {
        var travels: [String] = []
        let p2 = (UInt8(0x1E) << 3) | 0x04
        for recNo in UInt8(1)...UInt8(30) {
            guard let data = await readRecord(iso: iso, recordNumber: recNo, p2: p2) else { break }
            guard data.count >= 48 else { continue }
            guard data.contains(where: { $0 != 0x00 }) else { continue }
            travels.append(data.hexString.uppercased())
        }
        return travels
    }

    static func decodePBOC(data: Data, index: Int, resolveTUnionTerminals: Bool = true) -> TransitTransaction? {
        guard data.count >= 23 else { return nil }
        // PBOC Transaction Record (standard 23 bytes)
        // 0-1: Counter, 2-4: Overdraft, 5-8: Amount, 9: Type, 10-15: Terminal, 16-19: Date (BCD), 20-22: Time (BCD)
        let amountVal = UInt32(bigEndian: data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self) })
        let typeByte = data[9]
        let dateBCD = data.subdata(in: 16..<20).hexString
        let timeBCD = data.subdata(in: 20..<23).hexString
        let decodedType = decodePBOCType(typeByte)
        
        let amount = Decimal(Int(amountVal)) / 100
        let signedAmount = decodedType.isCredit ? amount : -amount
        
        let dateStr = dateBCD + timeBCD
        let date = CardDateFormatting.parseCompactDateTime(dateStr, format: "yyyyMMddHHmmss", brand: .tUnion)
        let timeString = formatBCDTime(timeBCD)
        let terminalID = data.subdata(in: 10..<16).hexString.uppercased()
        let terminalStation = resolveTUnionTerminals && (typeByte == 0x06 || typeByte == 0x09)
            ? TUnionCityDatabase.lookupTerminalStation(recordKind: "18", terminalID: terminalID)
            : nil
        
        return TransitTransaction(
            date: date,
            time: timeString,
            amount: signedAmount,
            terminalID: terminalID,
            type: decodedType.label,
            category: decodedType.category,
            balanceAfter: nil,
            location: terminalStation.map {
                "\(TUnionCityDatabase.lookupCityName(for: $0.cityID) ?? $0.cityID) • \($0.name)"
            },
            rawData: data.hexString.uppercased(),
            recordNumber: index + 1
        )
    }

    static func decodeTravelRecord(data: Data, index: Int) -> TransitTransaction? {
        guard data.count >= 48 else { return nil }

        let typeByte = data[0]
        let terminalID = data.subdata(in: 1..<9).hexString.uppercased()
        let subType = data[9]
        let stationID = data.subdata(in: 10..<17).hexString.uppercased()
        let amountVal = UInt32(bigEndian: data.subdata(in: 17..<21).withUnsafeBytes { $0.load(as: UInt32.self) })
        let balanceVal = UInt32(bigEndian: data.subdata(in: 21..<25).withUnsafeBytes { $0.load(as: UInt32.self) })
        let dateBCD = data.subdata(in: 25..<32).hexString
        let cityID = data.subdata(in: 32..<34).hexString.uppercased()

        let date = CardDateFormatting.parseCompactDateTime(dateBCD, format: "yyyyMMddHHmmss", brand: .tUnion)

        let locationPrefix = TUnionCityDatabase.lookupCityName(for: cityID) ?? "City \(cityID)"
        let station = TUnionCityDatabase.lookupTravelStation(cityID: cityID, stationID: stationID, terminalID: terminalID)
        let stationLabel = station?.name ?? "Station \(stationID)"
        let resolvedStationKey = station?.stationKey ?? (station == nil ? cityID + stationID : nil)
        let location = "\(locationPrefix) • \(stationLabel)"
        let amount = Decimal(Int(amountVal)) / 100
        let balance = Decimal(Int(balanceVal)) / 100

        let kind = decodeTravelType(typeByte: typeByte, subType: subType)

        return TransitTransaction(
            date: date,
            time: formatBCDTime(String(dateBCD.suffix(6))),
            amount: kind.isCredit ? amount : -amount,
            terminalID: terminalID,
            type: kind.label,
            category: kind.category,
            balanceAfter: balance,
            location: location,
            entryStation: kind.isEntry ? stationLabel : nil,
            exitStation: kind.isExit ? stationLabel : nil,
            entryStationCode: kind.isEntry ? resolvedStationKey : nil,
            exitStationCode: kind.isExit ? resolvedStationKey : nil,
            rawData: data.hexString.uppercased(),
            recordNumber: index + 1
        )
    }

    private static func readRecord(iso: NFCISO7816Tag, recordNumber: UInt8, p2: UInt8) async -> Data? {
        let baseAPDU = NFCISO7816APDU(
            instructionClass: 0x00,
            instructionCode: 0xB2,
            p1Parameter: recordNumber,
            p2Parameter: p2,
            data: Data(),
            expectedResponseLength: -1
        )

        guard let resp = try? await iso.sendCommand(apdu: baseAPDU) else { return nil }
        if resp.1 == 0x90 { return resp.0 }

        // Some cards reply with 6Cxx to request a specific Le for READ RECORD.
        if resp.1 == 0x6C {
            let retryAPDU = NFCISO7816APDU(
                instructionClass: 0x00,
                instructionCode: 0xB2,
                p1Parameter: recordNumber,
                p2Parameter: p2,
                data: Data(),
                expectedResponseLength: Int(resp.2)
            )
            if let retry = try? await iso.sendCommand(apdu: retryAPDU), retry.1 == 0x90 {
                return retry.0
            }
        }

        return nil
    }

    private static func decodePBOCType(_ type: UInt8) -> (label: String, category: TransactionCategory, isCredit: Bool) {
        switch type {
        case 0x02:
            return ("Top-up", .topUp, true)
        case 0x06:
            return ("Single Purchase", .purchase, false)
        case 0x09:
            return ("Compound Purchase", .purchase, false)
        case 0x04:
            return ("Adjustment", .adjustment, false)
        case 0x05:
            return ("Cash Withdrawal", .refund, true)
        default:
            return ("Transaction \(String(format: "%02X", type))", .unknown, false)
        }
    }

    private static func decodeTravelType(typeByte: UInt8, subType: UInt8) -> (label: String, category: TransactionCategory, isCredit: Bool, isEntry: Bool, isExit: Bool) {
        switch typeByte {
        case 0x03:
            return (subType == 0x02 ? "Bus Boarding" : "Entry", subType == 0x02 ? .busOn : .trainOn, false, true, false)
        case 0x04:
            return (subType == 0x02 ? "Bus Exit" : "Exit", subType == 0x02 ? .busOff : .trainOff, false, false, true)
        case 0x02, 0x06:
            return (subType == 0x02 ? "Bus Trip" : "Transit Trip", subType == 0x02 ? .bus : .train, false, false, false)
        default:
            return ("Travel \(String(format: "%02X", typeByte))", .unknown, false, false, false)
        }
    }

    private static func formatBCDTime(_ bcd: String) -> String? {
        guard bcd.count == 6 else { return nil }
        let hh = bcd.prefix(2)
        let mm = bcd.dropFirst(2).prefix(2)
        let ss = bcd.suffix(2)
        return "\(hh):\(mm):\(ss)"
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
    
    private static func parseTUnionBalances(_ payloads: [UInt8: Data]) -> (formatted: String?, rawSections: [RawDataSection]) {
        guard payloads[0x02]?.count == 4 else { return (nil, []) }
        var registerFields: [RawDataField] = []
        
        // Extract Purse (P1=0x00, P2=0x02)
        let purse: UInt32 = payloads[0x02].flatMap { d in
             guard d.count >= 4 else { return nil }
             return UInt32(bigEndian: d.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) })
        } ?? 0
        
        // Extract Debt (P1=0x01, P2=0x02) stored in virtual index 0x82
        let debt: UInt32 = payloads[0x82].flatMap { d in
             guard d.count >= 4 else { return nil }
             return UInt32(bigEndian: d.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) })
        } ?? 0

        // Rule: Final = Purse - Debt
        let selectedCents = Int(purse) - Int(debt)
        
        registerFields.append(RawDataField(title: "Balance 0", value: "\(Double(purse)/100.0) CNY"))
        registerFields.append(RawDataField(title: "Balance 1", value: "\(Double(debt)/100.0) CNY"))
        registerFields.append(RawDataField(title: "Final Balance (B0 - B1)", value: "\(Double(selectedCents)/100.0) CNY"))
        
        let amount = Double(selectedCents) / 100.0
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
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

enum CityUnionStationDatabase {
    struct Station {
        let prefix: String
        let name: String
        let line: String
        let type: String
        let stationKey: String?
    }

    private static let stations: [Station] = {
        guard let url = Bundle.main.url(forResource: "cardbal_transit", withExtension: "sqlite") else { return [] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return []
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT terminal_prefix, station_name, line_name, station_type, station_key FROM cityunion_terminal_prefixes ORDER BY length(terminal_prefix) DESC, terminal_prefix"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        var result: [Station] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func value(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            guard let prefix = value(0), let name = value(1), let line = value(2), let type = value(3) else { continue }
            result.append(Station(prefix: prefix, name: name, line: line, type: type, stationKey: value(4)))
        }
        return result
    }()

    static func cityName(_ code: String) -> String? { code == "2000" ? "上海市" : nil }

    static func lookup(terminalID: String, date: Date?) -> Station? {
        let terminal = terminalID.uppercased()
        guard terminal.count == 12, terminal.allSatisfy(\.isHexDigit), terminal.hasPrefix("2000"),
              let date, date.timeIntervalSince1970 >= 1_483_200_000 else { return nil }
        // Before 2017 some Shanghai buses reused metro terminal numbers.
        return stations.first { terminal.hasPrefix($0.prefix) }
    }
}

struct TUnionCityDatabase {
    struct StationMatch {
        let cityID: String
        let name: String
        let stationKey: String?
    }

    private static let terminalStations: [String: [StationMatch]] = {
        guard let url = Bundle.main.url(forResource: "cardbal_transit", withExtension: "sqlite") else { return [:] }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT record_kind, city_id, terminal_code, station_name, station_key FROM tunion_terminal_stations"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return [:]
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: [StationMatch]] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let kind = sqlite3_column_text(statement, 0),
                  let city = sqlite3_column_text(statement, 1),
                  let terminal = sqlite3_column_text(statement, 2),
                  let name = sqlite3_column_text(statement, 3) else { return [:] }
            let key = "\(String(cString: kind)):\(String(cString: terminal))"
            result[key, default: []].append(StationMatch(
                cityID: String(cString: city), name: String(cString: name),
                stationKey: sqlite3_column_text(statement, 4).map { String(cString: $0) }
            ))
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? result : [:]
    }()

    static func lookupTerminalStation(recordKind: String, terminalID: String, cityID: String? = nil) -> StationMatch? {
        let terminal = terminalID.uppercased()
        guard terminal.count == (recordKind == "18" ? 12 : 16),
              terminal.allSatisfy({ $0.isHexDigit }) else { return nil }
        let matches = (terminalStations["\(recordKind):\(terminal)"] ?? []).filter {
            cityID == nil || $0.cityID == cityID?.uppercased()
        }
        // A PBOC record has no city field: only a globally unambiguous exact ID
        // is usable. Never apply station-prefix matching to terminal numbers.
        return matches.count == 1 ? matches[0] : nil
    }

    static func lookupTravelStation(cityID: String, stationID: String, terminalID: String) -> StationMatch? {
        if let key = lookupStationKey(cityID: cityID, stationID: stationID), let name = lineStations[key] {
            return StationMatch(cityID: cityID, name: name, stationKey: key)
        }
        if let station = lookupTerminalStation(recordKind: "1e", terminalID: terminalID, cityID: cityID) {
            return station
        }
        if terminalID.count == 16, terminalID.hasPrefix("0000") {
            return lookupTerminalStation(recordKind: "18", terminalID: String(terminalID.suffix(12)), cityID: cityID)
        }
        return nil
    }

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

    private static let reviewedCityCodeDisplayNames: [String: String] = {
        guard let url = Bundle.main.url(
            forResource: "cardbal_transit",
            withExtension: "sqlite"
        ) else {
            return [:]
        }
        let escapedPath = url.path.replacingOccurrences(of: "?", with: "%3F")
        let sqliteURI = "file:\(escapedPath)?mode=ro&immutable=1"
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            sqliteURI,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
            nil
        ) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }

        let query = """
            SELECT code, display_name
            FROM city_identifiers
            WHERE namespace IN ('cn.tunion.city_code', 'cn.tunion.city_alias')
              AND display_name IS NOT NULL
            UNION ALL
            SELECT code, display_name
            FROM province_identifiers
            WHERE namespace = 'cn.tunion.province_only_city_code'
              AND display_name IS NOT NULL
            ORDER BY code;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var names: [String: String] = [:]
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let codeText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1) else { return [:] }
            let code = String(cString: codeText)
            let name = String(cString: nameText)
            guard names.updateValue(name, forKey: code) == nil else { return [:] }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE, names.count == 62 else { return [:] }
        return names
    }()

    private static let lineStations: [String: String] = {
        guard let url = Bundle.main.url(forResource: "TUnionLineStations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }()
    
    private static let sortedEntries: [(prefix: String, name: String)] = {
        cardNames.map { (prefix: $0.key, name: $0.value) }.sorted { $0.prefix.count > $1.prefix.count }
    }()

    private static let sortedStationEntries: [(key: String, name: String)] = {
        lineStations.map { (key: $0.key.uppercased(), name: $0.value) }.sorted { lhs, rhs in
            if lhs.key.count != rhs.key.count { return lhs.key.count > rhs.key.count }
            return lhs.key < rhs.key
        }
    }()

    static func lookupCardName(for value: String) -> String? {
        for entry in sortedEntries {
            if value.hasPrefix(entry.prefix) { return entry.name }
        }
        return nil
    }
    
    static func lookupCityName(for cityId: String) -> String? {
        cityCodes[cityId] ?? reviewedCityCodeDisplayNames[cityId]
    }

    static func lookupStationName(cityID: String, stationID: String) -> String? {
        lookupStationKey(cityID: cityID, stationID: stationID).flatMap { lineStations[$0] }
    }

    static func lookupStationKey(cityID: String, stationID: String) -> String? {
        let normalizedCityID = cityID.uppercased()
        let normalizedStationID = stationID.uppercased()
        let combined = normalizedCityID + normalizedStationID

        for entry in sortedStationEntries where combined.hasPrefix(entry.key) {
            return entry.key
        }

        return nil
    }
}
