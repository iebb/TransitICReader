import Foundation

/// Shared read guards for the FE00 stored-value services. Metadata services are
/// optional; callers decide which single service establishes their balance.
enum RetailFeliCaRead {
    static func select(_ tag: FeliCaCard) async -> Bool {
        let system = Data([0xFE, 0x00])
        guard let response = try? await tag.polling(systemCode: system, requestCode: .systemCode, timeSlot: .max1) else { return false }
        return response.1 == system
    }

    static func block(_ tag: FeliCaCard, service: Data, index: UInt8 = 0) async -> Data? {
        guard let response = try? await tag.readWithoutEncryption(
            serviceCodeList: [service], blockList: [Data([0x80, index])]
        ), response.0 == 0, response.1 == 0, response.2.count == 1,
              let block = response.2.first, block.count == 16 else { return nil }
        return block
    }

    static func number(_ block: Data?, bytes range: Range<Int>) -> String? {
        guard let block, block.count == 16, range.lowerBound >= 0, range.upperBound <= block.count else { return nil }
        let bytes = block.subdata(in: range)
        guard !bytes.isEmpty, bytes.contains(where: { $0 != 0 }),
              bytes.allSatisfy({ $0 >> 4 <= 9 && $0 & 15 <= 9 }) else { return nil }
        return bytes.hexString.uppercased()
    }
}
