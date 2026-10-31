import Foundation

enum OctopusProtocolError: Error {
    case invalidData, unsupportedInstruction, budgetExceeded, invalidResponse
}

enum OctopusOnlinePreferences {
    static let enabledKey = "octopusOnlineEnabled"
    static let cardUpdatesKey = "octopusCardUpdatesEnabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Card updates are writes the service asks the card to make. They stay off until the person opts in.
    static var allowsCardUpdates: Bool { UserDefaults.standard.bool(forKey: cardUpdatesKey) }
    /// Builds without an enquiry endpoint do not offer Octopus Online at all.
    static let isAvailable = OctopusEnquiryClient.configuredURL != nil
    /// The debug log header line. It says whether an endpoint exists, never which one.
    static var debugSummary: String {
        "Octopus Online: \(isEnabled ? "on" : "off"); card updates: \(allowsCardUpdates ? "on" : "off"); "
            + "endpoint configured: \(isAvailable ? "yes" : "no")"
    }
}

/// Octopus Online lines for the on-device debug log. See `DebugLog` for what may be recorded.
func octopusDebugLog(_ message: String) { DebugLog.shared.log("Octopus", message) }

/// OCAP has different incoming and outgoing length/checksum conventions.
enum OctopusOCAP {
    static let maximumBody = 1_048_576
    struct Instruction { let type: Int; let id: Int; let opcode: Int; let operands: [Int] }
    struct Message { let state: Int; let instructions: [Instruction]; let records: [Int: Data] }

    struct Cursor {
        let bytes: [UInt8]
        var position = 0
        init(_ data: Data) { bytes = Array(data) }
        mutating func take(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - position else { throw OctopusProtocolError.invalidData }
            defer { position += count }
            return Data(bytes[position..<(position + count)])
        }
        mutating func byte() throws -> Int { Int(try take(1).first!) }
        mutating func signedByte() throws -> Int { Int(Int8(bitPattern: UInt8(try byte()))) }
        mutating func word() throws -> Int { (try byte()) << 8 | (try byte()) }
        mutating func signedWord() throws -> Int { Int(Int16(bitPattern: UInt16(try word()))) }
        mutating func count() throws -> Int {
            let value = try signedWord()
            guard value >= 0 else { throw OctopusProtocolError.invalidData }
            return value
        }
    }

