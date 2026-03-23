import Foundation
import CoreNFC
import os
import SwiftUI

// MARK: - Models

struct ResultField: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let value: String
}

struct RawDataSection: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let fields: [RawDataField]
}

struct RawDataField: Identifiable, Codable, Hashable, Equatable {
    var id: String { title + value }
    let title: String
    let value: String
    
    static func systemCodeRow(_ codes: [String]) -> RawDataField {
        RawDataField(title: "System Codes", value: codes.joined(separator: ", "))
    }
}

struct ParsedBalance: Hashable {
    let formatted: String
    let detail: String
    let rawFields: [RawDataField]
}

struct TransitTransaction: Identifiable, Hashable, Codable {
    let id: UUID
    let date: Date?
    let time: String?
    let amount: Decimal
    let terminalID: String?
    let type: String
    let balanceAfter: Decimal?
    let location: String?
    let entryStation: String?
    let exitStation: String?
    let rawData: String?
    
    init(date: Date?, time: String? = nil, amount: Decimal, terminalID: String?, type: String, balanceAfter: Decimal? = nil, location: String? = nil, entryStation: String? = nil, exitStation: String? = nil, rawData: String? = nil) {
        self.id = UUID()
        self.date = date
        self.time = time
        self.amount = amount
        self.terminalID = terminalID
        self.type = type
        self.balanceAfter = balanceAfter
        self.location = location
        self.entryStation = entryStation
        self.exitStation = exitStation
        self.rawData = rawData
    }
}

struct TransitCardSnapshot: Identifiable {
    let id = UUID()
    let technology: String
    let cardFamily: String
    let identifierLabel: String
    let identifierValue: String
    let rawIdentifierValue: String
    let pmm: String?
    let systemCode: String?
    let selectedAID: String?
    let balanceText: String?
    let balanceDetail: String?
    let realSerialNumber: String?
    let region: String?
    let resultFields: [ResultField]
    let rawSections: [RawDataSection]
    let transactions: [TransitTransaction]
    let scannedAt: Date
}

enum StatusKind {
    case idle
    case success
    case error
}

enum NFCTestError: Error {
    case unsupportedCard
}

enum NFCISO7816AccessPolicy {
    static let exactAIDs: Set<String> = [
        "A0000004520001", "D4100000030001", "D4100000140001", "D410000029000001", "D4100000300001", "D4106509900020", "A000000632010105"
    ]

    static let ksx6924AllowedPrefixes: [String] = [
        "D410000003",
        "D410000014",
        "D410000029",
        "D410000030",
        "D410650990"
    ]

    static func isAllowed(aid: String) -> Bool {
        let normalized = aid.uppercased()
        return exactAIDs.contains(normalized)
            || ksx6924AllowedPrefixes.contains { normalized.hasPrefix($0) }
            || CalypsoCardProfile.supportedPrefixes.contains { normalized.hasPrefix($0) }
    }
}

// NFCTransitReader moved to NFC/NFCTransitReader.swift

// MARK: - Helpers & Extensions

// Helpers moved to end of file

struct TransitTransactionRow: View {
    let tx: TransitTransaction
    let cardFamily: String?
    @State private var showingDetails = false
    
