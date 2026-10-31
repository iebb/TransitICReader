import Foundation

/// Independent implementation of public Calypso/EN1545 wire facts. No keys,
/// secure-session commands, writes, holder decoding or reference-project code.
/// Metrodroid b910c1806fd86aa545223baf1d21fc5afe68eee2; Cardpeek
/// de8cee209b870f3d7aa1c6bd55e84738765dc1e6 c250n64/c250n901/c56n1.
/// Square schema groups carry LSB-first presence bits, not fixed offsets.
enum CalypsoProtocol {
    enum Network: UInt8, CaseIterable {
        case generic = 0, intercode, navigo, opus, mobib, ravKav
        var family: String {
            switch self { case .generic: return "Calypso"; case .intercode: return "Calypso"
            case .navigo: return "Navigo"; case .opus: return "OPUS"; case .mobib: return "MOBIB"; case .ravKav: return "Rav-Kav" }
        }
        var currency: String? {
            switch self { case .generic: return nil; case .opus: return "CAD"; case .ravKav: return "ILS"; default: return "EUR" }
        }
        var timeZone: String {
            switch self { case .generic: return "UTC"; case .opus: return "America/Toronto"; case .ravKav: return "Asia/Jerusalem"
            case .mobib: return "Europe/Brussels"; default: return "Europe/Paris" }
        }
    }
    struct Record { let sfi: Int; let number: Int; let payload: Data }
    struct Contract {
        let slot: Int; let productCode: Int64?; let providerCode: Int64?; let serialNumber: String?; let soldAt: String?
        let validFrom: String?; let validUntil: String?; let counter: Int64?
        let remainingTrips: Int64?; let balanceMinor: Int64?; let currency: String?
    }
    struct History {
        let network: Network; let timestamp: Date?; let amountMinor: Int64?; let currency: String?
        let description: String; let operatorCode: String?; let routeCode: String?; let stationCode: String?
        let eventCode: Int?; let resultCode: Int?; let counter: Int64?
    }
    struct ReadResult {
        let network: Network; let selectedAID: String; let serial: String?
        let balanceMinor: Int64?; let remainingTrips: Int64?; let fields: [(String, String)]
        let records: [Record]; let contracts: [Contract]; let rawHistories: [String]
        var family: String { network.family }
        var currency: String? { network.currency }
        var timeZone: String { network.timeZone }
        var hasDecodedData: Bool { network != .generic && (!contracts.isEmpty || records.contains {
            CalypsoProtocol.encodeRecord(network: network, record: $0).flatMap(CalypsoProtocol.parseHistory) != nil
        }) }
        var balanceText: String? {
            if let balanceMinor, let currency { return "\(currency) \(CalypsoProtocol.moneyText(balanceMinor))" }
            return remainingTrips.map { "\($0) trips" }
        }
    }
    static let selectionAIDs = ["A0000004040125090101", "315449432E494341", "334D54522E494341", "A000000291", "A000000404"]
    private static let magic = Data([0x43, 0x59, 0x50, 1])
    private enum ParseError: Error { case truncated, invalid }
    private struct Bits {
        let bytes: [UInt8]; var position = 0
        mutating func take(_ width: Int) throws -> Int64 {
            guard (0...63).contains(width), position + width <= bytes.count * 8 else { throw ParseError.truncated }
            var value: Int64 = 0
            for _ in 0..<width { value = (value << 1) | Int64((bytes[position / 8] >> (7 - position % 8)) & 1); position += 1 }
            return value
        }
        mutating func skip(_ width: Int) throws {
            guard width >= 0, position + width <= bytes.count * 8 else { throw ParseError.truncated }; position += width
        }
    }
    private indirect enum Field { case value(String, Int), group([Field], Bool) }
    private static func schema(_ text: String) throws -> Field {
        let chars = Array(text); var offset = 0
        func group(_ closing: Character?, _ optional: Bool) throws -> Field {
            var fields: [Field] = []
            while offset < chars.count {
                let char = chars[offset]
                if char == "," || char == " " { offset += 1; continue }
                if char == "]" || char == ")" {
                    guard char == closing else { throw ParseError.invalid }; offset += 1
                    return .group(fields, optional)
                }
                if char == "[" || char == "(" { offset += 1; fields.append(try group(char == "[" ? "]" : ")", char == "[")); continue }
                let start = offset
                while offset < chars.count, chars[offset] != ":" { offset += 1 }
                guard offset < chars.count else { throw ParseError.invalid }
                let name = String(chars[start..<offset]); offset += 1
                let widthStart = offset
                while offset < chars.count, chars[offset].isNumber { offset += 1 }
                guard let width = Int(String(chars[widthStart..<offset])) else { throw ParseError.invalid }
                fields.append(.value(name, width))
            }
            guard closing == nil else { throw ParseError.invalid }
            return .group(fields, optional)
        }
        return try group(nil, false)
    }
    private static func parse(_ payload: Data, _ name: String) -> [String: Int64]? {
        guard !payload.isEmpty, payload.count <= 256, let text = schemas[name] else { return nil }
        do {
            var bits = Bits(bytes: Array(payload)); var values: [String: Int64] = [:]
            func read(_ field: Field) throws {
                switch field {
                case let .value(name, width):
                    if name == "_" { try bits.skip(width) } else { values[name] = try bits.take(width) }
                case let .group(children, optional):
                    let mask = optional ? try bits.take(children.count) : -1
                    for (index, child) in children.enumerated() where !optional || mask & (Int64(1) << index) != 0 { try read(child) }
                }
            }
            try read(schema(text)); return values
        } catch { return nil }
    }
    private static func at(_ data: Data, _ bit: Int, _ count: Int) -> Int64? {
        var bits = Bits(bytes: Array(data), position: bit); return try? bits.take(count)
    }
    static func identify(_ environment: Data) -> Network {
        guard environment.count == 29, !environment.allSatisfy({ $0 == 0 || $0 == 255 }) else { return .generic }
        let rav = at(environment, 3, 20)
        if rav == 0x37602 || rav == 0x37603 { return parse(environment, "envRav") != nil ? .ravKav : .generic }
        let id = at(environment, 13, 24)
        if id == 0x056001 {
            let version = at(environment, 0, 6) ?? 63
            return version <= 4 && parse(environment, version <= 2 ? "envMobibOld" : "envMobibNew") != nil ? .mobib : .generic
        }
        guard let values = parse(environment, "env"), values["network"] == id else { return .generic }
        switch id { case 0x250901: return .navigo; case 0x124001: return .opus; default: return id.map { $0 >> 12 == 0x250 ? .intercode : .generic } ?? .generic }
    }
    private static func validRecord(_ record: Record) -> Bool {
        (1...30).contains(record.sfi) && (1...255).contains(record.number) && (1...256).contains(record.payload.count)
    }
    static func encodeRecord(network: Network, record: Record) -> Data? {
        guard validRecord(record) else { return nil }
        return magic + Data([network.rawValue, UInt8(record.sfi), UInt8(record.number), UInt8(record.payload.count >> 8), UInt8(record.payload.count & 255)]) + record.payload
    }
    private static func decodeRecord(_ data: Data) -> (Network, Record)? {
        let bytes = Array(data)
        guard bytes.count >= 10, data.prefix(4) == magic, let network = Network(rawValue: bytes[4]) else { return nil }
        let length = Int(bytes[7]) * 256 + Int(bytes[8])
        guard bytes.count == 9 + length else { return nil }
        let record = Record(sfi: Int(bytes[5]), number: Int(bytes[6]), payload: Data(bytes[9...]))
        return validRecord(record) ? (network, record) : nil
    }
    static func mergeHistory(_ records: [String]) -> [String] {
        var seen = Set<String>()
        return records.filter { raw in
            let key: String
            if let bytes = fromHex(raw), let (network, record) = decodeRecord(bytes), parseHistory(bytes) != nil {
                let file = network == .mobib && record.sfi == 23 ? 8 : record.sfi
                key = "E:\(network.rawValue):\(file):" + hex(record.payload)
            } else { key = "R:" + raw.uppercased() }
            return seen.insert(key).inserted
        }
    }
    private static func dayString(_ day: Int64?) -> String? {
        guard let day, (1...16382).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = calendar.date(from: DateComponents(year: 1997, month: 1, day: 1))!
        guard let date = calendar.date(byAdding: .day, value: Int(day), to: epoch) else { return nil }
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }
    private static func timestamp(_ day: Int64?, _ minute: Int64?, _ zone: String) -> Date? {
        guard let day, let minute, (1...16382).contains(day), (0...1439).contains(minute), let zone = TimeZone(identifier: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let epoch = calendar.date(from: DateComponents(year: 1997, month: 1, day: 1))!
        let raw = epoch.addingTimeInterval(Double(day) * 86400)
        var parts = calendar.dateComponents([.year, .month, .day], from: raw)
        parts.hour = Int(minute / 60); parts.minute = Int(minute % 60); parts.second = 0
        calendar.timeZone = zone
        guard let date = calendar.date(from: parts) else { return nil }
        let round = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard round.year == parts.year, round.month == parts.month, round.day == parts.day, round.hour == parts.hour, round.minute == parts.minute else { return nil }
        let before = date.addingTimeInterval(-86400)
        guard calendar.nextDate(after: before, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .first)
            == calendar.nextDate(after: before, matching: parts, matchingPolicy: .strict, repeatedTimePolicy: .last) else { return nil }
        return date
    }
    static func parseHistory(_ envelope: Data) -> History? {
        guard let (network, record) = decodeRecord(envelope), network != .generic, [8, 23, 29].contains(record.sfi),
              record.payload.count == 29, !record.payload.allSatisfy({ $0 == 0 }), let version = at(record.payload, 0, 6) else { return nil }
        if record.sfi == 29, ![.intercode, .navigo].contains(network) { return nil }
        if record.sfi == 23, network != .mobib { return nil }
        let layout: String
        switch network {
        case .opus: layout = "eventOpus"
        case .ravKav: layout = "eventRav"
        case .mobib: guard version <= 4 else { return nil }; layout = version <= 2 ? "eventMobibOld" : "eventMobibNew"
        default: layout = "eventIntercode"
        }
        guard let values = parse(record.payload, layout) else { return nil }
        if network == .intercode, ![Int64(0x250064),0x250901,0x250916,0x250920,0x250921].contains(values["network"] ?? -1) { return nil }
        if network == .navigo, let id = values["network"], id != 0x250901 { return nil }
        let code = values["code"].map(Int.init); let kind = code.map { $0 & 15 }
        let label: String
        switch kind { case 1, 6: label = "Entry"; case 2, 7: label = "Exit"; case 4: label = "Inspection"
        case 9: label = "Cancelled event"; case 13: label = "Top-up"; default: label = "Travel event" }
        let date: Date?
        if network == .ravKav, let seconds = values["seconds"], (1...0x3FFFFFFE).contains(seconds) {
            date = Date(timeIntervalSince1970: 852076800 + Double(seconds))
        } else { date = timestamp(values["day"], values["minute"], network.timeZone) }
        guard let date else { return nil }
        let result = values["result"].map(Int.init)
        let price = result == nil || result == 0 ? values["price"] : nil
        let amount: Int64? = kind == 13 ? price : ([1, 2, 6, 7].contains(kind ?? -1) ? price.map { -$0 } : nil)
        return History(network: network, timestamp: date, amountMinor: amount, currency: network.currency,
            description: result != nil && result != 0 ? "Rejected \(label)" : label,
            operatorCode: values["provider"].map(String.init), routeCode: values["route"].map(String.init), stationCode: values["station"].map(String.init),
            eventCode: code, resultCode: result, counter: values["counter"])
    }
    private static func counter(_ records: [Record], _ slot: Int) -> Int64? {
        if let common = records.first(where: { $0.sfi == 25 && $0.number == 1 }), let value = at(common.payload, (slot - 1) * 24, 24) { return value }
        if (1...4).contains(slot), let own = records.first(where: { $0.sfi == 9 + slot && $0.number == 1 }) { return at(own.payload, 0, 24) }
        return nil
    }
    private static func contractTypes(_ network: Network, _ data: Data?) -> [Int: Int] {
        guard [.navigo, .intercode].contains(network), let data else { return [:] }
        do {
            var bits = Bits(bytes: Array(data)); let count = try bits.take(4); var output: [Int: Int] = [:]
            for _ in 0..<count {
                let mask = try bits.take(3)
                if mask & 1 != 0 { try bits.skip(24) }
                let tariff: Int64? = mask & 2 != 0 ? try bits.take(16) : nil
                let slot: Int64? = mask & 4 != 0 ? try bits.take(5) : nil
                if let tariff, let slot, (1...8).contains(slot) { output[Int(slot)] = Int((tariff >> 4) & 255) }
            }
            return output
        } catch { return [:] }
    }
    static func contracts(network: Network, records: [Record]) -> [Contract] {
        guard network != .generic else { return [] }
        let types = contractTypes(network, records.first(where: { $0.sfi == 30 && $0.number == 1 })?.payload)
        return records.filter { $0.sfi == 9 && $0.payload.count == 29 && !$0.payload.allSatisfy({ $0 == 0 }) && !$0.payload.allSatisfy({ $0 == 255 }) }.compactMap { record in
            guard let version = at(record.payload, 0, 6) else { return nil }
            let layout: String
            switch network {
            case .opus: layout = "contractOpus"
            case .ravKav: layout = "contractRav"
            case .mobib:
                guard version <= 4 else { return nil }; layout = version <= 3 ? "contractMobibOld" : "contractMobibNew"
            default:
                switch types[record.number] { case 0x46: layout = "contract46"; case 0x20: layout = "contract20"; case 0xFF: layout = "contractFF"; default: layout = "commonContract" }
            }
            guard let values = parse(record.payload, layout), let product = values["product"], product != 0 else { return nil }
            if let id = values["network"], (network == .intercode && id >> 12 != 0x250) || (network == .navigo && id != 0x250901) { return nil }
            let count = counter(records, record.number)
            let remaining: Int64?
            switch network {
            case .opus: remaining = (values["end"] ?? 0) == 0 ? count : nil
            case .ravKav: remaining = (product >> 6) & 7 == 2 ? count : nil
            case .mobib: remaining = (product >> 10) & 7 != 4 ? count : nil
            case .intercode: remaining = product == 191 && types[record.number] == 0x46 && (count ?? 256) <= 255 ? count : nil
            case .navigo:
                if let debit = values["debit"], debit > 0, (values["sold"] ?? 0) > 0 { remaining = count.map { $0 / debit } }
                else if (values["journeys"] ?? 0) > 0 { remaining = count.map { $0 >> 18 } }
                else { remaining = nil }
            default: remaining = nil
            }
            let money = network == .ravKav && (product >> 6) & 7 == 3 ? count : nil
            let start = dayString(values["start"]); let end = dayString(values["end"])
            if let start, let end, start > end { return nil }
            return Contract(slot: record.number, productCode: product, providerCode: values["provider"], serialNumber: values["serial"].map(String.init), soldAt: dayString(values["sale"]), validFrom: start,
                validUntil: end, counter: count, remainingTrips: remaining, balanceMinor: money, currency: network.currency)
        }
    }
    private static func fields(_ network: Network, _ records: [Record], _ contracts: [Contract]) -> [(String, String)] {
        var output = [("Network", network.family)]
        if let env = records.first(where: { $0.sfi == 7 && $0.number == 1 })?.payload, network != .generic {
            let layout = network == .ravKav ? "envRav" : (network == .mobib ? ((at(env, 0, 6) ?? 63) <= 2 ? "envMobibOld" : "envMobibNew") : "env")
            if let expiry = dayString(parse(env, layout)?["expiry"]) { output.append(("Card Valid Until", expiry)) }
        }
        for c in contracts {
            let p = "Contract \(c.slot)"
            if let product = c.productCode { output.append((p + " Product", String(product)))
                if network == .intercode { output.append(("Ticket", "Product \(product)")) }
            }
            if let value = c.providerCode { output.append((p + " Provider Code", String(value))) }
            if let value = c.serialNumber { output.append((p + " Serial Number", value)) }
            if let value = c.soldAt { output.append((p + " Sold At", value)) }
            if let value = c.validFrom { output.append((p + " Valid From", value)) }
            if let value = c.validUntil { output.append((p + " Valid Until", value)) }
            if let value = c.remainingTrips { output.append((p + " Remaining Trips", String(value))) }
            if let value = c.balanceMinor { output.append((p + " Balance", "\(c.currency ?? "") \(moneyText(value))")) }
            if let value = c.counter { output.append((p + " Raw Counter", String(value))) }
        }
        return output
    }
    private static func response(_ command: Data, exchange: (Data) async throws -> (Data, UInt8, UInt8)) async -> Data? {
        guard var reply = try? await exchange(command) else { return nil }
        if reply.1 == 0x6C {
            var retry = command
            if retry.count >= 5, retry[1] == 0xA4, retry.count == 5 + Int(retry[4]) { retry.append(reply.2) }
            else { retry[retry.count - 1] = reply.2 }
            guard let result = try? await exchange(retry) else { return nil }; reply = result
        }
        return reply.1 == 0x90 && reply.2 == 0 ? reply.0 : nil
    }
    static func canSelect(exchange: (Data) async throws -> (Data, UInt8, UInt8)) async -> Bool {
        for aid in selectionAIDs {
            guard let name = fromHex(aid) else { continue }
            if await response(Data([0, 0xA4, 4, 0, UInt8(name.count)]) + name + Data([0]), exchange: exchange) != nil { return true }
        }
        return false
    }
    /// `progress` receives each file's SFI before its records are read.
    static func read(initialAID: String? = nil, exchange: (Data) async throws -> (Data, UInt8, UInt8),
                     progress: (Int) -> Void = { _ in }) async -> ReadResult? {
        var aids = selectionAIDs
        if let initialAID, selectionAIDs.contains(where: { initialAID.uppercased().hasPrefix($0) }) { aids.insert(initialAID.uppercased(), at: 0) }
        var seen = Set<String>()
        for aid in aids {
            guard seen.insert(aid).inserted else { continue }
            guard let name = fromHex(aid) else { continue }
            let command = Data([0, 0xA4, 4, 0, UInt8(name.count)]) + name + Data([0])
            guard await response(command, exchange: exchange) != nil else { continue }
            for cla: UInt8 in [0x94, 0] {
                _ = await response(Data([cla, 0xA4, 8, 0, 2, 0x20, 0]), exchange: exchange)
                func read(_ sfi: Int, _ number: Int) async -> Data? {
                    if let data = await response(Data([cla, 0xB2, UInt8(number), UInt8((sfi << 3) | 4), 0x1D]), exchange: exchange) { return data }
                    let files = [2: 0x0002, 7: 0x2001, 8: 0x2010, 9: 0x2020, 10: 0x202A, 11: 0x202B, 12: 0x202C, 13: 0x202D, 25: 0x2069, 29: 0x2040, 30: 0x2050]
                    guard let file = files[sfi] else { return nil }
                    let path = (sfi == 2 ? Data() : Data([0x20, 0])) + Data([UInt8(file >> 8), UInt8(file & 255)])
                    guard await response(Data([cla, 0xA4, 8, 0, UInt8(path.count)]) + path, exchange: exchange) != nil else { return nil }
                    return await response(Data([cla, 0xB2, UInt8(number), 4, 0x1D]), exchange: exchange)
                }
                guard let env = await read(7, 1), env.count == 29, !env.allSatisfy({ $0 == 0 || $0 == 255 }) else { continue }
                let network = identify(env)
                var records = [Record(sfi: 7, number: 1, payload: env)]
                let targets = [(2, 1), (8, 16), (9, 8), (10, 1), (11, 1), (12, 1), (13, 1), (25, 1), (29, 4), (30, 1)] + (network == .mobib ? [(23,16)] : [])
                for (sfi, maximum) in targets {
                    progress(sfi)
                    for number in 1...maximum {
                        guard let data = await read(sfi, number), (1...256).contains(data.count),
                              (!data.allSatisfy({ $0 == 0 }) || [10,11,12,13,25].contains(sfi)), !data.allSatisfy({ $0 == 255 }) else { break }
                        records.append(Record(sfi: sfi, number: number, payload: data))
                    }
                }
                let contracts = contracts(network: network, records: records)
                let balances = contracts.compactMap(\.balanceMinor)
                let remaining = contracts.compactMap(\.remainingTrips)
                var serial: String?
                if [.navigo, .opus].contains(network), let icc = records.first(where: { $0.sfi == 2 && $0.number == 1 })?.payload {
                    if let value = at(icc, 128, 32), value != 0 && value != 0xFFFFFFFF { serial = String(value) }
                    else if let value = at(icc, 0, 32), value != 0 && value != 0xFFFFFFFF { serial = String(value) }
                }
                return ReadResult(network: network, selectedAID: aid, serial: serial, balanceMinor: balances.count == 1 ? balances[0] : nil,
                    remainingTrips: remaining.first(where: { $0 > 0 }) ?? remaining.first, fields: fields(network, records, contracts),
                    records: records, contracts: contracts, rawHistories: records.compactMap { encodeRecord(network: network, record: $0).map(hex) })
            }
        }
        return nil
    }
    private static func fromHex(_ text: String) -> Data? {
        let chars = Array(text); guard chars.count % 2 == 0 else { return nil }; var bytes = Data()
        for offset in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[offset...offset + 1]), radix: 16) else { return nil }; bytes.append(byte)
        }
        return bytes
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
    private static func moneyText(_ minor: Int64) -> String {
        let formatter = NumberFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2; formatter.usesGroupingSeparator = false
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minor) / 100)) ?? "Unavailable"
    }
    private static let schemas: [String: String] = [
        "env": "version:6,[network:24,issuer:8,expiry:14,_:11,_:16,_:32,_:1]",
        "envRav": "version:3,network:20,_:26,issued:14,expiry:14",
        "envMobibOld": "version:6,_:7,network:24,_:9,expiry:14",
        "envMobibNew": "version:6,_:7,network:24,_:5,expiry:14",
        "commonContract": "[provider:8,product:16,serial:32,passenger:8,[start:14,end:14],status:8,_:0]",
        "contract46": "[provider:8,product:16,serial:32,passenger:8,[start:14,end:14],status:8,[(_:16,_:16,_:16),(_:16,_:16),zones:16,(sale:14,_:16,_:8),(_:11,price:16,_:1),_:6,(_:14,_:6),(sold:8,debit:5),_:4,_:5,startTime:11,endTime:11,_:14,_:14,_:28,journeys:16,_:32]]",
        "contract20": "[provider:8,product:16,serial:32,passenger:8,[start:14,end:14],status:8,[(_:16,_:16,_:16),(_:16,_:16),zones:16,(sale:14,_:16,_:8),(_:11,price:16,_:1),_:6,(_:14,_:6),(sold:8,debit:5),_:4,_:5]]",
        "contractFF": "[network:24,provider:8,product:16,serial:32,[_:6,_:32],[_:8,_:8],_:6,_:32,_:11,_:16,price:16,_:16,[_:11,_:11,_:8,_:8,_:8,_:16,_:16],[start:14,startTime:11,end:14,endTime:11,duration:8,_:14,zones:8,journeys:16,_:16],[_:16,_:16,_:16,_:8,_:16,_:16,_:16,_:8],[sale:14,_:11,_:8,_:16],status:8,_:16,_:16,_:0]",
        "contractOpus": "_:3,[provider:8,product:16,[start:14,end:14],(_:17,sale:14,_:11,_:36,status:8,_:36)]",
        "contractRav": "version:3,start:14,provider:8,product:11,sale:14,_:12,_:10,_:1,[_:5,_:5,_:6,end:14,duration:8,_:32,_:6,_:32,_:32]",
        "contractMobibOld": "version:6,_:21,product:14,sale:14,_:48,price:16,_:113",
        "contractMobibNew": "version:6,_:19,product:14,_:50,price:16,_:6,[_:5,_:5,sale:14,(_:2,duration:8),_:8],_:24",
        "eventIntercode": "day:14,minute:11,[_:8,network:24,code:8,result:8,provider:8,_:8,counter:24,_:16,station:16,_:8,_:16,route:16,_:8,_:16,_:16,_:8,_:5,_:240,_:16,_:8,_:16,_:16,_:16,price:16,unit:16,contract:5,_:16,[_:14,_:11,_:1,_:2,_:2]]",
        "eventOpus": "day:14,minute:11,_:19,[_:8,_:8,provider:8,_:16,route:16,_:16,_:16,contract:5,[_:14,_:11,_:1,_:4,_:4,_:4,_:4]]",
        "eventRav": "version:3,provider:8,contract:4,code:8,seconds:30,_:1,_:30,_:32,[station:16,route:16,_:8,_:12,_:14,_:4,_:8],[(_:10,_:8,price:16),_:32,_:32]",
        "eventMobibOld": "version:6,day:14,minute:11,_:21,_:5,_:14,_:12,route:16,provider:5,station:17,_:10,_:7,counter:24,_:24,_:14,_:11,_:21",
        "eventMobibNew": "version:6,day:14,minute:11,_:31,[(_:4,_:12),route:16,_:16,_:16,(provider:5,station:17,_:10)],[counter:24,_:16,_:8,_:16,(_:14,_:11),_:16],_:21",
    ]
}
