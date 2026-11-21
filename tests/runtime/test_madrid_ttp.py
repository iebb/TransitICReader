"""Production Swift Tarjeta Transporte Público relay and parser against invented exchanges."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from tools.paths import ROOT

RUNNER = r'''
import Foundation

final class Script {
    var responses: [Data]
    var bodies: [[String: Any]] = []
    var paths: [String] = []
    var replies: [Data]
    var commands: [String] = []
    init(responses: [Any], replies: [String]) {
        self.responses = responses.map { try! JSONSerialization.data(withJSONObject: $0) }
        self.replies = replies.map { MadridTTPProtocol.hexData($0)! }
    }
    func post(_ path: String, _ body: Data) async throws -> Data {
        paths.append(path)
        bodies.append(try JSONSerialization.jsonObject(with: body) as! [String: Any])
        precondition(!responses.isEmpty, "Unexpected request")
        return responses.removeFirst()
    }
    func transceive(_ apdu: Data) async throws -> Data {
        commands.append(apdu.map { String(format: "%02X", $0) }.joined())
        precondition(!replies.isEmpty, "Unexpected card command")
        return replies.removeFirst()
    }
    func read() async throws -> MadridTTPProtocol.Outcome {
        try await MadridTTPProtocol.read(post: post, transceive: transceive)
    }
}

func expect(_ expected: MadridTTPError, _ script: Script) async {
    do { _ = try await script.read(); preconditionFailure("Accepted: \(expected)") }
    catch let error as MadridTTPError { precondition(error == expected, "\(error) != \(expected)") }
    catch { preconditionFailure("Unexpected error \(error)") }
}

@main struct Tests {
    static func main() async throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let session = fixture["session"]!
        let rounds = fixture["rounds"] as! [[String: Any]]
        let final = fixture["final"] as! [String: Any]
        let expected = (fixture["expectedFields"] as! [[String]]).map { ($0[0], $0[1]) }

        for hex in fixture["permittedCommands"] as! [String] {
            precondition(MadridTTPProtocol.permittedCommand(hex, afterAdditionalFrame: false) != nil, hex)
        }
        for hex in fixture["refusedCommands"] as! [String] {
            precondition(MadridTTPProtocol.permittedCommand(hex, afterAdditionalFrame: false) == nil, hex)
        }
        precondition(MadridTTPProtocol.permittedCommand("90AF000000", afterAdditionalFrame: true) != nil)
        precondition(MadridTTPProtocol.permittedCommand("90AF0000", afterAdditionalFrame: true) == nil)

        let replies = rounds.flatMap { $0["replies"] as! [String] }
        let script = Script(responses: [session] + rounds.map { $0["response"]! } + [final], replies: replies)
        let outcome = try await script.read()
        precondition(script.paths == [MadridTTPProtocol.initPath] + Array(repeating: MadridTTPProtocol.readingPath, count: 3))
        precondition(script.bodies[1]["rapdu"] == nil && script.bodies[1]["updateCard"] as? Bool == false)
        for (index, round) in rounds.enumerated() {
            precondition(script.bodies[index + 2]["rapdu"] as? [String] == round["replies"] as? [String], "Round \(index + 1) replies")
            precondition(script.bodies[index + 2]["updateCard"] as? Bool == false)
        }
        precondition(script.commands == rounds.flatMap { ($0["response"] as! [String: Any])["capdu"] as! [String] })
        precondition(outcome.rounds == 2 && outcome.commands == 7)
        let fields = outcome.card.fields
        precondition(fields.count == expected.count, "Fields: \(fields)")
        for (actual, wanted) in zip(fields, expected) { precondition(actual == wanted, "\(actual) != \(wanted)") }
        precondition(outcome.card.remainingTrips == nil, "A pass hides the trip count")
        precondition(outcome.card.serial == "04112233445566")
        precondition(!outcome.card.summaryJSON.contains("families") && outcome.card.summaryJSON.contains("titMV1"))

        var tripsOnly = final
        var balance = final["balance"] as! [String: Any]
        balance["titTemp"] = NSNull()
        balance["blockedApp"] = true
        tripsOnly["balance"] = balance
        let card = MadridTTPProtocol.parse(tripsOnly)!
        precondition(card.remainingTrips == 7 && card.blocked)
        precondition(card.fields.contains { $0 == ("Remaining Trips", "7") } && card.fields.contains { $0 == ("Status", "Blocked") })
        balance["titMV2"] = balance["titMV1"]
        tripsOnly["balance"] = balance
        let twice = MadridTTPProtocol.parse(tripsOnly)!
        precondition(twice.remainingTrips == nil, "Two trip tickets are not summed")
        precondition(twice.fields.contains { $0 == ("10 viajes (2) Remaining Trips", "7") })

        var expiredBalance = final["balance"] as! [String: Any]
        var expiredTrips = expiredBalance["titMV1"] as! [String: Any]
        expiredTrips["chargeState"] = "CADUCADO"
        expiredBalance["titTemp"] = NSNull()
        expiredBalance["titMV1"] = expiredTrips
        var expiredResponse = final
        expiredResponse["balance"] = expiredBalance
        let expired = MadridTTPProtocol.parse(expiredResponse)!
        precondition(expired.remainingTrips == nil, "An expired ticket gives no card-level trip count")
        precondition(expired.fields.contains { $0 == ("10 viajes Status", "Expired") })
        var expiredPass = expiredBalance["titMV1"] as! [String: Any]
        expiredPass["chargeState"] = "0"
        expiredBalance["titMV1"] = expiredPass
        var oldPass = (final["balance"] as! [String: Any])["titTemp"] as! [String: Any]
        oldPass["chargeState"] = "CADUCADO"
        expiredBalance["titTemp"] = oldPass
        expiredResponse["balance"] = expiredBalance
        precondition(MadridTTPProtocol.parse(expiredResponse)!.remainingTrips == 7, "An expired pass does not hide trips")

        var multiBalance = final["balance"] as! [String: Any]
        multiBalance["cardNumber"] = NSNull()
        multiBalance["orderCode"] = "MB0"
        multiBalance["cardOrderNumber"] = "00000042"
        var multi = final
        multi["balance"] = multiBalance
        precondition(MadridTTPProtocol.parse(multi)!.fields.first! == ("Card Number", "MB0-00000042"))
        multiBalance["cardOrderNumber"] = "0000 0042"
        multi["balance"] = multiBalance
        precondition(MadridTTPProtocol.parse(multi)!.cardNumber == nil, "Unexpected order number accepted")

        precondition(MadridTTPProtocol.date("2026-11-02 00:00:00") == "2026-11-02")
        precondition(MadridTTPProtocol.date("2026-11-02T23:30:00Z") == "2026-11-03 00:30")
        precondition(MadridTTPProtocol.date("31/12/2026") == "31/12/2026")
        precondition(MadridTTPProtocol.date("") == nil && MadridTTPProtocol.date(NSNull()) == nil)
        precondition(MadridTTPProtocol.text(true) == nil && MadridTTPProtocol.text(7) == "7")

        let first = rounds[0]["response"] as! [String: Any]
        var write = first
        write["capdu"] = ["9060000000", "903D00000801000000010000AA00", "9060000000"]
        let refused = Script(responses: [session, write], replies: ["0401010100180591AF"])
        await expect(.refusedCommand(0x3D), refused)
        precondition(refused.commands == ["9060000000"] && refused.paths.count == 2, "Write reached the card or service")

        let failed = Script(responses: [session, ["status": ["code": "MDD-001", "description": ["MDD_SESSION_NOT_VALID"]]]], replies: [])
        await expect(.service("MDD-001"), failed)
        await expect(.service("FF"), Script(responses: [["status": ["code": "FF"]]], replies: []))
        await expect(.invalidResponse, Script(responses: [session, ["status": ["code": "0000"], "balance": NSNull()]], replies: []))
        var empty = first
        empty["capdu"] = [String]()
        await expect(.invalidResponse, Script(responses: [session, empty], replies: []))
        var endless = first
        endless["capdu"] = ["9060000000"]
        let looping = Script(responses: [session] + Array(repeating: endless, count: 17),
                             replies: Array(repeating: "9100", count: 16))
        await expect(.budgetExceeded, looping)
        precondition(looping.commands.count == MadridTTPProtocol.maximumRounds)
        do {
            _ = try MadridTTPProtocol.object(Data("<html>".utf8))
            preconditionFailure("HTML accepted")
        } catch let error as MadridTTPError { precondition(error == .invalidResponse) }
        print("Verified Madrid relay, command guard, budgets and ticket fields")
    }
}
'''


@unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
class MadridTTPTests(unittest.TestCase):
    def test_relay_guard_and_fields(self):
        with tempfile.TemporaryDirectory(prefix="cardbal-madrid-tests-") as directory:
            directory = Path(directory)
            runner = directory / "Runner.swift"
            runner.write_text(RUNNER)
            executable = directory / "madrid-tests"
            result = subprocess.run([
                "swiftc", "-parse-as-library", str(ROOT / "ios/CardBal/NFC/Profiles/MadridTTPProtocol.swift"),
                str(runner), "-o", str(executable),
            ], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable), str(ROOT / "tests/runtime/fixtures/madrid-ttp.json")],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Verified Madrid relay", result.stdout)


if __name__ == "__main__":
    unittest.main()
