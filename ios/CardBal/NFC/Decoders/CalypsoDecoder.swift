import Foundation

struct CalypsoDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        let aid = iso.initialSelectedAID.uppercased()
        if CalypsoCardProfile.matches(aid: aid) || CalypsoProtocol.selectionAIDs.contains(aid) { return true }
        return await CalypsoProtocol.canSelect { command in
            guard let apdu = CardAPDU(data: command) else { throw NFCTestError.unsupportedCard }
            return try await iso.sendCommand(apdu: apdu)
        }
    }

    /// True when the phone opened a Calypso application while finding the card.
    /// The reader then tries Calypso before decoders that open other applications.
    static func isPreselected(_ tag: CardTag) -> Bool {
        guard case .iso7816(let iso) = tag else { return false }
        return CalypsoCardProfile.matches(aid: iso.initialSelectedAID)
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .iso7816(let iso) = tag else { throw NFCTestError.unsupportedCard }
        let initialAID = iso.initialSelectedAID.uppercased()
        DebugLog.shared.log("Calypso", "Opened application " + (initialAID.isEmpty ? "none" : initialAID))
        // La Carte (Lignes d'Azur) is read first, while the application the phone
        // opened is still selected. This is the reader the iPhone used before the
        // shared public-record reader replaced it.
        var niceCard: (snapshot: TransitCardSnapshot, hasRecords: Bool)?
        if initialAID.hasPrefix(NiceCalypsoReader.applicationAID) {
            ScanProgress.report(.details)
            niceCard = await NiceCalypsoReader.read(iso, scannedAt: scannedAt)
        }
        let publicRead = await CalypsoProtocol.read(initialAID: iso.initialSelectedAID, exchange: { command in
            guard let apdu = CardAPDU(data: command) else { throw NFCTestError.unsupportedCard }
            return try await iso.sendCommand(apdu: apdu)
        }, progress: { sfi in
            switch sfi {
            case 2, 9: ScanProgress.report(.details)
            case 8: ScanProgress.report(.transactions)
            case 10: ScanProgress.report(.balance)
            default: break
            }
        })
        if let publicRead {
            DebugLog.shared.log("Calypso", "Public records: network \(publicRead.network), \(publicRead.records.count) records, "
                                + "\(publicRead.contracts.count) contracts" + (publicRead.hasDecodedData ? "" : ", nothing decodable"))
        } else {
            DebugLog.shared.log("Calypso", "Public records: no environment record could be read")
        }
        if let niceCard {
            // A positively identified named network keeps its own reader's result,
            // as does the public reader when the Nice records gave nothing.
            if let publicRead, publicRead.hasDecodedData,
               ![.generic, .intercode].contains(publicRead.network) || !niceCard.hasRecords {
                return publicSnapshot(publicRead, iso: iso, scannedAt: scannedAt)
            }
            // As before 2.5.0, La Carte is always shown, with its raw replies,
            // even when no record could be read.
            return niceCard.snapshot
        }
        guard let publicRead, publicRead.hasDecodedData else { throw NFCTestError.unsupportedCard }
        return publicSnapshot(publicRead, iso: iso, scannedAt: scannedAt)
    }

    private static func publicSnapshot(_ result: CalypsoProtocol.ReadResult, iso: any ISO7816Card, scannedAt: Date) -> TransitCardSnapshot {
        let uid = iso.identifier.hexString
        let uidSerial = iso.identifier.count <= 8
            ? String(iso.identifier.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }) : nil
        let serial = result.serial ?? uidSerial
        var fields = result.fields.map { ResultField(title: $0.0, value: $0.1) }
        if let serial { fields.insert(ResultField(title: "Card Number", value: serial), at: 0) }
        let records = result.records.map { record in
            RawDataSection(title: String(format: "Calypso SFI %02X Record %d", record.sfi, record.number), fields: [
                RawDataField(title: "Payload", value: record.payload.hexString),
                RawDataField(title: "SW1SW2", value: "9000")
            ])
        }
        return TransitCardSnapshot(
            technology: "ISO7816", cardFamily: result.family, identifierLabel: "UID", identifierValue: uid,
            rawIdentifierValue: uid, pmm: nil, systemCode: nil, selectedAID: result.selectedAID,
            balanceText: result.balanceText, balanceDetail: result.network == .generic ? "Public Calypso records; network not identified" : "Public contracts and travel records",
            realSerialNumber: serial, region: result.family, resultFields: fields,
            rawSections: [RawDataSection(title: "Application", fields: [RawDataField(title: "AID", value: result.selectedAID)])] + records,
            rawTransactions: result.rawHistories, rawTransitHistory: [], scannedAt: scannedAt
        )
    }
}

