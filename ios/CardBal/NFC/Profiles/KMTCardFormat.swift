import Foundation

/// Independently implemented from the documented KMT FeliCa wire fields.
/// Evidence: Metrodroid KMTTransitData at b910c1806fd86aa545223baf1d21fc5afe68eee2.
/// No reference implementation is copied; the history epoch is deliberately unused.
enum KMTCardFormat {
    static let systemCode = "90B7"
    static let balanceService = Data([0x17, 0x10])
    static let identifierService = Data([0x0B, 0x30])
    static let historyService = Data([0x0F, 0x20])
    static let historyReadLimit = 20

    struct Balance: Equatable {
        let amountIDR: UInt64
        let lastTransactionAmountIDR: UInt64
        let transactionCounter: UInt32
    }

    static func isSelectedSystem(_ system: Data?) -> Bool {
        system == Data([0x90, 0xB7])
    }

    /// Core NFC checks the addressed frame. Also require a successful status and
    /// exactly the one complete block requested, rather than accepting a prefix.
    static func validatedRead(
        selectedSystem: Data?, status1: Int, status2: Int, blocks: [Data]
    ) -> Data? {
        guard isSelectedSystem(selectedSystem), status1 == 0, status2 == 0,
              blocks.count == 1, let block = blocks.first, block.count == 16 else { return nil }
        return block
    }

    static func parseBalance(_ block: Data) -> Balance? {
        guard block.count == 16 else { return nil }
        let bytes = Array(block)
        func littleEndianAmount(at offset: Int) -> UInt64 {
            (0..<4).reduce(0) { value, index in
                value | (UInt64(bytes[offset + index]) << (index * 8))
            }
        }
        let counter = bytes[13..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Balance(
            amountIDR: littleEndianAmount(at: 0),
            lastTransactionAmountIDR: littleEndianAmount(at: 4),
            transactionCounter: counter
        )
    }

    /// Only display a printable identifier. Binary/unknown layouts remain raw
    /// data; the tag's IDm is always retained as the physical identifier.
    static func identifier(_ block: Data) -> String? {
        guard block.count == 16 else { return nil }
        var bytes = Array(block)
        while bytes.last == 0 || bytes.last == 0x20 { bytes.removeLast() }
        guard !bytes.isEmpty, bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
              let value = String(bytes: bytes, encoding: .ascii) else { return nil }
        let identifier = value.trimmingCharacters(in: .whitespaces)
        return identifier.isEmpty ? nil : identifier
    }

    static func isHistoryBlock(_ block: Data) -> Bool {
        block.count == 16 && block.contains { $0 != 0 }
    }

    static func matchesFamily(_ family: String) -> Bool {
        ["kmt", "kartu multi trip"].contains(family.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
