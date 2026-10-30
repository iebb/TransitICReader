import Foundation

// Wire-format facts are documented in docs/research/desfire-stored-value.md.
// This implementation and all fixtures are independent of the GPL references.
enum DesfireReadError: Error, Equatable {
    case malformedResponse, responseLimit, status(UInt8), unsupportedFile, protectedFile
}

final class DesfireReadSession {
    enum WireMode { case native, wrapped }
    private let mode: WireMode
    private let exchange: (Data) async throws -> Data

    init(mode: WireMode, exchange: @escaping (Data) async throws -> Data) {
        self.mode = mode
        self.exchange = exchange
    }

    func command(_ instruction: UInt8, _ payload: Data = Data()) async throws -> Data {
        guard [0x5A, 0xF5, 0xBD, 0xBB, 0x6A, 0x60, 0xAF].contains(instruction), payload.count <= 255 else {
            throw DesfireReadError.unsupportedFile
        }
        var operation = instruction
        var parameters = payload
        var accumulated = Data()
        for _ in 0..<64 {
            let request: Data
            if mode == .native {
                request = Data([operation]) + parameters
            } else if parameters.isEmpty {
                request = Data([0x90, operation, 0, 0, 0])
            } else {
                request = Data([0x90, operation, 0, 0, UInt8(parameters.count)]) + parameters + Data([0])
            }
            let response = Array(try await exchange(request))
            let status: UInt8
            let body: ArraySlice<UInt8>
            if mode == .native {
                guard !response.isEmpty else { throw DesfireReadError.malformedResponse }
                status = response[0]
                body = response.dropFirst()
            } else {
                guard response.count >= 2, response[response.count - 2] == 0x91 else { throw DesfireReadError.malformedResponse }
                status = response[response.count - 1]
                body = response.dropLast(2)
            }
            guard accumulated.count + body.count <= 65_536 else { throw DesfireReadError.responseLimit }
            if status == 0 {
                accumulated.append(contentsOf: body)
                return accumulated
            }
            guard status == 0xAF else { throw DesfireReadError.status(status) }
            accumulated.append(contentsOf: body)
            operation = 0xAF
            parameters = Data()
        }
        throw DesfireReadError.responseLimit
    }

    /// AIDs here use NXP numeric notation; the three command bytes are LE.
    func selectApplication(_ aid: UInt32) async throws {
        guard aid <= 0xFFFFFF else { throw DesfireReadError.malformedResponse }
        let data = try await command(0x5A, Data((0..<3).map { UInt8((aid >> ($0 * 8)) & 255) }))
        guard data.isEmpty else { throw DesfireReadError.malformedResponse }
    }

    func readFile(_ number: UInt8) async throws -> (data: Data, recordSize: Int?) {
        let settings = Array(try await command(0xF5, Data([number])))
        guard settings.count >= 4 else { throw DesfireReadError.malformedResponse }
        guard settings[1] == 0 else { throw DesfireReadError.protectedFile }
        func le24(_ start: Int) -> Int {
            Int(settings[start]) | Int(settings[start + 1]) << 8 | Int(settings[start + 2]) << 16
        }
        let size: Int
        let recordSize: Int?
        let instruction: UInt8
        if settings[0] == 0 || settings[0] == 1 {
            guard settings.count == 7 else { throw DesfireReadError.malformedResponse }
            size = le24(4)
            recordSize = nil
            instruction = 0xBD
        } else if settings[0] == 3 || settings[0] == 4 {
            guard settings.count == 13 else { throw DesfireReadError.malformedResponse }
            let record = le24(4), maximum = le24(7), count = le24(10)
            guard record > 0, count <= maximum, count <= 256, record <= 4096 else { throw DesfireReadError.responseLimit }
            size = record * count
            recordSize = record
            instruction = 0xBB
        } else {
            throw DesfireReadError.unsupportedFile
        }
        guard size <= 65_536 else { throw DesfireReadError.responseLimit }
        if size == 0 { return (Data(), recordSize) }
        // Zero length/count means all bytes/records; length is checked against settings.
        let bytes = try await command(instruction, Data([number, 0, 0, 0, 0, 0, 0]))
        guard bytes.count == size else { throw DesfireReadError.malformedResponse }
        return (bytes, recordSize)
    }
}

