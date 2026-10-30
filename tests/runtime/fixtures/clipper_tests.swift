// SPDX-License-Identifier: GPL-3.0-or-later
// Public mocked fixture from FareBot / Metrodroid ClipperTransitTest:
// Copyright (C) 2024 Eric Butler, 2017-2018 Michael Farrell.
import Foundation
import os

enum NFCTestError: Error { case unsupportedCard }
struct TransitApplication: Codable {
    let id: String
    var cardFamily = "Clipper"
    var technology = "ISO7816"
    var records: [TransitApplicationRecord]
    var isCityUnion: Bool { false }
    var isTUnion: Bool { false }
    var identityAlias: String { "\(technology)|test-adapter" }
    static func primary(in apps: [Self]) -> Self? { apps.first }
}
// Storage/UI adapters for the production wallet methods compiled by test_clipper.py.
struct SavedCardRecord: Codable {
    let id: String
    var cardFamily = "Clipper"
    var technology = "ISO7816"
    var rawTransactions: [String]
    var rawTransitHistory: [String]
    var applications: [TransitApplication]? = nil

    static func rawRecordHasContent(_ raw: String) -> Bool {
        Data(hexString: raw).contains { $0 != 0 }
    }

    mutating func applyApplications(_ apps: [TransitApplication]) { applications = apps }

    func history(_ kind: RawHistoryKind) -> [TransitTransaction] {
        if let applications { return TransitApplicationHistory.decode(applications, kind: kind) }
        let raw = kind == .transactions ? rawTransactions : rawTransitHistory
        return raw.enumerated().compactMap {
            TransactionDecoderRegistry.decode(raw: $0.element, family: cardFamily, technology: technology,
                                              context: raw, at: $0.offset, kind: kind)
        }
    }
}

final class ClipperTestWallet {
    var cards: [SavedCardRecord] = []
    var savedData: Data?
    var mapDataRevision = 0
    func markMapDataChanged() { mapDataRevision += 1 }
    func save() { savedData = try! JSONEncoder().encode(cards) }
}

struct UnrelatedDecoder: TransitCardDecoder {
    static let applicationAID = "0000000000"
    static func canDecode(tag: CardTag) async -> Bool { false }
    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot { throw NFCTestError.unsupportedCard }
    static func decodeTransaction(_ data: Data) -> TransitTransaction? { nil }
    static func decodeTransaction(block: Data, context: [Data], index: Int, family: String,
                                  kind: RawHistoryKind, relatedContext: [Data]) -> TransitTransaction? { nil }
    static func decodeTransitRecord(data: Data, index: Int) -> TransitTransaction? { nil }
    static func decodeTransitRecord(data: Data, index: Int, auxiliary: [TransitApplicationRecord]) -> TransitTransaction? { nil }
    static func decodeRecord(data: Data, index: Int) -> TransitTransaction? { nil }
    static func decodeTravelRecord(data: Data, index: Int) -> TransitTransaction? { nil }
    static func decodePBOC(data: Data, index: Int, resolveTUnionTerminals: Bool) -> TransitTransaction? { nil }
    static func parseTransitHistory(_ data: Data, sfi: Int, recordIndex: Int, brand: ICCardBrand, logger: Logger) -> TransitTransaction? { nil }
    static func parseSingleTransaction(_ data: Data, sfi: Int, recordIndex: Int, brand: ICCardBrand, logger: Logger) -> TransitTransaction? { nil }
    static func parseNAMANELog(_ data: Data, sfi: Int, recordIndex: Int, isNAMANE: Bool, logger: Logger) -> TransitTransaction? { nil }
}
typealias JapaneseICDecoder = UnrelatedDecoder
typealias KSX6924Decoder = UnrelatedDecoder
typealias NAMANEDecoder = UnrelatedDecoder
typealias CityUnionDecoder = UnrelatedDecoder
typealias TUnionDecoder = UnrelatedDecoder
typealias ChineseTransitDecoder = UnrelatedDecoder
typealias CalypsoDecoder = UnrelatedDecoder
typealias CEPASDecoder = UnrelatedDecoder
typealias MacauPassDecoder = UnrelatedDecoder
typealias EdyDecoder = UnrelatedDecoder
typealias WAONDecoder = UnrelatedDecoder
typealias NanacoDecoder = UnrelatedDecoder
typealias StoredValueDecoder = UnrelatedDecoder
typealias TianfuTongDecoder = UnrelatedDecoder

