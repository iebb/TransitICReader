"""Source contracts for map reflow; not rendered UI or MapKit runtime tests."""
import math
import unittest

from tools.paths import ROOT


class DuoMapLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        views = ROOT / "ios/CardBal/Views"
        cls.atlas = (views / "CityAtlasView.swift").read_text()
        cls.ride = (views / "RideMapView.swift").read_text()

    def test_atlas_safe_area_change_invalidates_without_caching_insets(self):
        view = self.atlas.split("private final class AtlasMapView:", 1)[1].split(
            "private struct CityAtlasMapRepresentable:", 1
        )[0]
        callback = view.split("override func safeAreaInsetsDidChange()", 1)[1].split(
            "override func layoutSubviews()", 1
        )[0]
        self.assertIn("super.safeAreaInsetsDidChange()", callback)
        self.assertIn("safeAreaInvalidated = true", callback)
        self.assertIn("setNeedsLayout()", callback)
        self.assertNotIn("safeAreaInsets", callback.split("super.safeAreaInsetsDidChange()", 1)[1])
        self.assertNotIn("previousInsets", view)
        self.assertIn("bounds.size != previousSize || safeAreaInvalidated", view)
        self.assertIn("let safeAreaChanged = safeAreaInvalidated", view)
        self.assertIn("safeAreaInvalidated = false", view)
        self.assertIn("viewportDidChange?(safeAreaChanged)", view)

    def test_invalidation_reaches_camera_guard_without_overriding_user_exploration(self):
        self.assertIn("updateMap(mapView, safeAreaChanged: safeAreaChanged)", self.atlas)
        update = self.atlas.split("func updateMap(_ mapView:", 1)[1].split(
            "private func focusOnAllCountries", 1
        )[0]
        self.assertIn("safeAreaChanged: Bool = false", update)
        self.assertIn("let viewportChanged = safeAreaChanged", update)
        self.assertIn("guard selectionChanged || (viewportChanged && !userAdjustedCamera)", update)
        self.assertIn("if selectionChanged { userAdjustedCamera = false }", update)
        self.assertIn("if isInteracting(mapView) { userAdjustedCamera = true }", update)
        # Same-size safe-area changes refit only a camera the user hasn't adjusted.
        for selection, safe_area, resized, user_adjusted, expected in (
            (False, True, False, False, True),
            (False, True, False, True, False),
            (False, False, True, True, False),
            (True, True, False, True, True),
            (False, False, False, False, False),
        ):
            actual = selection or ((safe_area or resized) and not user_adjusted)
            self.assertEqual(actual, expected)

    def test_atlas_camera_padding_comes_from_measured_frames(self):
        insets = self.atlas.split("private func mapContentInsets(", 1)[1].split(
            "@ViewBuilder\n    private func atlasControls(", 1
        )[0]
        self.assertIn("contentInsets: mapContentInsets(usesSidePanel: usesSidePanel, viewportSize: viewportSize)", self.atlas)
        self.assertIn('guard let measuredMap = controlFrames["map"]', insets)
        self.assertIn("measuredMap.intersection(CGRect(origin: .zero, size: viewportSize))", insets)
        for contract in (
            'if usesSidePanel, let panel = controlFrames["panel"] {',
            "if panel.intersects(map) {",
            "let panelOnLeft = panel.midX < map.midX",
            "let panelOnTop = panel.midY < map.midY",
            "? panel.maxX - map.minX + 12",
            ": map.maxX - panel.minX + 12",
            "? panel.maxY - map.minY + 12",
            ": map.maxY - panel.minY + 12",
            "panel.height < map.height * 0.6",
            'if let header = controlFrames["header"], header.intersects(map) {',
            "insets.top = header.maxY - map.minY + 12",
            'if showsSummary, let summary = controlFrames["summary"], summary.intersects(map) {',
            "insets.bottom = map.maxY - summary.minY + 24",
            "top: clampedInset(insets.top, dimension: map.height)",
            "left: clampedInset(insets.left, dimension: map.width)",
            "bottom: clampedInset(insets.bottom, dimension: map.height)",
            "right: clampedInset(insets.right, dimension: map.width)",
            "let limit = max(20, (dimension / 2 - 1).rounded(.down))",
            "return min(max(value.rounded(), 20), limit)",
        ):
            self.assertIn(contract, insets)
        # No dead overlap flags, hard-coded panel width + 32, or late side inference.
        for removed in ("panelOverlaps", "headerOverlaps", "summaryOverlaps", "panelTrailing", "panelLeading",
                        "+ 32", "onTrailingSide", 'controlSizes["panel"]', 'controlSizes["header"]',
                        'controlSizes["summary"]'):
            self.assertNotIn(removed, self.atlas)
        # Late side inference is about the camera insets only; 2.5.0 uses
        # `?? true` elsewhere for its country scope filter.
        self.assertNotIn("?? true", insets)
        for edge in ("top", "left", "bottom", "right"):
            self.assertIn(f"mapView.safeAreaInsets.{edge} + parent.contentInsets.{edge}", self.atlas)

    def test_atlas_inset_arithmetic_examples(self):
        # A Python port of mapContentInsets: arithmetic contracts, not MapKit evidence.
        # Rects are (minX, minY, maxX, maxY) in the "atlasViewport" space.
        def clamp(value, dimension):
            limit = max(20, math.floor(dimension / 2 - 1))
            return min(max(math.floor(value + 0.5), 20), limit)

        def insets(map_rect, viewport, panel=None, header=None, summary=None, side_panel=True):
            x0, y0 = max(map_rect[0], 0), max(map_rect[1], 0)
            x1, y1 = min(map_rect[2], viewport[0]), min(map_rect[3], viewport[1])
            w, h = x1 - x0, y1 - y0
            top = left = bottom = right = 20
            if side_panel and panel:
                px0, py0, px1, py1 = panel
                on_left = (px0 + px1) / 2 < (x0 + x1) / 2
                on_top = (py0 + py1) / 2 < (y0 + y1) / 2
                side = px1 - x0 + 12 if on_left else x1 - px0 + 12
                vertical = py1 - y0 + 12 if on_top else y1 - py0 + 12
                if py1 - py0 < h * 0.6 and vertical / h < side / w:
                    if on_top:
                        top = vertical
                    else:
                        bottom = vertical
                elif on_left:
                    left = side
                else:
                    right = side
            elif not side_panel:
                if header:
                    top = header[3] - y0 + 12
                if summary:
                    bottom = y1 - summary[1] + 24
            return clamp(top, h), clamp(left, w), clamp(bottom, h), clamp(right, w)

        viewport = (1700, 800)
        full_bleed = (-30, -24, 1730, 850)  # the map ignores the safe area
        # Tall leading panel on the left (LTR) pads only the left: 12 + 300 + 12.
        self.assertEqual(insets(full_bleed, viewport, panel=(12, 12, 312, 764)), (20, 324, 20, 20))
        # The same panel on the physical right (RTL or fold fallback) pads the right.
        self.assertEqual(insets(full_bleed, viewport, panel=(1388, 12, 1688, 764)), (20, 20, 20, 324))
        # A header-only panel pads the top: it costs less of the map than the side.
        self.assertEqual(insets(full_bleed, viewport, panel=(12, 12, 312, 64)), (76, 20, 20, 20))
        # A medium panel still pads the side when that is the cheaper edge.
        self.assertEqual(insets(full_bleed, viewport, panel=(12, 12, 312, 380)), (20, 324, 20, 20))
        # Tabletop fold: a short panel placed below the fold pads the bottom.
        self.assertEqual(insets((0, 0, 900, 860), (900, 860), panel=(12, 674, 312, 824)), (20, 20, 198, 20))
        # Insets stay under half the map dimension.
        self.assertEqual(insets((0, 0, 600, 800), (600, 800), panel=(12, 12, 340, 788)), (20, 299, 20, 20))
        # Compact: header on top, summary above the attribution.
        self.assertEqual(
            insets((0, -47, 390, 800), (390, 760), header=(12, 12, 378, 64), summary=(12, 600, 378, 724), side_panel=False),
            (76, 20, 184, 20),
        )

    def test_regular_width_and_actual_capacity_gate_both_companions(self):
        for source, name in ((self.atlas, "usesSidePanel"), (self.ride, "usesCompanion")):
            gate = source.split(f"let {name} =", 1)[1].split("\n\n", 1)[0]
            self.assertIn("horizontalSizeClass == .regular", gate)
            self.assertIn("!dynamicTypeSize.isAccessibilitySize", gate)
            self.assertIn(">= 320", gate)
            self.assertIn("viewport.size.height >= 220", gate)
            self.assertNotRegex(gate, r">= (?:700|560)|width > viewport.size.height")
        # Capacity examples are arithmetic contracts, not device/runtime evidence.
        for width, height, regular, accessibility, expected in (
            (669, 800, True, False, True),
            (867, 600, True, False, True),
            (540, 800, True, False, False),
            (867, 400, False, False, False),
            (867, 400, True, True, False),
            (867, 180, True, False, False),
        ):
            panel = min(300, max(240, width - 344))
            actual = regular and not accessibility and width - panel - 24 >= 320 and height >= 220
            self.assertEqual(actual, expected, (width, height, regular, accessibility))

    def test_atlas_panel_uses_local_capacity_and_measured_overlap(self):
        self.assertIn("min(panelWidth, max(0, controlsViewport.size.width - 24))", self.atlas)
        self.assertIn("usesSidePanel && localPanelWidth >= 240", self.atlas)
        self.assertIn(".frame(width: localPanelWidth)", self.atlas)
        self.assertIn('.atlasMeasureFrame("map")', self.atlas)
        self.assertIn('.atlasMeasureFrame("panel")', self.atlas)
        self.assertIn('.atlasMeasureFrame("header")', self.atlas)
        self.assertIn('.atlasMeasureFrame("summary")', self.atlas)
        self.assertIn("panel.intersects(map)", self.atlas)

    def test_atlas_keeps_one_full_bleed_map_behind_fold_aware_controls(self):
        atlas_layout = self.atlas.split("var body: some View {", 2)[2].split(
            ".preferredColorScheme", 1
        )[0]
        self.assertNotIn("ArrangementView", self.atlas)
        self.assertNotIn("arrangementViewStyle", self.atlas)
        self.assertNotIn("overlayArrangementEdge", self.atlas)
        # No availability or conditional branch may choose between trees holding the map.
        self.assertNotIn("#available", atlas_layout)
        self.assertNotRegex(atlas_layout, r"\bif\b")
        self.assertIn("ZStack {", atlas_layout)
        self.assertEqual(atlas_layout.count("atlasMap("), 1)
        self.assertEqual(atlas_layout.count("atlasControls("), 1)
        self.assertLess(atlas_layout.index("atlasMap("), atlas_layout.index("atlasControls("))
        self.assertEqual(self.atlas.count("CityAtlasMapRepresentable("), 1)
        for kept in ('.coordinateSpace(name: "atlasViewport")', ".onPreferenceChange(AtlasControlSizeKey.self)",
                     ".onPreferenceChange(AtlasControlFrameKey.self)", ".ignoresSafeArea())"):
            self.assertIn(kept, atlas_layout)
        atlas_map = self.atlas.split("private func atlasMap(", 1)[1].split("private func atlasControls(", 1)[0]
        self.assertIn(".ignoresSafeArea()", atlas_map)
        # The fold is read only for the foreground controls, from active regions.
        fold = self.atlas.split("private func activeFold(in proxy: GeometryProxy)", 1)[1].split(
            "private var header: some View", 1
        )[0]
        self.assertIn("if #available(iOS 27.1, *)", fold)
        self.assertIn("reservedRegions(kind: .division, layoutDirectionBehavior: .fixed)", fold)
        self.assertNotIn("includeInactive", self.atlas)
        controls = self.atlas.split("private func atlasControls(", 1)[1].split("private func sidePanel(", 1)[0]
        self.assertIn("controlsPlacement(", controls)
        self.assertNotIn("atlasMap(", controls)

    def test_atlas_controls_stay_beside_book_fold_and_off_tabletop_fold(self):
        placement = self.atlas.split("private func controlsPlacement(", 1)[1].split(
            "private func activeFold(", 1
        )[0]
        for contract in (
            "let leftWidth = max(0, book.minX - 12 - 12)",
            "let rightWidth = max(0, size.width - book.maxX - 12 - 12)",
            "let leadingWidth = isRightToLeft ? rightWidth : leftWidth",
            "placement.usesTrailingSide = leadingWidth < 240 && trailingWidth > leadingWidth",
            "localPanelWidth = min(localPanelWidth, sideWidth)",
            "placement.compactMaxWidth = sideWidth",
            "if aboveHeight >= 220 || aboveHeight >= belowHeight",
            "placement.panelTopOffset = tabletop.maxY",
            "&& panelRegionHeight >= 220",
        ):
            self.assertIn(contract, placement)
        self.assertEqual(self.atlas.count(".frame(maxWidth: placement.compactMaxWidth)"), 2)
        self.assertEqual(self.atlas.count(".frame(maxWidth: .infinity, alignment: placement.sideAlignment)"), 2)
        self.assertIn(".frame(maxHeight: placement.panelMaxHeight)", self.atlas)
        self.assertIn(".padding(.top, placement.panelTopOffset)", self.atlas)

        # Arithmetic contract (not device evidence): the LTR panel spans [12, 12 + w].
        def book(width, fold_min, fold_max, panel=300, rtl=False):
            left = max(0, fold_min - 24)
            right = max(0, width - fold_max - 24)
            leading, trailing = (right, left) if rtl else (left, right)
            use_trailing = leading < 240 and trailing > leading
            side = trailing if use_trailing else leading
            return min(panel, max(0, width - 24), side), use_trailing

        for width, fold_min, fold_max, rtl in (
            (1000, 490, 510, False), (1000, 490, 510, True), (700, 340, 360, False),
            (1000, 200, 220, False), (1000, 780, 800, True),
        ):
            with self.subTest(width=width, fold=(fold_min, fold_max), rtl=rtl):
                panel, use_trailing = book(width, fold_min, fold_max, rtl=rtl)
                on_left = rtl == use_trailing
                start, end = (12, 12 + panel) if on_left else (width - 12 - panel, width - 12)
                self.assertTrue(end <= fold_min - 12 or start >= fold_max + 12)
                self.assertGreaterEqual(panel, 240)
        self.assertEqual(book(1000, 200, 220), (300, True))
        # Tabletop: a panel never spans the fold; it moves below when above is short.
        for height, fold_min, fold_max in ((900, 440, 460), (900, 200, 220)):
            above = max(0, fold_min - 24)
            below = max(0, height - fold_max - 24)
            top, cap = (12, above) if above >= 220 or above >= below else (12 + fold_max, below)
            self.assertTrue(top + cap <= fold_min - 12 or top >= fold_max + 12)

    def test_atlas_side_panel_hugs_content_and_scrolls_only_when_needed(self):
        panel = self.atlas.split("private func sidePanel(", 1)[1].split("private func controlsPlacement(", 1)[0]
        self.assertIn("ScrollView {", panel)
        self.assertIn('.atlasMeasure("panelContent")', panel)
        self.assertIn('.frame(maxHeight: controlSizes["panelContent"]?.height ?? .infinity)', panel)
        self.assertLess(panel.index('"panelContent"]?.height'), panel.index('.atlasMeasureFrame("panel")'))
        self.assertIn(".modifier(AtlasPanelScrollBounce())", panel)
        bounce = self.atlas.split("private struct AtlasPanelScrollBounce", 1)[1].split("private extension View", 1)[0]
        self.assertIn("if #available(iOS 16.4, *)", bounce)
        self.assertIn("scrollBounceBehavior(.basedOnSize)", bounce)
        self.assertNotIn("Spacer(minLength: 0)", panel)
        self.assertIn(".padding(.bottom, 24) // Keep MapKit attribution below the floating panel.", self.atlas)

    def test_ride_arrangement_keeps_both_views_and_old_os_fallback(self):
        ride_layout = self.ride.split("private var mapContent:", 1)[1].split(
            "// MARK: - Card Picker", 1
        )[0]
        self.assertIn("if #available(iOS 27.1, *)", ride_layout)
        self.assertIn(".arrangementViewStyle(.split)", ride_layout)
        self.assertIn("minWidth: 240, idealWidth: 300, maxWidth: 340", ride_layout)
        self.assertIn("HStack(spacing: 0)", ride_layout)
        atlas_layout = self.atlas.split("var body: some View {", 2)[2].split(
            ".preferredColorScheme", 1
        )[0]
        for layout in (atlas_layout, ride_layout):
            self.assertNotIn(".split.axes", layout)
            self.assertNotIn("NavigationStack", layout)
            self.assertNotIn("NavigationSplitView", layout)
            self.assertNotIn("TabView", layout)

    def test_ride_compact_bars_reserve_both_edges(self):
        compact = self.ride.split("private var compactMap:", 1)[1].split(
            "private var companionPanel:", 1
        )[0]
        self.assertIn("if #available(iOS 26.0, *)", compact)
        for modifier in ("safeAreaBar", "safeAreaInset"):
            for edge in ("top", "bottom"):
                self.assertIn(f".{modifier}(edge: .{edge}, spacing: 0)", compact)
        self.assertNotIn("ZStack", compact)
        self.assertNotIn("ignoresSafeArea", compact)
        companion = self.ride.split("private var companionPanel:", 1)[1].split(
            "// MARK: - Card Picker", 1
        )[0]
        self.assertIn("cardPickerBar", companion)
        self.assertIn("bottomPanelView", companion)

    def test_map_screen_state_and_selection_stay_outside_layout_identity(self):
        for name in ("selectedCardID", "region", "screenData", "highlightedRouteID", "selectedPointID", "bottomPanel"):
            self.assertIn(f"@State private var {name}", self.ride)
        self.assertIn("region: $region", self.ride)
        self.assertIn("mapView.selectAnnotation(annotation, animated: false)", self.ride)
        for source in (self.atlas, self.ride):
            self.assertNotRegex(source, r"\.id\([^\n]*(?:width|height|size|hinge)")
            self.assertNotRegex(source, r"\.onChange\(of:.*(?:viewport|horizontalSizeClass)")
            self.assertNotRegex(source, r"UIScreen\s*\.\s*main|UIDevice\s*\.\s*current")


if __name__ == "__main__":
    unittest.main()
