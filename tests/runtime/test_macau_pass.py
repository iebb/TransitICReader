"""Compile the production Macau Pass decoder and replay synthetic card replies.

APDU replies are synthetic; these tests do not substitute for RF testing on
physical cards.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT

MACAU_ALIASES = ["macau pass", "macaupass", "macau-pass", "\u6fb3\u95e8\u901a", "\u6fb3\u9580\u901a"]

# Only unrelated decoders and envelope codecs are stubbed. Macau Pass, the
# transaction registry, application history and wallet models are production.
FIXTURE = r'''
import Foundation
import os

// All payloads below are synthetic. No upstream card captures are used.
// Protocol reference: HaoTian22/TU-Reader, f50948a0090f0b7b07e27369c3a9a66670b092a9:
// CardProfile.kt, ApduUtil.kt, TransitCardReader.kt, data/RecordDecoder.kt,
// and ui/RawHexFormatter.kt under app/src/main/java/com/example/nfctransit/.
// RawHexFormatter specifies four amount bytes [5,9); RecordDecoder reads [6,9).
// Nonzero high-byte fixtures deliberately distinguish these interpretations.

enum NFCTestError: Error { case unsupportedCard }

// Only unrelated decoders/UI are stubbed; Macau Pass and the history registry
// are compiled directly from production source.
struct UnrelatedDecoder: TransitCardDecoder {
    static let applicationAID = "0000000000"
    static func canDecode(tag: CardTag) async -> Bool { false }
    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        throw NFCTestError.unsupportedCard
    }
    static func decodeTransaction(_ data: Data) -> TransitTransaction? { nil }
    static func decodeTransaction(_ data: Data, context: [Data], index: Int) -> TransitTransaction? { nil }
    static func decodeTransaction(block: Data, context: [Data], index: Int, family: String,
                                  kind: RawHistoryKind, relatedContext: [Data]) -> TransitTransaction? { nil }
    static func decodeTransitRecord(data: Data, index: Int) -> TransitTransaction? { nil }
    static func decodeRecord(data: Data, index: Int) -> TransitTransaction? { nil }
    static func decodeTransitRecord(data: Data, index: Int,
                                    auxiliary: [TransitApplicationRecord]) -> TransitTransaction? { nil }
    static func decodeTravelRecord(data: Data, index: Int) -> TransitTransaction? { nil }
    static func decodePBOC(data: Data, index: Int, resolveTUnionTerminals: Bool) -> TransitTransaction? { nil }
    static func parseTransitHistory(_ data: Data, sfi: Int, recordIndex: Int,
                                   brand: ICCardBrand, logger: Logger) -> TransitTransaction? { nil }
    static func parseSingleTransaction(_ data: Data, sfi: Int, recordIndex: Int,
                                      brand: ICCardBrand, logger: Logger) -> TransitTransaction? { nil }
    static func parseNAMANELog(_ data: Data, sfi: Int, recordIndex: Int,
                              isNAMANE: Bool, logger: Logger) -> TransitTransaction? { nil }
}
typealias JapaneseICDecoder = UnrelatedDecoder
typealias KSX6924Decoder = UnrelatedDecoder
typealias NAMANEDecoder = UnrelatedDecoder
typealias CityUnionDecoder = UnrelatedDecoder
typealias ChineseTransitDecoder = UnrelatedDecoder
typealias CalypsoDecoder = UnrelatedDecoder
typealias CEPASDecoder = UnrelatedDecoder
typealias ClipperDecoder = UnrelatedDecoder
typealias ClipperUltralightDecoder = UnrelatedDecoder
typealias EdyDecoder = UnrelatedDecoder
typealias WAONDecoder = UnrelatedDecoder
typealias NanacoDecoder = UnrelatedDecoder
typealias TianfuTongDecoder = UnrelatedDecoder

// Envelope families use their own codecs. The Python test checks that the
// production family list does not claim any Macau Pass alias.
enum AdditionalCardHistory {
    static func handles(_ family: String) -> Bool { false }
    static func merge(_ records: [String]) -> [String] { records }
    static func decode(raw: String, family: String, context: [String] = []) -> TransitTransaction? { nil }
}

struct TUnionDecoder: TransitCardDecoder {
    static let applicationAID = "A000000632010105"
    static var companion: TransitCardSnapshot?
    static var readCount = 0
    static func canDecode(tag: CardTag) async -> Bool { false }
    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        readCount += 1
        guard let companion else { throw NFCTestError.unsupportedCard }
        return companion
    }
    static func decodeTravelRecord(data: Data, index: Int) -> TransitTransaction? { nil }
    static func decodePBOC(data: Data, index: Int, resolveTUnionTerminals: Bool) -> TransitTransaction? {
        // A canned companion event lets the real application-history pipeline
        // distinguish identical bytes in CNY and MOP without another NFC decoder.
        guard data == Synthetic.transaction() else { return nil }
        return TransitTransaction(date: Date(timeIntervalSince1970: 1_709_181_296),
            amount: Decimal(-37) / 100, terminalID: "001234005678", type: "Payment",
            category: .payment, rawData: data.hexString, recordNumber: 0x8123)
    }
}

struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

func check(_ condition: @autoclosure () -> Bool, _ message: String,
           file: StaticString = #fileID, line: UInt = #line) throws {
    if !condition() { throw FixtureFailure(description: "\(file):\(line): \(message)") }
}

func requireTransaction(_ data: Data) throws -> TransitTransaction {
    guard let transaction = MacauPassDecoder.decodeTransaction(data) else {
        throw FixtureFailure(description: "Rejected synthetic transaction \(data.hexString)")
    }
    return transaction
}

struct Reply {
    let command: String
    let data: Data
    let status: UInt16
    let failsTransport: Bool

    init(_ command: String, _ data: Data = Data(), status: UInt16 = 0x9000,
         failsTransport: Bool = false) {
        self.command = command
        self.data = data
        self.status = status
        self.failsTransport = failsTransport
    }
}

final class ReplayCard: ISO7816Card {
    let identifier: Data
    let initialSelectedAID: String
    let applicationData: Data? = nil
    private var replies: [Reply]
    private var violations: [String] = []
    private(set) var commands: [String] = []

    init(_ replies: [Reply], initialSelectedAID: String = "",
         identifier: Data = Data(hexString: "04DEADBEEF0102")) {
        self.replies = replies
        self.initialSelectedAID = initialSelectedAID
        self.identifier = identifier
    }

    func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8) {
        let command = apdu.encoded.hexString
        commands.append(command)
        guard !replies.isEmpty else {
            let message = "Unexpected APDU \(command)"
            violations.append(message)
            throw FixtureFailure(description: message)
        }
        let reply = replies.removeFirst()
        guard command == reply.command else {
            let message = "Expected APDU \(reply.command), got \(command)"
            violations.append(message)
            throw FixtureFailure(description: message)
        }
        if reply.failsTransport { throw ExternalReaderError.noCard }
        return (reply.data, UInt8(reply.status >> 8), UInt8(reply.status & 0xFF))
    }

    func checkComplete() throws {
        // A decoder may swallow an optional read error; it must not hide an
        // unexpected command or silently leave an expected command unissued.
        try check(violations.isEmpty, violations.joined(separator: "; "))
        try check(replies.isEmpty, "Unconsumed APDUs: \(replies.map(\.command))")
    }
}

struct NonISOCard: MiFareCard {
    let identifier = Data([4, 1, 2, 3])
    var mifareFamily: MiFareFamily { .ultralight }
    func sendMiFareCommand(commandPacket: Data) async throws -> Data {
        throw FixtureFailure(description: "Macau Pass must not send MIFARE commands")
    }
}

final class EndlessContinuationCard: ISO7816Card {
    let identifier = Data([4, 1, 2, 3])
    let initialSelectedAID = ""
    let applicationData: Data? = nil
    private(set) var calls = 0
    private(set) var wrongCommand = false
    func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8) {
        calls += 1
        let expected = calls == 1 ? Synthetic.select : "00C0000001"
        if apdu.encoded.hexString != expected { wrongCommand = true }
        // Stop a regressed decoder ourselves, then fail the call-count assertion.
        guard calls <= 64 else { throw FixtureFailure(description: "Unbounded GET RESPONSE") }
        return (Data([0x55]), 0x61, 0x01)
    }
}

enum Synthetic {
    static let aid = "B0C4C3C5CDA8C7AEB0FC"
    static let select = "00A404000AB0C4C3C5CDA8C7AEB0FC00"
    static let infoCommand = "00B0950000"
    static let balanceCommand = "805C000204"
    static let scannedAt = Date(timeIntervalSince1970: 1_800_000_000)

    static func recordCommand(_ number: Int) -> String {
        String(format: "00B2%02XC417", number)
    }

    static func uint32(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func info(serial: String = "12ABCDEF", issue: String = "20240229",
                     expiry: String = "20320630") -> Data {
        var data = Data(repeating: 0x55, count: 28)
        data.replaceSubrange(16..<20, with: Data(hexString: serial))
        data.replaceSubrange(20..<24, with: Data(hexString: issue))
        data.replaceSubrange(24..<28, with: Data(hexString: expiry))
        return data
    }

    static func transaction(sequence: UInt16 = 0x8123, units: UInt32 = 37,
                            type: UInt8 = 0x09, timestamp: String = "20240229123456",
                            terminal: String = "001234005678") -> Data {
        var data = Data(repeating: 0, count: 23)
        data[0] = UInt8(sequence >> 8)
        data[1] = UInt8(sequence & 0xFF)
        data.replaceSubrange(2..<5, with: Data([0x12, 0x34, 0x56]))
        data.replaceSubrange(5..<9, with: uint32(units))
        data[9] = type
        data.replaceSubrange(10..<16, with: Data(hexString: terminal))
        data.replaceSubrange(16..<23, with: Data(hexString: timestamp))
        return data
    }

    static func prefix(info: Data = info(), balance: Data = uint32(1234)) -> [Reply] {
        [Reply(select), Reply(infoCommand, info), Reply(balanceCommand, balance)]
    }

    static func read(_ replies: [Reply]) async throws -> TransitCardSnapshot {
        let card = ReplayCard(replies)
        let snapshot: TransitCardSnapshot
        do {
            snapshot = try await MacauPassDecoder.decode(tag: .iso7816(card), scannedAt: scannedAt)
        } catch {
            try card.checkComplete()
            throw error
        }
        try card.checkComplete()
        return snapshot
    }

    static func expectFailure(_ replies: [Reply]) async throws {
        let card = ReplayCard(replies)
        var failed = false
        do {
            _ = try await MacauPassDecoder.decode(tag: .iso7816(card), scannedAt: scannedAt)
        } catch {
            failed = true
        }
        try card.checkComplete()
        try check(failed, "A card without readable Macau data must not produce a snapshot")
    }
}

@main
struct MacauPassTests {
    static func main() async throws {
        let groups: [(String, () async throws -> Void)] = [
            ("selection", selection), ("read", read), ("errors", errors),
            ("bounds", bounds), ("amounts", amounts), ("dates", dates),
            ("persistence", persistence), ("applications", applications),
        ]
        let requested = CommandLine.arguments.dropFirst().first
        guard requested == nil || groups.contains(where: { $0.0 == requested }) else {
            throw FixtureFailure(description: "Unknown fixture group: \(requested!)")
        }
        for (name, run) in groups where requested == nil || requested == name {
            try await run()
            print("PASS: \(name)")
        }
    }

    static func selection() async throws {
        // canDecode admits ISO-DEP candidates, including co-branded cards
        // initially selected to T-Union. decode must prove the Macau SELECT.
        for initialAID in ["", Synthetic.aid, Synthetic.aid.lowercased(), "A000000632010105"] {
            let card = ReplayCard([], initialSelectedAID: initialAID)
            let supported = await MacauPassDecoder.canDecode(tag: .iso7816(card))
            try check(supported, "ISO-DEP candidate must reach the Macau probe: \(initialAID)")
            try card.checkComplete()
        }

        let other = CardTag.miFare(NonISOCard())
        let acceptsOther = await MacauPassDecoder.canDecode(tag: other)
        try check(!acceptsOther, "MIFARE Ultralight is not an ISO-DEP Macau wallet")
        do {
            _ = try await MacauPassDecoder.decode(tag: other, scannedAt: Synthetic.scannedAt)
            throw FixtureFailure(description: "Decoded an unsupported tag")
        } catch is NFCTestError {}

        let serialOnly = ReplayCard(Synthetic.prefix() + [
            Reply(Synthetic.recordCommand(1), status: 0x6A83),
        ], identifier: Data())
        let snapshot = try await MacauPassDecoder.decode(tag: .iso7816(serialOnly),
                                                        scannedAt: Synthetic.scannedAt)
        try serialOnly.checkComplete()
        try check(snapshot.identifierValue == "12ABCDEF" && snapshot.rawIdentifierValue == "12ABCDEF",
                  "A valid application serial supplies identity when the UID is absent")
        try check(snapshot.applicationSnapshots.first?.identityAlias == "ISO7816|12ABCDEF",
                  "Serial-only scans retain a nonempty wallet identity")

        let unidentified = ReplayCard(Synthetic.prefix(info: Data()) + [
            Reply(Synthetic.recordCommand(1), status: 0x6A83),
        ], identifier: Data())
        do {
            _ = try await MacauPassDecoder.decode(tag: .iso7816(unidentified),
                                                  scannedAt: Synthetic.scannedAt)
            throw FixtureFailure(description: "A valid balance without serial or UID must not create a wallet")
        } catch is NFCTestError {}
        try unidentified.checkComplete()
    }

    static func read() async throws {
        let debit = Synthetic.transaction()
        let credit = Synthetic.transaction(sequence: 0x8122, units: 500, type: 0x02)
        let snapshot = try await Synthetic.read(Synthetic.prefix() + [
            Reply(Synthetic.recordCommand(1), debit),
            Reply(Synthetic.recordCommand(2), credit),
            Reply(Synthetic.recordCommand(3), status: 0x6A83),
        ])
        try check(snapshot.brand == .macauPass, "Snapshot brand")
        try check(snapshot.technology == "ISO7816", "Snapshot technology")
        try check(snapshot.selectedAID == Synthetic.aid, "Selected wallet AID")
        try check(snapshot.scannedAt == Synthetic.scannedAt, "Scan timestamp must be preserved")
        try check(snapshot.identifierValue == "12ABCDEF", "Serial is forward uppercase hex")
        try check(snapshot.balanceText == formatCurrency(amount: Decimal(1134) / 10,
                                                        code: "MOP", fractionDigits: 2),
                  "Balance uses tenths of MOP minus the MOP 10 reserve")
        try check(snapshot.rawTransactions == [debit.hexString, credit.hexString],
                  "Persist payloads without status words or invented prefixes")
        try check(snapshot.transactions.count == 2, "Snapshot decodes through the production registry")
        try check(snapshot.transactions.allSatisfy { $0.currencyCode == "MOP" }, "Snapshot history currency")
        try check(snapshot.resultFields.contains { $0.value == "2024-02-29" }, "Issue date")
        try check(snapshot.resultFields.contains { $0.value == "2032-06-30" }, "Expiry date")
    }

    static func errors() async throws {
        for status: UInt16 in [0x9001, 0x6A82, 0x6982, 0x6A83, 0x6F00, 0x6300] {
            try await Synthetic.expectFailure([Reply(Synthetic.select, status: status)])

            let noInfo = try await Synthetic.read([
                Reply(Synthetic.select),
                Reply(Synthetic.infoCommand, Synthetic.info(), status: status),
                Reply(Synthetic.balanceCommand, Synthetic.uint32(1234)),
                Reply(Synthetic.recordCommand(1), status: 0x6A83),
            ])
            try check(noInfo.realSerialNumber == nil, "Unsuccessful info cannot supply a serial")
            try check(noInfo.balanceText != nil, "Unavailable info must preserve a valid balance")

            let noBalance = try await Synthetic.read([
                Reply(Synthetic.select), Reply(Synthetic.infoCommand, Synthetic.info()),
                Reply(Synthetic.balanceCommand, Synthetic.uint32(1234), status: status),
                Reply(Synthetic.recordCommand(1), Synthetic.transaction()),
                Reply(Synthetic.recordCommand(2), status: 0x6A83),
            ])
            try check(noBalance.balanceText == nil, "Unsuccessful balance must remain unknown")
            try check(noBalance.transactions.count == 1, "Failed balance must not erase history")

            let noHistory = try await Synthetic.read(Synthetic.prefix() + [
                Reply(Synthetic.recordCommand(1), Synthetic.transaction(), status: status),
            ])
            try check(noHistory.transactions.isEmpty && noHistory.rawTransactions.isEmpty,
                      "A status error cannot contribute history bytes")
            try check(noHistory.balanceText != nil, "History failure must preserve the purse")
        }

        let historyOnly = try await Synthetic.read([
            Reply(Synthetic.select),
            Reply(Synthetic.infoCommand, status: 0x6A82),
            Reply(Synthetic.balanceCommand, status: 0x6982),
            Reply(Synthetic.recordCommand(1), Synthetic.transaction()),
            Reply(Synthetic.recordCommand(2), status: 0x6A83),
        ])
        try check(historyOnly.balanceText == nil && historyOnly.transactions.count == 1,
                  "A readable history alone is a useful partial scan")
        try await Synthetic.expectFailure([
            Reply(Synthetic.select),
            Reply(Synthetic.infoCommand, status: 0x6A82),
            Reply(Synthetic.balanceCommand, status: 0x6982),
            Reply(Synthetic.recordCommand(1), status: 0x6A83),
        ])
        try await Synthetic.expectFailure([
            Reply(Synthetic.select), Reply(Synthetic.infoCommand),
            Reply(Synthetic.balanceCommand), Reply(Synthetic.recordCommand(1)),
        ])
        try await Synthetic.expectFailure([Reply(Synthetic.select, failsTransport: true)])
        for failingIndex in 1...3 {
            var replies = Synthetic.prefix() + [Reply(Synthetic.recordCommand(1), status: 0x6A83)]
            let command = replies[failingIndex].command
            replies[failingIndex] = Reply(command, failsTransport: true)
            let partial = try await Synthetic.read(replies)
            try check(partial.realSerialNumber != nil || partial.balanceText != nil,
                      "Optional transport errors preserve other readable fields")
        }

        // A 6C status retries the same command once with the supplied Le.
        let retry = try await Synthetic.read([
            Reply(Synthetic.select, status: 0x6C1C),
            Reply("00A404000AB0C4C3C5CDA8C7AEB0FC1C"),
            Reply(Synthetic.infoCommand, status: 0x6C1C),
            Reply("00B095001C", Synthetic.info()),
            Reply(Synthetic.balanceCommand, status: 0x6C00),
            Reply("805C000200", Synthetic.uint32(1234)),
            Reply(Synthetic.recordCommand(1), status: 0x6C17),
            Reply(Synthetic.recordCommand(1), Synthetic.transaction()),
            Reply(Synthetic.recordCommand(2), status: 0x6A83),
        ])
        try check(retry.transactions.count == 1 && retry.balanceText != nil, "6C correction")
        try await Synthetic.expectFailure([
            Reply(Synthetic.select, status: 0x6C1C),
            Reply("00A404000AB0C4C3C5CDA8C7AEB0FC1C", status: 0x6C1C),
        ])

        // Chunks carry payload only; the transport already separates SW1/SW2.
        let info = Synthetic.info()
        let balance = Synthetic.uint32(1234)
        let history = Synthetic.transaction()
        let continued = try await Synthetic.read([
            Reply(Synthetic.select, Data([0x6F]), status: 0x6100),
            Reply("00C0000000", Data([0])),
            Reply(Synthetic.infoCommand, Data(info.prefix(12)), status: 0x6110),
            Reply("00C0000010", Data(info.suffix(16))),
            Reply(Synthetic.balanceCommand, Data(balance.prefix(1)), status: 0x6101),
            Reply("00C0000001", Data(balance[1..<2]), status: 0x6102),
            Reply("00C0000002", Data(balance.suffix(2))),
            Reply(Synthetic.recordCommand(1), Data(history.prefix(7)), status: 0x6110),
            Reply("00C0000010", Data(history.suffix(16))),
            Reply(Synthetic.recordCommand(2), status: 0x6A83),
        ])
        try check(continued.identifierValue == "12ABCDEF", "Chained info is reassembled")
        try check(continued.balanceText == retry.balanceText, "Chained balance is reassembled")
        try check(continued.rawTransactions == [history.hexString], "Chained history is reassembled")

        let badContinuation = try await Synthetic.read([
            Reply(Synthetic.select), Reply(Synthetic.infoCommand, info),
            Reply(Synthetic.balanceCommand, Data(balance.prefix(2)), status: 0x6102),
            Reply("00C0000002", Data(balance.suffix(2)), status: 0x9001),
            Reply(Synthetic.recordCommand(1), status: 0x6A83),
        ])
        try check(badContinuation.balanceText == nil, "Failed continuation cannot yield a balance")

        let endless = EndlessContinuationCard()
        var failed = false
        do {
            _ = try await MacauPassDecoder.decode(tag: .iso7816(endless), scannedAt: Synthetic.scannedAt)
        } catch {
            failed = true
        }
        try check(failed && endless.calls > 1 && endless.calls <= 64,
                  "An endless 61 response must stop within a finite command budget")
        try check(!endless.wrongCommand, "Continuation must use GET RESPONSE without fallback selections")
        try await Synthetic.expectFailure([
            Reply(Synthetic.select, Data(repeating: 0x55, count: 16_385)),
        ])
    }

    static func bounds() async throws {
        for length in 0..<23 {
            let data = Data(Synthetic.transaction().prefix(length))
            try check(MacauPassDecoder.decodeTransaction(data) == nil,
                      "Accepted truncated history payload of \(length) bytes")
            let snapshot = try await Synthetic.read(Synthetic.prefix() + [
                Reply(Synthetic.recordCommand(1), data),
            ])
            try check(snapshot.rawTransactions.isEmpty && snapshot.balanceText != nil,
                      "Short history terminates reads without discarding balance")
        }
        try check(MacauPassDecoder.decodeTransaction(Data(repeating: 0, count: 23)) == nil,
                  "All-zero history slot is empty")
        for length in [24, 25, 46, 256] {
            let data = Synthetic.transaction() + Data(repeating: 0, count: length - 23)
            try check(MacauPassDecoder.decodeTransaction(data) == nil,
                      "History must be exactly 23 bytes, got \(length)")
            let snapshot = try await Synthetic.read(Synthetic.prefix() + [
                Reply(Synthetic.recordCommand(1), data),
            ])
            try check(snapshot.rawTransactions.isEmpty && snapshot.balanceText != nil,
                      "Oversized history is not a transaction and preserves the purse")
        }
        for length in 0..<28 {
            let snapshot = try await Synthetic.read(
                Synthetic.prefix(info: Data(Synthetic.info().prefix(length))) +
                [Reply(Synthetic.recordCommand(1), status: 0x6A83)]
            )
            try check(snapshot.balanceText != nil, "Truncated info preserves readable balance")
            if length < 20 {
                try check(snapshot.realSerialNumber == nil, "Incomplete serial must not be invented")
            }
            if length < 24 {
                try check(!snapshot.resultFields.contains { $0.value == "2024-02-29" },
                          "Incomplete issue date must not be invented")
            }
            try check(!snapshot.resultFields.contains { $0.value == "2032-06-30" },
                      "Incomplete expiry date must not be invented")
        }
        for length in [0, 1, 2, 3, 5, 6, 8] {
            let snapshot = try await Synthetic.read(
                Synthetic.prefix(balance: Data(repeating: 1, count: length)) +
                [Reply(Synthetic.recordCommand(1), status: 0x6A83)]
            )
            try check(snapshot.balanceText == nil, "Balance payload must be exactly four bytes")
            try check(snapshot.realSerialNumber == "12ABCDEF", "Invalid balance preserves serial")
        }
        let records = (1...30).map { Synthetic.transaction(sequence: UInt16($0)) }
        let snapshot = try await Synthetic.read(Synthetic.prefix() + records.enumerated().map {
            Reply(Synthetic.recordCommand($0.offset + 1), $0.element)
        })
        try check(snapshot.rawTransactions.count == 30, "History read cap is 30 records")
        try check(Set(snapshot.transactions.compactMap(\.recordNumber)) == Set(1...30),
                  "Every bounded history record is decoded")

        let invalid = Synthetic.transaction(timestamp: "20230229123456")
        let sparse = try await Synthetic.read(Synthetic.prefix() + [
            Reply(Synthetic.recordCommand(1), Data(repeating: 0, count: 23)),
            Reply(Synthetic.recordCommand(2), invalid),
            Reply(Synthetic.recordCommand(3), Synthetic.transaction()),
            Reply(Synthetic.recordCommand(4), status: 0x6A83),
        ])
        try check(sparse.rawTransactions == [invalid.hexString, Synthetic.transaction().hexString],
                  "Empty slots are omitted; undecodable complete records retain their evidence")
        try check(sparse.transactions.count == 1, "Invalid history cannot become a normalized transaction")
        try check(sparse.applications?.first?.records.map(\.index) == [2, 3],
                  "History preserves original on-card record indexes after empty slots")
        try await Synthetic.expectFailure([
            Reply(Synthetic.select), Reply(Synthetic.infoCommand),
            Reply(Synthetic.balanceCommand),
            Reply(Synthetic.recordCommand(1), invalid),
            Reply(Synthetic.recordCommand(2), status: 0x6A83),
        ])
        for serial in ["00000000", "FFFFFFFF"] {
            let partial = try await Synthetic.read(Synthetic.prefix(info: Synthetic.info(serial: serial)) + [
                Reply(Synthetic.recordCommand(1), status: 0x6A83),
            ])
            try check(partial.realSerialNumber == nil && partial.balanceText != nil,
                      "Placeholder serial \(serial) must not erase valid balance")
        }
    }

    static func amounts() async throws {
        let debit = try requireTransaction(Synthetic.transaction())
        try check(debit.amount == Decimal(-37) / 10, "Debit unit is 0.1 MOP")
        try check(debit.recordNumber == 0x8123, "Sequence is unsigned big endian")
        try check(debit.terminalID == "001234005678", "Terminal preserves leading zeroes")
        try check(debit.currencyCode == "MOP", "Transaction currency")
        try check(debit.issuerTimeZone == "Asia/Macau" && debit.amountIsSigned && debit.amountKnown,
                  "Debit carries the issuer clock and a known signed amount")
        try check(debit.balanceAfter == nil, "History does not encode a post-transaction balance")
        try check(debit.rawData == Synthetic.transaction().hexString, "Preserve original history bytes")

        let credit = try requireTransaction(Synthetic.transaction(units: 500, type: 0x02))
        try check(credit.amount == 50 && credit.category == .topUp,
                  "Top-up is positive, with no reserve deducted")
        let hexTerminal = try requireTransaction(Synthetic.transaction(terminal: "0000ABCDEF98"))
        try check(hexTerminal.terminalID == "0000ABCDEF98", "Terminal is an opaque hex identifier")
        let otherDebit = try requireTransaction(Synthetic.transaction(type: 0x06))
        try check(otherDebit.amount == Decimal(-37) / 10, "Type 06 is also a debit")
        for units: UInt32 in [0, 1, 0x01000001, 0x80000000, 0xFFFFFFFF] {
            let transaction = try requireTransaction(Synthetic.transaction(sequence: 0xFFFF, units: units))
            try check(transaction.amount == -Decimal(UInt64(units)) / 10,
                      "All four amount bytes are unsigned: \(units)")
            try check(transaction.recordNumber == 65535, "Maximum unsigned sequence")
        }
        let unknown = try requireTransaction(Synthetic.transaction(type: 0xFE))
        try check(unknown.category == .unknown, "Unknown type must not invent a transport category")
        try check(unknown.amount == 0, "Unknown type must not invent a signed amount")
        try check(unknown.currencyCode == "MOP" && unknown.balanceAfter == nil, "Unknown type provenance")
        try check(!unknown.amountKnown, "Unknown type amount must display as unavailable")
        for units: UInt32 in [0, 1, 99, 100, 1234, 0x7FFFFFFF] {
            let snapshot = try await Synthetic.read(
                Synthetic.prefix(balance: Synthetic.uint32(units)) +
                [Reply(Synthetic.recordCommand(1), status: 0x6A83)]
            )
            let expected = formatCurrency(amount: Decimal(UInt64(units)) / 10 - 10,
                                          code: "MOP", fractionDigits: 2)
            try check(snapshot.balanceText == expected, "Unsigned balance minus reserve: \(units)")
        }
        for units: UInt32 in [0x80000000, 0x80000001, 0xFFFFFFFF] {
            let bytes = Synthetic.uint32(units)
            let snapshot = try await Synthetic.read(Synthetic.prefix(balance: bytes) + [
                Reply(Synthetic.recordCommand(1), status: 0x6A83),
            ])
            try check(snapshot.balanceText == nil, "Unsupported high-bit balance must stay unavailable")
            try check(snapshot.rawSections.flatMap(\.fields).contains { $0.value.contains(bytes.hexString) },
                      "Unsupported high-bit balance retains raw diagnostic bytes")
        }
        try check(ICCardBrand.macauPass.region == .macau, "Macau region")
        try check(ICCardRegion.macau.currencyCode == "MOP", "Macau currency")
        try check(CardDateFormatting.issuerTimeZone(for: .macauPass)?.identifier == "Asia/Macau",
                  "Macau issuer time zone")
    }

    static func dates() async throws {
        // Epoch constants were calculated independently, without production date helpers.
        let dates: [(String, TimeInterval)] = [
            ("20240229123456", 1_709_181_296),
            ("20000229000000", 951_753_600),
            ("20251231235959", 1_767_196_799),
            ("20260101000000", 1_767_196_800),
            ("21000301000000", 4_107_513_600),
        ]
        for (stamp, epoch) in dates {
            let transaction = try requireTransaction(Synthetic.transaction(timestamp: stamp))
            try check(transaction.date?.timeIntervalSince1970 == epoch,
                      "Full BCD year and Asia/Macau timestamp \(stamp)")
        }
        for stamp in [
            "20230229123456", "21000229123456", "20240431123456",
            "20240001123456", "20241301123456", "20240100123456",
            "20240132123456", "20240229243456", "20240229126056",
            "20240229123460", "2024022912346A", "2024FA29123456",
            "00000000000000", "FFFFFFFFFFFFFF",
        ] {
            try check(MacauPassDecoder.decodeTransaction(Synthetic.transaction(timestamp: stamp)) == nil,
                      "Invalid BCD/calendar timestamp must not normalize: \(stamp)")
        }
        for offset in 16..<23 {
            var data = Synthetic.transaction()
            data[offset] = 0x1A
            try check(MacauPassDecoder.decodeTransaction(data) == nil,
                      "Invalid BCD nibble at timestamp byte \(offset)")
        }
        let clock = try requireTransaction(Synthetic.transaction())
        try check(clock.time == "12:34:56", "Displayed transaction time uses the issuer clock")
        for date in ["20230229", "21000229", "20240431", "20241301", "20240001",
                     "20240100", "2024FA29", "00000000", "FFFFFFFF"] {
            let snapshot = try await Synthetic.read(
                Synthetic.prefix(info: Synthetic.info(issue: date, expiry: date)) +
                [Reply(Synthetic.recordCommand(1), status: 0x6A83)]
            )
            try check(!snapshot.resultFields.contains { ["Issue Date", "Expiry Date"].contains($0.title) },
                      "Invalid metadata dates must not normalize: \(date)")
            try check(snapshot.realSerialNumber == "12ABCDEF" && snapshot.balanceText != nil,
                      "Invalid optional dates preserve the serial and purse")
        }
    }

    static func persistence() async throws {
        let raw = [
            Synthetic.transaction().hexString,
            Synthetic.transaction(sequence: 7, units: 900, type: 0x02).hexString,
        ]
        let persisted = try JSONDecoder().decode([String].self, from: JSONEncoder().encode(raw))
        for family in ["Macau Pass", "macaupass", "macau-pass", "\u{6FB3}\u{95E8}\u{901A}",
                       "\u{6FB3}\u{9580}\u{901A}"] {
            try check(ICCardBrand.from(family: family) == .macauPass, "Persisted family alias \(family)")
            let transactions = persisted.enumerated().compactMap {
                TransactionDecoderRegistry.decode(raw: $0.element, family: family, technology: "ISO7816",
                                                  context: persisted, at: $0.offset)
            }
            try check(transactions.count == 2, "Registry routes persisted Macau history: \(family)")
            try check(transactions[0].amount == Decimal(-37) / 10 && transactions[1].amount == 90,
                      "Reload preserves amount unit and sign")
            try check(transactions.map(\.rawData) == persisted.map(Optional.some), "Reload preserves raw records")
            try check(transactions.allSatisfy { $0.currencyCode == "MOP" }, "Reload keeps MOP, not generic CNY")
            try check(transactions[0].recordNumber == 0x8123, "Reload preserves record sequence")
            try check(transactions[0].date?.timeIntervalSince1970 == 1_709_181_296, "Reload preserves timestamp")
            let roundTrip = try JSONDecoder().decode([TransitTransaction].self,
                                                     from: JSONEncoder().encode(transactions))
            try check(roundTrip == transactions, "Codable transaction round trip")
        }
        let empty = String(repeating: "00", count: 23)
        try check(TransactionDecoderRegistry.decode(raw: empty, family: "Macau Pass", technology: "ISO7816",
                                                    context: [empty], at: 0) == nil, "Reload ignores empty slots")
        let record = Synthetic.transaction().hexString
        try check(TransactionDecoderRegistry.decode(raw: record, family: "Macau Pass", technology: "ISO7816",
                                                    context: [record], at: 0, kind: .transit) == nil,
                  "Macau Pass has no separate transit-history layout")
        try check(TransactionDecoderRegistry.decode(raw: record, family: "Macau Pass", technology: "FeliCa",
                                                    context: [record], at: 0) == nil,
                  "Macau Pass history requires its ISO 7816 application")
    }

    static func applications() async throws {
        let raw = Synthetic.transaction().hexString
        let macau = try await Synthetic.read(Synthetic.prefix() + [
            Reply(Synthetic.recordCommand(1), Synthetic.transaction()),
            Reply(Synthetic.recordCommand(2), status: 0x6A83),
        ])
        let cnyBalance = formatCurrency(amount: 8, code: "CNY", fractionDigits: 2)
        let tu = TransitCardSnapshot(
            technology: "ISO7816", cardFamily: "China T-Union",
            identifierLabel: "UID", identifierValue: macau.rawIdentifierValue,
            rawIdentifierValue: macau.rawIdentifierValue, pmm: nil, systemCode: nil,
            selectedAID: TUnionDecoder.applicationAID, balanceText: cnyBalance, balanceDetail: nil,
            realSerialNumber: "12345678", region: "China", resultFields: [], rawSections: [],
            rawTransactions: [raw], rawTransitHistory: [], scannedAt: Synthetic.scannedAt.addingTimeInterval(60))

        for snapshots in [[macau, tu], [tu, macau]] {
            guard let combined = TransitCardSnapshot.combining(snapshots),
                  let apps = combined.applications else {
                throw FixtureFailure(description: "Production application composition failed")
            }
            try check(combined.brand == .macauPass && combined.selectedAID == Synthetic.aid,
                      "Macau remains primary regardless of application ordering")
            try check(combined.balanceText == macau.balanceText, "Newer CNY purse must not replace MOP")
            try check(apps.count == 2, "Separate purses retain separate applications")
            try check(TransitApplication.primary(in: apps)?.selectedAID == Synthetic.aid,
                      "Primary application remains the Macau wallet")
            let restored = try JSONDecoder().decode([TransitApplication].self,
                                                    from: JSONEncoder().encode(apps))
            try check(restored == apps, "Application records and metadata survive persistence")
            let history = TransitApplicationHistory.decode(restored, kind: .transactions)
            try check(history.count == 2, "Identical raw bytes in different currencies must not deduplicate")
            let mop = history.first { $0.currencyCode == "MOP" }
            let cny = history.first { $0.currencyCode == "CNY" }
            try check(mop?.amount == Decimal(-37) / 10 && cny?.amount == Decimal(-37) / 100,
                      "Reload uses each application's currency and amount scale")
            try check(mop?.sourceApplicationID == "ISO7816:\(Synthetic.aid)",
                      "Macau history retains wallet identity")
            try check(cny?.sourceApplicationID == "ISO7816:\(TUnionDecoder.applicationAID)",
                      "Companion history retains wallet identity")
            try check(Set(history.map(\.stableID)).count == 2, "Persisted event identities include the wallet")
            try check(history.allSatisfy { $0.sourceRecordIDs?.count == 1 && $0.rawData == raw },
                      "Each event keeps its own application/file provenance")
        }

        let noBalance = try await Synthetic.read([
            Reply(Synthetic.select), Reply(Synthetic.infoCommand, Synthetic.info()),
            Reply(Synthetic.balanceCommand, status: 0x6982),
            Reply(Synthetic.recordCommand(1), status: 0x6A83),
        ])
        let combined = TransitCardSnapshot.combining([tu, noBalance])!
        try check(combined.balanceText == nil && combined.brand == .macauPass,
                  "An unavailable Macau balance must not display a companion CNY balance")

        let uidAlias = "ISO7816UID|\(macau.rawIdentifierValue)"
        try check(macau.identityAliases.isSuperset(of: ["ISO7816|12ABCDEF", uidAlias]),
                  "Macau wallet identity includes its serial and UID")
        let noSerial = try await Synthetic.read([
            Reply(Synthetic.select), Reply(Synthetic.infoCommand, status: 0x6A82),
            Reply(Synthetic.balanceCommand, Synthetic.uint32(1234)),
            Reply(Synthetic.recordCommand(1), status: 0x6A83),
        ])
        try check(!noSerial.identityAliases.isDisjoint(with: macau.identityAliases),
                  "A rescan without the serial still matches the same wallet by UID")
        let merged = TransitApplication.merge(existing: macau.applicationSnapshots,
                                               incoming: noBalance.applicationSnapshots)
        try check(merged.first?.balanceText == macau.balanceText,
                  "A partial rescan must preserve the last known Macau balance")
        try check(merged.first?.records.count == 1, "A partial rescan must preserve recorded Macau history")

        TUnionDecoder.companion = tu
        TUnionDecoder.readCount = 0
        defer { TUnionDecoder.companion = nil }
        let readWithCompanion = try await Synthetic.read(Synthetic.prefix() + [
            Reply(Synthetic.recordCommand(1), Synthetic.transaction()),
            Reply(Synthetic.recordCommand(2), status: 0x6A83),
        ])
        try check(TUnionDecoder.readCount == 1, "Successful Macau decode attempts the companion once")
        try check(readWithCompanion.applications?.count == 2 && readWithCompanion.transactions.count == 2,
                  "Decoder composes a successful companion through production application models")
        try check(readWithCompanion.brand == .macauPass && readWithCompanion.balanceText == macau.balanceText,
                  "Companion integration preserves the Macau purse")
    }
}
'''


@unittest.skipUnless(
    sys.platform == "darwin" and shutil.which("swiftc"), "Requires Swift on macOS"
)
class MacauPassTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="cardbal-macau-pass-")
        cls.addClassCleanup(directory.cleanup)
        directory = Path(directory.name)
        utils = (ROOT / "ios/CardBal/NFC/NFCUtils.swift").read_text()
        # Extract the real models and registry, leaving SwiftUI out of this executable.
        models = "import Foundation\nimport os\n"
        models += utils[
            utils.index("public enum ICCardRegion"):
            utils.index("extension TransitTransaction {")
        ]
        models += utils[
            utils.index("struct TransitCardSnapshot:"):utils.index("enum StatusKind")
        ]
        models += utils[
            utils.index("extension Data {"):utils.index("struct BERTLVNode")
        ]
        models += utils[
            utils.index("func formatCurrency("):utils.index("func formatUTF8OrHex")
        ]
        saved = (ROOT / "ios/CardBal/Models/SavedCardRecord.swift").read_text()
        models += saved[
            saved.index("struct SavedCardField:"):saved.index("struct SavedCardColor:")
        ]
        applications = (ROOT / "ios/CardBal/Models/TransitApplications.swift").read_text()
        # Keep real application records, composition, persistence, and history
        # decoding, excluding the extension that depends on the full UI wallet.
        models += applications[:applications.index("extension SavedCardRecord {")]
        models += applications[applications.index("enum TransitApplicationHistory {"):]
        dates = (ROOT / "ios/CardBal/Utils/DateFormatting.swift").read_text()
        models += dates[:dates.index("struct KSX6924DateFormatting")]
        source = directory / "Models.swift"
        source.write_text(models)
        fixture = directory / "MacauPassTests.swift"
        fixture.write_text(FIXTURE)
        cls.executable = directory / "macau-pass-tests"
        sources = [
            "ios/CardBal/NFC/CardTransport.swift",
            "ios/CardBal/NFC/Decoders/TransitCardDecoder.swift",
            "ios/CardBal/NFC/Profiles/SnapperPlusProtocol.swift",
            "ios/CardBal/NFC/Decoders/MacauPassDecoder.swift",
        ]
        result = subprocess.run(
            [
                "swiftc", "-parse-as-library", str(source),
                *[str(ROOT / path) for path in sources], str(fixture),
                "-o", str(cls.executable),
            ],
            capture_output=True,
            text=True,
            timeout=180,
        )
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)

    def run_fixture(self, group, time_zone="UTC"):
        result = subprocess.run(
            [str(self.executable), group],
            capture_output=True,
            text=True,
            timeout=30,
            env={**os.environ, "TZ": time_zone},
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"PASS: {group}", result.stdout)

    def test_selection_and_detection(self):
        self.run_fixture("selection")

    def test_exact_read_commands_and_snapshot(self):
        self.run_fixture("read")

    def test_status_errors_and_optional_data(self):
        self.run_fixture("errors")

    def test_truncated_payloads_and_history_bound(self):
        self.run_fixture("bounds")

    def test_unsigned_fields_and_currency(self):
        self.run_fixture("amounts")

    def test_timestamp_validity_and_issuer_time_zone(self):
        for time_zone in ("UTC", "America/Los_Angeles", "Asia/Tokyo"):
            with self.subTest(time_zone=time_zone):
                self.run_fixture("dates", time_zone)

    def test_persisted_history_uses_production_registry(self):
        self.run_fixture("persistence")

    def test_companion_wallet_keeps_currency_and_identity(self):
        self.run_fixture("applications")

    def test_envelope_router_does_not_claim_macau_families(self):
        # The fixture stubs AdditionalCardHistory, which the production
        # registry consults before the Macau Pass route.
        source = (ROOT / "ios/CardBal/NFC/Profiles/AdditionalCardHistory.swift").read_text()
        families = re.search(r"static let families: Set<String> = \[(.*?)\]", source).group(1)
        claimed = set(re.findall(r'"([^"]*)"', families))
        self.assertFalse(claimed & set(MACAU_ALIASES))


if __name__ == "__main__":
    unittest.main()