typealias Reply = (String, Data, UInt8, UInt8)
final class ReplayCard: ISO7816Card {
    let identifier = Data(hexString: "04010203040506"), initialSelectedAID = ""
    let applicationData: Data? = nil
    var commands: [Data] = []
    var replies: [Reply]
    init(_ replies: [Reply]) { self.replies = replies }
    func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8) {
        commands.append(apdu.encoded)
        precondition(!replies.isEmpty, "Unexpected command \(apdu.encoded.hexString)")
        let (expected, data, sw1, sw2) = replies.removeFirst()
        precondition(apdu.encoded.hexString == expected, "Expected \(expected), got \(apdu.encoded.hexString)")
        return (data, sw1, sw2)
    }
}

final class ReplayMiFare: MiFareCard {
    let identifier = Data(hexString: "04010203040506")
    let mifareFamily: MiFareFamily
    let replay: ReplayCard
    init(_ replies: [Reply], family: MiFareFamily = .desfire) {
        replay = ReplayCard(replies)
        mifareFamily = family
    }
    func sendMiFareCommand(commandPacket: Data) async throws -> Data {
        guard let command = CardAPDU(data: commandPacket) else { preconditionFailure("Invalid wrapped APDU") }
        let (data, sw1, sw2) = try await replay.sendCommand(apdu: command)
        return data + Data([sw1, sw2])
    }
}

final class TicketCard: MiFareCard {
    let identifier = Data([4, 1, 2, 3, 4, 5, 6])
    let mifareFamily: MiFareFamily = .ultralight
    let data: Data
    var commands: [Data] = []
    var shortPage: UInt8?
    init(data: Data, shortPage: UInt8? = nil) { self.data = data; self.shortPage = shortPage }
    func sendMiFareCommand(commandPacket: Data) async throws -> Data {
        commands.append(commandPacket)
        precondition(commandPacket.count == 2 && commandPacket[0] == 0x30)
        let page = commandPacket[1]
        precondition([0, 4, 8, 12].contains(page))
        if shortPage == page { return Data() }
        return data.subdata(in: Int(page) * 4..<(Int(page) * 4 + 16))
    }
}

final class CancelledCard: MiFareCard {
    let identifier = Data([4])
    let mifareFamily: MiFareFamily = .desfire
    var calls = 0
    func sendMiFareCommand(commandPacket: Data) async throws -> Data {
        calls += 1
        if calls == 1 { return Data([0x91, 0]) }
        if calls == 2 { return Data(hexString: "000000000500009100") }
        if calls == 3 { return Data(hexString: "00222295339100") }
        if calls == 4 { return Data(hexString: "000000001400009100") }
        if calls == 5 { return Data(repeating: 0, count: 20) + Data([0x91, 0]) }
        throw CancellationError()
    }
}

final class ReplayChannel: CardCommandChannel {
    var replies: [(String, Data, UInt8, UInt8)]
    init(_ replies: [(String, Data, UInt8, UInt8)]) { self.replies = replies }
    func exchange(_ command: Data) async throws -> (Data, UInt8, UInt8) {
        precondition(!replies.isEmpty, "Unexpected USB command")
        let (expected, body, sw1, sw2) = replies.removeFirst()
        precondition(command.hexString == expected, "Incorrect USB framing")
        return (body, sw1, sw2)
    }
}

@main struct ClipperTests {
    static let serial = Data(hexString: "0022229533")
    static let balance = Data(hexString: "0000000000000000000000000000000000007777")
    static let trip = Data(hexString: "000000040000027600000000DE580000DE58100000080027000000000000006F")
    static let refill = Data(hexString: "000002CFDE440000781234560000138800000000000000000000000000000000")
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() async throws {
        let name = CommandLine.arguments[1]
        switch name {
        case "history": try history()
        case "transport": try await transport()
        case "ticket": try await ticket()
        case "cancellation": try await cancellation()
        case "catalog": catalog()
        case "registry": try await registry()
        case "wallet":
            var provisional = trip
            provisional.replaceSubrange(16..<20, with: Data(repeating: 0, count: 4))
            for technology in ["ISO7816", "DESFire"] {
                try await testWalletDeletion(trip: trip, provisional: provisional, refill: refill, technology: technology)
            }
            try await legacyWalletMerge()
        case "external": try await external()
        default: preconditionFailure("Unknown case")
        }
        print("PASS: \(name)")
    }

