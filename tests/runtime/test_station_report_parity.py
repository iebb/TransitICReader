"""Source contracts keeping the Android station-report port aligned with iOS and the server."""
import re
import unittest

from tools.paths import ROOT

SWIFT = ROOT / "ios/CardBal/Views/StationReportView.swift"
KOTLIN = ROOT / "android/app/src/main/java/ad/neko/cardbal/android/data/StationReports.kt"
SCREEN = ROOT / "android/app/src/main/java/ad/neko/cardbal/android/ui/StationReportScreen.kt"
WIDGETS = ROOT / "android/app/src/main/java/ad/neko/cardbal/android/ui/TransitWidgets.kt"
VALIDATION = ROOT / "services/station-reports/src/validation.ts"
MANIFEST = ROOT / "android/app/src/main/AndroidManifest.xml"


def kotlin_fields(source, name):
    body = source.split(f"data class {name}(", 1)[1].split("\n)", 1)[0]
    fields = []
    for line in body.splitlines():
        match = re.search(r'(?:@SerialName\("(\w+)"\)\s*)?val (\w+):', line)
        if match:
            fields.append(match[1] or match[2])
    return fields


class StationReportParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.swift = SWIFT.read_text()
        cls.kotlin = KOTLIN.read_text()
        cls.screen = SCREEN.read_text()
        validation = VALIDATION.read_text()
        block = re.search(r"allowedFields = new Set\(\[(.*?)\]\)", validation, re.S)[1]
        cls.server_fields = set(re.findall(r'"(\w+)"', block))

    def test_android_payload_keys_match_ios_and_the_server(self):
        swift_body = self.swift.split("private struct StationReportPayload: Encodable {", 1)[1].split("}", 1)[0]
        swift_fields = [name.strip("`") for name in re.findall(r"let (`?\w+`?):", swift_body)]
        android_fields = kotlin_fields(self.kotlin, "StationReportPayload")
        self.assertEqual(swift_fields, android_fields)
        self.assertEqual(self.server_fields, set(android_fields))
        self.assertEqual(["latitude", "longitude", "accuracyMeters"], kotlin_fields(self.kotlin, "StationReportLocationPayload"))

    def test_endpoint_identity_source_and_limits_match_ios(self):
        endpoint = re.search(r'URL\(string: "([^"]+)"\)', self.swift)[1]
        self.assertIn(f'const val ENDPOINT = "{endpoint}"', self.kotlin)
        self.assertIn('deviceIDKey = "stationReportDeviceID"', self.swift)
        self.assertIn('const val DEVICE_ID_KEY = "stationReportDeviceID"', self.kotlin)
        self.assertIn('source: "ios"', self.swift)
        self.assertIn('const val SOURCE = "android"', self.kotlin)
        self.assertIn('source !== "ios" && source !== "android"', VALIDATION.read_text())
        self.assertIn('"CardBal-Android/${payload.appVersion}"', self.kotlin)
        can_submit = self.swift.split("private var canSubmit: Bool {", 1)[1].split("\n    }", 1)[0]
        limits = dict(re.findall(r"(\w+)\.count <= (\d+)", can_submit))
        constants = dict(re.findall(r"const val (MAX_\w+) = (\d+)", self.kotlin))
        names = {"stationName": "MAX_NAME", "stationCode": "MAX_CODE", "suggestedCode": "MAX_CODE",
                 "lines": "MAX_LINES", "operatorName": "MAX_NAME", "city": "MAX_NAME",
                 "country": "MAX_NAME", "notes": "MAX_NOTES"}
        self.assertEqual(set(names), set(limits))
        for field, constant in names.items():
            with self.subTest(field=field):
                self.assertEqual(limits[field], constants[constant])
                self.assertIn(f"{field}.length <= StationReports.{constant}", self.kotlin)

    def test_entry_points_location_and_permissions(self):
        widgets = WIDGETS.read_text()
        self.assertIn('tr("Station Data")', widgets)
        self.assertIn("StationReports.prefilledStationCode(tx)", widgets)
        self.assertIn('tr("Check any prefilled code before submitting.', widgets)
        self.assertIn("LatLng(30.0, 115.0)", self.screen)
        self.assertIn("StationReportKind.Missing", self.screen)
        self.assertNotIn("com.google.android.gms.location", self.screen)
        # Location permission is only requested from the Use Current Location action.
        self.assertEqual(1, self.screen.count("permissionLauncher.launch("))
        manifest = MANIFEST.read_text()
        for permission in ("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION"):
            self.assertIn(f'android:name="android.permission.{permission}"', manifest)


if __name__ == "__main__":
    unittest.main()
