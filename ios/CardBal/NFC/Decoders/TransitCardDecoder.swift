import Foundation

protocol TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool
    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot
}
