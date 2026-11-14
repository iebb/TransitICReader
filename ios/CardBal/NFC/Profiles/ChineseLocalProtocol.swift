import Foundation

/// Independent implementation of public PBOC wire facts; see docs/decoding/china-local.md.
enum ChineseLocalProtocol {
    enum Kind: String, CaseIterable {
        // Specific names before Beijing's generic short ones.
        case shenzhen, wuhan, lingnan, beijing
        var aids: [String] {
            switch self {
            case .shenzhen: return ["5041592E535A54"] // PAY.SZT
            case .wuhan: return ["4150312E5748435443"] // AP1.WHCTC
            // The purse is PAY.TICL; PAY.APPY holds the card details (and is tried for the purse when TICL is absent).
            case .lingnan: return [Self.lingnanPurseAID, Self.lingnanInfoAID]
            case .beijing: return ["4F43", "50424F43"] // OC / PBOC (external readers on iOS)
            }
        }
        static let lingnanPurseAID = "5041592E5449434C" // PAY.TICL
        static let lingnanInfoAID = "5041592E41505059" // PAY.APPY
        var family: String {
            switch self {
            case .shenzhen: return "Shenzhen Tong"; case .wuhan: return "Wuhan Tong"
            case .lingnan: return "Lingnan Pass"; case .beijing: return "Beijing Yikatong"
            }
        }
        var city: String {
            switch self { case .shenzhen: return "Shenzhen"; case .wuhan: return "Wuhan"; case .lingnan: return "Guangzhou"; case .beijing: return "Beijing" }
        }
        static func from(family: String) -> Kind? { allCases.first { $0.family.lowercased() == family.lowercased() } }
    }
    struct File { let sfi: Int; let data: Data }
    struct Record { let number: Int; let data: Data }
    struct Result {
        let kind: Kind; let aid: String; let selection: Data; let balance: Data; let balanceMinor: Int64
        let serial: String?; let issueDate: String?; let expiryDate: String?
        let files: [File]; let records: [Record]
        /// Another application of the card that supplied its details (Lingnan Pass: PAY.APPY).
        var infoAID: String? = nil; var infoSelection: Data? = nil
    }
    struct History {
        let date: Date; let amountMinor: Int64?; let type: UInt8; let terminal: String; let counter: Int
    }
    static func balanceMinor(_ bytes: Data) -> Int64? {
        guard bytes.count == 4, !bytes.allSatisfy({ $0 == 255 }) else { return nil }
        // Bit 31 is a flag. The remaining 31 bits are signed (overdrafts exist).
        let value = uint(bytes) & 0x7FFFFFFF
        return value & 0x40000000 == 0 ? value : value - 0x80000000
    }
    static func history(_ bytes: Data) -> History? {
        guard bytes.count == 23, let date = bcdDate(Data(bytes.suffix(7))),
              uint(bytes.subdata(in: 5..<9)) <= Int32.max else { return nil }
        let type = bytes[9]; let amount = uint(bytes.subdata(in: 5..<9))
        return History(date: date, amountMinor: type == 2 ? amount : [UInt8(6), 9].contains(type) ? -amount : nil,
                       type: type, terminal: hex(bytes.subdata(in: 10..<16)), counter: Int(uint(Data(bytes.prefix(2)))))
    }
    /// Readable application name for the debug log ("PAY.TICL"); AIDs are public, not card data.
    static func name(_ aid: String) -> String {
        let bytes = unhex(aid)
        guard bytes.allSatisfy({ (0x20..<0x7F).contains($0) }) else { return aid }
        return String(decoding: bytes, as: UTF8.self) + " (" + aid + ")"
    }
    /// Core NFC can select only the Info.plist AIDs, so built-in reads pass [.shenzhen, .wuhan, .lingnan].
    /// `log` receives the applications tried and their status words (never card data).
    static func read(kinds: [Kind] = Kind.allCases, log: ((String) -> Void)? = nil,
                     exchange: (Data) async throws -> (Data, UInt8, UInt8)) async -> Result? {
        var status = "no reply"
        func command(_ request: Data) async -> Data? {
            var current = request; var output = Data(); var corrected = false
            for _ in 0..<16 {
                let reply: (Data, UInt8, UInt8)
                do { reply = try await exchange(current) } catch { status = "no reply"; return nil }
                let (body, sw1, sw2) = reply
                status = String(format: "SW %02X%02X", sw1, sw2)
                if sw1 == 0x6C, !corrected {
                    current[current.count - 1] = sw2; corrected = true; continue
                }
                guard (sw1 == 0x90 && sw2 == 0) || sw1 == 0x61, output.count + body.count <= 2048 else { return nil }
                output += body
                if sw1 == 0x90 { return output }
                current = Data([0, 0xC0, 0, 0, sw2]); corrected = false
            }
            return nil
        }
        func select(_ aid: String) async -> Data? {
            let name = unhex(aid)
            return await command(Data([0, 0xA4, 4, 0, UInt8(name.count)]) + name + Data([0]))
        }
        for kind in kinds {
            // Lingnan Pass keeps its details in PAY.APPY: FCI tag 9F0C, else SFI 15 (as NFSee reads them).
            var lingnanInfo: (selection: Data, info: Data?)?
            if kind == .lingnan {
                if let fci = await select(Kind.lingnanInfoAID) {
                    var info = tlv(0x9F0C, in: fci)
                    if info == nil { info = await command(Data([0, 0xB0, 0x95, 0, 0])) }
                    log?("\(kind.family): SELECT \(name(Kind.lingnanInfoAID)) \(status); details " + (info == nil ? "not readable" : "read (\(info!.count) bytes)"))
                    lingnanInfo = (fci, info)
                } else {
                    log?("\(kind.family): SELECT \(name(Kind.lingnanInfoAID)) \(status)")
                }
            }
            for aid in kind.aids {
                if kind == .lingnan, aid == Kind.lingnanInfoAID, lingnanInfo == nil { continue } // Already tried above.
                guard let selection = await select(aid) else {
                    log?("\(kind.family): SELECT \(name(aid)) \(status)")
                    continue
                }
                var usesPurseDF = false
                var balance = await command(Data([0x80, 0x5C, 0, 2, 4]))
                if balance == nil, kind == .beijing,
                   await command(Data([0, 0xA4, 0, 0, 2, 0x10, 1, 0])) != nil {
                    usesPurseDF = true
                    balance = await command(Data([0x80, 0x5C, 0, 2, 4]))
                }
                guard let balance, let minor = balanceMinor(balance) else {
                    log?("\(kind.family): SELECT \(name(aid)) SW 9000; GET BALANCE " + (balance == nil ? status : "not a balance (\(balance!.count) bytes)"))
                    continue
                }
                func file(_ sfi: Int) async -> Data? {
                    _ = await select(aid)
                    if let bytes = await command(Data([0, 0xB0, UInt8(0x80 | sfi), 0, 0])) { return bytes }
                    // Some generations expose the same file by path rather than SFI.
                    for path in [Data([0x10, 1, 0, UInt8(sfi)]), Data([0, UInt8(sfi)])] {
                        _ = await select(aid)
                        if await command(Data([0, 0xA4, 8, 0, UInt8(path.count)]) + path + Data([0])) != nil,
                           let bytes = await command(Data([0, 0xB0, 0, 0, 0])) { return bytes }
                    }
                    if kind != .shenzhen, kind != .lingnan,
                       await command(Data([0, 0xA4, 0, 0, 2, 0x3F, 0, 0])) != nil {
                        return await command(Data([0, 0xB0, UInt8(0x80 | sfi), 0, 0]))
                    }
                    return nil
                }
                let infoSFI = kind == .shenzhen || kind == .lingnan ? 0x15 : kind == .wuhan ? 5 : 4
                var files: [File] = []
                var info = kind == .lingnan ? lingnanInfo?.info : nil
                if info == nil { info = await file(infoSFI) }
                if let info { files.append(File(sfi: infoSFI, data: info)) }
                let serialFile = kind == .wuhan ? await file(10) : nil
                if let serialFile { files.append(File(sfi: 10, data: serialFile)) }
                let metadata = metadata(kind: kind, info: info, serialFile: serialFile, selection: selection)
                // A generic short PBOC name alone is not evidence of a Beijing card.
                if kind == .beijing && (metadata.serial == nil || metadata.issue == nil || metadata.expiry == nil) { continue }
                _ = await select(aid)
                if usesPurseDF { _ = await command(Data([0, 0xA4, 0, 0, 2, 0x10, 1, 0])) }
                var records: [Record] = []; var recordP2: UInt8 = 0xC4
                for number in 1...30 {
                    var payload = await command(Data([0, 0xB2, UInt8(number), recordP2, 23]))
                    if number == 1, payload == nil {
                        for path in [Data([0x10, 1, 0, 0x18]), Data([0, 0x18])] {
                            _ = await select(aid)
                            if await command(Data([0, 0xA4, 8, 0, UInt8(path.count)]) + path + Data([0])) != nil {
                                recordP2 = 4
                                payload = await command(Data([0, 0xB2, 1, recordP2, 23]))
                                if payload != nil { break }
                            }
                        }
                    }
                    guard let bytes = payload else { break }
                    guard bytes.count == 23 else { break }
                    if bytes.allSatisfy({ $0 == 0 || $0 == 255 }) { break }
                    records.append(Record(number: number, data: bytes))
                }
                log?("\(kind.family): read from \(name(aid)); \(records.count) record(s)"
                     + (metadata.serial == nil ? ", no card number" : "") + (info == nil ? ", no details file" : ""))
                var result = Result(kind: kind, aid: aid, selection: selection, balance: balance, balanceMinor: minor,
                                    serial: metadata.serial, issueDate: metadata.issue, expiryDate: metadata.expiry,
                                    files: files, records: records)
                if kind == .lingnan, aid != Kind.lingnanInfoAID, let lingnanInfo {
                    result.infoAID = Kind.lingnanInfoAID; result.infoSelection = lingnanInfo.selection
                }
                return result
            }
        }
        return nil
    }
    private static func metadata(kind: Kind, info: Data?, serialFile: Data?, selection: Data) -> (serial: String?, issue: String?, expiry: String?) {
        let info = info ?? (kind == .shenzhen ? tlv(0x8C, in: selection) : nil)
        func date(_ offset: Int) -> String? {
            guard let info, info.count >= offset + 4 else { return nil }
            let bytes = info.subdata(in: offset..<offset + 4)
            guard bcdDate(bytes + Data([0, 0, 0])) != nil else { return nil }
            let text = hex(bytes)
            return "\(text.prefix(4))-\(text.dropFirst(4).prefix(2))-\(text.suffix(2))"
        }
        var serial: String?
        switch kind {
        case .shenzhen:
            if let info, info.count >= 20 {
                let bytes = info.subdata(in: 16..<20)
                if validSerial(bytes) {
                    let value = uint(Data(bytes.reversed())); let digits = String(value).compactMap(\.wholeNumberValue).reduce(0, +)
                    serial = "\(value)(\((10 - digits % 10) % 10))"
                }
            }
        case .wuhan: if let serialFile, serialFile.count >= 5, validSerial(Data(serialFile.prefix(5))) { serial = hex(Data(serialFile.prefix(5))) }
        case .beijing: if let info, info.count >= 32, validSerial(Data(info.prefix(8))) { serial = hex(Data(info.prefix(8))) }
        case .lingnan:
            // Card number: bytes 11-15 of the details (NFSee); dates at the standard bytes 20-23 / 24-27.
            if let info, info.count >= 16 {
                let bytes = info.subdata(in: 11..<16)
                if validSerial(bytes) { serial = hex(bytes) }
            }
        }
        let issue = date(kind == .beijing ? 24 : 20)
        let expiry = date(kind == .beijing ? 28 : kind == .wuhan ? 16 : 24)
        // Lingnan dates are unconfirmed on real cards: show them only as a consistent pair.
        if kind == .lingnan, issue == nil || expiry == nil { return (serial, nil, nil) }
        guard issue == nil || expiry == nil || issue! <= expiry! else { return (serial, nil, nil) }
        return (serial, issue, expiry)
    }
    private static func validSerial(_ bytes: Data) -> Bool { bytes.contains { $0 != 0 } && bytes.contains { $0 != 255 } }
    private static func bcdDate(_ bytes: Data) -> Date? {
        guard bytes.count == 7, bytes.allSatisfy({ $0 >> 4 < 10 && $0 & 15 < 10 }) else { return nil }
        let text = hex(bytes); guard let year = Int(text.prefix(4)), (1900...2200).contains(year) else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyyMMddHHmmss"; formatter.isLenient = false
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
    /// `wanted` is the whole tag: 0x8C, or 0x9F0C for a two-byte tag.
    private static func tlv(_ wanted: Int, in bytes: Data, depth: Int = 0) -> Data? {
        guard depth < 8 else { return nil }
        let bytes = Array(bytes); var position = 0
        while position + 2 <= bytes.count {
            let first = bytes[position]; position += 1
            var tag = Int(first)
            if first & 31 == 31 {
                repeat {
                    guard position < bytes.count, tag <= 0xFFFFFF else { return nil }
                    tag = (tag << 8) | Int(bytes[position]); position += 1
                } while bytes[position - 1] & 128 != 0
            }
            guard position < bytes.count else { return nil }
            var length = Int(bytes[position]); position += 1
            if length & 128 != 0 {
                let count = length & 127; guard (1...2).contains(count), position + count <= bytes.count else { return nil }
                length = Int(uint(Data(bytes[position..<position + count]))); position += count
            }
            guard position + length <= bytes.count else { return nil }
            let body = Data(bytes[position..<position + length]); position += length
            if tag == wanted { return body }
            if first & 32 != 0, let found = tlv(wanted, in: body, depth: depth + 1) { return found }
        }
        return nil
    }
    private static func uint(_ bytes: Data) -> Int64 { bytes.reduce(0) { ($0 << 8) | Int64($1) } }
    private static func hex(_ bytes: Data) -> String { bytes.map { String(format: "%02X", $0) }.joined() }
    private static func unhex(_ text: String) -> Data {
        let chars = Array(text)
        return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }
}
