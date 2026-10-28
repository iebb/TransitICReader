import Foundation

/// Geohash cell centres, with shared-prefix compression for successive vertices.
/// Header: one precision digit. Each vertex: prefix length + remaining base32 digits.
enum GeohashPath {
    private static let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz".utf8)

    static func encode(longitude: Double, latitude: Double, precision: Int = 9) -> String? {
        guard (1...9).contains(precision), longitude.isFinite, latitude.isFinite,
              (-180...180).contains(longitude), (-90...90).contains(latitude) else { return nil }
        var bounds = [(-180.0, 180.0), (-90.0, 90.0)]
        var bytes: [UInt8] = []
        var value = 0
        for bit in 0..<(precision * 5) {
            let axis = bit % 2
            let middle = (bounds[axis].0 + bounds[axis].1) / 2
            let high = (axis == 0 ? longitude : latitude) >= middle
            value = (value << 1) | (high ? 1 : 0)
            if high { bounds[axis].0 = middle } else { bounds[axis].1 = middle }
            if bit % 5 == 4 { bytes.append(alphabet[value]); value = 0 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func decode(_ hash: String) -> (longitude: Double, latitude: Double)? {
        let bytes = Array(hash.utf8)
        guard (1...9).contains(bytes.count) else { return nil }
        var bounds = [(-180.0, 180.0), (-90.0, 90.0)]
        var bit = 0
        for byte in bytes {
            guard let value = alphabet.firstIndex(of: byte) else { return nil }
            for shift in stride(from: 4, through: 0, by: -1) {
                let axis = bit % 2
                let middle = (bounds[axis].0 + bounds[axis].1) / 2
                if value & (1 << shift) != 0 { bounds[axis].0 = middle } else { bounds[axis].1 = middle }
                bit += 1
            }
        }
        return ((bounds[0].0 + bounds[0].1) / 2, (bounds[1].0 + bounds[1].1) / 2)
    }

    static func encode(_ points: [(longitude: Double, latitude: Double)], precision: Int = 9) -> String? {
        guard (1...9).contains(precision) else { return nil }
        var result = String(precision)
        var previous: [UInt8] = []
        var count = 0
        for point in points {
            guard let hash = encode(longitude: point.longitude, latitude: point.latitude, precision: precision) else { return nil }
            let current = Array(hash.utf8)
            if current == previous { continue }
            var shared = 0
            while shared < previous.count && previous[shared] == current[shared] { shared += 1 }
            result += String(shared) + String(decoding: current.dropFirst(shared), as: UTF8.self)
            previous = current
            count += 1
        }
        return count >= 2 ? result : nil
    }

    static func decodePath(_ value: String) -> [(longitude: Double, latitude: Double)]? {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, (49...57).contains(first) else { return nil }
        let precision = Int(first - 48)
        var offset = 1
        var previous: [UInt8] = []
        var output: [(longitude: Double, latitude: Double)] = []
        while offset < bytes.count {
            let prefix = bytes[offset]
            guard (48...57).contains(prefix) else { return nil }
            let shared = Int(prefix - 48)
            offset += 1
            guard shared <= min(previous.count, precision), offset + precision - shared <= bytes.count else { return nil }
            let current = Array(previous.prefix(shared)) + bytes[offset..<(offset + precision - shared)]
            offset += precision - shared
            guard let point = decode(String(decoding: current, as: UTF8.self)) else { return nil }
            output.append(point)
            previous = current
        }
        return output.count >= 2 ? output : nil
    }
}
