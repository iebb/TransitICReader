import Foundation
struct ResultField { let title: String; let value: String }
struct RawDataField { let title: String; let value: String }
struct RawDataSection { let title: String; let fields: [RawDataField] }
struct TransitCardSnapshot {
 let technology: String, cardFamily: String, identifierLabel: String, identifierValue: String, rawIdentifierValue: String
 let pmm: String?, systemCode: String?, selectedAID: String?, balanceText: String?, balanceDetail: String?, realSerialNumber: String?, region: String?
 let resultFields: [ResultField], rawSections: [RawDataSection], rawTransactions: [String], rawTransitHistory: [String], scannedAt: Date
}
enum NFCTestError: Error { case unsupportedCard }
struct UnsupportedDecoder: TransitCardDecoder {
 static func canDecode(tag: CardTag) async -> Bool { false }
 static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot { throw NFCTestError.unsupportedCard }
}
typealias EdyDecoder = UnsupportedDecoder
typealias StoredValueDecoder = UnsupportedDecoder
typealias TianfuTongDecoder = UnsupportedDecoder
typealias WAONDecoder = UnsupportedDecoder
typealias NanacoDecoder = UnsupportedDecoder
typealias JapaneseICDecoder = UnsupportedDecoder
typealias KSX6924Decoder = UnsupportedDecoder
typealias CalypsoDecoder = UnsupportedDecoder
struct ChineseTransitDecoder: TransitCardDecoder {
 static func canDecode(tag: CardTag) async -> Bool { false }
 static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot { throw NFCTestError.unsupportedCard }
}
struct CityUnionDecoder { static let applicationAID = "A00000000386980701" }
struct TUnionDecoder { static let applicationAID = "A000000632010105" }
extension Data {
 var hexString: String { map { String(format: "%02X", $0) }.joined() }
 init(hexString: String) { self.init(stride(from: 0, to: hexString.count, by: 2).map { i in let a=hexString.index(hexString.startIndex,offsetBy:i); return UInt8(hexString[a..<hexString.index(a,offsetBy:2)],radix:16)! }) }
}
func formatFeliCaIDm(_ idm: String) -> String { idm }
func formatCurrency(amount: Decimal, code: String, fractionDigits: Int) -> String { "\(code) \(amount)" }

enum TransactionCategory { case train, bus, topUp, refund, payment, adjustment, unknown }
struct TransitTransaction {
    let date: Date?, amount: Decimal, terminalID: String?, type: String, category: TransactionCategory
    let location: String?, rawData: String?
    var currencyCode: String? = nil
}