    static func history() throws {
        var expiry = Data(repeating: 0, count: 10)
        expiry[8] = 0xAF; expiry[9] = 0xC8
        var files: [UInt8: Data] = [1: expiry, 2: balance, 8: serial, 14: trip, 4: refill]
        let snapshot = try ClipperDecoder.snapshot(files: files, identifier: Data(), scannedAt: now)
        precondition(snapshot.identifierValue == "572691763" && snapshot.selectedAID == "9011F2")
        precondition(snapshot.rawIdentifierValue.isEmpty && snapshot.storageIdentifier == "ISO7816|572691763")
        let withUID = try ClipperDecoder.snapshot(files: files, identifier: Data(hexString: "04010203040506"), scannedAt: now)
        precondition(withUID.storageIdentifier == "DESFire|04010203040506")
        precondition(snapshot.balanceText == formatCurrency(amount: Decimal(30583) / 100, code: "USD", fractionDigits: 2))
        precondition(snapshot.transactions.count == 2 && snapshot.transitHistory.count == 1)
        let decoded = snapshot.transactions.first { $0.category == .train }!
        precondition(decoded.amount == Decimal(-630) / 100 && decoded.amountIsSigned)
        precondition(decoded.date?.timeIntervalSince1970 == 1_521_320_320)
        precondition(decoded.entryStation == "Powell Street" && decoded.exitStation == "Dublin / Pleasanton")
        precondition(decoded.entryStationCode == "CLIPPER:262152")
        precondition(decoded.currencyCode == "USD" && decoded.issuerTimeZone == "America/Los_Angeles")
        let topUp = snapshot.transactions.first { $0.category == .topUp }!
        precondition(topUp.amount == 50 && topUp.terminalID == "2014458966")
        precondition(snapshot.resultFields.first { $0.title == "Expiry Date" }?.value == "2023-03-17")
        precondition(ClipperDecoder.timeText(Date(timeIntervalSince1970: 1_704_067_200)) == "16:00:00")
        precondition(ClipperDecoder.timeText(Date(timeIntervalSince1970: 1_719_792_000)) == "17:00:00")
        var negative = balance
        negative[18] = 0xFF; negative[19] = 0x9C
        files[2] = negative; files[8] = Data(hexString: "00FFFFFFFF")
        let debit = try ClipperDecoder.snapshot(files: files, identifier: Data(), scannedAt: now)
        precondition(debit.balanceText == formatCurrency(amount: -1, code: "USD", fractionDigits: 2))
        precondition(debit.identifierValue == "4294967295")
        for length in 0..<20 {
            do {
                _ = try ClipperDecoder.snapshot(files: [8: serial, 2: Data(repeating: 0, count: length)],
                                               identifier: Data(), scannedAt: now)
                preconditionFailure("Truncated balance accepted")
            } catch {}
        }
        for length in 0..<5 {
            do {
                _ = try ClipperDecoder.snapshot(files: [8: Data(repeating: 0, count: length), 2: balance],
                                               identifier: Data(), scannedAt: now)
                preconditionFailure("Truncated serial accepted")
            } catch {}
        }
        precondition(ClipperDecoder.records(Data(), file: 14).isEmpty)
        precondition(ClipperDecoder.records(Data(repeating: 0, count: 32), file: 14).isEmpty)
        precondition(ClipperDecoder.records(trip + Data([0]), file: 14).isEmpty)
        for length in 0..<33 { precondition(ClipperDecoder.decodeRecord(Data(repeating: 0, count: length)) == nil) }
        var provisional = trip
        provisional.replaceSubrange(16..<20, with: Data(repeating: 0, count: 4))
        let raw = [Data([14]) + provisional, Data([14]) + trip, Data([4]) + refill].map(\.hexString)
        let persisted = try JSONDecoder().decode([String].self, from: JSONEncoder().encode(raw))
        let context = persisted.map { Data(hexString: $0) }
        let history = context.enumerated().compactMap {
            ClipperDecoder.decodeTransaction($0.element, context: context, index: $0.offset)
        }
        precondition(history.count == 2 && history.filter { $0.category == .train }.count == 1)
        precondition(history.first { $0.category == .train }?.rawData == (Data([14]) + trip).hexString)
        var invalid = trip
        invalid[2] = 0; invalid[3] = 0
        let invalidContext = [Data([14]) + invalid, Data([14]) + trip]
        precondition(ClipperDecoder.decodeTransaction(invalidContext[1], context: invalidContext, index: 1) != nil)
        precondition(ClipperDecoder.tripEntryTimestamp(Data([4]) + trip) == nil)
        for (mode, agency, category) in [(0x61, 1, TransactionCategory.bus), (0x62, 25, .ferry),
                                         (0x73, 27, .ferry), (0x78, 6, .train), (0xFF, 4, .unknown)] {
            var sample = trip; sample[3] = UInt8(agency); sample[31] = UInt8(mode)
            precondition(ClipperDecoder.decodeRecord(Data([14]) + sample)?.category == category)
        }
        precondition(ClipperDecoder.vehicleName(20101) == "2010A" && ClipperDecoder.vehicleName(0xFFFF) == nil)
    }

