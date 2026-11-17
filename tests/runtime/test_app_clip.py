"""App Clip invocation safety and packaging contract; Swift runs only on macOS."""
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppClipTests(unittest.TestCase):
    def test_clip_metadata_and_deployment(self):
        info = plistlib.loads((ROOT / 'ios/CardBalClip/Info.plist').read_bytes())
        entitlements = plistlib.loads((ROOT / 'ios/CardBalClip/CardBalClip.entitlements').read_bytes())
        self.assertEqual(entitlements, {
            'com.apple.developer.parent-application-identifiers': ['$(AppIdentifierPrefix)ad.neko.cardbal'],
            'com.apple.developer.nfc.readersession.formats': ['TAG'],
        })
        full = plistlib.loads((ROOT / 'ios/CardBal/Info.plist').read_bytes())
        aid = 'com.apple.developer.nfc.readersession.iso7816.select-identifiers'
        self.assertEqual(info[aid], full[aid])
        self.assertNotIn('8008', info['com.apple.developer.nfc.readersession.felica.systemcodes'])
        self.assertNotIn('NSCameraUsageDescription', info)
        self.assertNotIn('NSUbiquitousContainers', info)
        self.assertTrue(info['NFCReaderUsageDescription'])
        self.assertFalse(any(info['NSAppClip'].values()))
        manifest = (ROOT / 'airbuild.yaml').read_text()
        self.assertIn('id: ad.neko.cardbal.Clip\n      app_clip_of: ad.neko.cardbal', manifest)

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'Swift SDK tests run on remote macOS')
    def test_untrusted_invocations(self):
        # Production parser compiled unchanged, with real Foundation URL parsing.
        harness = r'''
import Foundation
@main struct InvocationTests {
    static func main() {
        let base = "https://appclip.apple.com/id?p=ad.neko.cardbal.Clip"
        let accepted = [base, base + "&unknown=1", base + "&scan=1&scan=2&balance=999&card=abc", base + "#scan"]
        for value in accepted { precondition(ClipInvocation(URL(string: value)!) != nil, value) }
        let rejected = ["https://appclip.apple.com/id", base + "&p=ad.neko.cardbal.Clip", base + "&p=evil",
            "http://appclip.apple.com/id?p=ad.neko.cardbal.Clip", "https://evil.example/id?p=ad.neko.cardbal.Clip",
            "https://appclip.apple.com.evil.example/id?p=ad.neko.cardbal.Clip", "https://appclip.apple.com:443/id?p=ad.neko.cardbal.Clip",
            "https://user@appclip.apple.com/id?p=ad.neko.cardbal.Clip", "https://appclip.apple.com/other?p=ad.neko.cardbal.Clip"]
        for value in rejected { precondition(ClipInvocation(URL(string: value)!) == nil, value) }
        precondition(ClipInvocation(URL(string: base)!) == ClipInvocation(URL(string: base)!))
        let absent: URL? = nil
        precondition(absent.flatMap(ClipInvocation.init) == nil)
        print("Invocation safety: default, unknown, absent, duplicate, hostile values passed")
    }
}
'''
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path / 'InvocationTests.swift').write_text(harness)
            executable = path / 'invocation-tests'
            subprocess.run(['swiftc', str(ROOT / 'ios/CardBal/Helpers/ClipInvocation.swift'),
                            str(path / 'InvocationTests.swift'), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)
