import Foundation
import CryptoTokenKit

/// USB CCID readers are supplied by the OS; no generic USB or private APIs.
final class ExternalCardReader {
    private let manager = TKSmartCardSlotManager.default
    private var observation: NSKeyValueObservation?

    func observeReaders(_ changed: @escaping ([String]) -> Void) {
        observation = manager?.observe(\.slotNames, options: [.initial, .new]) { manager, _ in
            changed(manager.slotNames.sorted())
        }
        if manager == nil { changed([]) }
    }

    func scan(readerName: String?, options: CardPollingOption) async throws -> TransitCardSnapshot {
        guard let manager else { throw ExternalReaderError.unavailable }
        let names = manager.slotNames.sorted()
        let name = try ExternalReaderSelection.choose(preferred: readerName, available: names)
        guard let slot = manager.slotNamed(name) else { throw ExternalReaderError.noReader }
        guard slot.state == .validCard, let card = slot.makeSmartCard() else { throw ExternalReaderError.noCard }
        try Task.checkCancellation()
        // Start from the implicitly selected application on every scan, even
        // when a previous scan explicitly selected a different application.
        card.isSensitive = true
        try await card.beginSession()
        defer { card.endSession() }
        ScanProgress.report(.found)
        let connection = SmartCardConnection(card: card)
        let uidResponse = try? await connection.exchange(Data([0xFF, 0xCA, 0, 0, 0]))
        let uid = uidResponse.flatMap { $0.1 == 0x90 && $0.2 == 0 ? $0.0 : nil } ?? Data()

        // ACR122U's documented PN532 Direct Transmit is reader specific. Never
        // send it to unrelated CCID readers (which can still exchange ISO APDUs).
        let supportsFeliCa = name.localizedCaseInsensitiveContains("ACR122")
        // The ACR122U reports the eight-byte IDm for FeliCa. ISO 14443 A UIDs
        // are 4/7/10 bytes and B PUPIs are four bytes. Do not repoll an active
        // ISO target as FeliCa: that would deselect it before CEPAS/APDU reads.
        if options.contains(.iso18092), supportsFeliCa, uid.count == 8 {
            let felica = ACR122FeliCaCard(connection: connection)
            if (try? await felica.polling(systemCode: Data([0xFF, 0xFF]), requestCode: .systemCode, timeSlot: .max1)) != nil {
                let tag = CardTag.feliCa(felica)
                for decoder in [EdyDecoder.self, WAONDecoder.self, NanacoDecoder.self, JapaneseICDecoder.self] as [TransitCardDecoder.Type] {
                    if let snapshot = try? await decoder.decode(tag: tag, scannedAt: Date()) {
                        return snapshot
                    }
                    try Task.checkCancellation()
                }
                // Do not send ISO commands to a FeliCa-only target. A dual-mode
                // card can be rescanned using the ISO 14443 protocol selection.
                throw NFCTestError.unsupportedCard
            }
        }

        if options.contains(.iso14443) {
            let iso = ExternalISO7816Card(connection: connection, identifier: uid)
            // CEPAS selects file 4000 in the default application. Probe before
            // selecting other applications by AID.
            if let snapshot = try? await CEPASDecoder.decode(tag: .iso7816(iso), scannedAt: Date()) { return snapshot }
            if let snapshot = try? await MacauPassDecoder.decode(tag: .iso7816(iso), scannedAt: Date()) { return snapshot }
            if let snapshot = try? await ClipperDecoder.decode(tag: .iso7816(iso), scannedAt: Date()) { return snapshot }
            if let snapshot = try? await StoredValueDecoder.decode(tag: .iso7816(iso), scannedAt: Date()) { return snapshot }
            if let snapshot = try? await TianfuTongDecoder.decode(tag: .iso7816(iso), scannedAt: Date()) { return snapshot }
            let aids = [CityUnionDecoder.applicationAID, TUnionDecoder.applicationAID,
                        "D4100000030001", "D4100000140001", "D410000029000001", "D4100000300001", "D4106509900020",
                        "A0000004520001", "A000000291", "A000000404"]
            for aid in aids {
                try Task.checkCancellation()
                let select = CardAPDU(instructionClass: 0, instructionCode: 0xA4, p1Parameter: 4, p2Parameter: 0,
                                      data: Data(hexString: aid), expectedResponseLength: 256)
                guard let response = try? await iso.sendCommand(apdu: select), response.1 == 0x90, response.2 == 0 else { continue }
                iso.initialSelectedAID = aid
                iso.applicationData = response.0
                for decoder in [ChineseTransitDecoder.self, KSX6924Decoder.self, CalypsoDecoder.self] as [TransitCardDecoder.Type] {
                    if await decoder.canDecode(tag: .iso7816(iso)),
                       let snapshot = try? await decoder.decode(tag: .iso7816(iso), scannedAt: Date()) { return snapshot }
                }
            }
            if supportsFeliCa, uid.count == 7 {
                try Task.checkCancellation()
                let ticket = ACR122UltralightCard(connection: connection, identifier: uid)
                if let snapshot = try? await ClipperUltralightDecoder.decode(tag: .miFare(ticket), scannedAt: Date()) {
                    return snapshot
                }
            }
        }
        try Task.checkCancellation()
        if !supportsFeliCa && options == [.iso18092] { throw ExternalReaderError.unsupportedReader }
        throw NFCTestError.unsupportedCard
    }
}