    var body: some View {
        Button {
            showingDetails = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: iconMapping.name)
                    .font(.title2)
                    .frame(width: 30)
                    .foregroundStyle(iconMapping.color)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tx.type)
                        .font(.headline)
                    HStack(spacing: 4) {
                        if let date = tx.date {
                            Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Unknown Date").font(.caption).foregroundStyle(.secondary)
                        }
                        if let loc = tx.location {
                             Text("•").font(.caption).foregroundStyle(.tertiary)
                             Text(loc).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let term = tx.terminalID, term != tx.type {
                        Text(term).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 2) {
                    if tx.amount != 0 {
                        Text((tx.type.lowercased().contains("top-up") || tx.type.lowercased().contains("charge") ? "+" : "-") + 
                             formatCurrency(amount: tx.amount, code: currencyCode, fractionDigits: cardFamily == "Octopus" ? 1 : 0))
                            .font(.headline.monospacedDigit().bold())
                    }
                    
                    if let bal = tx.balanceAfter {
                        Text(formatCurrency(amount: bal, code: currencyCode, fractionDigits: cardFamily == "Octopus" ? 1 : 0))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingDetails) {
            TransactionDetailView(tx: tx, cardFamily: cardFamily)
        }
    }
    
    private var iconMapping: (name: String, color: Color) {
        let low = tx.type.lowercased()
        if low.contains("top-up") || low.contains("charge") || low.contains("入金") { 
            return ("arrow.down.left.circle.fill", .green) 
        }
        if low.contains("goods") || low.contains("物販") || low.contains("purchase") { 
            return ("cart.fill", .orange) 
        }
        if low.contains("bus") || low.contains("バス") { 
            return ("bus.fill", .cyan) 
        }
        if low.contains("fare") || low.contains("journey") || low.contains("gate") || low.contains("運賃") || tx.entryStation != nil { 
            return ("tram.fill", .blue) 
        }
        if low.contains("ticket") || low.contains("purchase") || low.contains("券") { 
            return ("ticket.fill", .purple) 
        }
        if low.contains("issuance") || low.contains("発行") { 
            return ("plus.app.fill", .indigo) 
        }
        if low.contains("adjustment") || low.contains("清算") { 
            return ("hammer.fill", .brown) 
        }
        if low.contains("refund") || low.contains("返金") { 
            return ("arrow.uturn.left.circle.fill", .red) 
        }
        return ("creditcard.fill", .accentColor)
    }
    
    private var currencyCode: String {
        cardFamily == "Octopus" ? "HKD" : (cardFamily?.contains("China") == true ? "CNY" : "JPY")
    }
}

struct TransactionDetailView: View {
    let tx: TransitTransaction
    let cardFamily: String?
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Transaction Summary") {
                    LabeledContent("Process", value: tx.type)
                    if let term = tx.terminalID {
                        LabeledContent("Terminal", value: term)
                    }
                    if let date = tx.date {
                        LabeledContent("Date", value: date.formatted(date: .numeric, time: .omitted))
                    }
                    if let time = tx.time {
                        LabeledContent("Time", value: time)
                    }
                    if let amount = tx.amount != 0 ? tx.amount : nil {
                        LabeledContent("Amount", value: formatCurrency(amount: amount, code: currencyCode, fractionDigits: cardFamily == "Octopus" ? 1 : 0))
                    }
                    if let balance = tx.balanceAfter {
                        LabeledContent("Balance After", value: formatCurrency(amount: balance, code: currencyCode, fractionDigits: cardFamily == "Octopus" ? 1 : 0))
                    }
                }
                
                if tx.entryStation != nil || tx.exitStation != nil {
                    Section("Journey Details") {
                        if let entry = tx.entryStation {
                            LabeledContent(tx.type.lowercased().contains("bus") ? "Operator" : "Entry", value: entry)
                        }
                        if let exit = tx.exitStation {
                            LabeledContent(tx.type.lowercased().contains("bus") ? "Station" : "Exit", value: exit)
                        }
                    }
                } else if let loc = tx.location {
                    Section("Location / Info") {
                        Text(loc).font(.headline)
                    }
                }
                
                if let raw = tx.rawData {
                    Section("Hex Dump (16 Bytes)") {
                        Text(raw)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        
                        if cardFamily == "Japan Transit IC" {
                             SuicaRawBreakdownView(raw: raw)
                        }
                    }
                }
            }
            .navigationTitle("Transaction Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private var currencyCode: String {
        cardFamily == "Octopus" ? "HKD" : (cardFamily?.contains("China") == true ? "CNY" : "JPY")
    }
}