    static func word(_ value: Int) -> Data { Data([UInt8((value >> 8) & 255), UInt8(value & 255)]) }
    static func checksum(_ data: Data) -> Int {
        let bytes = Array(data)
        var sum = 0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            sum += Int(bytes[index]) << 8
            if index + 1 < bytes.count { sum += Int(bytes[index + 1]) }
        }
        return (-sum) & 0xFFFF
    }
    static func outbound(state: UInt8, payload: Data) throws -> Data {
        var frame = Data("OCAP".utf8) + Data([0, 0, 1, 0, state]) + payload
        let length = frame.count - 6
        guard length <= 0x7FFF else { throw OctopusProtocolError.invalidData }
        frame.append(word(checksum(frame)))
        frame[4] = UInt8(length & 255)
        frame[5] = UInt8(length >> 8)
        return frame
    }
    static func deviceInfo() throws -> Data {
        var payload = Data("DINF".utf8) + word(2)
        for (id, type, name) in [(0x13, 1, "IOS_NFC"), (3, 2, "APPLET")] {
            payload += Data([UInt8(id), UInt8(type)]) + word(name.utf8.count) + Data(name.utf8)
        }
        return try outbound(state: 1, payload: payload)
    }
    static func reply(_ data: Data) throws -> Data {
        guard data.count <= 0x7FFF else { throw OctopusProtocolError.invalidData }
        return try outbound(state: 2, payload: Data("RPLY".utf8) + Data([0]) + word(data.count) + data)
    }
    /// `onFailure` receives a short reason for the debug log; the error thrown is unchanged.
    static func parse(_ data: Data, onFailure: ((String) -> Void)? = nil) throws -> [Message] {
        var cursor = Cursor(data)
        var messages: [Message] = []
        var part = "body"
        var reason: String?
        do {
            guard !data.isEmpty, data.count <= maximumBody else {
                reason = data.isEmpty ? "empty body" : "body over \(maximumBody) bytes"
                throw OctopusProtocolError.invalidData
            }
            while cursor.position < data.count {
                let start = cursor.position
                let number = messages.count + 1
                part = "message \(number) header"
                guard try cursor.take(4) == Data("OCAP".utf8) else {
                    reason = "message \(number) is not OCAP" + (number == 1 && data.first == UInt8(ascii: "<") ? " (looks like HTML)" : "")
                    throw OctopusProtocolError.invalidData
                }
                _ = try cursor.count()
                _ = try cursor.take(2)
                let state = try cursor.byte()
                _ = try cursor.take(4)
                part = "message \(number) instructions"
                var instructions: [Instruction] = []
                for _ in 0..<(try cursor.count()) {
                    let type = try cursor.signedByte(), id = try cursor.signedWord(), opcode = try cursor.signedByte()
                    let count = try cursor.signedByte()
                    guard count >= 0 else {
                        reason = "message \(number) has a negative operand count"
                        throw OctopusProtocolError.invalidData
                    }
                    var operands: [Int] = []
                    for _ in 0..<count { operands.append(try cursor.signedByte()) }
                    instructions.append(Instruction(type: type, id: id, opcode: opcode, operands: operands))
                }
                _ = try cursor.take(4)
                part = "message \(number) records"
                var records: [Int: Data] = [:]
                for _ in 0..<(try cursor.count()) {
                    let id = try cursor.signedWord(), length = try cursor.count()
                    guard records[id] == nil else {
                        reason = "message \(number) repeats record \(id)"
                        throw OctopusProtocolError.invalidData
                    }
                    records[id] = try cursor.take(length)
                }
                let end = cursor.position
                part = "message \(number) checksum"
                guard try cursor.word() == checksum(data.subdata(in: start..<end)) else {
                    reason = "message \(number) checksum mismatch"
                    throw OctopusProtocolError.invalidData
                }
                messages.append(Message(state: state, instructions: instructions, records: records))
            }
        } catch {
            onFailure?((reason ?? "truncated or invalid \(part)") + " at byte \(cursor.position) of \(data.count)")
            throw error
        }
        return messages
    }
}

