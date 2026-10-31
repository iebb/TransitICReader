"""Keep both native clients' catalogs complete and in sync."""
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.localization import ROOT, catalogs, check, outputs, source_errors


class LocalizationTests(unittest.TestCase):
    def test_all_supported_languages_have_matching_keys_and_arguments(self):
        self.assertEqual([], check(catalogs()))

    def test_android_resources_match_the_shared_catalogs(self):
        for path, content in outputs(catalogs()).items():
            with self.subTest(path=path):
                self.assertEqual(content, path.read_text())

    def test_ui_literals_and_card_field_labels_are_translatable(self):
        self.assertEqual([], source_errors(catalogs()))

    @unittest.skipUnless(shutil.which("swiftc"), "Requires Swift")
    def test_swift_localizer_uses_bundled_translations_and_preserves_data(self):
        tables = catalogs()
        cases = []
        for language, table in tables.items():
            cases.extend([
                ("Balance", language, table["Balance"]),
                ("Balance (IDR)", language, table["Balance"] + " (IDR)"),
                ("Import failed: This file is not a Trip Reader backup.", language,
                 table["Import failed: %@"].replace("%@", table["This file is not a Trip Reader backup."])),
                ("Imported 2 cards (1 replaced)", language,
                 table["Imported %lld cards (%lld replaced)"].replace("%lld", "2", 1).replace("%lld", "1", 1)),
                ("Vending Machine", language, table["Vending Machine"]),
                ("Consumption", language, table["consumption"]),
                ("Import failed: $1\\path", language, table["Import failed: %@"].replace("%@", "$1\\path")),
                ("Reading transactions (3 of 30)…", language,
                 table["Reading transactions (%lld of %lld)…"].replace("%1$lld", "3").replace("%2$lld", "30")
                 .replace("%lld", "3", 1).replace("%lld", "30", 1)),
                ("A000000632010105", language, "A000000632010105"),
                ("My commuter card", language, "My commuter card"),
            ])
        with tempfile.TemporaryDirectory(prefix="cardbal-localization-") as temporary:
            root = Path(temporary)
            contents = root / "Localization.app/Contents"
            resources = contents / "Resources"
            binary = contents / "MacOS/Localization"
            binary.parent.mkdir(parents=True)
            resources.mkdir()
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Localization",
                "CFBundleIdentifier": "ad.neko.cardbal.localization-test",
                "CFBundleDevelopmentRegion": "en",
                "CFBundleLocalizations": list(tables),
            }))
            for language in tables:
                directory = resources / f"{language}.lproj"
                directory.mkdir()
                shutil.copy2(ROOT / f"ios/CardBal/Resources/{language}.lproj/Localizable.strings", directory)
            fixtures = root / "cases.json"
            fixtures.write_text(json.dumps(cases))
            swift = root / "main.swift"
            swift.write_text(r'''
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let cases = try JSONDecoder().decode([[String]].self, from: data)
for item in cases {
    let actual = Localizer.localize(item[0], preferredLocale: item[1])
    guard actual == item[2] else {
        fatalError("\(item[1]): \(item[0]): \(actual) != \(item[2])")
    }
}
print("PASS: bundled localization in all supported languages")
''')
            build = subprocess.run(
                ["swiftc", str(swift), str(ROOT / "ios/CardBal/Helpers/Localizer.swift"), "-o", str(binary)],
                capture_output=True, text=True,
            )
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(binary), str(fixtures)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("PASS:", run.stdout)


if __name__ == "__main__":
    unittest.main()
