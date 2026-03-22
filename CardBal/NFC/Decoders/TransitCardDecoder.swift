import Foundation
import CoreNFC

protocol TransitCardDecoder {
    static func canDecode(tag: NFCTag) async -> Bool
    static func decode(tag: NFCTag, scannedAt: Date) async throws -> TransitCardSnapshot
}
