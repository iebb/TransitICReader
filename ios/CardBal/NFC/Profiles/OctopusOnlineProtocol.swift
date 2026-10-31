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
}

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
    static func parse(_ data: Data) throws -> [Message] {
        guard !data.isEmpty, data.count <= maximumBody else { throw OctopusProtocolError.invalidData }
        var cursor = Cursor(data)
        var messages: [Message] = []
        while cursor.position < data.count {
            let start = cursor.position
            guard try cursor.take(4) == Data("OCAP".utf8) else { throw OctopusProtocolError.invalidData }
            _ = try cursor.count()
            _ = try cursor.take(2)
            let state = try cursor.byte()
            _ = try cursor.take(4)
            var instructions: [Instruction] = []
            for _ in 0..<(try cursor.count()) {
                let type = try cursor.signedByte(), id = try cursor.signedWord(), opcode = try cursor.signedByte()
                let count = try cursor.signedByte()
                guard count >= 0 else { throw OctopusProtocolError.invalidData }
                var operands: [Int] = []
                for _ in 0..<count { operands.append(try cursor.signedByte()) }
                instructions.append(Instruction(type: type, id: id, opcode: opcode, operands: operands))
            }
            _ = try cursor.take(4)
            var records: [Int: Data] = [:]
            for _ in 0..<(try cursor.count()) {
                let id = try cursor.signedWord(), length = try cursor.count()
                guard records[id] == nil else { throw OctopusProtocolError.invalidData }
                records[id] = try cursor.take(length)
            }
            let end = cursor.position
            guard try cursor.word() == checksum(data.subdata(in: start..<end)) else { throw OctopusProtocolError.invalidData }
            messages.append(Message(state: state, instructions: instructions, records: records))
        }
        return messages
    }
}