struct SuicaRawBreakdownView: View {
    let raw: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 16 {
                let console = data[0]
                let process = data[1]
                let payType = data[2]
                let ioType = data[3]
                
                let regionFull = Int(data[15])
                let r1 = (regionFull >> 6) & 0x03
                let r2 = (regionFull >> 4) & 0x03
                let entryH = (regionFull >> 2) & 0x03
                let exitH = regionFull & 0x03
                
                Group {
                    DetailRawRow(title: "Terminal", value: japaneseTerminal(console), hex: String(format: "0x%02X", console))
                    DetailRawRow(title: "Process", value: japaneseProcess(process), hex: String(format: "0x%02X", process))
                    DetailRawRow(title: "Payment Type", value: paymentType(payType), hex: String(format: "0x%02X", payType))
                    DetailRawRow(title: "Entry/Exit", value: ioTypeStatus(ioType), hex: String(format: "0x%02X", ioType))
                }
                
                let rawDate = Int(data[4]) << 8 | Int(data[5])
                let dateStr = String(format: "%02d-%02d-%02d", (rawDate >> 9) & 0x7F, (rawDate >> 5) & 0x0F, rawDate & 0x1F)
                DetailRawRow(title: "Processing Date", value: "20\(dateStr)", hex: data.subdata(in: 4..<6).hexString)
                
                if console == 199 || console == 200 || process == 70 || process == 198 || process == 203 {
                    let timeData = Int(data[6]) << 8 | Int(data[7])
                    let hour = (timeData >> 11) & 0x1F
                    let minute = (timeData >> 5) & 0x3F
                    let second = (timeData & 0x1F) * 2
                    let timeStr = String(format: "%02d:%02d:%02d", hour, minute, second)
                    DetailRawRow(title: "Processing Time", value: timeStr, hex: data.subdata(in: 6..<8).hexString)
                    
                    let shopTerm = data.subdata(in: 8..<10).hexString.uppercased()
                    DetailRawRow(title: "Vending Terminal ID", value: shopTerm, hex: "")
                } else {
                    let entryLow = Int(data[6]) << 8 | Int(data[7])
                    let exitLow = Int(data[8]) << 8 | Int(data[9])
                    
                    if process == 13 || process == 15 {
                        let operatorName = BusResolver.shared.resolve(entryLow) ?? "Bus Operator \(String(format: "%04X", entryLow))"
                        let stopName = exitLow == 0 ? "N/A" : "Station \(String(format: "%04X", exitLow))"
                        
                        DetailRawRow(title: "Bus Operator", value: operatorName, hex: String(format: "0x%04X", entryLow))
                        DetailRawRow(title: "Bus Station", value: stopName, hex: String(format: "0x%04X", exitLow))
                    } else {
                        let fullEntryCode = (r1 << 16) | entryLow
                        let fullExitCode = (r1 << 16) | exitLow
                        
                        let entryName = StationResolver.shared.resolve(fullEntryCode) ?? "(Region \(r1)) Station \(String(format: "%04X", entryLow))"
                        let exitName = StationResolver.shared.resolve(fullExitCode) ?? (exitLow == 0 ? nil : "(Region \(r1)) Station \(String(format: "%04X", exitLow))")
                        
                        DetailRawRow(title: "Entry Station", value: entryName, hex: "\(r1)-[0x\(String(format: "%04X", entryLow))]")
                        if let exit = exitName {
                            DetailRawRow(title: "Exit Station", value: exit, hex: "\(r1)-[0x\(String(format: "%04X", exitLow))]")
                        } else {
                            DetailRawRow(title: "Exit Station", value: "None", hex: "")
                        }
                    }
                }
                
                let balance = Int(data[10]) | (Int(data[11]) << 8)
                DetailRawRow(title: "Balance", value: "¥\(balance)", hex: data.subdata(in: 10..<12).hexString)
                
                // byte 12 remains unknown
                DetailRawRow(title: "Unknown (Byte 12)", value: String(format: "0x%02X", data[12]), hex: "")
                
                // Byte 13, 14 Transaction serial
                let serial = Int(data[13]) << 8 | Int(data[14])
                DetailRawRow(title: "Transaction Serial", value: "\(serial)", hex: data.subdata(in: 13..<15).hexString)
                
                // Byte 15 Station Region Code
                DetailRawRow(title: "Station Region Code", value: "\(r1), \(r2)", hex: String(format: "0x%02X", regionFull))
            }
        }
        .padding(.top, 4)
    }
    
    private func paymentType(_ type: UInt8) -> String {
        Localizer.localize(String(format: "pay_%02X", type))
    }
    
    private func ioTypeStatus(_ type: UInt8) -> String {
        Localizer.localize(String(format: "io_%02X", type))
    }
    
    // Copy-pasted helper from decoder for UI
    private func japaneseTerminal(_ console: UInt8) -> String {
        Localizer.localize("suica_terminal_\(console)")
    }
    private func japaneseProcess(_ process: UInt8) -> String {
        Localizer.localize("suica_process_\(process)")
    }
}