struct ACR122UltralightCard: MiFareCard {
    let connection: any CardCommandChannel
    let identifier: Data
    var mifareFamily: MiFareFamily { .ultralight }

    func sendMiFareCommand(commandPacket: Data) async throws -> Data {
        guard commandPacket.count == 2, commandPacket.first == 0x30 else {
            throw ExternalReaderError.malformedResponse
        }
        let response = [UInt8](try await connection.pn532(Data([0xD4, 0x40, 1]) + commandPacket))
        guard response.count >= 3, response[0] == 0xD5, response[1] == 0x41 else {
            throw ExternalReaderError.malformedResponse
        }
        guard response[2] == 0 else { throw ExternalReaderError.readerStatus(response[2]) }
        guard response.count == 19 else { throw ExternalReaderError.malformedResponse }
        return Data(response.dropFirst(3))
    }
}

protocol CardCommandChannel {
    func exchange(_ command: Data) async throws -> (Data, UInt8, UInt8)
}

final class SmartCardConnection: CardCommandChannel {
    private let card: TKSmartCard
    init(card: TKSmartCard) { self.card = card }

    func exchange(_ command: Data) async throws -> (Data, UInt8, UInt8) {
        try Task.checkCancellation()
        let response = try await card.transmit(command)
        guard response.count >= 2 else { throw ExternalReaderError.malformedResponse }
        let bytes = [UInt8](response)
        return (Data(bytes.dropLast(2)), bytes[bytes.count - 2], bytes[bytes.count - 1])
    }

}

extension CardCommandChannel {
    func pn532(_ command: Data) async throws -> Data {
        guard command.count <= 255 else { throw ExternalReaderError.malformedResponse }
        var response = try await exchange(Data([0xFF, 0, 0, 0, UInt8(command.count)]) + command)
        // Some ACR122 firmware returns 61xx and requires the reader's GET RESPONSE.
        if response.1 == 0x61 { response = try await exchange(Data([0xFF, 0xC0, 0, 0, response.2])) }
        guard response.1 == 0x90, response.2 == 0 else {
            throw ExternalReaderError.cardStatus(UInt16(response.1) << 8 | UInt16(response.2))
        }
        return response.0
    }
}

final class ExternalISO7816Card: ISO7816Card {
    let connection: any CardCommandChannel
    let identifier: Data
    var initialSelectedAID = ""
    var applicationData: Data?
    init(connection: any CardCommandChannel, identifier: Data) { self.connection = connection; self.identifier = identifier }
    func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8) { try await connection.exchange(apdu.encoded) }
}