    static func replies() -> [Reply] {
        [
            ("905A0000039011F200", Data(), 0x91, 0),
            ("90F50000010800", Data(hexString: "0001F0EF050000"), 0x91, 0),
            ("90BD0000070800000000000000", serial, 0x91, 0),
            ("90F50000010200", Data(hexString: "010130E2140000"), 0x91, 0),
            ("90BD0000070200000000000000", Data(balance.prefix(10)), 0x91, 0xAF),
            ("90AF000000", Data(balance.suffix(10)), 0x91, 0),
            ("90F50000010100", Data(), 0x91, 0xF0),
            ("90F50000010400", Data(), 0x91, 0x9D),
            ("90F50000010E00", Data(), 0x91, 0xAE),
        ]
    }

    static func transport() async throws {
        let iso = ReplayCard(replies())
        let read = try await ClipperDecoder.decode(tag: .iso7816(iso), scannedAt: now)
        precondition(read.identifierValue == "572691763" && iso.replies.isEmpty)
        precondition(read.rawSections.contains { $0.title == "Clipper Read Status" })
        let miFare = ReplayMiFare(replies())
        let native = try await ClipperDecoder.decode(tag: .miFare(miFare), scannedAt: now)
        precondition(native.identifierValue == read.identifierValue && miFare.replay.replies.isEmpty)
        precondition(miFare.replay.commands == iso.commands, "Wrapped APDUs must be identical")
        let cyclic = ReplayCard([
            ("90F50000010400", Data(hexString: "040130E2200000060000010000"), 0x91, 0),
            ("90BB0000070400000000000000", refill, 0x91, 0),
        ])
        let recordData = try await DESFireReader(card: cyclic).readFile(4)
        precondition(recordData == refill && cyclic.replies.isEmpty)
        for (body, sw1, sw2) in [(Data(), UInt8(0x90), UInt8(0)), (Data(), 0x91, 0xA0),
                                  (Data(), 0x91, 0xAF), (Data(repeating: 1, count: 8193), 0x91, 0)] {
            let malformed = ReplayCard([("90BD000000", body, sw1, sw2)])
            do { _ = try await DESFireReader(card: malformed).exchange(0xBD); preconditionFailure("Bad reply accepted") }
            catch {}
        }
        let endless = ReplayCard([("90BD000000", Data([1]), 0x91, 0xAF)] +
            Array(repeating: ("90AF000000", Data([1]), UInt8(0x91), UInt8(0xAF)), count: 255))
        do { _ = try await DESFireReader(card: endless).exchange(0xBD); preconditionFailure("Unbounded continuation") }
        catch { precondition(endless.replies.isEmpty) }
        for settings in ["00000000FFFFFF", "0000000005000000", "04000000200000010000020000",
                         "040000001F0000010000010000"] {
            let card = ReplayCard([("90F50000010800", Data(hexString: settings), 0x91, 0)])
            do { _ = try await DESFireReader(card: card).readFile(8); preconditionFailure("Bad settings accepted") }
            catch { precondition(card.replies.isEmpty) }
        }
        let empty = ReplayCard([("90F50000010400", Data(hexString: "04000000200000060000000000"), 0x91, 0)])
        let emptyRecords = try await DESFireReader(card: empty).readFile(4)
        precondition(emptyRecords.isEmpty && empty.commands.count == 1)
        let truncated = ReplayCard([
            ("90F50000010800", Data(hexString: "00000000200000"), 0x91, 0),
            ("90BD0000070800000000000000", serial, 0x91, 0),
        ])
        do { _ = try await DESFireReader(card: truncated).readFile(8); preconditionFailure("Truncated file accepted") }
        catch {}
        let noWrites = ReplayCard([])
        do { _ = try await DESFireReader(card: noWrites).exchange(0x3D); preconditionFailure("Write allowed") }
        catch { precondition(noWrites.commands.isEmpty) }
    }

    static func event(sequence: Int, balanceSequence: Int, remaining: Int, type: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        func set(_ offset: Int, _ length: Int, _ value: Int) {
            for i in 0..<length {
                let bit = UInt8((value >> (length - i - 1)) & 1)
                bytes[(offset + i) / 8] |= bit << (7 - (offset + i) % 8)
            }
        }
        set(0, 7, sequence); set(7, 17, type); set(24, 17, 120)
        set(41, 17, 7); set(68, 5, 18); set(80, 4, balanceSequence)
        set(84, 6, remaining); set(100, 10, 90)
        return Data(bytes)
    }