/// La Carte, the Lignes d'Azur card of Nice. Restores the iPhone reader that
/// worked with the physical card before 2.5.0: Core NFC has already selected
/// 1TIC.ICA, so it selects the ticketing directory and reads the Nice records
/// with the Calypso class byte, without selecting the application again.
/// Read-only: SELECT and READ RECORD only, no keys, no secure session.
enum NiceCalypsoReader {
    static let applicationAID = "315449432E494341"

    private struct Probe {
        let title: String; let sfi: UInt8; let record: UInt8
        var command: Data { Data([0x94, 0xB2, record, (sfi << 3) | 0x04, 0x1D]) }
    }
    private struct Reply {
        let payload: Data; let sw1: UInt8; let sw2: UInt8
        var ok: Bool { sw1 == 0x90 && sw2 == 0 }
        var hasData: Bool { ok && !payload.isEmpty && !payload.allSatisfy { $0 == 0 } }
        var status: String { String(format: "%02X%02X", sw1, sw2) }
    }
    private static let probes: [Probe] = [
        Probe(title: "Environment Record", sfi: 0x07, record: 1),
        Probe(title: "Best Contracts", sfi: 0x1E, record: 1),
        Probe(title: "Event Record 1", sfi: 0x08, record: 1),
        Probe(title: "Contract Summary Record 1", sfi: 0x09, record: 1),
        Probe(title: "Ticket Detail Record 1", sfi: 0x0A, record: 1),
        Probe(title: "Contract Summary Record 2", sfi: 0x09, record: 2),
        Probe(title: "Ticket Detail Record 2", sfi: 0x0A, record: 2),
        Probe(title: "Contract Summary Record 3", sfi: 0x09, record: 3),
        Probe(title: "Ticket Detail Record 3", sfi: 0x0A, record: 3),
        Probe(title: "Contract Summary Record 4", sfi: 0x09, record: 4),
        Probe(title: "Ticket Detail Record 4", sfi: 0x0A, record: 4)
    ]

    /// Sends one command; a 6Cxx reply is retried once with the length the card asked for.
    private static func send(_ command: Data, to iso: any ISO7816Card) async -> Reply {
        guard let apdu = CardAPDU(data: command), let first = try? await iso.sendCommand(apdu: apdu) else {
            return Reply(payload: Data(), sw1: 0, sw2: 0)
        }
        if first.1 == 0x6C {
            var retry = command; retry[retry.count - 1] = first.2
            if let apdu = CardAPDU(data: retry), let second = try? await iso.sendCommand(apdu: apdu) {
                return Reply(payload: second.0, sw1: second.1, sw2: second.2)
            }
        }
        return Reply(payload: first.0, sw1: first.1, sw2: first.2)
    }