final class OctopusEnquiryVM {
    /// FeliCa commands that only read, authenticate or describe the card, in both the DES and
    /// the AES (V2) command sets. Polling (0x00) is checked separately by the relay. Without
    /// consent, any other command is a possible card update and is skipped, not sent to the card.
    static let readOnlyCardOpcodes: Set<UInt8> = [
        0x02, // Request Service
        0x04, // Request Response
        0x06, // Read Without Encryption
        0x0A, // Search Service Code
        0x0C, // Request System Code
        0x0E, // Request Block Information
        0x10, // Authentication1 (DES)
        0x12, // Authentication2
        0x14, // Read
        0x1A, // Request Code List
        0x1E, // Request Block Information Ex
        0x22, // Get Container Issue Information
        0x24, // Get Area Information
        0x28, // Get Node Property
        0x2E, // Get Container Property
        0x32, // Request Service V2
        0x34, // Internal Authenticate And Read
        0x38, // Get System Status
        0x3A, // Request Product Information
        0x3C, // Request Specification Version
        0x40, // Authentication1 V2 (AES)
        0x42, // Authentication2 V2
        0x44, // Read V2
    ]
    /// An authenticated read in either generation: Authentication1, Authentication2 and Read.
    static let authenticatedReadOpcodes: [Set<UInt8>] = [[0x10, 0x40], [0x12, 0x42], [0x14, 0x44]]
    /// Names for the debug log, including the commands that are skipped without consent.
    static let cardCommandNames: [UInt8: String] = [
        0x00: "Polling", 0x02: "Request Service", 0x04: "Request Response", 0x06: "Read Without Encryption",
        0x08: "Write Without Encryption", 0x0A: "Search Service Code", 0x0C: "Request System Code",
        0x0E: "Request Block Information", 0x10: "Authentication1 (DES)", 0x12: "Authentication2", 0x14: "Read",
        0x16: "Write", 0x1A: "Request Code List", 0x1E: "Request Block Information Ex",
        0x22: "Get Container Issue Information", 0x24: "Get Area Information", 0x28: "Get Node Property",
        0x2E: "Get Container Property", 0x32: "Request Service V2", 0x34: "Internal Authenticate And Read",
        0x38: "Get System Status", 0x3A: "Request Product Information", 0x3C: "Request Specification Version",
        0x3E: "Reset Mode", 0x40: "Authentication1 V2 (AES)", 0x42: "Authentication2 V2", 0x44: "Read V2",
        0x46: "Write V2", 0x4C: "Update Random ID",
    ]
    /// Replies whose two status flags follow the IDm in plaintext.
    private static let plaintextStatusReplies: Set<UInt8> = [0x07, 0x09, 0x15, 0x17, 0x45, 0x47]
    static func commandLabel(_ opcode: UInt8) -> String {
        DebugLog.hex(opcode) + (cardCommandNames[opcode].map { " " + $0 } ?? "")
    }
    /// Code, length and (where plaintext) status flags of a length-prefixed card reply; never its contents.
    static func replySummary(_ response: Data) -> String {
        guard response.count >= 2 else { return response.isEmpty ? "empty" : "1 byte" }
        let bytes = Array(response)
        var summary = "code \(DebugLog.hex(bytes[1])), \(bytes.count) bytes"
        if Int(bytes[0]) != bytes.count { summary += " (length byte \(bytes[0]))" }
        if plaintextStatusReplies.contains(bytes[1]), bytes.count >= 12 {
            summary += String(format: ", status flags %02X %02X", bytes[10], bytes[11])
        }
        return summary
    }
    let inputs: [String: String]
    let exchange: (Data) async throws -> Data
    let deadline: Date
    let allowsCardUpdates: Bool
    private(set) var serverData: [Int: Data] = [:]
    private(set) var cardOpcodes: Set<UInt8> = []
    private(set) var skippedCardUpdates = 0
    private var cardCommands = 0

    init(inputs: [String: String], deadline: Date, allowsCardUpdates: Bool = false,
         exchange: @escaping (Data) async throws -> Data) {
        self.inputs = inputs; self.deadline = deadline; self.allowsCardUpdates = allowsCardUpdates; self.exchange = exchange
    }
    func run(_ message: OctopusOCAP.Message) async throws -> Data {
        var registers = Array(repeating: Data(), count: 16)
        func register(_ index: Int) throws -> Int {
            guard (0..<16).contains(index) else { throw OctopusProtocolError.invalidData }
            return index
        }
        var pc = 0, steps = 0
        while pc < message.instructions.count {
            steps += 1
            guard steps <= 4096, Date() < deadline else {
                octopusDebugLog("VM: \(steps > 4096 ? "step budget" : "deadline") exceeded after \(steps - 1) steps")
                throw OctopusProtocolError.budgetExceeded
            }
            let instruction = message.instructions[pc], op = instruction.operands
            pc += 1
            let counts = [1: 2, 2: 2, 3: 2, 4: 3, 5: 4, 0x11: 0, 0x12: 3]
            guard instruction.type == 1, counts[instruction.opcode] == op.count else {
                octopusDebugLog("VM: unsupported instruction type \(instruction.type), opcode \(instruction.opcode), \(op.count) operands")
                throw OctopusProtocolError.unsupportedInstruction
            }
            if instruction.opcode == 0x11 { break }
            if instruction.opcode == 0x12 {
                if registers[try register(op[1])] == registers[try register(op[2])] {
                    guard let target = message.instructions.firstIndex(where: { $0.id == op[0] }) else {
                        throw OctopusProtocolError.invalidData
                    }
                    pc = target
                }
                continue
            }
            let destination = try register(op[0])
            switch instruction.opcode {
            case 1: registers[destination] = try await execute(registers[try register(op[1])])
            case 2:
                guard let record = message.records[op[1]] else { throw OctopusProtocolError.invalidData }
                registers[destination] = record
            case 3: registers[destination] = registers[try register(op[1])]
            case 4: registers[destination] = registers[try register(op[1])] + registers[try register(op[2])]
            case 5:
                let source = registers[try register(op[1])]
                guard op[2] >= 0, op[3] >= 0, op[2] <= source.count, op[3] <= source.count - op[2] else {
                    throw OctopusProtocolError.invalidData
                }
                registers[destination] = source.subdata(in: op[2]..<(op[2] + op[3]))
            default: throw OctopusProtocolError.unsupportedInstruction
            }
            guard registers[destination].count <= OctopusOCAP.maximumBody else { throw OctopusProtocolError.budgetExceeded }
        }
        return registers[15]
    }

