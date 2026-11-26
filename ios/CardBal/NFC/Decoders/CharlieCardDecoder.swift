// SPDX-License-Identifier: GPL-3.0-or-later
// CharlieCard reader adapted from Metrodroid. See docs/decoding/charliecard.md.
import Foundation

/// Reads a Boston CharlieCard over a MIFARE Classic transport. Sector 0 is
/// authenticated with the two public CharlieCard sector-0 keys first, each as
/// key A and key B; a card that refuses them is not a CharlieCard. Every other
/// sector is opened by trying the public key pool. No block is ever written.
struct CharlieCardDecoder: TransitCardDecoder {
    static func canDecode(tag: CardTag) async -> Bool {
        if case .classic = tag { return true }
        return false
    }

    static func decode(tag: CardTag, scannedAt: Date) async throws -> TransitCardSnapshot {
        guard case .classic(let card) = tag else { throw NFCTestError.unsupportedCard }
        // Identify the card by its sector-0 key before touching other sectors.
        guard try await authenticate(card, sector: 0) != nil else {
            DebugLog.shared.log("CharlieCard", "Sector 0 refused the CharlieCard keys; not a CharlieCard")
            throw NFCTestError.unsupportedCard
        }
        ScanProgress.report(.balance)
        var sectors: [Int: [Data]] = [:]
        for sector in CharlieCardProtocol.requiredSectors {
            try Task.checkCancellation()
            guard try await authenticate(card, sector: sector) != nil else {
                DebugLog.shared.log("CharlieCard", "Sector \(sector) refused the public keys")
                if sector == 0 { throw NFCTestError.unsupportedCard }
                continue
            }
            var blocks: [Data] = []
            for block in 0..<3 {
                let data = try await card.readBlock(sector * 4 + block)
                guard data.count == 16 else { throw ExternalReaderError.malformedResponse }
                blocks.append(data)
            }
            sectors[sector] = blocks
        }
        guard let snapshot = CharlieCardProtocol.snapshot(sectors: sectors, identifier: card.identifier, scannedAt: scannedAt) else {
            throw NFCTestError.unsupportedCard
        }
        return snapshot
    }

    /// Authenticate `sector` by trying the public key pool as key A then key B.
    /// Sector 0 uses only its two known keys, each as key A and key B, since
    /// either may hold either role. Returns the key that worked.
    private static func authenticate(_ card: any ClassicCard, sector: Int) async throws -> Data? {
        let block = sector * 4
        let keys = sector == 0 ? CharlieCardProtocol.sector0Keys : CharlieCardProtocol.keys
        for isKeyB in [false, true] {
            for key in keys {
                try Task.checkCancellation()
                if try await card.authenticate(block: block, key: key, isKeyB: isKeyB) { return key }
            }
        }
        return nil
    }

    static func decodeTransaction(_ data: Data) -> TransitTransaction? {
        CharlieCardProtocol.decodeTransaction(data)
    }
}