    /// `hasRecords` is false when the card answered none of the Nice records.
    static func read(_ iso: any ISO7816Card, scannedAt: Date) async -> (snapshot: TransitCardSnapshot, hasRecords: Bool) {
        let directory = await send(Data([0x94, 0xA4, 0x08, 0x00, 0x02, 0x20, 0x00]), to: iso)
        var replies: [String: Reply] = [:]
        var sections = [RawDataSection(title: "Identification", fields: [
            RawDataField(title: "Technology", value: "ISO7816"),
            RawDataField(title: "UID", value: iso.identifier.hexString),
            RawDataField(title: "Application AID", value: applicationAID),
            RawDataField(title: "Application Data", value: iso.applicationData?.hexString ?? "Unavailable")
        ]), RawDataSection(title: "Ticketing Directory", fields: [
            RawDataField(title: "Command", value: "94A4080002 2000"),
            RawDataField(title: "SW1SW2", value: directory.status)
        ])]
        for probe in probes {
            let reply = await send(probe.command, to: iso)
            replies[probe.title] = reply
            sections.append(RawDataSection(title: probe.title, fields: [
                RawDataField(title: "Command", value: probe.command.hexString),
                RawDataField(title: "Response Payload", value: reply.payload.hexString),
                RawDataField(title: "SW1SW2", value: reply.status)
            ]))
        }
        DebugLog.shared.log("Calypso", "La Carte records: directory \(directory.status), "
            + probes.map { "\($0.title) \(replies[$0.title]?.status ?? "-")" }.joined(separator: ", "))
        let hasRecords = replies.values.contains(where: \.hasData)

        let bestContracts = NiceRecords.bestContracts(replies["Best Contracts"].flatMap { $0.ok ? $0.payload : nil } ?? Data())
        var contracts: [Int: NiceRecords.Contract] = [:]
        var tickets: [Int: Int] = [:]
        for slot in 1...4 {
            if let reply = replies["Contract Summary Record \(slot)"], reply.hasData {
                let best = bestContracts.first { $0.pointer == slot || $0.index == slot }
                    ?? NiceRecords.BestContract(index: slot, structure: "Unknown", pointer: slot)
                contracts[slot] = NiceRecords.contract(reply.payload, best: best)
            }
            if let reply = replies["Ticket Detail Record \(slot)"], reply.hasData, reply.payload.count >= 3 {
                tickets[slot] = Int(reply.payload[2])
            }
        }
        let primarySlot = bestContracts.first.map { $0.pointer }
        let primary = primarySlot.flatMap { contracts[$0] }
        let remaining = tickets.sorted { $0.key < $1.key }.first { $0.value > 0 }?.value ?? primarySlot.flatMap { tickets[$0] }
        let expiry = replies["Environment Record"].flatMap { $0.hasData ? NiceRecords.cardExpiry($0.payload) : nil }
        let event = replies["Event Record 1"].flatMap { $0.hasData ? NiceRecords.event($0.payload) : nil }
        DebugLog.shared.log("Calypso", "La Carte: \(contracts.count) tickets decoded, remaining trips "
            + (remaining.map(String.init) ?? "unknown"))

        let uidDecimal = String(iso.identifier.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        var fields = [ResultField(title: "Card Number", value: NiceRecords.grouped(uidDecimal)),
                      ResultField(title: "Product Type", value: "Ticket / Contract Card")]
        if !contracts.isEmpty { fields.append(ResultField(title: "Loaded Tickets", value: String(contracts.count))) }
        var ticketName: String?
        if let primary {
            let label = NiceRecords.label(primary)
            ticketName = label.name
            fields.append(ResultField(title: "Ticket", value: label.name))
            if let family = label.family { fields.append(ResultField(title: "Ticket Family", value: family)) }
            fields.append(ResultField(title: "Contract Serial Number", value: primary.serial))
            fields.append(ResultField(title: "Product Code", value: primary.tariff))
            if let sold = primary.soldAt { fields.append(ResultField(title: "Sold At", value: sold)) }
            if let until = primary.validUntil { fields.append(ResultField(title: "Valid Until", value: until)) }
        }
        if let remaining { fields.append(ResultField(title: "Remaining Trips", value: String(remaining))) }
        if let expiry { fields.append(ResultField(title: "Card Valid Until", value: expiry)) }
        if let event {
            fields.append(ResultField(title: "Last Ticket Event", value: event.when))
            if let route = event.route { fields.append(ResultField(title: "Route", value: route)) }
        }
        if primary != nil || remaining != nil {
            fields.append(ResultField(title: "Ticket Status", value: remaining.map { "Remaining trips: \($0)" } ?? "Contract decoded"))
        }
        let balanceDetail: String = ticketName.map { name in
            remaining.map { "\(name): \($0) remaining trip\($0 == 1 ? "" : "s")" } ?? name
        } ?? "Calypso card recognized."
        let snapshot = TransitCardSnapshot(
            technology: "ISO7816", cardFamily: "Lignes d'Azur card", identifierLabel: "UID",
            identifierValue: iso.identifier.hexString, rawIdentifierValue: iso.identifier.hexString,
            pmm: nil, systemCode: nil, selectedAID: applicationAID,
            balanceText: remaining.map { $0 == 1 ? "1 trip" : "\($0) trips" }, balanceDetail: balanceDetail,
            realSerialNumber: uidDecimal, region: "Nice, France", resultFields: fields,
            rawSections: sections, rawTransactions: [], rawTransitHistory: [], scannedAt: scannedAt
        )
        return (snapshot, hasRecords)
    }
}

/// Bit layouts of the Nice records, unchanged from the reader used before 2.5.0.
enum NiceRecords {
    struct BestContract { let index: Int; let structure: String; let pointer: Int }
    struct Contract { let structure: String; let tariff: String; let serial: String; let soldAt: String?; let validUntil: String? }
    struct Event { let when: String; let route: String? }