    private func execute(_ data: Data) async throws -> Data {
        var packet = OctopusOCAP.Cursor(data)
        guard try packet.take(4) == Data("DMSG".utf8) else {
            octopusDebugLog("DMSG: missing DMSG header")
            throw OctopusProtocolError.invalidData
        }
        _ = try packet.take(6)
        let device = try packet.byte(), sequence = try packet.byte(), length = try packet.word()
        let commandData = try packet.take(length)
        guard packet.position == data.count else {
            octopusDebugLog("DMSG device \(device) seq \(sequence): \(data.count - packet.position) trailing bytes")
            throw OctopusProtocolError.invalidData
        }
        let response: Data
        if device == 1 {
            if commandData.isEmpty {
                octopusDebugLog("Card seq \(sequence): empty command, nothing sent")
                response = Data()
            } else {
                var command = Data(commandData.dropFirst())
                if command.first.map({ Int($0) == command.count }) == true { command = Data(command.dropFirst()) }
                guard let opcode = command.first, command.count <= 253, cardCommands < 256 else {
                    octopusDebugLog("Card seq \(sequence): command refused (\(command.count) bytes after \(cardCommands) card commands)")
                    throw OctopusProtocolError.invalidData
                }
                let label = "Card seq \(sequence): \(Self.commandLabel(opcode)), \(command.count) bytes"
                if !allowsCardUpdates && opcode != 0 && !Self.readOnlyCardOpcodes.contains(opcode) {
                    // Skip the update: the card never sees it and the service gets no card reply.
                    octopusDebugLog(label + ": SKIPPED (card update not allowed)")
                    response = Data()
                    skippedCardUpdates += 1
                    cardCommands += 1
                } else {
                    do { response = try await exchange(command) } catch {
                        octopusDebugLog(label + ": SENT; card exchange failed: " + DebugLog.describe(error))
                        throw error
                    }
                    guard response.count >= 2, response.count <= 255, Int(response[0]) == response.count,
                          response[1] == opcode &+ 1 else {
                        octopusDebugLog(label + ": SENT; reply rejected (\(Self.replySummary(response)); expected code \(DebugLog.hex(opcode &+ 1)))")
                        throw OctopusProtocolError.invalidResponse
                    }
                    octopusDebugLog(label + ": SENT; reply " + Self.replySummary(response))
                    cardOpcodes.insert(opcode)
                    cardCommands += 1
                }
            }
        } else if device == 2 {
            var command = OctopusOCAP.Cursor(commandData)
            let appletOpcode = try command.byte()
            switch appletOpcode {
            case 7:
                var entries: [Data] = []
                var keys: [String] = [], missing: [String] = []
                for _ in 0..<(try command.count()) {
                    let keyData = try command.take(command.byte())
                    guard let key = String(data: keyData, encoding: .ascii) else {
                        octopusDebugLog("Applet seq \(sequence): GET_DATA (7) key is not ASCII")
                        throw OctopusProtocolError.invalidData
                    }
                    let name = key.count > 40 ? String(key.prefix(40)) + "…" : key
                    keys.append(name)
                    if let value = inputs[key]?.data(using: .ascii), value.count <= 0x7FFF {
                        entries.append(Data([UInt8(keyData.count)]) + keyData + OctopusOCAP.word(value.count) + value)
                    } else {
                        missing.append(name)
                    }
                }
                octopusDebugLog("Applet seq \(sequence): GET_DATA (7) keys \(keys.isEmpty ? "none" : keys.joined(separator: ", ")); "
                                + "missing \(missing.isEmpty ? "none" : missing.joined(separator: ", "))")
                response = Data([0x0A, 0]) + OctopusOCAP.word(entries.count) + entries.reduce(Data(), +)
            case 5:
                var updates: [Int: Data] = [:]
                for _ in 0..<(try command.count()) {
                    let key = try command.signedWord(), size = try command.count()
                    updates[key] = try command.take(size)
                }
                octopusDebugLog("Applet seq \(sequence): store data (5) keys "
                                + updates.keys.sorted().map { "\($0) (\(updates[$0]!.count) bytes)" }.joined(separator: ", "))
                serverData.merge(updates) { _, new in new }
                response = Data([6, 0])
            case 1:
                let ignored = try command.take(command.bytes.count - command.position)
                octopusDebugLog("Applet seq \(sequence): opcode 1 (\(ignored.count) bytes ignored)")
                response = Data()
            default:
                octopusDebugLog("Applet seq \(sequence): unsupported opcode \(appletOpcode)")
                throw OctopusProtocolError.unsupportedInstruction
            }
            guard command.position == commandData.count else {
                octopusDebugLog("Applet seq \(sequence): \(commandData.count - command.position) trailing bytes")
                throw OctopusProtocolError.invalidData
            }
        } else {
            octopusDebugLog("DMSG device \(device) seq \(sequence): unsupported device")
            throw OctopusProtocolError.unsupportedInstruction
        }
        guard response.count <= 0x7FFF - 10 else { throw OctopusProtocolError.invalidData }
        return Data("DMSG".utf8) + OctopusOCAP.word(response.count + 10) + Data([1, 0, 0, 2, UInt8(device), UInt8(sequence)])
            + OctopusOCAP.word(response.count + 2) + response + Data([0x90, 0])
    }
}