final class ACR122FeliCaCard: FeliCaCard {
    private let connection: any CardCommandChannel
    private(set) var currentIDm = Data()
    init(connection: any CardCommandChannel) { self.connection = connection }

    func polling(systemCode: Data, requestCode: FeliCaRequestCode, timeSlot: FeliCaTimeSlot) async throws -> (Data, Data) {
        guard systemCode.count == 2 else { throw ExternalReaderError.malformedResponse }
        // InListPassiveTarget, one target, 212 kbps; try 424 kbps if necessary.
        for speed: UInt8 in [1, 2] {
            let result = try await connection.pn532(Data([0xD4, 0x4A, 1, speed, 0]) + systemCode + Data([requestCode.rawValue, timeSlot.rawValue]))
            let b = [UInt8](result)
            guard b.count >= 3, b[0] == 0xD5, b[1] == 0x4B else { throw ExternalReaderError.malformedResponse }
            if b[2] == 0 { continue }
            guard b[2] == 1, b.count >= 22, b[3] == 1, b[4] >= 18,
                  b.count == 4 + Int(b[4]), b[5] == 1 else { throw ExternalReaderError.malformedResponse }
            currentIDm = Data(b[6..<14])
            return (Data(b[14..<22]), b.count >= 24 ? Data(b[22..<24]) : Data())
        }
        throw NFCTestError.unsupportedCard
    }

    func sendFeliCaCommand(commandPacket: Data) async throws -> Data {
        guard !currentIDm.isEmpty, commandPacket.count < 253 else { throw ExternalReaderError.malformedResponse }
        // InDataExchange takes a FeliCa frame INCLUDING its length byte.
        let result = try await connection.pn532(Data([0xD4, 0x40, 1, UInt8(commandPacket.count + 1)]) + commandPacket)
        let b = [UInt8](result)
        guard b.count >= 3, b[0] == 0xD5, b[1] == 0x41 else { throw ExternalReaderError.malformedResponse }
        guard b[2] == 0 else { throw ExternalReaderError.readerStatus(b[2]) }
        guard b.count >= 5, Int(b[3]) == b.count - 3 else { throw ExternalReaderError.malformedResponse }
        return Data(b.dropFirst(4))
    }

    func readWithoutEncryption(serviceCodeList: [Data], blockList: [Data]) async throws -> (Int, Int, [Data]) {
        guard (1...16).contains(serviceCodeList.count), serviceCodeList.allSatisfy({ $0.count == 2 }),
              (1...12).contains(blockList.count), blockList.allSatisfy({ $0.count == 2 || $0.count == 3 }) else { throw ExternalReaderError.malformedResponse }
        var command = Data([0x06]) + currentIDm + Data([UInt8(serviceCodeList.count)])
        serviceCodeList.forEach { command.append($0) }
        command.append(UInt8(blockList.count))
        blockList.forEach { command.append($0) }
        let response = [UInt8](try await sendFeliCaCommand(commandPacket: command))
        guard response.count >= 11, response[0] == 0x07, Data(response[1..<9]) == currentIDm else { throw ExternalReaderError.malformedResponse }
        if response[9] != 0 || response[10] != 0 { return (Int(response[9]), Int(response[10]), []) }
        guard response.count >= 12, Int(response[11]) == blockList.count,
              response.count == 12 + Int(response[11]) * 16 else { throw ExternalReaderError.malformedResponse }
        let blocks = (0..<Int(response[11])).map { Data(response[(12 + $0 * 16)..<(28 + $0 * 16)]) }
        return (0, 0, blocks)
    }

    func requestSystemCode() async throws -> [Data] {
        let response = [UInt8](try await sendFeliCaCommand(commandPacket: Data([0x0C]) + currentIDm))
        guard response.count >= 10, response[0] == 0x0D, Data(response[1..<9]) == currentIDm,
              response.count == 10 + Int(response[9]) * 2 else { throw ExternalReaderError.malformedResponse }
        return (0..<Int(response[9])).map { Data(response[(10 + $0 * 2)..<(12 + $0 * 2)]) }
    }
}
