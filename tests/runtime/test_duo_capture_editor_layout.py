"""Focused source/geometry contracts, not SwiftUI runtime or camera evidence."""
import re
import unittest

from tools.paths import ROOT


class DuoCaptureEditorLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        secondary = (ROOT / "ios/CardBal/Views/SecondaryViews.swift").read_text()
        cls.secondary = secondary
        cls.editor = secondary.split("struct FaceImageEditorSheet: View {", 1)[1].split(
            "struct MarkerPreviewBadge: View {", 1
        )[0]
        cls.scanner = (ROOT / "ios/CardBal/Views/FeliCaSNScannerView.swift").read_text()

    def test_canonical_export_is_independent_of_display_fit(self):
        self.assertIn("private let cardWidth: CGFloat = 320", self.editor)
        self.assertIn("private let cardAspectRatio: CGFloat = 27.0 / 17.0", self.editor)
        save = self.editor.split("private func saveCroppedImage()", 1)[1]
        self.assertIn(".frame(width: cardWidth, height: cardHeight)", save)
        self.assertIn("renderer.scale = 3.0", save)
        self.assertNotIn("displayScale", save)
        for operation in (".brightness(brightness)", ".contrast(contrast)",
                          ".rotationEffect(.degrees(rotation))", ".projectionEffect(perspectiveTransform)",
                          ".scaleEffect(scale)", "offset.width + dragOffset.width"):
            self.assertIn(operation, self.editor)

    def test_fitted_preview_stays_inside_local_geometry(self):
        expression = re.search(r"let displayScale = (max\(0, min\(1,.*?\)\))", self.editor, re.S).group(1)
        expression = expression.replace("proxy.size.width", "width").replace("proxy.size.height", "height")
        for width, height in ((0, 0), (240, 100), (320, 220), (390, 300), (700, 500)):
            with self.subTest(width=width, height=height):
                scale = eval(expression, {"__builtins__": {}, "min": min, "max": max},
                             dict(width=width, height=height, cardWidth=320, cardHeight=320 * 17 / 27))
                self.assertGreaterEqual(scale, 0)
                self.assertLessEqual(scale, 1)
                self.assertLessEqual(320 * scale, max(width - 32, 0) + 1e-8)
                self.assertLessEqual(320 * 17 / 27 * scale, max(height - 32, 0) + 1e-8)

    def test_display_drag_is_converted_before_committing(self):
        self.assertIn("translation.width / max(displayScale, 0.001)", self.editor)
        self.assertIn("translation.height / max(displayScale, 0.001)", self.editor)
        self.assertEqual(self.editor.count("canonicalTranslation(value.translation, displayScale: displayScale)"), 2)
        self.assertIn("offset.width + delta.width", self.editor)
        self.assertIn("offset.height + delta.height", self.editor)
        self.assertIn("if !hasAppliedAutoZoom { applyAutoZoomIfNeeded() }", self.editor)
        self.assertIn("hasAppliedAutoZoom = true", self.editor)
        self.assertNotRegex(self.editor, r"\.onChange\(of:.*(?:size|width|height|horizontalSizeClass)")
        self.assertNotRegex(self.editor, r"\.id\(")

    def test_tools_reflow_without_fixed_height_groups(self):
        self.assertIn("horizontalSizeClass == .regular && proxy.size.width >= 600", self.editor)
        self.assertIn("AnyLayout(HStackLayout(spacing: 0))", self.editor)
        self.assertIn("AnyLayout(VStackLayout(spacing: 0))", self.editor)
        self.assertIn("ScrollView {", self.editor)
        self.assertIn("minWidth: isWide ? 240 : nil", self.editor)
        self.assertIn("idealWidth: isWide ? 280 : nil", self.editor)
        self.assertIn("maxWidth: isWide ? 320 : .infinity", self.editor)
        self.assertIn("min(toolsContentHeight, proxy.size.height * 0.5)", self.editor)
        self.assertNotRegex(self.editor, r"\.frame\((?:minHeight|height): 100\)")

    def test_scanner_actions_reserve_space_and_scroll_when_needed(self):
        self.assertIn("if #available(iOS 26.0, *)", self.scanner)
        self.assertIn("scannerContent.safeAreaBar(edge: .bottom)", self.scanner)
        self.assertIn("scannerContent.safeAreaInset(edge: .bottom, spacing: 0)", self.scanner)
        actions = self.scanner.split("private func scannerActions", 1)[1].split("private struct ActionsHeightKey", 1)[0]
        self.assertIn("ScrollView {", actions)
        self.assertIn("VStack(spacing: 12)", actions)
        self.assertIn(".padding(16)", actions)
        self.assertIn("min(actionsMeasuredHeight, maxHeight)", actions)
        self.assertIn(".frame(minHeight: 44)", actions)
        self.assertIn(".frame(maxWidth: .infinity, minHeight: 44)", actions)
        self.assertNotIn("Spacer()", actions)

    def test_scanner_guide_fits_remaining_region_with_margins(self):
        expression = re.search(r"let width = (min\(max\(available.width.*?480\))", self.scanner, re.S).group(1)
        expression = expression.replace("available.width", "width").replace("available.height", "height")
        for width, height in ((0, 0), (240, 100), (320, 160), (500, 300), (900, 600)):
            with self.subTest(width=width, height=height):
                card_width = eval(expression, {"__builtins__": {}, "min": min, "max": max},
                                  dict(width=width, height=height))
                self.assertGreaterEqual(card_width, 0)
                self.assertLessEqual(card_width, max(width - 32, 0) + 1e-8)
                self.assertLessEqual(card_width / (85.6 / 54), max(height - 32, 0) + 1e-8)
        self.assertIn("if #available(iOS 27.1, *)", self.scanner)
        self.assertIn("reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)", self.scanner)
        self.assertNotIn("includeInactive", self.scanner)
        self.assertIn("let serialStart = guide.maxX - serialWidth", self.scanner)
        self.assertIn("let snBoxX = guide.maxX - snBoxW", self.scanner)
        self.assertIn("let cardCenterY = guide.midY", self.scanner)

    def test_scanner_latch_callbacks_and_camera_pipeline_are_retained(self):
        for operation in ("@State private var wasValidOnce = false", "if valid { withAnimation { wasValidOnce = true } }",
                          "if wasValidOnce {", "onRecognized(fullSN)", "wasValidOnce = false",
                          "onPhotoTaken?(finalImage)", "CardPhotoProcessor.process(image)",
                          "let orientation: CGImagePropertyOrientation = .right",
                          "previewLayer?.frame = view.layer.bounds",
                          "uiViewController.onFragments = onFragments"):
            self.assertIn(operation, self.scanner)

    def test_same_image_has_stable_sheet_identity(self):
        identity = self.secondary.split("struct EditableFaceImage: Identifiable {", 1)[1].split(
            "struct FaceImageEditorSheet: View {", 1
        )[0]
        self.assertIn("var id: ObjectIdentifier { ObjectIdentifier(image) }", identity)
        self.assertNotIn("UUID()", identity)

    def test_upper_guide_after_horizontal_fold_is_not_excluded_from_ocr(self):
        # A horizontal division leaves a larger upper region, so the guide moves up.
        # Its serial strip is then above the old fixed Vision ROI (y=0.2...0.5).
        preview_width, preview_height = 900, 800
        upper_height, lower_height = 420, 360
        self.assertGreater(upper_height, lower_height)
        self.assertIn("available = candidates.max { $0.width * $0.height < $1.width * $1.height }", self.scanner)
        self.assertIn("height: max(0, fold.minY - available.minY)", self.scanner)
        expression = re.search(r"let width = (min\(max\(available.width.*?480\))", self.scanner, re.S).group(1)
        expression = expression.replace("available.width", "width").replace("available.height", "height")
        card_width = eval(expression, {"__builtins__": {}, "min": min, "max": max},
                          dict(width=preview_width, height=upper_height))
        card_height = card_width / (85.6 / 54)
        serial_bottom = upper_height / 2 + card_height / 2
        vision_serial_min_y = 1 - serial_bottom / preview_height
        self.assertGreater(vision_serial_min_y, 0.5)
        self.assertNotIn("request.regionOfInterest", self.scanner)
        self.assertIn("request.recognitionLevel = VNRequestTextRecognitionLevel.accurate", self.scanner)
        self.assertIn("sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)", self.scanner)

    def test_toolbar_actions_have_native_symbol_labels(self):
        for title, symbol in (("Cancel", "xmark"), ("Save", "checkmark"), ("Rotate", "rotate.right")):
            self.assertIn(f'Label("{title}", systemImage: "{symbol}")', self.editor)
        self.assertIn('Label("Close", systemImage: "xmark")', self.scanner)
        self.assertEqual(self.secondary.count('Label("Done", systemImage: "checkmark")'), 2)


if __name__ == "__main__":
    unittest.main()
