"""Ride camera source contracts and optional Swift production-logic harness.

The harness runs extracted production methods against deterministic MapKit stand-ins.
It is not a simulator, an app build, or evidence of native MapKit rendering.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.paths import ROOT


SOURCE = ROOT / "ios/CardBal/Views/RideMapView.swift"


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


class RideCameraStateTests(unittest.TestCase):
    def test_full_camera_is_owned_above_presentation_switch(self):
        source = SOURCE.read_text()
        self.assertIn("@State private var cameraState = RideMapCameraState()", source)
        snapshot = declaration(source, "private struct RideMapCameraSnapshot")
        for stored, api in (("center", "centerCoordinate"), ("altitude", "altitude"), ("heading", "heading"), ("pitch", "pitch")):
            self.assertIn(f"{stored} = camera.{api}", snapshot)
            self.assertIn(f"camera.{api} = {stored}", snapshot)
        viewport = declaration(source, "private final class RideMapViewportView")
        self.assertIn("bounds.width > 0, bounds.height > 0", viewport)
        self.assertIn("DispatchQueue.main.async", viewport)

    def test_commands_and_stale_callbacks_are_guarded(self):
        source = SOURCE.read_text()
        self.assertEqual(source.count("regionCommandRevision &+= 1"), 2)
        for target in ("route.coordinates", "screenData.allCoordinates"):
            self.assertIn(f"regionCommandRevision &+= 1\n            region = region(for: {target})", source)
        restore = declaration(source, "func applyInitialViewport")
        self.assertIn("snapshot.commandRevision == regionCommandRevision", restore)
        self.assertIn("mapView.setCamera(snapshot.camera, animated: false)", restore)
        self.assertIn("mapView.setRegion(region, animated: false)", restore)
        capture = declaration(source, "private func captureViewport")
        self.assertIn("isActive, !needsInitialViewport, !isApplyingViewport", capture)
        self.assertIn("appliedCommandRevision == regionCommandRevision", capture)
        self.assertIn("coordinator.isActive = false", source)
        self.assertIn("mapView.delegate = nil", source)

    @unittest.skipUnless(shutil.which("swift"), "Swift CLI unavailable; source contracts still run")
    def test_extracted_production_camera_logic(self):
        source = SOURCE.read_text()
        snapshot = declaration(source, "private struct RideMapCameraSnapshot")
        state = declaration(source, "private final class RideMapCameraState")
        restore = declaration(source, "func applyInitialViewport")
        capture = declaration(source, "private func captureViewport")
        equality = declaration(source, "func region(_ lhs: MKCoordinateRegion")
        harness = r'''
import Foundation
import CoreGraphics

typealias CLLocationDistance = Double
typealias CLLocationDirection = Double
struct CLLocationCoordinate2D { var latitude: Double; var longitude: Double }
struct MKCoordinateSpan { var latitudeDelta: Double; var longitudeDelta: Double }
struct MKCoordinateRegion {
    var center: CLLocationCoordinate2D
    var span: MKCoordinateSpan
}
final class MKMapCamera {
    var centerCoordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var altitude: Double = 1
    var heading: Double = 0
    var pitch: CGFloat = 0
}
final class MKMapView {
    var bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
    var camera = MKMapCamera()
    var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
    )
    var lastOperation = ""
    var duringApply: (() -> Void)?
    func setCamera(_ value: MKMapCamera, animated: Bool) {
        lastOperation = "camera"
        camera = value
        region.center = value.centerCoordinate
        region.span = MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 3)
        duringApply?()
    }
    func setRegion(_ value: MKCoordinateRegion, animated: Bool) {
        lastOperation = "region"
        region = value
        camera = MKMapCamera()
        camera.centerCoordinate = value.center
        duringApply?()
    }
}
__SNAPSHOT__
__STATE__
private final class Coordinator {
    var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 5, longitude: 6),
        span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
    )
    let cameraState = RideMapCameraState()
    var regionCommandRevision = 4
    var appliedCommandRevision: Int?
    var needsInitialViewport = true
    var isActive = true
    private var isApplyingViewport = false
    __RESTORE__
    __CAPTURE__
    __EQUALITY__
    func receive(_ map: MKMapView) { captureViewport(from: map) }
}
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fatalError(label) }
}
private func runTests() {
let original = MKMapCamera()
original.centerCoordinate = CLLocationCoordinate2D(latitude: 31.5, longitude: 121.5)
original.altitude = 12345
original.heading = 137
original.pitch = 48
let c = Coordinator()
c.cameraState.snapshot = RideMapCameraSnapshot(camera: original, commandRevision: 4)
let map = MKMapView()
map.bounds = .zero
c.applyInitialViewport(to: map)
check(c.needsInitialViewport && map.lastOperation.isEmpty, "wait for nonzero bounds")
map.bounds = CGRect(x: 0, y: 0, width: 700, height: 350)
map.duringApply = {
    c.receive(map)
    check(c.cameraState.snapshot!.altitude == 12345, "ignore reentrant callbacks")
}
c.applyInitialViewport(to: map)
check(map.lastOperation == "camera", "restore unchanged command")
check(map.camera.centerCoordinate.latitude == 31.5 && map.camera.centerCoordinate.longitude == 121.5, "center")
check(map.camera.altitude == 12345 && map.camera.heading == 137 && map.camera.pitch == 48, "full camera")
check(c.region.span.longitudeDelta == 3, "publish resized region before later updates")
let focus = Coordinator()
focus.cameraState.snapshot = RideMapCameraSnapshot(camera: original, commandRevision: 4)
focus.regionCommandRevision = 5
focus.applyInitialViewport(to: MKMapView())
check(focus.cameraState.snapshot!.center.latitude == 5, "new focus wins over stale camera")
let stale = MKMapView()
stale.camera.altitude = 999
c.regionCommandRevision = 5
c.receive(stale)
check(c.cameraState.snapshot!.altitude == 12345, "callback before command application ignored")
c.regionCommandRevision = 4
c.isActive = false
c.receive(stale)
check(c.cameraState.snapshot!.altitude == 12345, "dismantled callback ignored")
print("PASS: full camera, nonzero viewport, new focus, feedback and teardown guards")
}
runTests()
'''
        for marker, content in (("__SNAPSHOT__", snapshot), ("__STATE__", state), ("__RESTORE__", restore), ("__CAPTURE__", capture), ("__EQUALITY__", equality)):
            harness = harness.replace(marker, content)
        with tempfile.TemporaryDirectory(prefix="ride-camera-test-") as directory:
            path = Path(directory) / "main.swift"
            path.write_text(harness)
            result = subprocess.run([shutil.which("swift"), str(path)], text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS: full camera", result.stdout)


if __name__ == "__main__":
    unittest.main()