    static func ticket() async throws {
        var ticket = Data(repeating: 0, count: 64)
        ticket.replaceSubrange(12..<16, with: Data(hexString: "12345678"))
        ticket[16] = 0x13; ticket[17] = 4; ticket[20] = 2; ticket[21] = 0x14
        ticket[22] = 0xAF; ticket[23] = 0xC8
        ticket.replaceSubrange(24..<44, with: event(sequence: 127, balanceSequence: 15, remaining: 2, type: 2))
        ticket.replaceSubrange(44..<64, with: event(sequence: 0, balanceSequence: 0, remaining: 1, type: 1))
        let card = TicketCard(data: ticket)
        let snapshot = try await ClipperUltralightDecoder.decode(tag: .miFare(card), scannedAt: now)
        precondition(card.commands == [4, 0, 8, 12].map { Data([0x30, UInt8($0)]) })
        precondition(snapshot.identifierValue == "305419896" && snapshot.balanceText == nil)
        precondition(snapshot.resultFields.first { $0.title == "Trips Remaining" }?.value == "1")
        precondition(snapshot.resultFields.first { $0.title == "Product" }?.value == "Adult return")
        precondition(snapshot.rawTransitHistory.count == 2 && snapshot.transitHistory.count == 1)
        precondition(snapshot.transactions.isEmpty && !snapshot.transitHistory[0].amountKnown)
        precondition(snapshot.transitHistory[0].issuerTimeZone == "America/Los_Angeles")
        let visible = Data(hexString: "AFC8") + event(sequence: 0, balanceSequence: 0, remaining: 1, type: 2)
        let previous = Data(hexString: "AFC8") + event(sequence: 127, balanceSequence: 0, remaining: 2, type: 2)
        precondition(ClipperUltralightDecoder.TicketEvent(visible)!.isNewer(than: ClipperUltralightDecoder.TicketEvent(previous)!))
        let persisted = try JSONDecoder().decode([String].self, from: JSONEncoder().encode(snapshot.rawTransitHistory))
        precondition(persisted.compactMap { ClipperUltralightDecoder.decodeTransaction(Data(hexString: $0)) }.count == 1)
        for length in 0..<22 { precondition(ClipperUltralightDecoder.decodeTransaction(Data(repeating: 0, count: length)) == nil) }
        for page: UInt8 in [0, 4, 8, 12] {
            do {
                _ = try await ClipperUltralightDecoder.decode(tag: .miFare(TicketCard(data: ticket, shortPage: page)), scannedAt: now)
                preconditionFailure("Short page accepted")
            } catch {}
        }
        ticket[16] = 0
        let other = TicketCard(data: ticket)
        do { _ = try await ClipperUltralightDecoder.decode(tag: .miFare(other), scannedAt: now); preconditionFailure("Bad marker") }
        catch { precondition(other.commands.count == 1) }
    }