struct OctopusCardMetadata: Codable, Equatable {
    let cardNumber: String
    let offset: Int
    let serviceStatus: String

    var isValid: Bool {
        (8...12).contains(cardNumber.count) && cardNumber.utf8.allSatisfy { (48...57).contains($0) }
            && cardNumber.contains(where: { $0 != "0" }) && [350, 500].contains(offset)
    }
    static func calibrated(result: Data, rawValue: Int, opcodes: Set<UInt8>) -> Self? {
        try? calibration(result: result, rawValue: rawValue, opcodes: opcodes).get()
    }
    /// Like `calibrated`, but says which check failed.
    static func calibration(result: Data, rawValue: Int, opcodes: Set<UInt8>) -> Result<Self, OctopusCalibrationFailure> {
        struct Response: Decodable {
            struct Card: Decodable {
                let balance: Decimal
                let octopusNo: String?
                let octopusNoLong: UInt64?
                let status: String
            }
            let cardDataVO: Card
        }
        guard OctopusEnquiryVM.authenticatedReadOpcodes.allSatisfy({ !$0.isDisjoint(with: opcodes) }) else {
            return .failure(.missingAuthenticatedRead(seen: opcodes.sorted()))
        }
        guard let card = try? JSONDecoder().decode(Response.self, from: result).cardDataVO else {
            return .failure(.undecodableResult(topLevelKeys: Self.topLevelKeys(result)))
        }
        guard !card.balance.isNaN, !card.status.isEmpty else { return .failure(.missingBalanceOrStatus) }
        let short = card.octopusNo?.filter { $0.isASCII && $0.isNumber }
        let long = card.octopusNoLong.map(String.init)
        guard let number = long ?? short else { return .failure(.missingCardNumber) }
        guard short == nil || short == number else { return .failure(.mismatchedCardNumbers) }
        let offset = Decimal(rawValue) - card.balance * 10
        guard offset == 350 || offset == 500 else { return .failure(.unexpectedOffset(offset)) }
        let metadata = Self(cardNumber: number, offset: NSDecimalNumber(decimal: offset).intValue, serviceStatus: card.status)
        return metadata.isValid ? .success(metadata) : .failure(.invalidCardNumber)
    }
    /// What the debug log records about an enquiry result. Card numbers are only reported as present.
    static func resultSummary(_ result: Data, rawValue: Int) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] else {
            return "result is not a JSON object (\(result.count) bytes)"
        }
        guard let card = object["cardDataVO"] as? [String: Any] else {
            return "result has no cardDataVO; top-level keys: " + Self.keyList(object.keys)
        }
        func short(_ value: Any) -> String {
            let text = "\(value)"
            return text.count > 24 ? String(text.prefix(24)) + "…" : text
        }
        func presence(_ key: String) -> String { card[key].map { $0 is NSNull ? "null" : "present" } ?? "missing" }
        let balance = card["balance"].map(short) ?? "missing"
        var summary = "cardDataVO.status " + (card["status"].map { "\"" + short($0) + "\"" } ?? "missing")
            + ", balance " + balance + ", octopusNo " + presence("octopusNo") + ", octopusNoLong " + presence("octopusNoLong")
            + ", raw purse \(rawValue)"
        if let number = card["balance"] as? NSNumber {
            summary += ", offset \(Decimal(rawValue) - number.decimalValue * 10)"
        }
        return summary
    }
    private static func topLevelKeys(_ result: Data) -> [String] {
        ((try? JSONSerialization.jsonObject(with: result)) as? [String: Any]).map { Array($0.keys).sorted() } ?? []
    }
    fileprivate static func keyList<S: Sequence>(_ keys: S) -> String where S.Element == String {
        let names = keys.sorted().prefix(12).map { $0.count > 32 ? String($0.prefix(32)) + "…" : $0 }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }
}

