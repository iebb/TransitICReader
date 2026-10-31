"""Android Firebase Analytics stays optional, like iOS: synthetic configuration only."""

import base64
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

from tools.paths import ROOT

WORKFLOW = ROOT / ".github/workflows/play-internal.yml"
APP_GRADLE = ROOT / "android/app/build.gradle.kts"
ROOT_GRADLE = ROOT / "android/build.gradle.kts"
MANIFEST = ROOT / "android/app/src/main/AndroidManifest.xml"
SECRET = "FIREBASE_GOOGLE_SERVICES_JSON_BASE64"


def restore_script():
    workflow = WORKFLOW.read_text()
    step = workflow.split("- name: Restore optional Firebase configuration", 1)[1].split("\n      - name:", 1)[0]
    return textwrap.dedent(re.search(r"python3 - <<'PY'\n(.*?)\n\s*PY$", step, re.S)[1])


def restore(secret):
    with tempfile.TemporaryDirectory() as directory:
        (Path(directory) / "android/app").mkdir(parents=True)
        result = subprocess.run([sys.executable, "-c", restore_script()], cwd=directory, capture_output=True, text=True,
                                env={**os.environ, SECRET: secret})
        path = Path(directory) / "android/app/google-services.json"
        written = path.read_bytes() if path.exists() else None
        mode = path.stat().st_mode & 0o777 if path.exists() else None
        return result, written, mode


def services_json(package):
    return json.dumps({"project_info": {"project_id": "synthetic"},
                       "client": [{"client_info": {"android_client_info": {"package_name": package}}}]}).encode()


class AndroidFirebaseTests(unittest.TestCase):
    def test_plugin_is_applied_only_when_the_ignored_configuration_exists(self):
        gradle = APP_GRADLE.read_text()
        self.assertIn('if (file("google-services.json").isFile) {\n    apply(plugin = "com.google.gms.google-services")', gradle)
        self.assertNotIn('id("com.google.gms.google-services")', gradle)
        self.assertIn('id("com.google.gms.google-services") version', ROOT_GRADLE.read_text())
        self.assertIn('platform("com.google.firebase:firebase-bom:', gradle)
        self.assertIn('implementation("com.google.firebase:firebase-analytics")', gradle)
        self.assertIn("/android/app/google-services.json", (ROOT / ".gitignore").read_text().splitlines())

    def test_advertising_id_is_not_collected(self):
        manifest = MANIFEST.read_text()
        for permission in ("com.google.android.gms.permission.AD_ID", "android.permission.ACCESS_ADSERVICES_AD_ID",
                           "android.permission.ACCESS_ADSERVICES_ATTRIBUTION"):
            self.assertIn(f'<uses-permission android:name="{permission}" tools:node="remove" />', manifest)
        self.assertRegex(manifest, r'android:name="google_analytics_adid_collection_enabled"\s+android:value="false"')

    def test_workflow_restores_and_removes_the_configuration(self):
        workflow = WORKFLOW.read_text()
        self.assertIn(f"{SECRET}: ${{{{ secrets.{SECRET} }}}}", workflow)
        self.assertLess(workflow.index("Restore optional Firebase configuration"), workflow.index("bundleRelease"))
        cleanup = workflow.split("- name: Remove upload keystore and Firebase configuration", 1)[1].split("\n      - name:", 1)[0]
        self.assertIn("if: always()", cleanup)
        self.assertIn("android/app/google-services.json", cleanup)
        self.assertNotIn(SECRET, (ROOT / ".github/workflows/ci.yml").read_text())

    def test_restore_script_writes_a_private_file_or_skips(self):
        data = services_json("ad.neko.cardbal.android")
        encoded = base64.b64encode(data).decode()
        result, written, mode = restore(encoded[:20] + "\n" + encoded[20:])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(data, written)
        self.assertEqual(0o600, mode)

        result, written, _ = restore("")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIsNone(written)
        self.assertIn("analytics disabled", result.stdout)

        result, written, _ = restore(base64.b64encode(services_json("com.example.other")).decode())
        self.assertNotEqual(0, result.returncode)
        self.assertIsNone(written)


if __name__ == "__main__":
    unittest.main()
