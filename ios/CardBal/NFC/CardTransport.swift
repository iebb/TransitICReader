import Foundation

/// The decoders operate on card commands, independently of the reader hardware.
enum CardTag {
    case feliCa(any FeliCaCard)
    case iso7816(any ISO7816Card)
    case miFare(any MiFareCard)
}

struct CardPollingOption: OptionSet {
    let rawValue: Int
    static let iso14443 = Self(rawValue: 1)
    static let iso15693 = Self(rawValue: 2)
    static let iso18092 = Self(rawValue: 4)
}

enum FeliCaRequestCode: UInt8 { case noRequest = 0, systemCode = 1 }
enum FeliCaTimeSlot: UInt8 { case max1 = 0 }

protocol FeliCaCard {
    var currentIDm: Data { get }
    func polling(systemCode: Data, requestCode: FeliCaRequestCode, timeSlot: FeliCaTimeSlot) async throws -> (Data, Data)
    func readWithoutEncryption(serviceCodeList: [Data], blockList: [Data]) async throws -> (Int, Int, [Data])
    func requestSystemCode() async throws -> [Data]
    func sendFeliCaCommand(commandPacket: Data) async throws -> Data
}

enum MiFareFamily { case ultralight, desfire, plus, unknown }
protocol MiFareCard {
    var identifier: Data { get }
    var mifareFamily: MiFareFamily { get }
    func sendMiFareCommand(commandPacket: Data) async throws -> Data
}

protocol ISO7816Card {
    var identifier: Data { get }
    var initialSelectedAID: String { get }
    var applicationData: Data? { get }
    func sendCommand(apdu: CardAPDU) async throws -> (Data, UInt8, UInt8)
}

struct CardResponseAPDU {
    let statusWord1: UInt8
    let statusWord2: UInt8
    let payload: Data?
}

/// ISO 7816 cases 1–4, including extended lengths. No response length means no Le.
struct CardAPDU {
    let instructionClass: UInt8
    let instructionCode: UInt8
    let p1Parameter: UInt8
    let p2Parameter: UInt8
    let data: Data?
    let expectedResponseLength: Int
    private var preservesExtendedEncoding = false

    init(instructionClass: UInt8, instructionCode: UInt8, p1Parameter: UInt8,
         p2Parameter: UInt8, data: Data, expectedResponseLength: Int) {
        self.instructionClass = instructionClass
        self.instructionCode = instructionCode
        self.p1Parameter = p1Parameter
        self.p2Parameter = p2Parameter
        self.data = data
        self.expectedResponseLength = expectedResponseLength
    }

    init?(data raw: Data) {
        let bytes = [UInt8](raw)
        guard bytes.count >= 4 else { return nil }
        var payload = Data(), le = -1
        if bytes.count == 5 {
            le = bytes[4] == 0 ? 256 : Int(bytes[4])
        } else if bytes.count > 5 {
            let extended = bytes[4] == 0
            guard !extended || bytes.count >= 7 else { return nil }
            let length = extended ? Int(bytes[5]) << 8 | Int(bytes[6]) : Int(bytes[4])
            let start = extended ? 7 : 5
            if extended && bytes.count == 7 {
                le = length == 0 ? 65536 : length
            } else {
                guard length > 0, bytes.count >= start + length else { return nil }
                payload = Data(bytes[start..<(start + length)])
                let remaining = bytes.count - start - length
                guard remaining == 0 || remaining == (extended ? 2 : 1) else { return nil }
                if remaining > 0 {
                    let value = extended ? Int(bytes[bytes.count - 2]) << 8 | Int(bytes.last!) : Int(bytes.last!)
                    le = value == 0 ? (extended ? 65536 : 256) : value
                }
            }
        }
        self.init(instructionClass: bytes[0], instructionCode: bytes[1], p1Parameter: bytes[2],
                  p2Parameter: bytes[3], data: payload, expectedResponseLength: le)
        preservesExtendedEncoding = bytes.count > 5 && bytes[4] == 0
    }

    var encoded: Data {
        let payload = data ?? Data()
        var bytes = Data([instructionClass, instructionCode, p1Parameter, p2Parameter])
        let extended = preservesExtendedEncoding || payload.count > 255 || expectedResponseLength > 256
        if !payload.isEmpty {
            if extended { bytes.append(contentsOf: [0, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
            else { bytes.append(UInt8(payload.count)) }
            bytes.append(payload)
        }
        if expectedResponseLength > 0 {
            let le = expectedResponseLength
            if extended {
                if payload.isEmpty { bytes.append(0) }
                bytes.append(contentsOf: [UInt8((le >> 8) & 255), UInt8(le & 255)])
            } else { bytes.append(UInt8(le & 255)) }
        }
        return bytes
    }
}

enum ExternalReaderError: LocalizedError {
    case unavailable, noReader, noCard, unsupportedReader, malformedResponse, cardStatus(UInt16), readerStatus(UInt8)
    var errorDescription: String? {
        switch self {
        case .unavailable: return String(localized: "External card-reader access is unavailable.")
        case .noReader: return String(localized: "Connect a compatible USB smart-card reader. iPad and macOS require an external reader.")
        case .noCard: return String(localized: "Place one card on the external reader, then scan again.")
        case .unsupportedReader: return String(localized: "This reader does not support the required card commands. FeliCa reading requires an ACR122U-compatible reader.")
        case .malformedResponse: return String(localized: "The reader returned an incomplete or invalid response.")
        case .cardStatus(let sw): return String(format: String(localized: "Card command failed (%04X)."), sw)
        case .readerStatus(let status): return String(format: String(localized: "Reader command failed (%02X)."), status)
        }
    }
}

enum ExternalReaderSelection {
    static func choose(preferred: String?, available: [String]) throws -> String {
        if let preferred {
            guard available.contains(preferred) else { throw ExternalReaderError.noReader }
            return preferred
        }
        guard let first = available.sorted().first else { throw ExternalReaderError.noReader }
        return first
    }
}