/// Why an enquiry result did not calibrate the card, as written to the debug log.
enum OctopusCalibrationFailure: Error, Equatable, CustomStringConvertible {
    case missingAuthenticatedRead(seen: [UInt8])
    case undecodableResult(topLevelKeys: [String])
    case missingBalanceOrStatus
    case missingCardNumber
    case mismatchedCardNumbers
    case unexpectedOffset(Decimal)
    case invalidCardNumber

    var description: String {
        switch self {
        case .missingAuthenticatedRead(let seen):
            return "no authenticated read (needs 0x10 or 0x40, 0x12 or 0x42, and 0x14 or 0x44); card opcodes seen: "
                + (seen.isEmpty ? "none" : seen.map(DebugLog.hex).joined(separator: ", "))
        case .undecodableResult(let keys):
            return "result JSON not decodable as cardDataVO; top-level keys: " + OctopusCardMetadata.keyList(keys)
        case .missingBalanceOrStatus: return "balance or status missing"
        case .missingCardNumber: return "no octopusNo or octopusNoLong"
        case .mismatchedCardNumbers: return "octopusNo and octopusNoLong differ"
        case .unexpectedOffset(let offset): return "offset \(offset) is not 350 or 500"
        case .invalidCardNumber: return "invalid card number"
        }
    }
}

final class OctopusMetadataStore {
    static let shared = OctopusMetadataStore()
    private let defaults: UserDefaults
    private let lock = NSLock()
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ idm: String) -> String? {
        let normalized = idm.uppercased()
        guard normalized.utf8.count == 16,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return "octopus.metadata.v1." + normalized
    }
    func metadata(for idm: String) -> OctopusCardMetadata? {
        lock.lock(); defer { lock.unlock() }
        guard let key = key(idm), let data = defaults.data(forKey: key),
              let metadata = try? JSONDecoder().decode(OctopusCardMetadata.self, from: data),
              metadata.isValid else { return nil }
        return metadata
    }
    func save(_ metadata: OctopusCardMetadata, for idm: String) {
        lock.lock(); defer { lock.unlock() }
        guard metadata.isValid, let key = key(idm), let data = try? JSONEncoder().encode(metadata) else { return }
        defaults.set(data, forKey: key)
    }
}