final class OctopusEnquiryVM {
    /// FeliCa commands that only read or authenticate. Polling (0x00) is checked separately by the relay.
    /// Without consent, any other command is a possible card update and is skipped, not sent to the card.
    static let readOnlyCardOpcodes: Set<UInt8> = [0x02, 0x04, 0x06, 0x0A, 0x0C, 0x10, 0x12, 0x14]
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
            guard steps <= 4096, Date() < deadline else { throw OctopusProtocolError.budgetExceeded }
            let instruction = message.instructions[pc], op = instruction.operands
            pc += 1
            let counts = [1: 2, 2: 2, 3: 2, 4: 3, 5: 4, 0x11: 0, 0x12: 3]
            guard instruction.type == 1, counts[instruction.opcode] == op.count else {
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
        guard try packet.take(4) == Data("DMSG".utf8) else { throw OctopusProtocolError.invalidData }
        _ = try packet.take(6)
        let device = try packet.byte(), sequence = try packet.byte(), length = try packet.word()
        let commandData = try packet.take(length)
        guard packet.position == data.count else { throw OctopusProtocolError.invalidData }
        let response: Data
        if device == 1 {
            if commandData.isEmpty { response = Data() }
            else {
                var command = Data(commandData.dropFirst())
                if command.first.map({ Int($0) == command.count }) == true { command = Data(command.dropFirst()) }
                guard let opcode = command.first, command.count <= 253, cardCommands < 256 else {
                    throw OctopusProtocolError.invalidData
                }
                if !allowsCardUpdates && opcode != 0 && !Self.readOnlyCardOpcodes.contains(opcode) {
                    // Skip the update: the card never sees it and the service gets no card reply.
                    response = Data()
                    skippedCardUpdates += 1
                    cardCommands += 1
                } else {
                    response = try await exchange(command)
                    guard response.count >= 2, response.count <= 255, Int(response[0]) == response.count,
                          response[1] == opcode &+ 1 else { throw OctopusProtocolError.invalidResponse }
                    cardOpcodes.insert(opcode)
                    cardCommands += 1
                }
            }
        } else if device == 2 {
            var command = OctopusOCAP.Cursor(commandData)
            switch try command.byte() {
            case 7:
                var entries: [Data] = []
                for _ in 0..<(try command.count()) {
                    let keyData = try command.take(command.byte())
                    guard let key = String(data: keyData, encoding: .ascii) else { throw OctopusProtocolError.invalidData }
                    if let value = inputs[key]?.data(using: .ascii), value.count <= 0x7FFF {
                        entries.append(Data([UInt8(keyData.count)]) + keyData + OctopusOCAP.word(value.count) + value)
                    }
                }
                response = Data([0x0A, 0]) + OctopusOCAP.word(entries.count) + entries.reduce(Data(), +)
            case 5:
                var updates: [Int: Data] = [:]
                for _ in 0..<(try command.count()) {
                    let key = try command.signedWord(), size = try command.count()
                    updates[key] = try command.take(size)
                }
                serverData.merge(updates) { _, new in new }
                response = Data([6, 0])
            case 1:
                _ = try command.take(command.bytes.count - command.position)
                response = Data()
            default: throw OctopusProtocolError.unsupportedInstruction
            }
            guard command.position == commandData.count else { throw OctopusProtocolError.invalidData }
        } else { throw OctopusProtocolError.unsupportedInstruction }
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
        struct Result: Decodable {
            struct Card: Decodable {
                let balance: Decimal
                let octopusNo: String?
                let octopusNoLong: UInt64?
                let status: String
            }
            let cardDataVO: Card
        }
        guard [UInt8(0x10), 0x12, 0x14].allSatisfy(opcodes.contains),
              let card = try? JSONDecoder().decode(Result.self, from: result).cardDataVO,
              !card.balance.isNaN, !card.status.isEmpty else { return nil }
        let short = card.octopusNo?.filter { $0.isASCII && $0.isNumber }
        let long = card.octopusNoLong.map(String.init)
        guard let number = long ?? short, short == nil || short == number else { return nil }
        let offset = Decimal(rawValue) - card.balance * 10
        guard offset == 350 || offset == 500 else { return nil }
        let metadata = Self(cardNumber: number, offset: NSDecimalNumber(decimal: offset).intValue, serviceStatus: card.status)
        return metadata.isValid ? metadata : nil
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
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
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
    private func post(_ path: String, body: Data = Data()) async throws -> Data {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, let baseURL else { throw OctopusProtocolError.budgetExceeded }
        var request = URLRequest(url: URL(string: baseURL.absoluteString + path)!)
        request.httpMethod = "POST"; request.httpBody = body
        request.timeoutInterval = min(5, remaining)
        request.setValue("application/ocap", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-OMA-DeviceID")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= OctopusOCAP.maximumBody else { throw OctopusProtocolError.invalidResponse }
        var result = Data()
        for try await byte in bytes {
            guard result.count < OctopusOCAP.maximumBody, Date() < deadline else { throw OctopusProtocolError.budgetExceeded }
            result.append(byte)
        }
        return result
    }
    func enquire(allowsCardUpdates: Bool = false,
                 exchange: @escaping (Data) async throws -> Data) async throws -> (Data, Set<UInt8>) {
        let greeting = try await post("/index.htm")
        guard let text = String(data: greeting, encoding: .utf8),
              let marker = text.range(of: "JSESSIONID=", options: .caseInsensitive) else { throw OctopusProtocolError.invalidResponse }
        let identifier = String(text[marker.upperBound...])
        guard identifier.range(of: "^[A-Za-z0-9._~-]{1,256}$", options: .regularExpression) != nil else {
            throw OctopusProtocolError.invalidResponse
        }
        let path = "/service.htm;jsessionid=" + identifier
        let config = "APP_TYPE=0&APP_HASH=AZdOKmzuRKj0x3GPHqlXHgY93q6u9HQUkKC6q%2BlNVGU4&APP=9.40.0&PLATFORM=IOS&phone_id="
            + deviceID.replacingOccurrences(of: "-", with: "") + "&LANG=EN_US&TXNTIME_DATEFORMAT=yyyyMMddHHmmss"
        let vm = OctopusEnquiryVM(inputs: ["oma_config": config, "cardid_list_v2": ""], deadline: deadline,
                                  allowsCardUpdates: allowsCardUpdates, exchange: exchange)
        defer { skippedCardUpdates = vm.skippedCardUpdates }
        var body = try await post(path, body: OctopusOCAP.deviceInfo())
        for _ in 0..<32 {
            var outbound = Data()
            let messages = try OctopusOCAP.parse(body)
            for (index, message) in messages.enumerated() {
                if message.state == 3 {
                    guard index == messages.count - 1, let result = vm.serverData[1] else { throw OctopusProtocolError.invalidResponse }
                    return (result, vm.cardOpcodes)
                }
                guard message.state == 2 else { throw OctopusProtocolError.invalidResponse }
                outbound += try await OctopusOCAP.reply(vm.run(message))
            }
            body = try await post(path, body: outbound)
        }
        throw OctopusProtocolError.budgetExceeded
    }
}