struct DetailRawRow: View {
    let title: String
    let value: String
    let hex: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value)
                if !hex.isEmpty {
                    Text("[\(hex)]").font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// octopusOffset moved to end of file
// formatFeliCaIDm moved to end of file

extension Data {
    var hexString: String { map { String(format: "%02X", $0) }.joined() }
    
    func sliceHexString(start: Int, length: Int) -> String {
        guard start >= 0, length > 0, count >= start + length else { return "Unavailable" }
        return self[start..<(start + length)].map { String(format: "%02X", $0) }.joined()
    }
    
    func bigEndianInt(start: Int, length: Int) -> Int {
        guard start >= 0, length > 0, count >= start + length else { return 0 }
        return self[start..<(start + length)].reduce(0) { ($0 << 8) | Int($1) }
    }
    
    var systemCodeCandidates: [String] {
        guard count >= 1 else { return [] }
        let count = Int(self[0])
        var candidates: [String] = []
        for i in 0..<count {
            let start = 1 + (i * 2)
            guard self.count >= start + 2 else { break }
            candidates.append(self[start..<(start+2)].hexString.uppercased())
        }
        return candidates
    }
}


struct BERTLVNode {
    let tag: [UInt8]
    let value: Data
    var isConstructed: Bool {
        guard let first = tag.first else { return false }
        return (first & 0x20) != 0
    }
}

func findTLVValue(tag targetTag: [UInt8], in data: Data) -> Data? {
    parseBERTLVs(in: data).lazy.compactMap { node -> Data? in
        if node.tag == targetTag { return node.value }
        if node.isConstructed { return findTLVValue(tag: targetTag, in: node.value) }
        return nil
    }.first
}

func parseBERTLVs(in data: Data) -> [BERTLVNode] {
    var nodes: [BERTLVNode] = []
    var index = data.startIndex
    while index < data.endIndex {
        let tagStart = index
        index = data.index(after: index)
        if data[tagStart] & 0x1F == 0x1F {
            while index < data.endIndex {
                let byte = data[index]
                index = data.index(after: index)
                if byte & 0x80 == 0 { break }
            }
        }
        let tagEnd = index
        guard index < data.endIndex else { break }
        let firstLengthByte = data[index]
        index = data.index(after: index)
        let length: Int
        if firstLengthByte & 0x80 == 0 {
            length = Int(firstLengthByte)
        } else {
            let byteCount = Int(firstLengthByte & 0x7F)
            guard byteCount > 0, data.distance(from: index, to: data.endIndex) >= byteCount else { break }
            var accumulated = 0
            for _ in 0..<byteCount {
                accumulated = (accumulated << 8) | Int(data[index]); index = data.index(after: index)
            }
            length = accumulated
        }
        guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else { break }
        let valueEnd = data.index(index, offsetBy: length)
        nodes.append(BERTLVNode(tag: Array(data[tagStart..<tagEnd]), value: Data(data[index..<valueEnd])))
        index = valueEnd
    }
    return nodes
}

extension String {
    func binaryDecimalString() -> String { String(Int(self, radix: 2) ?? 0) }
}

func formatCurrency(amount: Decimal, code: String, fractionDigits: Int = 0) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = code
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    return formatter.string(from: amount as NSDecimalNumber) ?? "\(code) \(amount)"
}

func octopusOffset(for date: Date) -> Int {
    let calendar = Calendar.current
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    if let year = components.year, let month = components.month, let day = components.day {
        if year > 2010 || (year == 2010 && month > 12) || (year == 2010 && month == 12 && day >= 1) {
            return 350
        }
    }
    return 35
}

func formatFeliCaIDm(_ idm: String) -> String {
    let clean = idm.uppercased()
    guard clean.count == 16 else { return clean }
    return stride(from: 0, to: 16, by: 4).map { index in
        let start = clean.index(clean.startIndex, offsetBy: index)
        let end = clean.index(start, offsetBy: 4)
        return String(clean[start..<end])
    }.joined(separator: " ")
}

func formatFeliCaIDi(_ data: Data) -> String {
    guard data.count >= 8 else { return data.hexString }

    let issuerHex = data.subdata(in: 0..<2).hexString.uppercased()
    let remainder = data.subdata(in: 2..<4).hexString.uppercased()
    let issuer: String
    switch issuerHex {
    case "0102": issuer = "JH"
    case "0103": issuer = "JE"
    case "0104": issuer = "JC"
    case "0105": issuer = "JW"
    case "0107": issuer = "JK"
    case "0252": issuer = "PB"
    case "0387": issuer = "TP"
    case "04AD": issuer = "SU"
    case "05D5": issuer = "NR"
    case "05D7": issuer = "FC"
    default: issuer = issuerHex
    }

    let value = (Int(data[4]) << 8) | Int(data[5])
    let datePart = String(format: "%02d%02d%02d", (value >> 9) & 0x3F, (value >> 5) & 0x0F, value & 0x1F)
    let tail = String(format: "%05d", (Int(data[6]) << 8) | Int(data[7]))
    return "\(issuer)\(remainder)\(datePart)\(tail)"
}
