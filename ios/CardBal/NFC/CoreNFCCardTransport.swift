#if canImport(CoreNFC) && !targetEnvironment(macCatalyst)
import Foundation
import CoreNFC

extension CardTag {
    init?(_ tag: NFCTag) {
        switch tag {
        case .feliCa(let card): self = .feliCa(CoreFeliCaCard(card))
        case .iso7816(let card): self = .iso7816(CoreISO7816Card(card))
        case .miFare(let card): self = .miFare(CoreMiFareCard(card))
        default: return nil
        }
    }
}

private struct CoreMiFareCard: MiFareCard {
    let card: any NFCMiFareTag
    init(_ card: any NFCMiFareTag) { self.card = card }
    var identifier: Data { card.identifier }
    var mifareFamily: MiFareFamily {
        switch card.mifareFamily {
        case .ultralight: return .ultralight
        case .desfire: return .desfire
        case .plus: return .plus
        default: return .unknown
        }
    }
    func sendMiFareCommand(commandPacket: Data) async throws -> Data {
        try await card.sendMiFareCommand(commandPacket: commandPacket)
    }
}

private struct CoreISO7816Card: ISO7816Card {
    let card: any NFCISO7816Tag
    init(_ card: any NFCISO7816Tag) { self.card = card }
    var identifier: Data { card.identifier }
    var initialSelectedAID: String { card.initialSelectedAID }
    var applicationData: Data? { card.applicationData }
    func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8) {
        guard let command = NFCISO7816APDU(data: apdu.encoded) else { throw ExternalReaderError.malformedResponse }
        return try await card.sendCommand(apdu: command)
    }
}

private struct CoreFeliCaCard: FeliCaCard {
    let card: any NFCFeliCaTag
    init(_ card: any NFCFeliCaTag) { self.card = card }
    var currentIDm: Data { card.currentIDm }
    func polling(systemCode: Data, requestCode: FeliCaRequestCode, timeSlot: FeliCaTimeSlot) async throws -> (Data, Data) {
        try await withCheckedThrowingContinuation { continuation in
            card.polling(systemCode: systemCode, requestCode: requestCode == .systemCode ? .systemCode : .noRequest, timeSlot: .max1) { pmm, requestData, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (pmm, requestData)) }
            }
        }
    }
    func readWithoutEncryption(serviceCodeList: [Data], blockList: [Data]) async throws -> (Int, Int, [Data]) {
        let response = try await card.readWithoutEncryption(serviceCodeList: serviceCodeList, blockList: blockList)
        return (Int(response.0), Int(response.1), response.2)
    }
    func requestSystemCode() async throws -> [Data] { try await card.requestSystemCode() }
    func sendFeliCaCommand(commandPacket: Data) async throws -> Data { try await card.sendFeliCaCommand(commandPacket: commandPacket) }
}
#endif
