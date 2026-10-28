from __future__ import annotations
import shutil
import sqlite3
import subprocess
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from tools.paths import ROOT


class GeohashRuntimeTests(unittest.TestCase):
    def test_swift_codec_matches_reference_vectors_and_rejects_truncation(self):
        if not shutil.which('swiftc'):
            self.skipTest('Swift compiler unavailable')
        fixture = ROOT / 'tests/runtime/fixtures/geohash_paths.json'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            (path/'main.swift').write_text(r'''
import Foundation
let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let input = fixture["points"] as! [[Double]]
let expected = fixture["decoded"] as! [[Double]]
let packed = fixture["encoded"] as! String
precondition(GeohashPath.encode(longitude: -5.6, latitude: 42.6, precision: 5) == "ezs42")
let points = input.map { (longitude: $0[0], latitude: $0[1]) }
precondition(GeohashPath.encode(points) == packed)
let decoded = GeohashPath.decodePath(packed)!
precondition(decoded.count == expected.count)
for (point, wanted) in zip(decoded, expected) {
    precondition(abs(point.longitude - wanted[0]) < 1e-10)
    precondition(abs(point.latitude - wanted[1]) < 1e-10)
}
let reversed = GeohashPath.decodePath(GeohashPath.encode(Array(points.reversed()))!)!
precondition(abs(reversed[0].longitude - decoded.last!.longitude) < 1e-10)
for bad in ["", "0", "9", "91abc", "90!!!!!!!!!", "90xn76urx66x"] {
    precondition(GeohashPath.decodePath(bad) == nil)
}
print("Swift/Python geohash vectors match")
''')
            subprocess.run(['swiftc',str(ROOT/'ios/CardBal/Helpers/GeohashPath.swift'),str(path/'main.swift'),'-o',str(path/'codec')],check=True,capture_output=True)
            result = subprocess.run([str(path/'codec'),str(fixture)],check=True,capture_output=True,text=True)
            self.assertIn('vectors match',result.stdout)

    def test_runtime_paths_are_attached_to_real_graph_edges(self):
        path = ROOT/'build/stations/cardbal_transit.sqlite'
        with closing(sqlite3.connect(path)) as db:
            if not db.execute("SELECT 1 FROM sqlite_master WHERE name='station_edge_paths'").fetchone():
                self.skipTest('Generate CSV routing assets first')
            self.assertGreater(db.execute("SELECT COUNT(*) FROM station_edge_paths WHERE country_code='JP'").fetchone()[0],12000)
            self.assertEqual(db.execute("""SELECT COUNT(*) FROM station_edge_paths p LEFT JOIN station_graph_edges e
              USING(country_code,line_code,from_station_code,to_station_code) WHERE e.country_code IS NULL""").fetchone()[0],0)
            self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])


if __name__ == '__main__':
    unittest.main()
