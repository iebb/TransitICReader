import struct
import unittest


import tools.maintenance.stations.ub_smart_bus as module


def utf16(value: str) -> bytes:
    encoded = value.encode("utf-16le")
    return bytes([len(encoded)]) + encoded


def route(route_id: int, name: str, endpoint: str) -> bytes:
    return struct.pack("<i", route_id) + utf16(name) + utf16(endpoint)


def station(station_id: int, name: str, longitude: float, latitude: float) -> bytes:
    return (
        struct.pack("<i", station_id)
        + b"123456"
        + utf16(name)
        + struct.pack("<ii", round(longitude * 1_000_000), round(latitude * 1_000_000))
    )


class PacketTests(unittest.TestCase):
    def test_packet_round_trip(self) -> None:
        encoded = module.encode_packet(9, 5, 9, b"payload")
        decoded = module.decode_packet(encoded[:7], encoded[7:])
        self.assertEqual(decoded.sequence, 9)
        self.assertEqual(decoded.packet_type, 5)
        self.assertEqual(decoded.opcode, 9)
        self.assertEqual(decoded.body, b"payload")

    def test_production_zero_response_crc_is_accepted(self) -> None:
        encoded = bytearray(module.encode_packet(1, 1, 2, b""))
        encoded[-3:-1] = b"\0\0"
        decoded = module.decode_packet(bytes(encoded[:7]), bytes(encoded[7:]))
        self.assertEqual(decoded.opcode, 2)

    def test_nonzero_invalid_crc_is_rejected(self) -> None:
        encoded = bytearray(module.encode_packet(1, 1, 2, b""))
        encoded[-3:-1] = b"\x01\x00"
        with self.assertRaises(module.ProtocolError):
            module.decode_packet(bytes(encoded[:7]), bytes(encoded[7:]))


class BodyTests(unittest.TestCase):
    def test_search_response(self) -> None:
        body = (
            bytes([1, 1, 1])
            + route(11100801, "Ч:1", "5 шар-Офицеруудын ордон")
            + bytes([1])
            + station(1226, "10 ШАР БАЙР", 107.24589, 47.76735)
        )
        page = module.parse_search_response(body)
        self.assertEqual(page.total_routes, 1)
        self.assertEqual(page.total_stations, 1)
        self.assertEqual(page.routes[0].route_id, 11100801)
        self.assertEqual(page.stations[0].station_id, 1226)
        self.assertAlmostEqual(page.stations[0].longitude, 107.24589)

    def test_route_station_response(self) -> None:
        body = struct.pack("<hB", 1, 1) + station(305, "100 айл", 106.928349, 47.92983)
        page = module.parse_route_stations_response(body)
        self.assertEqual(page.total_stations, 1)
        self.assertEqual(page.stations[0].station_name, "100 айл")

    def test_mns_5217_romanization(self) -> None:
        self.assertEqual(module.romanize_mongolian("Өвөр согоот"), "Övör sogoot")
        self.assertEqual(module.romanize_mongolian("Чингэлтэй"), "Chingeltej")


if __name__ == "__main__":
    unittest.main()
