import Foundation

/// Public DESFire reads wrapped in ISO 7816 APDUs. Application IDs use the
/// on-wire byte order (FareBot's Clipper ID is 90 11 F2).
struct DESFireReader {
    private let transmit: (Data) async throws -> Data
    static let maximumFileSize = 8192
    static let maximumFrames = 256

    enum ReadError: Error {
        case status(UInt8)
        case malformedResponse
    }

    init(card: any ISO7816Card) {
        transmit = { request in
            guard let apdu = CardAPDU(data: request) else { throw ReadError.malformedResponse }
            let (body, sw1, sw2) = try await card.sendCommand(apdu: apdu)
            return body + Data([sw1, sw2])
        }
    }

    init(card: any MiFareCard) {
        transmit = { try await card.sendMiFareCommand(commandPacket: $0) }
    }

    func select(application: Data) async throws {
        guard application.count == 3 else { throw ReadError.malformedResponse }
        let response = try await exchange(0x5A, data: application)
        guard response.isEmpty else { throw ReadError.malformedResponse }
    }

    func readFile(_ number: UInt8) async throws -> Data {
        let settings = try await exchange(0xF5, data: Data([number]))
        let bytes = [UInt8](settings)
        guard bytes.count >= 7 else { throw ReadError.malformedResponse }
        func length(at offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
        }
        let command: UInt8
        let expectedSize: Int
        switch bytes[0] {
        case 0, 1:
            guard bytes.count == 7 else { throw ReadError.malformedResponse }
            command = 0xBD
            expectedSize = length(at: 4)
        case 3, 4:
            guard bytes.count == 13, length(at: 4) == 32,
                  length(at: 10) <= length(at: 7) else { throw ReadError.malformedResponse }
            command = 0xBB
            expectedSize = length(at: 4) * length(at: 10)
        default:
            throw ReadError.malformedResponse
        }
        guard expectedSize <= Self.maximumFileSize else { throw ReadError.malformedResponse }
        if expectedSize == 0 { return Data() }
        // Zero offset and length request the entire data file / record history.
        let response = try await exchange(command, data: Data([number, 0, 0, 0, 0, 0, 0]))
        guard response.count == expectedSize else { throw ReadError.malformedResponse }
        return response
    }

    func exchange(_ instruction: UInt8, data: Data = Data()) async throws -> Data {
        guard [0x5A, 0xF5, 0xBD, 0xBB].contains(instruction), data.count <= 255 else {
            throw ReadError.malformedResponse
        }
        var instruction = instruction
        var parameters = data
        var result = Data()
        // Bound both bytes and frames: broken cards can return 91AF forever.
        for _ in 0..<Self.maximumFrames {
            try Task.checkCancellation()
            let apdu = CardAPDU(instructionClass: 0x90, instructionCode: instruction,
                                p1Parameter: 0, p2Parameter: 0, data: parameters, expectedResponseLength: 256)
            let response = [UInt8](try await transmit(apdu.encoded))
            try Task.checkCancellation()
            guard response.count >= 2, response[response.count - 2] == 0x91 else {
                throw ReadError.malformedResponse
            }
            let sw2 = response[response.count - 1]
            let body = response.dropLast(2)
            guard sw2 == 0 || sw2 == 0xAF else { throw ReadError.status(sw2) }
            guard result.count + body.count <= Self.maximumFileSize else { throw ReadError.malformedResponse }
            result.append(contentsOf: body)
            if sw2 == 0 { return result }
            guard !body.isEmpty else { throw ReadError.malformedResponse }
            instruction = 0xAF
            parameters = Data()
        }
        throw ReadError.malformedResponse
    }
}