final class ScriptedChannel: CardCommandChannel {
    var script: [(Data, Data, UInt8, UInt8)]
    init(_ script: [(Data, Data, UInt8, UInt8)]) { self.script = script }
    func exchange(_ command: Data) async throws -> (Data, UInt8, UInt8) {
        precondition(!script.isEmpty, "Unexpected command")
        let (expected, body, sw1, sw2) = script.removeFirst()
        precondition(command == expected, "Incorrect command framing")
        return (body, sw1, sw2)
    }
}
final class PurseCard: ISO7816Card {
    let identifier = Data([1, 2, 3, 4]), initialSelectedAID = "", applicationData: Data? = nil
    var commands: [Data] = []
    let purse: Data, history: Data
    init(purse: Data, history: Data) { self.purse = purse; self.history = history }
    func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8) {
        commands.append(apdu.encoded)
        return (commands.count == 1 ? purse : history, 0x90, 0)
    }
}
@main struct ExternalReaderTests {
    static func main() async throws {
        // Short and extended APDUs round-trip without confusing Le with Lc.
        for hex in ["00A40400", "9032030000", "00A4040002FE00", "00A4040002FE0000", "00CA0000000100"] {
            let raw = Data(hexString: hex)
            precondition(CardAPDU(data: raw)?.encoded == raw, "APDU case round trip")
        }
        let extended = CardAPDU(instructionClass: 0, instructionCode: 0xA4, p1Parameter: 4, p2Parameter: 0,
                                data: Data(repeating: 0x42, count: 300), expectedResponseLength: 65536)
        precondition(CardAPDU(data: extended.encoded)?.encoded == extended.encoded)
        for hex in ["00", "00A4040002AA", "00A404000000", "00A4040001AA0001"] {
            precondition(CardAPDU(data: Data(hexString: hex)) == nil, "Truncated APDU accepted")
        }

        let idm = Data(hexString: "0102030405060708")
        let pmm = Data(repeating: 0x11, count: 8)
        let pollCommand = Data(hexString: "FF00000009D44A010100FE000100")
        let pollResponse = Data(hexString: "D54B01011401") + idm + pmm + Data([0xFE, 0])
        let readCommand = Data(hexString: "FF00000013D440011006") + idm + Data(hexString: "011713018000")
        let block = Data(hexString: "1E020000000000000000000000000000")
        let readResponse = Data(hexString: "D541001D07") + idm + Data([0, 0, 1]) + block
        let channel = ScriptedChannel([(pollCommand, pollResponse, 0x90, 0), (readCommand, readResponse, 0x90, 0)])
        let felica = ACR122FeliCaCard(connection: channel)
        let (actualPMm, requestData) = try await felica.polling(systemCode: Data([0xFE, 0]), requestCode: .systemCode, timeSlot: .max1)
        precondition(felica.currentIDm == idm && actualPMm == pmm && requestData == Data([0xFE, 0]))
        let read = try await felica.readWithoutEncryption(serviceCodeList: [Data([0x17, 0x13])], blockList: [Data([0x80, 0])])
        precondition(read.0 == 0 && read.1 == 0 && read.2 == [block] && channel.script.isEmpty)

        // Short PN532 packets, card errors, and mismatched IDs must not decode.
        for bad in [Data(hexString: "D541001D07"), Data(hexString: "D541001D07") + Data(repeating: 0, count: 8) + Data([0, 0, 1]) + block,
                    Data(hexString: "D54101")] {
            let c = ScriptedChannel([(pollCommand, pollResponse, 0x90, 0), (readCommand, bad, 0x90, 0)])
            let f = ACR122FeliCaCard(connection: c)
            _ = try await f.polling(systemCode: Data([0xFE, 0]), requestCode: .systemCode, timeSlot: .max1)
            var rejected = false
            do { _ = try await f.readWithoutEncryption(serviceCodeList: [Data([0x17, 0x13])], blockList: [Data([0x80, 0])]) }
            catch { rejected = true }
            precondition(rejected, "Malformed FeliCa response accepted")
        }
        let continuation = ScriptedChannel([(Data(hexString: "FF00000002D402"), Data(), 0x61, 2),
                                            (Data(hexString: "FFC0000002"), Data([0xD5, 3]), 0x90, 0)])
        let continued = try await continuation.pn532(Data([0xD4, 2]))
        precondition(continued == Data([0xD5, 3]) && continuation.script.isEmpty)

        // Synthetic CEPAS data: signed 24-bit cents, CAN, SGT epoch, and exact
        // implicit GET PURSE / GET HISTORY commands; no application SELECT.
        var purse = Data(repeating: 0, count: 64)
        purse[0] = 2; purse[2] = 0xFF; purse[3] = 0xFF; purse[4] = 0x9C
        purse.replaceSubrange(8..<16, with: Data(hexString: "1000000000000001"))
        purse[40] = 2
        var transaction = Data(repeating: 0, count: 16)
        transaction[0] = 0x31; transaction[1] = 0xFF; transaction[2] = 0xFF; transaction[3] = 0x9C
        transaction[7] = 60
        let iso = PurseCard(purse: purse, history: transaction + Data(repeating: 0, count: 16))
        let snapshot = try await CEPASDecoder.decode(tag: .iso7816(iso), scannedAt: Date())
        precondition(snapshot.balanceText == "SGD -1" && snapshot.rawTransactions.count == 1)
        precondition(iso.commands == [Data(hexString: "9032030000"), Data(hexString: "90320300010000")])
        let decoded = CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(transaction)!)!
        precondition(decoded.amountMinor == -100 && decoded.kind == .bus)
        for kind: UInt8 in [0xF0, 0x05] {
            var activation = transaction; activation[0] = kind
            precondition(!CEPASProtocol.decodeHistory(CEPASProtocol.encodeHistory(activation)!)!.hasMonetaryAmount)
        }
        for size in 0..<63 { precondition(CEPASProtocol.parsePurse(Data(purse.prefix(size))) == nil) }
        purse[41] = 20
        precondition(CEPASProtocol.parsePurse(purse) == nil)
        let chosen = try ExternalReaderSelection.choose(preferred: "Reader B", available: ["Reader A", "Reader B"]); precondition(chosen == "Reader B")
        let automatic = try ExternalReaderSelection.choose(preferred: nil, available: ["Reader B", "Reader A"]); precondition(automatic == "Reader A")
        var rejected = false
        do { _ = try ExternalReaderSelection.choose(preferred: "Disconnected", available: ["Other Reader"]) }
        catch { rejected = true }
        precondition(rejected, "An explicitly selected reader silently fell back")
        print("PASS: APDU encoding, ACR122 FeliCa framing, malformed replies, status handling, CEPAS purse/history")
    }
}
