"""Exercise the scan sheet's reading-step coalescing and its reader wiring."""
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT

HARNESS = r'''
import Foundation
@MainActor final class Lines { var values: [String] = [] }
func settle(_ milliseconds: UInt64) async throws { try await Task.sleep(nanoseconds: milliseconds * 1_000_000) }
@main struct Run {
    @MainActor static func main() async throws {
        precondition(ScanStep.transactionCount(3, 30).message == "Reading transactions (3 of 30)…")
        ScanProgress.report(.found) // Nothing is bound, so nothing happens.
        let lines = Lines()
        let progress = ScanProgress(delayNanoseconds: 80_000_000) { lines.values.append($0) }
        ScanProgress.$current.withValue(progress) { ScanProgress.report(.found) }
        try await settle(20)
        precondition(lines.values == [ScanStep.found.message], "Detection was not shown at once")
        progress.report(.balance)
        progress.report(.transactions)
        try await settle(250)
        precondition(lines.values == [ScanStep.found.message, ScanStep.transactions.message], "A superseded step flashed")
        for number in 1...5 { progress.report(.transactionCount(number, 5)) }
        try await settle(250)
        precondition(lines.values.count == 3 && lines.values.last == ScanStep.transactionCount(5, 5).message,
                     "Counter updates were not coalesced")
        progress.report(.octopusOnline)
        try await settle(250)
        progress.report(.octopusUnavailable)
        try await settle(20)
        precondition(lines.values.count == 5 && lines.values.last == ScanStep.octopusUnavailable.message,
                     "The failed online check was not shown at once")
        progress.report(.finishing)
        try await settle(250)
        precondition(lines.values.count == 5, "Finishing replaced the unavailable line")
        progress.report(.details)
        progress.finish()
        progress.report(.found)
        try await settle(250)
        precondition(lines.values.count == 5, "A step applied after the scan ended")
        let ended = Lines()
        let finished = ScanProgress(delayNanoseconds: 80_000_000) { ended.values.append($0) }
        finished.report(.found)
        finished.finish()
        try await settle(50)
        precondition(ended.values.isEmpty, "A queued line replaced the final message")
        print("PASS: scan progress coalescing")
    }
}
'''


class ScanProgressTests(unittest.TestCase):
    def test_reader_binds_progress_and_ends_with_card_read(self):
        reader = (ROOT / "ios/CardBal/NFC/NFCTransitReader.swift").read_text()
        self.assertIn("ScanProgress.$current.withValue(progress) {\n"
                      "                            try await decoder.decode(tag: cardTag, scannedAt: Date())", reader)
        self.assertIn("ScanProgress.$current.withValue(progress) {\n"
                      "                        try await self.externalReader.scan(", reader)
        self.assertIn("progress.report(.finishing)\n                    self.accept(snapshot, session: session)", reader)
        done = "session.alertMessage = Localizer.localize(ScanStep.done.message)\n"
        self.assertEqual(2, reader.count(done))
        self.assertEqual(2, len(re.findall(re.escape(done) + r"\s*session\.invalidate\(\)", reader)))
        octopus = (ROOT / "ios/CardBal/NFC/Decoders/OctopusOnlineDecoder.swift").read_text()
        self.assertLess(octopus.index("ScanProgress.report(.octopusOnline)"), octopus.index("client.enquire("))
        # A failed first check says Octopus Online is unavailable; a failed rate refresh keeps the saved
        # details and finishes quietly.
        self.assertRegex(octopus, r"if enquiryFailed && metadata != nil \{\s*octopusDebugLog\([^\n]*\)\s*"
                                  r"\} else if enquiryFailed \{\s*ScanProgress\.report\(\.octopusUnavailable\)\s*\}")

    @unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
    def test_steps_are_coalesced_and_end_with_the_scan(self):
        with tempfile.TemporaryDirectory(prefix="cardbal-scan-progress-") as directory:
            path = Path(directory)
            (path / "main.swift").write_text(HARNESS)
            binary = path / "scan-progress"
            build = subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "ios/CardBal/NFC/ScanProgress.swift"),
                                    str(path / "main.swift"), "-o", str(binary)], capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS:", run.stdout)


if __name__ == "__main__":
    unittest.main()