enum StoredValueProtocol {
    struct Snapshot {
        let family: String
        let currencyCode: String
        let fractionDigits: Int
        let balanceMinor: Int64?
        let serial: String?
        let metadata: [String: String]
        let rawTransactions: [String]
        let passes: [Pass]
    }
    struct History {
        let family: String
        let currencyCode: String
        let issuerTimeZone: String
        let dateEpochSeconds: Double?
        let endDateEpochSeconds: Double?
        let amountMinor: Int64?
        let balanceMinor: Int64?
        let kind: String
        let label: String
        let counter: Int?
        let locationCode: String?
        let route: String?
        let rawEnvelope: String
    }
    struct Pass {
        let family: String
        let label: String
        let productCode: Int
        let zoneCode: Int
        let validFromEpochSeconds: Double?
        let validToEpochSeconds: Double?
    }
    private struct Format {
        let tag: UInt8
        let aid: UInt32
        let family: String
        let currency: String
    }
    private static let formats = [
        Format(tag: 1, aid: 0x534531, family: "Opal", currency: "AUD"),
        Format(tag: 3, aid: 0xEF2014, family: "HSL", currency: "EUR"),
        Format(tag: 2, aid: 0xEF2011, family: "HSL", currency: "EUR"),
        Format(tag: 4, aid: 0xAB1000, family: "Waltti", currency: "EUR"),
        Format(tag: 5, aid: 0xF21190, family: "Clipper", currency: "USD")
    ]

    /// No authentication or write commands are issued. A matching AID alone is insufficient.
    static func readFirst(mode: DesfireReadSession.WireMode, exchange: @escaping (Data) async throws -> Data) async throws -> Snapshot? {
        let session = DesfireReadSession(mode: mode, exchange: exchange)
        for format in formats {
            do { try await session.selectApplication(format.aid) }
            catch DesfireReadError.status { continue }
            var files: [UInt8: Data] = [:]
            var recordSizes: [UInt8: Int] = [:]
            let wanted: [UInt8] = format.tag == 1 ? [7] : format.tag == 5 ? [2, 8, 14, 4] : [2, 8, 4, 1, 3]
            for file in wanted {
                do {
                    let result = try await session.readFile(file)
                    files[file] = result.data
                    if let size = result.recordSize { recordSizes[file] = size }
                } catch DesfireReadError.status { continue }
                catch DesfireReadError.protectedFile { continue }
                catch DesfireReadError.unsupportedFile { continue }
            }
            if let snapshot = parseFiles(tag: format.tag, files: files, recordSizes: recordSizes) { return snapshot }
        }
        return nil
    }

    /// Public for synthetic tests and platform adapters which already read files.
    static func parseFiles(tag: UInt8, files: [UInt8: Data], recordSizes: [UInt8: Int] = [:]) -> Snapshot? {
        guard let format = formats.first(where: { $0.tag == tag }) else { return nil }
        var balance: Int64?, serial: String?
        var records: [String] = []
        var metadata = ["generation": "DESFire public files", "applicationAID": String(format: "%06X", format.aid)]
        if tag == 1 {
            guard let data = files[7], data.count >= 16 else { return nil }
            let bits = Bits(Data(data.prefix(16).reversed()))
            balance = bits.signed(54, 21)
            if let number = bits.unsigned(96, 32), let digit = bits.unsigned(92, 4), digit <= 9 {
                serial = String(3_085_220_000_000_000 + number * 10 + digit)
            }
            metadata["scope"] = "Balance and last-event summary; not full history"
            records = [envelope(tag: tag, kind: 1, index: 0, data: Data(data.prefix(16)))]
        } else if tag == 5 {
            if let data = files[2], data.count >= 20 { balance = Bits(data).signed(18 * 8, 16) }
            if let data = files[8], let value = Bits(data).unsigned(8, 32) { serial = String(value) }
            for (file, kind): (UInt8, UInt8) in [(14, 3), (4, 2)] {
                guard let data = files[file], data.count % 32 == 0 else { continue }
                for offset in stride(from: 0, to: data.count, by: 32) {
                    records.append(envelope(tag: tag, kind: kind, index: offset / 32, data: data.subdata(in: offset..<(offset + 32))))
                }
            }
            metadata["scope"] = "Older DESFire generation; newer Clipper generations are not decoded"
        } else {
            if let data = files[2] {
                balance = Bits(data).unsigned(0, 20).map(Int64.init)
                records.append(envelope(tag: tag, kind: 2, index: 0, data: data))
            }
            if let info = files[8], info.count >= 10 { serial = hex(info.subdata(in: 1..<10)) }
            if let data = files[4], let size = recordSizes[4], size >= 12, data.count % size == 0 {
                for offset in stride(from: 0, to: data.count, by: size) {
                    records.append(envelope(tag: tag, kind: 3, index: offset / size, data: data.subdata(in: offset..<(offset + size))))
                }
            }
            if let data = files[1] { records.append(envelope(tag: tag, kind: 4, index: 0, data: data)) }
            if let data = files[3] { records.append(envelope(tag: tag, kind: 5, index: 0, data: data)) }
            metadata["scope"] = "HSL V1/V2 or Waltti DESFire public purse, logs and ticket products"
        }
        records = records.filter { !$0.isEmpty }
        let passes = parsePasses(records)
        guard balance != nil || !parseHistories(records).isEmpty || !passes.isEmpty else { return nil }
        return Snapshot(family: format.family, currencyCode: format.currency, fractionDigits: 2,
                        balanceMinor: balance, serial: serial, metadata: metadata,
                        rawTransactions: records, passes: passes)
    }

