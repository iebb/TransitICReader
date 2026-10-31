"""Source contracts for readable native Settings forms; not rendered UI tests."""
import unittest

from tools.paths import ROOT


class ReadableSettingsLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "ios/CardBal/ContentView.swift").read_text()
        cls.settings = cls.source.split("struct SettingsView: View {", 1)[1].split("struct CardDetailRoute:", 1)[0]
        cls.modifier = cls.source.split("private struct ReadableSettingsForm: ViewModifier {", 1)[1].split("struct SettingsView:", 1)[0]

    def test_width_cap_tracks_live_size_class_without_changing_identity(self):
        self.assertIn("@Environment(\\.horizontalSizeClass)", self.modifier)
        self.assertIn(".frame(maxWidth: horizontalSizeClass == .regular ? 640 : .infinity)", self.modifier)
        self.assertIn(".frame(maxWidth: .infinity, alignment: .center)", self.modifier)
        self.assertIn(".background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())", self.modifier)
        self.assertNotIn("if ", self.modifier)
        self.assertNotIn("@State", self.modifier)
        self.assertNotIn(".id(", self.modifier)

    def test_only_requested_six_lists_receive_the_modifier(self):
        self.assertEqual(self.settings.count(".modifier(ReadableSettingsForm())"), 6)
        for title in ("Settings", "Display", "Backup", "Privacy", "Advanced", "About"):
            self.assertRegex(self.settings, rf'\.modifier\(ReadableSettingsForm\(\)\)\s*\.navigationTitle\("{title}"\)')
        credits = self.settings.split("private var creditsSettings", 1)[1]
        self.assertNotIn("ReadableSettingsForm", credits)
        self.assertIn("NavigationLink { CardFaceLibraryView(store: store) }", self.settings)
        # No alternate form tree, extra navigation layer, or resized stack.
        self.assertEqual(self.settings.count("List {"), 7)
        self.assertEqual(self.settings.count("NavigationStack {"), 1)
        self.assertNotIn("GeometryReader", self.settings)
        self.assertNotIn(".id(", self.settings)

    def test_native_navigation_and_file_picker_host_stay_outside_cap(self):
        root, subforms = self.settings.split("private var displaySettings", 1)
        self.assertIn('List {', root)
        self.assertIn('            .modifier(ReadableSettingsForm())\n            .navigationTitle("Settings")\n        }\n        .fileExporter(', root)
        self.assertEqual(root.count(".fileExporter("), 1)
        self.assertEqual(root.count(".fileImporter("), 1)
        self.assertNotIn(".fileExporter(", subforms)
        self.assertNotIn(".fileImporter(", subforms)
        for state in ("backupDocument", "isExportingBackup", "isImportingBackup", "backupMessage"):
            self.assertIn("@State private var " + state, root)


if __name__ == "__main__":
    unittest.main()