/// The endpoint is supplied by the build environment, never by a server response.
final class OctopusEnquiryClient: NSObject, URLSessionTaskDelegate {
    static var configuredURL: URL? {
        let environment = ProcessInfo.processInfo.environment["OCTOPUS_ENQUIRY_BASE_URL"]
        let bundled = Bundle.main.url(forResource: "OctopusEnquiryConfig", withExtension: "plist")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: String] }
        return validatedURL(environment ?? bundled?["OCTOPUS_ENQUIRY_BASE_URL"] ?? "")
    }
    static func validatedURL(_ value: String, allowLoopback: Bool = false) -> URL? {
        guard let parts = URLComponents(string: value), let host = parts.host,
              parts.scheme == "https" || allowLoopback && parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        return URL(string: value.hasSuffix("/") ? String(value.dropLast()) : value)
    }
    private let baseURL: URL?
    private let deadline: Date
    /// Card updates skipped during the last enquiry, kept even when it fails.
    private(set) var skippedCardUpdates = 0
    var isConfigured: Bool { baseURL != nil }
    private let deviceID = UUID().uuidString
    /// Each request may take up to this long, within the overall 25-second deadline.
    static let requestTimeout: TimeInterval = 10
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    init(baseURL: URL? = configuredURL, deadline: Date = Date().addingTimeInterval(25)) {
        self.baseURL = baseURL; self.deadline = deadline
    }
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    /// `label` names the request in the debug log, which never records the URL or session ID.
    private func post(_ path: String, body: Data = Data(), label: String) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, let baseURL else {
            octopusDebugLog(label + ": not sent (" + (baseURL == nil ? "no endpoint" : "deadline passed") + ")")
            throw OctopusProtocolError.budgetExceeded
        }
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "POST"; request.httpBody = body
        request.timeoutInterval = min(Self.requestTimeout, remaining)
        request.setValue("application/ocap", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-OMA-DeviceID")
        let started = Date()
        func elapsed() -> String { "\(Int(Date().timeIntervalSince(started) * 1000)) ms" }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            let reply = try await session.bytes(for: request)
            bytes = reply.0; response = reply.1
        } catch {
            octopusDebugLog(label + ": sent \(body.count) bytes; failed after \(elapsed()): " + DebugLog.describe(error))
            throw error
        }
        let status = (response as? HTTPURLResponse).map { "HTTP \($0.statusCode)" } ?? "not HTTP"
        let length = response.expectedContentLength >= 0 ? "Content-Length \(response.expectedContentLength)" : "no Content-Length"
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= OctopusOCAP.maximumBody else {
            octopusDebugLog(label + ": sent \(body.count) bytes; \(status), \(length), \(elapsed()); rejected")
            throw OctopusProtocolError.invalidResponse
        }
        var result = Data()
        do {
            for try await byte in bytes {
                guard result.count < OctopusOCAP.maximumBody, Date() < deadline else { throw OctopusProtocolError.budgetExceeded }
                result.append(byte)
            }
        } catch {
            octopusDebugLog(label + ": sent \(body.count) bytes; \(status), \(length); body failed after \(result.count) bytes, "
                            + elapsed() + ": " + DebugLog.describe(error))
            throw error
        }
        octopusDebugLog(label + ": sent \(body.count) bytes; \(status), \(length), body \(result.count) bytes, \(elapsed())")
        return result
    }
    func enquire(allowsCardUpdates: Bool = false,
                 exchange: @escaping (Data) async throws -> Data) async throws -> (Data, Set<UInt8>) {
        octopusDebugLog("Enquiry started (card updates \(allowsCardUpdates ? "allowed" : "not allowed"))")
        do {
            return try await performEnquiry(allowsCardUpdates: allowsCardUpdates, exchange: exchange)
        } catch {
            octopusDebugLog("Enquiry failed: " + DebugLog.describe(error))
            throw error
        }
    }
    private func performEnquiry(allowsCardUpdates: Bool,
                                exchange: @escaping (Data) async throws -> Data) async throws -> (Data, Set<UInt8>) {
        let greeting = try await post("/index.htm", label: "Greeting")
        guard let text = String(data: greeting, encoding: .utf8) else {
            octopusDebugLog("Greeting: body is not UTF-8")
            throw OctopusProtocolError.invalidResponse
        }
        guard let marker = text.range(of: "JSESSIONID=", options: .caseInsensitive) else {
            octopusDebugLog("Greeting: JSESSIONID marker not found")
            throw OctopusProtocolError.invalidResponse
        }
        let identifier = String(text[marker.upperBound...])
        guard identifier.range(of: "^[A-Za-z0-9._~-]{1,256}$", options: .regularExpression) != nil else {
            octopusDebugLog("Greeting: JSESSIONID marker found; session ID format unexpected (" + Self.formatProblems(identifier) + ")")
            throw OctopusProtocolError.invalidResponse
        }
        octopusDebugLog("Greeting: JSESSIONID marker found; session ID format OK")
        let path = "/service.htm;jsessionid=" + identifier
        let config = "APP_TYPE=0&APP_HASH=AZdOKmzuRKj0x3GPHqlXHgY93q6u9HQUkKC6q%2BlNVGU4&APP=9.40.0&PLATFORM=IOS&phone_id="
            + deviceID.replacingOccurrences(of: "-", with: "") + "&LANG=EN_US&TXNTIME_DATEFORMAT=yyyyMMddHHmmss"
        let vm = OctopusEnquiryVM(inputs: ["oma_config": config, "cardid_list_v2": ""], deadline: deadline,
                                  allowsCardUpdates: allowsCardUpdates, exchange: exchange)
        defer { skippedCardUpdates = vm.skippedCardUpdates }
        var body = try await post(path, body: OctopusOCAP.deviceInfo(), label: "Device info POST")
        for round in 1...32 {
            var outbound = Data()
            let messages = try OctopusOCAP.parse(body) { reason in octopusDebugLog("Round \(round): parse failed: " + reason) }
            octopusDebugLog("Round \(round): \(messages.count) message(s): " + messages.map {
                "state \($0.state), \($0.instructions.count) instructions, \($0.records.count) records"
            }.joined(separator: "; "))
            for (index, message) in messages.enumerated() {
                if message.state == 3 {
                    guard index == messages.count - 1, let result = vm.serverData[1] else {
                        octopusDebugLog("Round \(round): end state 3 " + (index == messages.count - 1
                            ? "without result data" : "before the last message"))
                        throw OctopusProtocolError.invalidResponse
                    }
                    octopusDebugLog("Round \(round): end state 3 received; result \(result.count) bytes; card opcodes "
                                    + (vm.cardOpcodes.isEmpty ? "none" : vm.cardOpcodes.sorted().map(DebugLog.hex).joined(separator: ", "))
                                    + "; skipped card updates \(vm.skippedCardUpdates)")
                    return (result, vm.cardOpcodes)
                }
                guard message.state == 2 else {
                    octopusDebugLog("Round \(round): unexpected state \(message.state)")
                    throw OctopusProtocolError.invalidResponse
                }
                outbound += try await OctopusOCAP.reply(vm.run(message))
            }
            body = try await post(path, body: outbound, label: "Round \(round) POST")
        }
        octopusDebugLog("Round budget exceeded after 32 rounds")
        throw OctopusProtocolError.budgetExceeded
    }
    /// Length and kinds of unexpected characters; never the session ID itself.
    static func formatProblems(_ identifier: String) -> String {
        var problems: [String] = []
        for scalar in identifier.unicodeScalars {
            let value = scalar.value
            if (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
                || "._~-".unicodeScalars.contains(scalar) { continue }
            let name: String
            switch scalar {
            case "\n": name = "newline"
            case "\r": name = "carriage return"
            case "\t": name = "tab"
            case " ": name = "space"
            case ";": name = "semicolon"
            case "/": name = "slash"
            case "=": name = "equals sign"
            case "&": name = "ampersand"
            case ",": name = "comma"
            case "\"", "'": name = "quote"
            case "<", ">": name = "angle bracket"
            default:
                name = !scalar.isASCII ? "non-ASCII character" : value < 0x20 || value == 0x7F ? "control character"
                    : String(format: "symbol U+%04X", value)
            }
            if !problems.contains(name) { problems.append(name) }
        }
        let count = identifier.unicodeScalars.count
        var summary = "length \(count)"
        if count == 0 { summary += ", empty" } else if count > 256 { summary += ", over 256" }
        return summary + (problems.isEmpty ? "" : ", contains " + problems.joined(separator: ", "))
    }
}