    static func bits(_ data: Data) -> [UInt8] { data.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 } } }
    static func value(_ bits: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard start >= 0, length > 0, length <= 62, start + length <= bits.count else { return nil }
        return bits[start..<(start + length)].reduce(0) { ($0 << 1) | Int($1) }
    }
    /// Presence bitmaps are stored least significant bit first.
    static func flag(_ bits: [UInt8], bitmapStart: Int, width: Int, index: Int) -> Bool {
        index < width && bitmapStart + width <= bits.count && bits[bitmapStart + width - 1 - index] == 1
    }

    static func bestContracts(_ payload: Data) -> [BestContract] {
        let b = bits(payload)
        guard let count = value(b, 0, 4) else { return [] }
        return (0..<count).compactMap { index in
            let start = 4 + index * 24
            guard let structure = value(b, start + 7, 8), let pointer = value(b, start + 19, 5) else { return nil }
            return BestContract(index: index + 1, structure: String(structure, radix: 16).uppercased(), pointer: pointer)
        }
    }

    static func contract(_ payload: Data, best: BestContract) -> Contract? {
        let b = bits(payload)
        guard b.count >= 63, let tariff = value(b, 15, 16), let serial = value(b, 31, 32) else { return nil }
        let sold = b.count >= 102 ? value(b, 88, 14).flatMap(day) : nil
        var cursor = 63
        if flag(b, bitmapStart: 0, width: 7, index: 3) { cursor += 8 }
        var validUntil: String?
        if flag(b, bitmapStart: 0, width: 7, index: 4), cursor + 2 <= b.count {
            let hasStart = flag(b, bitmapStart: cursor, width: 2, index: 0)
            let hasEnd = flag(b, bitmapStart: cursor, width: 2, index: 1)
            cursor += 2
            if hasStart { cursor += 14 }
            if hasEnd { validUntil = value(b, cursor, 14).flatMap(day) }
        }
        return Contract(structure: best.structure, tariff: String(tariff), serial: String(serial), soldAt: sold, validUntil: validUntil)
    }

    static func cardExpiry(_ payload: Data) -> String? { value(bits(payload), 45, 14).flatMap(day) }

    static func event(_ payload: Data) -> Event? {
        let b = bits(payload)
        guard b.count >= 53, let dayValue = value(b, 0, 14), let time = value(b, 14, 11) else { return nil }
        var cursor = 53
        func present(_ index: Int) -> Bool { flag(b, bitmapStart: 25, width: 28, index: index) }
        if present(2) { cursor += 8 }
        if present(3) { cursor += 8 }
        cursor += 8
        if present(8) { cursor += 24 }
        let route = present(11) ? value(b, cursor, 16).map(String.init) : nil
        let when = (day(dayValue) ?? String(dayValue)) + " " + clock(time)
        return Event(when: when, route: route)
    }

    static func label(_ contract: Contract) -> (name: String, family: String?) {
        switch contract.tariff {
        case "191": return ("N Voyage Multi", "MULTI Voyages")
        case "99": return ("Consigne", nil)
        default: break
        }
        return contract.structure.uppercased() == "46" ? ("N Voyage Multi", "MULTI Voyages") : ("Contract type \(contract.structure)", nil)
    }

    /// Days since 1997-01-01, shown as a date.
    static func day(_ value: Int) -> String? {
        KSX6924DateFormatting.formatRawDateForDisplay(Date(timeIntervalSince1970: 852_073_200 + Double(value) * 86_400))
    }
    /// Minutes since midnight. The pre-2.5.0 reader read them as seconds, which
    /// always showed an hour of 00.
    static func clock(_ value: Int) -> String {
        (0..<1440).contains(value) ? String(format: "%02d:%02d", value / 60, value % 60) : String(value)
    }
    static func grouped(_ decimal: String) -> String {
        guard !decimal.isEmpty else { return decimal }
        var rest = Substring(decimal); var groups: [Substring] = []
        let first = rest.count % 3 == 0 ? 3 : rest.count % 3
        groups.append(rest.prefix(first)); rest = rest.dropFirst(first)
        while !rest.isEmpty { groups.append(rest.prefix(3)); rest = rest.dropFirst(3) }
        return groups.joined(separator: " ")
    }
}