    static func cancellation() async throws {
        let card = CancelledCard()
        do { _ = try await ClipperDecoder.decode(tag: .miFare(card), scannedAt: now); preconditionFailure("Cancellation swallowed") }
        catch is CancellationError { precondition(card.calls == 6) }
        let wrongFamily = ReplayMiFare([], family: .plus)
        let canRead = await ClipperDecoder.canDecode(tag: .miFare(wrongFamily))
        let canReadTicket = await ClipperUltralightDecoder.canDecode(tag: .miFare(wrongFamily))
        precondition(!canRead && !canReadTicket)
        do { _ = try await ClipperDecoder.decode(tag: .miFare(wrongFamily), scannedAt: now); preconditionFailure("Wrong family accepted") }
        catch { precondition(wrongFamily.replay.commands.isEmpty) }
        let cancelled = ReplayMiFare([])
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await ClipperDecoder.decode(tag: .miFare(cancelled), scannedAt: now)
        }
        task.cancel()
        do { _ = try await task.value; preconditionFailure("Cancelled task ran") }
        catch is CancellationError { precondition(cancelled.replay.commands.isEmpty) }
    }

    static func catalog() {
        let catalog = ClipperTransitCatalog.shared
        precondition(catalog.stations.count == 129)
        precondition(catalog.agencyName(4) == "Bay Area Rapid Transit")
        precondition(catalog.stationName(agency: 4, station: 8, isEnd: false) == "Powell Street")
        precondition(catalog.stationName(agency: 6, station: 0xFFFF, isEnd: true) == "End of line")
        precondition(catalog.stationName(agency: 6, station: 9, isEnd: false) == "Zone 9")
        precondition(catalog.stationName(agency: 0xFF, station: 0, isEnd: false) == nil)
        precondition(catalog.routeName(agency: 25, route: 1) == "Sausalito - San Francisco")
        let missing = ClipperTransitCatalog(url: nil)
        precondition(missing.stations.isEmpty && missing.agencyName(4) == "Agency 0x4")
        precondition(missing.stationName(agency: 4, station: 8, isEnd: false) == "0x4/0x8")
        precondition(catalog.notice.contains("same license terms as Metrodroid"))
    }

    static func envelope(_ payload: Data, kind: UInt8, tag: UInt8 = 5, index: UInt16 = 0) -> String {
        StoredValueProtocol.envelope(tag: tag, kind: kind, index: Int(index), data: payload)
    }

    static func registry() async throws {
        let oldTrip = envelope(trip, kind: 3)
        let oldRefill = envelope(refill, kind: 2)
        let newTrip = (Data([14]) + trip).hexString
        let newRefill = (Data([4]) + refill).hexString
        precondition(ClipperDecoder.canonicalHistoryRecord(oldTrip) == newTrip)
        precondition(ClipperDecoder.canonicalHistoryRecord(oldRefill.lowercased()) == newRefill)
        precondition(ClipperDecoder.canonicalHistoryRecord(envelope(trip, kind: 3, index: 65535)) == newTrip)
        for value in [
            newTrip, "", "not hex", oldTrip + "00", String(oldTrip.dropLast(2)),
            envelope(trip, kind: 3, tag: 1), envelope(trip, kind: 1),
            envelope(trip, kind: 4), envelope(trip, kind: 3).replacingOccurrences(of: "4446535601", with: "4446535602"),
            envelope(trip + Data([0]), kind: 3), envelope(Data(trip.dropLast()), kind: 3),
            oldTrip.replacingOccurrences(of: "44465356", with: "00465356"), " " + oldTrip,
        ] {
            precondition(ClipperDecoder.canonicalHistoryRecord(value) == value, "Unrelated raw was rewritten")
        }
        var badLength = Data(hexString: oldTrip)
        badLength[10] = 31
        precondition(ClipperDecoder.canonicalHistoryRecord(badLength.hexString) == badLength.hexString)
        for technology in ["DESFire", "ISO7816"] {
            for raw in [oldTrip, newTrip] {
                let decoded = TransactionDecoderRegistry.decode(raw: raw, family: "Clipper",
                    technology: technology, context: [raw], at: 0)!
                precondition(decoded.amount == Decimal(-630) / 100 && decoded.currencyCode == "USD")
                precondition(decoded.date?.timeIntervalSince1970 == 1_521_320_320)
            }
            for raw in [oldRefill, newRefill] {
                let decoded = TransactionDecoderRegistry.decode(raw: raw, family: "Clipper",
                    technology: technology, context: [raw], at: 0)!
                precondition(decoded.amount == 50 && decoded.category == .topUp)
            }
        }
    }

    @MainActor
    static func legacyWalletMerge() async throws {
        let oldTrip = envelope(trip, kind: 3)
        let oldRefill = envelope(refill, kind: 2)
        var older = trip
        older[15] = 1
        let oldOnly = envelope(older, kind: 3)
        let expectedOldOnly = (Data([14]) + older).hexString
        let newTrip = (Data([14]) + trip).hexString
        let newRefill = (Data([4]) + refill).hexString
        for technology in ["DESFire", "ISO7816"] {
            let wallet = ClipperTestWallet()
            let merged = wallet.mergeRawRecords(existing: [oldTrip, oldRefill, oldOnly],
                incoming: [newTrip, newRefill], family: "Clipper", technology: technology, kind: .transactions)
            precondition(merged.count == 3 && Set(merged) == Set([newTrip, newRefill, expectedOldOnly]),
                         "Old/new Clipper histories must deduplicate and retain unscanned old events")
            let original = SavedCardRecord(id: "legacy", technology: technology,
                                          rawTransactions: merged, rawTransitHistory: merged)
            let reloaded = try JSONDecoder().decode(SavedCardRecord.self, from: JSONEncoder().encode(original))
            precondition(reloaded.history(.transactions).count == 3)
            precondition(reloaded.history(.transactions).contains { $0.rawData == expectedOldOnly })
            wallet.cards = [reloaded]
            wallet.deleteLocalRecord(cardID: "legacy", kind: .transactions, rawData: newTrip)
            await flushWalletChanges()
            precondition(Set(wallet.cards[0].rawTransactions) == Set([newRefill, expectedOldOnly]))
            precondition(wallet.cards[0].rawTransitHistory == merged)
        }
    }

    static func external() async throws {
        let pages = Data(repeating: 0x13, count: 16)
        let body = Data([0xD5, 0x41, 0]) + pages
        let channel = ReplayChannel([("FF00000005D440013004", body, 0x90, 0)])
        let adapter = ACR122UltralightCard(connection: channel, identifier: Data([4]))
        let response = try await adapter.sendMiFareCommand(commandPacket: Data([0x30, 4]))
        precondition(response == pages && channel.replies.isEmpty && adapter.mifareFamily == .ultralight)
        let continued = ReplayChannel([
            ("FF00000005D440013004", Data(), 0x61, 19),
            ("FFC0000013", body, 0x90, 0),
        ])
        let continuedPages = try await ACR122UltralightCard(connection: continued, identifier: Data())
            .sendMiFareCommand(commandPacket: Data([0x30, 4]))
        precondition(continuedPages == pages && continued.replies.isEmpty)
        for bad in [Data(), Data([0xD5, 0x41, 1]), Data([0xD5, 0x41, 0, 0]),
                    Data([0xD5, 0x40, 0]) + pages, body + Data([0])] {
            let invalid = ReplayChannel([("FF00000005D440013004", bad, 0x90, 0)])
            do {
                _ = try await ACR122UltralightCard(connection: invalid, identifier: Data())
                    .sendMiFareCommand(commandPacket: Data([0x30, 4]))
                preconditionFailure("Invalid USB page accepted")
            } catch { precondition(invalid.replies.isEmpty) }
        }
        let noWrite = ReplayChannel([])
        do {
            _ = try await ACR122UltralightCard(connection: noWrite, identifier: Data())
                .sendMiFareCommand(commandPacket: Data([0xA2, 4]))
            preconditionFailure("Non-read ticket command accepted")
        } catch { precondition(noWrite.replies.isEmpty) }
    }
    @MainActor
    static func testWalletDeletion(trip: Data, provisional: Data, refill: Data, technology: String) async throws {
        let completed = (Data([14]) + trip).hexString
        let pending = (Data([14]) + provisional).hexString
        var otherTrip = trip
        otherTrip[15] = 1
        let other = (Data([14]) + otherTrip).hexString
        var sameTimeRefill = refill
        sameTimeRefill.replaceSubrange(12..<16, with: trip.subdata(in: 12..<16))
        let topUp = (Data([4]) + sameTimeRefill).hexString

        // Actual merge/deletion methods: scan a tap-in, then its completed trip,
        // delete from either history, and reload the resulting saved payload.
        for kind in [RawHistoryKind.transactions, .transit] {
            let wallet = ClipperTestWallet()
            let merged = wallet.mergeRawRecords(existing: [pending, other, topUp], incoming: [completed],
                                                family: "Clipper", technology: technology, kind: kind)
            precondition(merged.contains(pending) && merged.contains(completed))
            let card = SavedCardRecord(id: "clipper", technology: technology, rawTransactions: merged, rawTransitHistory: merged)
            wallet.cards = [card, SavedCardRecord(id: "other-card", rawTransactions: merged, rawTransitHistory: merged)]
            let displayed = card.history(kind).first { $0.rawData == completed }!
            precondition(!card.history(kind).contains { $0.rawData == pending })

            wallet.deleteLocalRecord(cardID: card.id, kind: kind, rawData: displayed.rawData!,
                                     sourceRecordIDs: displayed.sourceRecordIDs)
            precondition(wallet.savedData == nil, "Wallet deletion should remain deferred")
            await flushWalletChanges()

            let reloaded = try JSONDecoder().decode([SavedCardRecord].self, from: wallet.savedData!)
            let remaining = kind == .transactions ? reloaded[0].rawTransactions : reloaded[0].rawTransitHistory
            precondition(Set(remaining) == Set([other, topUp]),
                         "Deleting the completed Clipper trip must remove its hidden tap-in")
            precondition(!reloaded[0].history(kind).contains { $0.rawData == pending || $0.rawData == completed })
            precondition((kind == .transactions ? reloaded[0].rawTransitHistory : reloaded[0].rawTransactions) == merged)
            precondition(reloaded[1].rawTransactions == merged && reloaded[1].rawTransitHistory == merged)
            precondition(wallet.mapDataRevision == 1)
        }

        // Existing exact-record behavior is unchanged for refills and other
        // technologies/families, even when their bytes resemble a Clipper trip.
        for (family, technology, selected, records) in [
            ("Clipper", "ISO7816", topUp, [pending, completed, topUp, topUp]),
            ("Other", "ISO7816", completed, [pending, completed, completed]),
            ("Clipper Ticket", "MIFARE Ultralight", completed, [pending, completed, completed]),
        ] {
            let wallet = ClipperTestWallet()
            wallet.cards = [SavedCardRecord(id: "unchanged", cardFamily: family, technology: technology,
                                           rawTransactions: records, rawTransitHistory: records)]
            wallet.deleteLocalRecord(cardID: "unchanged", kind: .transactions, rawData: selected)
            await flushWalletChanges()
            var expected = records
            expected.remove(at: expected.firstIndex(of: selected)!)
            precondition(wallet.cards[0].rawTransactions == expected)
            precondition(wallet.cards[0].rawTransitHistory == records)
        }

        // Application-backed deletion must keep using its scoped evidence IDs.
        let wallet = ClipperTestWallet()
        let record = TransitApplicationRecord(kind: .transaction, sfi: 24, index: 1, hex: completed)
        let unrelatedPending = TransitApplicationRecord(kind: .transaction, sfi: 24, index: 2, hex: pending)
        wallet.cards = [SavedCardRecord(id: "applications", cardFamily: "China T-Union",
            rawTransactions: [], rawTransitHistory: [],
            applications: [TransitApplication(id: "first", cardFamily: "China T-Union", records: [record, unrelatedPending]),
                           TransitApplication(id: "second", cardFamily: "China T-Union", records: [record, unrelatedPending])])]
        wallet.deleteLocalRecord(cardID: "applications", kind: .transactions, rawData: completed,
                                 sourceRecordIDs: ["first|\(record.identity)"])
        await flushWalletChanges()
        precondition(wallet.cards[0].applications![0].records == [unrelatedPending])
        precondition(wallet.cards[0].applications![1].records == [record, unrelatedPending])
        try await testApplicationBackedDeletion(pending: pending, completed: completed, other: other,
                                               topUp: topUp, technology: technology)
        print("PASS: production wallet Clipper deletion, reload, and unrelated record scopes")
    }

    @MainActor
    static func testApplicationBackedDeletion(pending: String, completed: String, other: String,
                                            topUp: String, technology: String) async throws {
        let records = [TransitApplicationRecord.Kind.transaction, .transit, .auxiliary].flatMap { kind in
            [pending, completed, other, topUp].enumerated().map {
                TransitApplicationRecord(kind: kind, sfi: kind == .transaction ? 0x18 : 0x1E,
                                         index: $0.offset + 1, hex: $0.element)
            }
        }
        let applicationID = "\(technology):9011F2"
        let imported = SavedCardRecord(id: "application-backup", technology: technology, rawTransactions: [], rawTransitHistory: [],
            applications: [TransitApplication(id: applicationID, technology: technology, records: records),
                           TransitApplication(id: "other-application", technology: technology, records: records)])
        for (kind, recordKind) in [(RawHistoryKind.transactions, TransitApplicationRecord.Kind.transaction),
                                   (.transit, .transit)] {
            let wallet = ClipperTestWallet()
            // An imported backup can carry applications even though normal
            // Clipper scans use flattened histories. Reload before deletion.
            let backup = try JSONEncoder().encode([imported])
            wallet.cards = try JSONDecoder().decode([SavedCardRecord].self, from: backup)
            let displayed = wallet.cards[0].history(kind).first {
                $0.sourceApplicationID == applicationID && $0.rawData == completed
            }!
            let completedRecord = records.first { $0.kind == recordKind && $0.hex == completed }!
            // Use the actual application decoder's single-record evidence;
            // it does not include the hidden provisional record.
            precondition(displayed.sourceRecordIDs == ["\(applicationID)|\(completedRecord.identity)"])
            wallet.deleteLocalRecord(cardID: imported.id, kind: kind, rawData: displayed.rawData!,
                                     sourceRecordIDs: displayed.sourceRecordIDs)
            await flushWalletChanges()

            let reloaded = try JSONDecoder().decode([SavedCardRecord].self, from: wallet.savedData!)
            let expected = records.filter { !($0.kind == recordKind && [pending, completed].contains($0.hex)) }
            precondition(reloaded[0].applications![0].records == expected,
                         "Application-backed Clipper deletion must remove hidden tap-ins only in the selected kind")
            precondition(reloaded[0].applications![1].records == records,
                         "Clipper trip deletion must not expand into another application")
            precondition(!reloaded[0].history(kind).contains {
                $0.sourceApplicationID == applicationID && [pending, completed].contains($0.rawData ?? "")
            })
            precondition(wallet.mapDataRevision == 1)
        }
        let wallet = ClipperTestWallet()
        wallet.cards = [imported]
        wallet.deleteLocalRecord(cardID: imported.id, kind: .transactions, rawData: completed,
                                 sourceRecordIDs: ["missing-application|transaction:24:\(completed)"])
        await flushWalletChanges()
        precondition(wallet.cards[0].applications!.allSatisfy { $0.records == records },
                     "An unmatched source ID must not fall back to deleting matching raw data")
    }

    static func flushWalletChanges() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
