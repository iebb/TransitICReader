"""Production Swift CharlieCard parser against a synthetic MIFARE Classic dump."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.paths import ROOT

STUBS = r'''
import Foundation

struct ResultField: Equatable { let title: String; let value: String }
struct RawDataField { let title: String; let value: String }
struct RawDataSection { let title: String; let fields: [RawDataField] }
struct TransitCardSnapshot {
    let technology: String, cardFamily: String, identifierLabel: String, identifierValue: String, rawIdentifierValue: String
    let pmm: String?, systemCode: String?, selectedAID: String?, balanceText: String?, balanceDetail: String?
    let realSerialNumber: String?, region: String?
    let resultFields: [ResultField], rawSections: [RawDataSection], rawTransactions: [String], rawTransitHistory: [String], scannedAt: Date
}
enum TransactionCategory { case topUp, tapOn, tapOff, payment, purchase, adjustment, refund, bus, busOn, busOff, train, trainOn, trainOff, ferry, unknown }
struct TransitTransaction {
    let date: Date?, time: String?, amount: Decimal, terminalID: String?, type: String, category: TransactionCategory, rawData: String?
    var currencyCode: String? = nil
    var issuerTimeZone: String? = nil
    var amountIsSigned: Bool = false
    init(date: Date?, time: String? = nil, amount: Decimal, terminalID: String?, type: String,
         category: TransactionCategory = .unknown, rawData: String? = nil) {
        self.date = date; self.time = time; self.amount = amount; self.terminalID = terminalID
        self.type = type; self.category = category; self.rawData = rawData
    }
}
func formatCurrency(amount: Decimal, code: String, fractionDigits: Int = 0) -> String {
    let formatter = NumberFormatter()
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return code + " " + (formatter.string(from: amount as NSDecimalNumber) ?? "\(amount)")
}
extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
    init(hexString: String) {
        self.init(stride(from: 0, to: hexString.count, by: 2).compactMap { i in
            let a = hexString.index(hexString.startIndex, offsetBy: i)
            return UInt8(hexString[a..<hexString.index(a, offsetBy: 2)], radix: 16)
        })
    }
    func bigEndianInt(start: Int, length: Int) -> Int {
        guard start >= 0, length > 0, count >= start + length else { return 0 }
        return self[start..<(start + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
}

func block(_ hex: String) -> Data {
    var data = Data(hexString: hex)
    data.append(Data(repeating: 0, count: max(0, 16 - data.count)))
    return Data(data.prefix(16))
}

@main struct Tests {
    static func main() {
        // Serial 12345678; balance sector 2 (bigger counter); $10.00; issued at epoch.
        var sectors: [Int: [Data]] = [
            0: [block("00BC614E"), block(""), block("")],
            2: [block("00000000000000000000020000000000"), block("000000000007D0"), block("")],
            3: [block(""), block(""), block("")],
            6: [block(""), block(""), block("")],
            7: [block(""), block(""), block("")],
            8: [block("0000000A"), block(""), block("")],
        ]
        guard let snapshot = CharlieCardProtocol.snapshot(sectors: sectors, identifier: Data([0x04, 0x11, 0x22, 0x33]), scannedAt: Date()) else {
            preconditionFailure("Rejected a valid card")
        }
        precondition(snapshot.technology == "MIFARE Classic", snapshot.technology)
        precondition(snapshot.cardFamily == "CharlieCard")
        precondition(snapshot.identifierValue == "5-12345678", snapshot.identifierValue)
        precondition(snapshot.balanceText == "USD 10.00", snapshot.balanceText ?? "nil")
        func field(_ title: String) -> String? { snapshot.resultFields.first { $0.title == title }?.value }
        precondition(field("Issue Date") == "2003-01-01", field("Issue Date") ?? "nil")
        precondition(field("Expiry Date") == "2013-12-31", field("Expiry Date") ?? "nil")
        precondition(field("Second Card Number") == "A0000000010", field("Second Card Number") ?? "nil")
        precondition(snapshot.rawTransitHistory.isEmpty)

        // A used card expires two years after the last trip when that is earlier.
        sectors[6] = [block("000064" + "0001" + "0064"), block(""), block("")]
        let used = CharlieCardProtocol.snapshot(sectors: sectors, identifier: Data(), scannedAt: Date())!
        precondition(used.rawTransitHistory.count == 1)
        precondition(used.resultFields.first { $0.title == "Expiry Date" }!.value == "2005-01-01")

        // Bus fare, subway, ticket machine and a negative (signed) price.
        let bus = CharlieCardProtocol.decodeTransaction(Data(hexString: "00006400010064"))!
        precondition(bus.type == "Bus" && bus.category == .bus, bus.type)
        precondition(bus.amount == Decimal(-50) / 100, "\(bus.amount)")
        precondition(bus.currencyCode == "USD" && bus.issuerTimeZone == "America/New_York" && bus.amountIsSigned)
        let subway = CharlieCardProtocol.decodeTransaction(Data(hexString: "000064004A0064"))!
        precondition(subway.type == "Subway" && subway.category == .train, subway.type)
        precondition(subway.terminalID == "9", subway.terminalID ?? "nil")
        let machine = CharlieCardProtocol.decodeTransaction(Data(hexString: "00006400000064"))!
        precondition(machine.type == "Ticket Machine" && machine.category == .purchase, machine.type)
        precondition(CharlieCardProtocol.decodeTransaction(Data(hexString: "00000000000000")) == nil)
        precondition(CharlieCardProtocol.decodeTransaction(Data(hexString: "0000")) == nil)
        precondition(CharlieCardProtocol.price(Data(hexString: "8064"), 0) == -50)
        precondition(CharlieCardProtocol.keys.count == 21 && CharlieCardProtocol.keys.allSatisfy { $0.count == 6 })
        print("Verified CharlieCard serial, balance, dates, trips and key pool")
    }
}
'''


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class CharlieCardTests(unittest.TestCase):
    def test_parser_fields_and_trips(self):
        with tempfile.TemporaryDirectory(prefix="cardbal-charlie-tests-") as directory:
            directory = Path(directory)
            runner = directory / "Runner.swift"
            runner.write_text(STUBS)
            executable = directory / "charlie-tests"
            result = subprocess.run([
                "swiftc", "-parse-as-library",
                str(ROOT / "ios/CardBal/NFC/Profiles/CharlieCardProtocol.swift"),
                str(runner), "-o", str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Verified CharlieCard", result.stdout)


if __name__ == "__main__":
    unittest.main()