    // DFSV, version, format tag, record kind, index BE16, payload length BE16.
    static func envelope(tag: UInt8, kind: UInt8, index: Int, data: Data) -> String {
        guard formats.contains(where: { $0.tag == tag }), (1...5).contains(kind),
              (0...65535).contains(index), !data.isEmpty, data.count <= 4096 else { return "" }
        return hex(Data([0x44, 0x46, 0x53, 0x56, 1, tag, kind, UInt8(index >> 8), UInt8(index & 255),
                         UInt8(data.count >> 8), UInt8(data.count & 255)]) + data)
    }
    private static func unpack(_ value: String) -> (tag: UInt8, kind: UInt8, index: Int, data: Data)? {
        guard value.count % 2 == 0, value.count <= (4096 + 11) * 2,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let chars = Array(value.utf8)
        var data: [UInt8] = []
        for offset in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(bytes: chars[offset..<(offset + 2)], encoding: .utf8)!, radix: 16) else { return nil }
            data.append(byte)
        }
        guard data.count >= 12, Array(data[0..<5]) == [0x44, 0x46, 0x53, 0x56, 1],
              formats.contains(where: { $0.tag == data[5] }), (1...5).contains(data[6]),
              Int(data[9]) * 256 + Int(data[10]) == data.count - 11 else { return nil }
        return (data[5], data[6], Int(data[7]) * 256 + Int(data[8]), Data(data.dropFirst(11)))
    }

    static func parseHistory(_ raw: String, expectedFamily: String? = nil) -> History? {
        guard let item = unpack(raw), let format = formats.first(where: { $0.tag == item.tag }),
              expectedFamily == nil || expectedFamily == format.family,
              item.data.contains(where: { $0 != 0 }) else { return nil }
        let bits = Bits(item.data)
        var date: Double?, end: Double?, amount: Int64?, balance: Int64?, counter: Int?
        var location: String?, route: String?
        var kind = "trip", label = "Journey", zone = "Europe/Helsinki"
        if item.tag == 1 {
            guard item.kind == 1, item.data.count == 16 else { return nil }
            let opal = Bits(Data(item.data.reversed()))
            guard let action = opal.unsigned(21, 4), action != 0,
                  let day = opal.unsigned(39, 15), let minute = opal.unsigned(28, 11) else { return nil }
            zone = "Australia/Sydney"
            date = localTime(year: 1980, day: Int(day), minute: Int(minute), zone: zone)
            balance = opal.signed(54, 21)
            counter = opal.unsigned(75, 16).map(Int.init)
            kind = "event"
            label = (1...6).contains(action) ? "Tap on" : (7...10).contains(action) ? "Tap off" : action == 11 ? "Tap-on reversal" : action == 12 ? "Tap rejected" : "Last event \(action)"
        } else if item.tag == 5 {
            guard item.data.count == 32, item.kind == 2 || item.kind == 3 else { return nil }
            zone = "America/Los_Angeles"
            location = bits.unsigned(16, 16).map { "Agency \($0)" }
            if item.kind == 2 {
                guard let time = bits.unsigned(32, 32), time != 0, let fare = bits.unsigned(112, 16) else { return nil }
                date = Double(time) - 2_208_988_800
                amount = Int64(fare)
                kind = "reload"; label = "Reload"
            } else {
                guard bits.unsigned(16, 16) != 0, let fare = bits.unsigned(48, 16) else { return nil }
                if let time = bits.unsigned(96, 32), time != 0 { date = Double(time) - 2_208_988_800 }
                if let time = bits.unsigned(128, 32), time != 0 { end = Double(time) - 2_208_988_800 }
                amount = -Int64(fare)
                route = bits.unsigned(224, 16).map(String.init)
                let from = bits.unsigned(160, 16) ?? 0, to = bits.unsigned(176, 16) ?? 0
                location = "\(location ?? "Agency") · \(from) → \(to)"
            }
        } else if item.kind == 2 {
            guard let day = bits.unsigned(20, 14), day != 0, let minute = bits.unsigned(34, 11),
                  let fare = bits.unsigned(45, 20) else { return nil }
            date = localTime(year: 1997, day: Int(day), minute: Int(minute), zone: zone)
            // File 02's first field is today's purse, not the balance after
            // this older reload; do not turn it into historical evidence.
            amount = Int64(fare)
            kind = "reload"; label = "Value reload"
        } else if item.kind == 3 {
            guard item.data.count >= 12, let day = bits.unsigned(1, 14), let minute = bits.unsigned(15, 11),
                  day != 0 || minute != 0, let fare = bits.unsigned(51, 14) else { return nil }
            date = localTime(year: 1997, day: Int(day), minute: Int(minute), zone: zone)
            amount = -Int64(fare)
            balance = bits.unsigned(item.tag == 3 ? 71 : 70, 20).map(Int64.init)
        } else if item.kind == 4 || item.kind == 5 {
            let start: Int = item.kind == 4 ? (item.tag == 2 ? 192 : item.tag == 3 ? 208 : 280) : (item.tag == 2 ? 144 : item.tag == 3 ? 286 : 168)
            guard let day = bits.unsigned(start, 14), let minute = bits.unsigned(start + 14, 11), day != 0 || minute != 0 else { return nil }
            date = localTime(year: 1997, day: Int(day), minute: Int(minute), zone: zone)
            label = "Ticket validation"
            if item.tag != 4 { route = bits.unsigned(start + 41, 14).map(String.init) }
        } else { return nil }
        return History(family: format.family, currencyCode: format.currency, issuerTimeZone: zone,
                       dateEpochSeconds: date, endDateEpochSeconds: end, amountMinor: amount, balanceMinor: balance,
                       kind: kind, label: label, counter: counter, locationCode: location, route: route, rawEnvelope: raw)
    }

    static func parseHistories(_ raw: [String], expectedFamily: String? = nil) -> [History] {
        let events = raw.compactMap { parseHistory($0, expectedFamily: expectedFamily) }
        // An embedded pass validation can enrich a single dated log entry. Do
        // not deduplicate conflicting paid logs or unrelated undated records.
        let filtered = events.filter { event in
            guard ["HSL", "Waltti"].contains(event.family), event.amountMinor == nil, let time = event.dateEpochSeconds else { return true }
            return events.filter { $0.family == event.family && $0.kind == "trip" && $0.dateEpochSeconds == time && $0.amountMinor != nil }.count != 1
        }
        var result: [History] = []
        var reloadSummaries: Set<String> = []
        func clipperKey(_ event: History) -> String? {
            guard event.family == "Clipper", event.kind == "trip", let time = event.dateEpochSeconds,
                  let item = unpack(event.rawEnvelope) else { return nil }
            let bits = Bits(item.data)
            return "\(time):\(bits.unsigned(16, 16) ?? 0):\(bits.unsigned(160, 16) ?? 0):\(bits.unsigned(224, 16) ?? 0)"
        }
        for event in filtered {
            if ["HSL", "Waltti"].contains(event.family), event.kind == "reload", let item = unpack(event.rawEnvelope), item.kind == 2 {
                // The first 20 bits change as the current purse changes. The
                // remaining bytes describe the same last-reload summary.
                var summary = Array(item.data)
                summary[0] = 0; summary[1] = 0; summary[2] &= 0x0F
                if !reloadSummaries.insert("\(item.tag):\(hex(Data(summary)))").inserted { continue }
            }
            if let key = clipperKey(event), let index = result.firstIndex(where: { clipperKey($0) == key }) {
                let previous = result[index]
                if previous.endDateEpochSeconds == nil && event.endDateEpochSeconds != nil { result[index] = event; continue }
                if previous.endDateEpochSeconds != nil && event.endDateEpochSeconds == nil { continue }
                if previous.endDateEpochSeconds == event.endDateEpochSeconds && previous.amountMinor == event.amountMinor { continue }
            }
            result.append(event)
        }
        return result
    }

    static func parsePasses(_ raw: [String], expectedFamily: String? = nil) -> [Pass] {
        var result: [Pass] = []
        for value in raw {
            guard let item = unpack(value), [2, 3, 4].contains(item.tag), item.kind == 4 || item.kind == 5,
                  let format = formats.first(where: { $0.tag == item.tag }), expectedFamily == nil || expectedFamily == format.family else { continue }
            if item.kind == 4 {
                let width = item.tag == 2 ? 6 : item.tag == 3 ? 7 : 10
                for index in 0..<2 {
                    guard item.data.count >= (index + 1) * width else { continue }
                    let data = item.data.subdata(in: (index * width)..<((index + 1) * width)), bits = Bits(data)
                    guard data.contains(where: { $0 != 0 }) else { continue }
                    let productOffset = item.tag == 2 ? 0 : item.tag == 3 ? 1 : 12
                    let zoneOffset = item.tag == 2 ? 15 : item.tag == 3 ? 17 : 27
                    let dateOffset = item.tag == 2 ? 19 : item.tag == 3 ? 23 : 33
                    guard let product = bits.unsigned(productOffset, 14), product != 0,
                          let area = bits.unsigned(zoneOffset, item.tag == 2 ? 4 : 6),
                          let start = bits.unsigned(dateOffset, 14), let end = bits.unsigned(dateOffset + 14, 14),
                          !(item.tag == 4 && start == 999 && end == 0), start == 0 || end == 0 || end >= start else { continue }
                    result.append(Pass(family: format.family, label: "Season pass", productCode: Int(product), zoneCode: Int(area),
                                       validFromEpochSeconds: start == 0 ? nil : localTime(year: 1997, day: Int(start), minute: 0, zone: "Europe/Helsinki"),
                                       validToEpochSeconds: end == 0 ? nil : localTime(year: 1997, day: Int(end), minute: 0, zone: "Europe/Helsinki")))
                }
            } else {
                let bits = Bits(item.data)
                let productOffset = item.tag == 3 ? 1 : item.tag == 4 ? 8 : 0
                let validityOffset = item.tag == 2 ? 88 : item.tag == 3 ? 205 : 112
                let areaOffset = item.tag == 2 ? 28 : item.tag == 3 ? 63 : 44
                guard let product = bits.unsigned(productOffset, 14), product != 0,
                      let area = bits.unsigned(areaOffset, item.tag == 2 ? 4 : 6),
                      let start = bits.unsigned(validityOffset, 14), let startMinute = bits.unsigned(validityOffset + 14, 11),
                      let end = bits.unsigned(validityOffset + 25, 14), let endMinute = bits.unsigned(validityOffset + 39, 11),
                      start != 0 || end != 0 else { continue }
                let from = start == 0 && startMinute == 0 ? nil : localTime(year: 1997, day: Int(start), minute: Int(startMinute), zone: "Europe/Helsinki")
                let to = end == 0 && endMinute == 0 ? nil : localTime(year: 1997, day: Int(end), minute: Int(endMinute), zone: "Europe/Helsinki")
                if let from, let to, to < from { continue }
                result.append(Pass(family: format.family, label: "Value ticket", productCode: Int(product), zoneCode: Int(area),
                                   validFromEpochSeconds: from, validToEpochSeconds: to))
            }
        }
        return result
    }

    static func localTime(year: Int, day: Int, minute: Int, zone: String) -> Double? {
        guard day >= 0, (0..<1440).contains(minute), let timeZone = TimeZone(identifier: zone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard let epoch = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let date = calendar.date(byAdding: .day, value: day, to: epoch) else { return nil }
        let components = DateComponents(hour: minute / 60, minute: minute % 60, second: 0)
        let before = calendar.startOfDay(for: date).addingTimeInterval(-1)
        guard let first = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.nextDate(after: before, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last),
              first == last, calendar.isDate(first, inSameDayAs: date) else { return nil }
        return first.timeIntervalSince1970
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }
    private struct Bits {
        let data: [UInt8]
        init(_ data: Data) { self.data = Array(data) }
        func unsigned(_ start: Int, _ length: Int) -> UInt64? {
            guard start >= 0, (1...63).contains(length), start + length <= data.count * 8 else { return nil }
            return (start..<(start + length)).reduce(UInt64(0)) { value, bit in
                (value << 1) | UInt64((data[bit / 8] >> (7 - bit % 8)) & 1)
            }
        }
        func signed(_ start: Int, _ length: Int) -> Int64? {
            guard let value = unsigned(start, length) else { return nil }
            return value & (1 << (length - 1)) == 0 ? Int64(value) : Int64(value) - (1 << length)
        }
    }
}
