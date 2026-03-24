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

enum TransactionCategory: String, Codable {
    case topUp
    case tapOn
    case tapOff
    case payment
    case purchase
    case adjustment
    case refund
    case bus
    case busOn
    case busOff
    case train
    case trainOn
    case trainOff
    case unknown
}

struct TransitTransaction: Identifiable, Hashable, Codable {
    let id: UUID
    let date: Date?
    let time: String?
    let amount: Decimal
    let terminalID: String?
    let recordNumber: Int?
    let ntsam: Int?
    let type: String
    let category: TransactionCategory
    let balanceAfter: Decimal?
    let location: String?
    let entryStation: String?
    let exitStation: String?
    let rawData: String?
    let distance: Double?
    
    init(date: Date?, time: String? = nil, amount: Decimal, terminalID: String?, type: String, category: TransactionCategory = .unknown, balanceAfter: Decimal? = nil, location: String? = nil, entryStation: String? = nil, exitStation: String? = nil, rawData: String? = nil, recordNumber: Int? = nil, ntsam: Int? = nil, distance: Double? = nil) {
        self.id = UUID()
        self.date = date
        self.time = time
        self.amount = amount
        self.terminalID = terminalID
        self.recordNumber = recordNumber
        self.ntsam = ntsam
        self.type = type
        self.category = category
        self.balanceAfter = balanceAfter
        self.location = location
        self.entryStation = entryStation
        self.exitStation = exitStation
        self.rawData = rawData
        self.distance = distance
    }
}

extension TransitTransaction {
    var iconInfo: (name: String, color: Color) {
        switch self.category {
        case .topUp: return ("arrow.down.left.circle.fill", .green)
        case .tapOn, .busOn: return ("bus.fill", .blue)
        case .tapOff, .busOff: return ("bus", .indigo)
        case .trainOn: return ("tram.fill", .blue)
        case .trainOff: return ("tram", .indigo)
        case .train: return ("tram.fill", .blue)
        case .purchase: return ("cart.fill", .orange)
        case .adjustment: return ("hammer.fill", .brown)
        case .refund: return ("arrow.uturn.left.circle.fill", .red)
        case .bus: return ("bus.fill", .cyan)
        case .payment, .unknown:
            let low = self.type.lowercased()
            if low.contains("top-up") || low.contains("charge") || low.contains("入金") { 
                return ("arrow.down.left.circle.fill", .green) 
            }
            if low.contains("tap on") || low.contains("tap-on") || low.contains("进站") || low.contains("入場") || low.contains("tapon") { 
                return ("bus.fill", .blue) 
            }
            if low.contains("tap off") || low.contains("tap-off") || low.contains("出站") || low.contains("出場") || low.contains("tapoff") { 
                return ("bus", .indigo) 
            }
            if low.contains("goods") || low.contains("物販") || low.contains("purchase") { 
                return ("cart.fill", .orange) 
            }
            if low.contains("bus") || low.contains("バス") { 
                return ("bus.fill", .cyan) 
            }
            if low.contains("fare") || low.contains("journey") || low.contains("gate") || low.contains("運賃") || self.entryStation != nil { 
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
    let transitHistory: [TransitTransaction]
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
                        let isRecordOnly = tx.time?.contains("Record #") ?? false
                        let isTimeMissing = tx.time == nil || isRecordOnly || tx.time?.lowercased() == "n/a"
                        
                        if let date = tx.date {
                            Text(date.formatted(date: .numeric, time: isTimeMissing ? .omitted : .complete))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else if let time = tx.time, !isRecordOnly {
                            Text(time).font(.caption).foregroundStyle(.secondary)
                        }
                        
                        if let loc = tx.location {
                            // Only show location if it's not just a duplicate of the time (common in Japanese IC purchase records)
                            let isTimeDuplicate = tx.time != nil && loc.contains(":") && loc.count <= 8 && tx.time!.contains(loc)
                            if !isTimeDuplicate {
                                Text("•").font(.caption).foregroundStyle(.tertiary)
                                Text(loc).font(.caption).foregroundStyle(.secondary)
                            }
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
                             formatCurrency(amount: abs(tx.amount), code: currencyCode, fractionDigits: cardFamily == "Octopus" ? 1 : 0))
                            .font(.headline.monospacedDigit().bold())
                    } else {
                        Text("No Charge")
                            .font(.headline.monospacedDigit().bold())
                            .foregroundStyle(.secondary)
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
        tx.iconInfo
    }
    
    private var currencyCode: String {
        if cardFamily == "Octopus" { return "HKD" }
        if cardFamily?.contains("China") == true { return "CNY" }
        let koreanFamilies = ["T-money", "NAMANE", "Climate Card", "EZL / Cashbee", "MOIBA", "K-Cash"]
        if let family = cardFamily, koreanFamilies.contains(family) { return "KRW" }
        return "JPY"
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
                    let f = (cardFamily ?? "").lowercased()
                    let isKorean = f.contains("namane") || f.contains("t-money") || f.contains("ks x") || f.contains("climate") || f.contains("ezl")
                    let isJapan = f.contains("japan") || f.contains("suica") || f.contains("pasmo") || f.contains("icoca")
                    let isNAMANE = f.contains("namane")
                    
                    LabeledContent {
                        Text(tx.type)
                    } label: {
                        HStack {
                            Circle().fill(tx.iconInfo.color).frame(width: 8, height: 8)
                            Text("Process")
                        }
                    }
                    
                    if let term = tx.terminalID, !isKorean {
                        LabeledContent("Terminal", value: term)
                    }
                    let lowType = tx.type.lowercased()
                    let isPurchase = tx.category == .purchase || lowType.contains("purchase") || lowType.contains("goods") || lowType.contains("物販")
                    let isRecordOnly = tx.time?.contains("Record #") ?? false
                    
                    if let date = tx.date, !isNAMANE, !isRecordOnly {
                        LabeledContent {
                            Text(date.formatted(date: .numeric, time: .omitted))
                        } label: {
                            HStack {
                                if isKorean { Circle().fill(.brown).frame(width: 8, height: 8) }
                                if isJapan { Circle().fill(.orange).frame(width: 8, height: 8) }
                                Text("Date")
                            }
                        }
                    }
                    if let time = tx.time, !isNAMANE, !isRecordOnly {
                        LabeledContent {
                            Text(time)
                        } label: {
                            HStack {
                                if isKorean { Circle().fill(.purple).frame(width: 8, height: 8) }
                                if isJapan { Circle().fill(.cyan).frame(width: 8, height: 8) }
                                Text("Time")
                            }
                        }
                    }
                    if let amount = tx.amount != 0 ? tx.amount : nil {
                        LabeledContent {
                            let signedAmount = (tx.type.lowercased().contains("top-up") || tx.type.lowercased().contains("charge") ? "+" : "-") + 
                                               formatCurrency(amount: abs(amount), code: currencyCode, fractionDigits: cardFamily == "Octopus" ? 1 : 0)
                            Text(signedAmount)
                        } label: {
                            HStack {
                                Circle().fill(.orange).frame(width: 8, height: 8)
                                Text("Amount")
                            }
                        }
                    }

                    if let balance = tx.balanceAfter {
                        LabeledContent {
                            Text(formatCurrency(amount: balance, code: currencyCode, fractionDigits: cardFamily == "Octopus" ? 1 : 0))
                        } label: {
                            HStack {
                                Circle().fill(.green).frame(width: 8, height: 8)
                                Text("Balance After")
                            }
                        }
                    }
                    
                    if let entry = tx.entryStation, !isPurchase {
                         LabeledContent {
                             Text(entry)
                         } label: {
                             HStack {
                                 Circle().fill(.cyan).frame(width: 8, height: 8)
                                 Text(tx.type.lowercased().contains("bus") ? "Operator" : "Entry")
                             }
                         }
                    }
                    if let exit = tx.exitStation, !isPurchase {
                         LabeledContent {
                             Text(exit)
                         } label: {
                             HStack {
                                 Circle().fill(.teal).frame(width: 8, height: 8)
                                 Text(tx.type.lowercased().contains("bus") ? "Station" : "Exit")
                             }
                         }
                    }
                    
                    if let loc = tx.location, !isNAMANE {
                         let isTimeOnly = loc.contains(":") && loc.count <= 8
                         if !isJapan || !isTimeOnly {
                             LabeledContent("Location", value: loc)
                         }
                    }

                    if isKorean {
                        let is52 = (tx.rawData?.count ?? 0) >= 104
                        
                        if let dist = tx.distance {
                            LabeledContent {
                                Text(String(format: "%.1f km", dist))
                            } label: {
                                HStack {
                                    Circle().fill(.indigo).frame(width: 8, height: 8)
                                    Text("Distance")
                                }
                            }
                        }
                        
                        if let tid = tx.terminalID {
                            LabeledContent {
                                Text(tid)
                            } label: {
                                HStack {
                                    Circle().fill(.cyan).frame(width: 8, height: 8)
                                    Text(is52 ? "Location Code" : "Terminal (IDSAM)")
                                }
                            }
                        }
                        if let ntsam = tx.ntsam, !is52 {
                            LabeledContent {
                                Text("\(ntsam)")
                            } label: {
                                HStack {
                                    Circle().fill(.indigo).frame(width: 8, height: 8)
                                    Text("NTSAM")
                                }
                            }
                        }
                        if let ntep = tx.recordNumber {
                            LabeledContent {
                                Text("\(ntep)")
                            } label: {
                                HStack {
                                    Circle().fill(.blue).frame(width: 8, height: 8)
                                    Text(is52 ? "Record Order" : "Record (NTEP)")
                                }
                            }
                        }
                    }
                }
                
                if let raw = tx.rawData {
                    Section("Raw Transaction Record") {
                        CardRawDataHighlightView(raw: raw, tx: tx, cardFamily: cardFamily ?? "")
                        
                        let f = (cardFamily ?? "").lowercased()
                        if f.contains("japan") || f.contains("suica") || f.contains("pasmo") {
                             SuicaRawBreakdownView(raw: raw)
                        } else if f.contains("t-money") || f.contains("ezl") || f.contains("namane") || f.contains("ks x") {
                             KoreanRawBreakdownView(raw: raw)
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
        if cardFamily == "Octopus" { return "HKD" }
        if cardFamily?.contains("China") == true { return "CNY" }
        let koreanFamilies = ["T-money", "NAMANE", "Climate Card", "EZL / Cashbee", "MOIBA", "K-Cash"]
        if let family = cardFamily, koreanFamilies.contains(family) { return "KRW" }
        return "JPY"
    }
}

struct KoreanRawBreakdownView: View {
    let raw: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let data = Data(hexString: raw)
            if data.count >= 52 {
                // T-Money Transit Record (52 bytes)
                let recType = data.subdata(in: 0..<2).hexString
                let tripState = data[2]
                let seq = data.bigEndianInt(start: 6, length: 2)
                let subtype = data[8]
                
                let dtRaw = UInt32(data.bigEndianInt(start: 11, length: 4))
                let dateWord = UInt16(dtRaw >> 16)
                let timeWord = UInt16(dtRaw & 0xFFFF)
                
                let year = 2000 + Int(dateWord >> 9)
                let month = Int((dateWord >> 5) & 0x0F)
                let day = Int(dateWord & 0x1F)
                let hour = Int(timeWord >> 11)
                let minute = Int((timeWord >> 5) & 0x3F)
                let second = Int(timeWord & 0x1F) * 2
                
                let ts = String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
                
                let distM = data.bigEndianInt(start: 18, length: 3)
                let amountMain = data.bigEndianInt(start: 22, length: 2)
                let baseFare = data.bigEndianInt(start: 40, length: 2)
                let locCode = data.bigEndianInt(start: 44, length: 2)
                
                Group {
                    DetailRawRow(title: "Record Type", value: recType, hex: "")
                    DetailRawRow(title: "Trip State", value: tripState == 0x01 ? "Exit / Closed" : "Entry / Open", hex: String(format: "0x%02X", tripState), color: .red)
                    DetailRawRow(title: "Unknown Header (Seq)", value: "\(seq)", hex: data.subdata(in: 6..<8).hexString, color: .blue)
                    DetailRawRow(title: "Trip Subtype", value: String(format: "0x%02X", subtype), hex: "")
                    DetailRawRow(title: "Packed Timestamp", value: ts, hex: data.subdata(in: 11..<15).hexString, color: .brown)
                    DetailRawRow(title: "Distance", value: "\(distM) m (\(Double(distM)/1000.0) km)", hex: data.subdata(in: 18..<21).hexString, color: .indigo)
                    DetailRawRow(title: "Main Fare", value: "₩\(amountMain)", hex: data.subdata(in: 22..<24).hexString, color: .orange)
                    DetailRawRow(title: "Base Fare", value: "₩\(baseFare)", hex: data.subdata(in: 40..<42).hexString, color: .indigo)
                    DetailRawRow(title: "Location Code", value: String(format: "%04X", locCode), hex: data.subdata(in: 44..<46).hexString, color: .cyan)
                }
            } else if data.count >= 33 {
                let type = data[0]
                let balance = data.bigEndianInt(start: 2, length: 4)
                let ntep = data.bigEndianInt(start: 6, length: 4)
                let fare = data.bigEndianInt(start: 10, length: 4)
                let idsam = data.subdata(in: 14..<22).hexString
                let ntsam = data.bigEndianInt(start: 22, length: 4)
                let bcdTime = data.subdata(in: 26..<33).hexString
                
                Group {
                    DetailRawRow(title: "Log Type", value: type == 0x02 ? "Top-up" : "Payment / Trip", hex: String(format: "0x%02X", type), color: .red)
                    DetailRawRow(title: "New Balance", value: "₩\(balance)", hex: data.subdata(in: 2..<6).hexString, color: .green)
                    DetailRawRow(title: "NTEP (Tx Number)", value: "\(ntep)", hex: data.subdata(in: 6..<10).hexString, color: .blue)
                    DetailRawRow(title: "M Fare", value: "₩\(fare)", hex: data.subdata(in: 10..<14).hexString, color: .orange)
                    DetailRawRow(title: "IDSAM (Terminal)", value: idsam, hex: "", color: .cyan)
                    DetailRawRow(title: "NTSAM (Terminal Count)", value: "\(ntsam)", hex: data.subdata(in: 22..<26).hexString, color: .indigo)
                    DetailRawRow(title: "BCD Timestamp", value: formatBCDDate(bcdTime), hex: bcdTime, color: .brown)
                }
            } else if data.count >= 18 {
                let cost = data.bigEndianInt(start: 10, length: 4)
                let balance = data.bigEndianInt(start: 14, length: 4)
                DetailRawRow(title: "Journey Cost", value: "₩\(cost)", hex: data.subdata(in: 10..<14).hexString, color: .orange)
                DetailRawRow(title: "Balance After", value: "₩\(balance)", hex: data.subdata(in: 14..<18).hexString, color: .green)
                if data.count >= 24 {
                    let km = Int(data[22]) * 256 + Int(data[23])
                    DetailRawRow(title: "Distance", value: "\(km) km", hex: data.subdata(in: 22..<24).hexString, color: .indigo)
                }
            }
        }
        .padding(.top, 4)
    }

    private func formatBCDDate(_ bcd: String) -> String {
        guard bcd.count >= 12 else { return bcd }
        return "\(bcd.prefix(4))-\(bcd.dropFirst(4).prefix(2))-\(bcd.dropFirst(6).prefix(2)) \(bcd.dropFirst(8).prefix(2)):\(bcd.dropFirst(10).prefix(2)):\(bcd.suffix(2))"
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
                    DetailRawRow(title: "Terminal", value: japaneseTerminal(console), hex: String(format: "0x%02X", console), color: .red)
                    DetailRawRow(title: "Process", value: japaneseProcess(process), hex: String(format: "0x%02X", process), color: .orange)
                    DetailRawRow(title: "Payment Type", value: paymentType(payType), hex: String(format: "0x%02X", payType), color: .purple)
                    DetailRawRow(title: "Entry/Exit", value: ioTypeStatus(ioType), hex: String(format: "0x%02X", ioType), color: .pink)
                }
                
                let rawDate = Int(data[4]) << 8 | Int(data[5])
                let dateStr = String(format: "%02d-%02d-%02d", (rawDate >> 9) & 0x7F, (rawDate >> 5) & 0x0F, rawDate & 0x1F)
                DetailRawRow(title: "Processing Date", value: "20\(dateStr)", hex: data.subdata(in: 4..<6).hexString, color: .brown)
                
                if console == 199 || console == 200 || process == 70 || process == 198 || process == 203 {
                    let timeData = Int(data[6]) << 8 | Int(data[7])
                    let hour = (timeData >> 11) & 0x1F
                    let minute = (timeData >> 5) & 0x3F
                    let second = (timeData & 0x1F) * 2
                    let timeStr = String(format: "%02d:%02d:%02d", hour, minute, second)
                    DetailRawRow(title: "Processing Time", value: timeStr, hex: data.subdata(in: 6..<8).hexString, color: .purple)
                    
                    let shopTerm = data.subdata(in: 8..<10).hexString.uppercased()
                    DetailRawRow(title: "Vending Terminal ID", value: shopTerm, hex: "", color: .cyan)
                } else {
                    let entryLow = Int(data[6]) << 8 | Int(data[7])
                    let exitLow = Int(data[8]) << 8 | Int(data[9])
                    
                    if process == 13 || process == 15 {
                        let operatorName = BusResolver.shared.resolve(entryLow) ?? "Bus Operator \(String(format: "%04X", entryLow))"
                        let stopName = exitLow == 0 ? "N/A" : "Station \(String(format: "%04X", exitLow))"
                        
                        DetailRawRow(title: "Bus Operator", value: operatorName, hex: String(format: "0x%04X", entryLow), color: .cyan)
                        DetailRawRow(title: "Bus Station", value: stopName, hex: String(format: "0x%04X", exitLow), color: .teal)
                    } else {
                        let fullEntryCode = (r1 << 16) | entryLow
                        let fullExitCode = (r1 << 16) | exitLow
                        
                        let entryName = StationResolver.shared.resolve(fullEntryCode) ?? "(Region \(r1)) Station \(String(format: "%04X", entryLow))"
                        let exitName = StationResolver.shared.resolve(fullExitCode) ?? (exitLow == 0 ? nil : "(Region \(r1)) Station \(String(format: "%04X", exitLow))")
                        
                        DetailRawRow(title: "Entry Station", value: entryName, hex: "\(r1)-[0x\(String(format: "%04X", entryLow))]", color: .cyan)
                        if let exit = exitName {
                            DetailRawRow(title: "Exit Station", value: exit, hex: "\(r1)-[0x\(String(format: "%04X", exitLow))]", color: .teal)
                        } else {
                            DetailRawRow(title: "Exit Station", value: "None", hex: "", color: .teal)
                        }
                    }
                }
                
                let balance = Int(data[10]) | (Int(data[11]) << 8)
                DetailRawRow(title: "Balance", value: "¥\(balance)", hex: data.subdata(in: 10..<12).hexString, color: .green)
                
                // byte 12 remains unknown
                DetailRawRow(title: "Unknown (Byte 12)", value: String(format: "0x%02X", data[12]), hex: "")
                
                // Byte 13, 14 Transaction serial
                let serial = Int(data[13]) << 8 | Int(data[14])
                DetailRawRow(title: "Transaction Serial", value: "\(serial)", hex: data.subdata(in: 13..<15).hexString, color: .blue)
                
                // Byte 15 Station Region Code
                DetailRawRow(title: "Station Region Code", value: "\(r1), \(r2)", hex: String(format: "0x%02X", regionFull), color: .indigo)
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
    var color: Color? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let color = color {
                    Circle().fill(color).frame(width: 8, height: 8)
                }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
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
    
    init(hexString: String) {
        var data = Data()
        // Strip everything except hex digits
        let hexDigits = hexString.replacingOccurrences(of: "[^0-9A-Fa-f]", with: "", options: .regularExpression)
        var text = hexDigits
        if text.count % 2 != 0 { text = "0" + text }
        
        var index = text.startIndex
        while index < text.endIndex {
            let nextIndex = text.index(index, offsetBy: 2)
            if let byte = UInt8(text[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        self = data
    }
    
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

struct CardRawDataHighlightView: View {
    let raw: String
    var tx: TransitTransaction? = nil
    let cardFamily: String
    @State private var copied = false
    
    var body: some View {
        let data = Data(hexString: raw)
        let highlights = getHighlights(for: cardFamily, tx: tx, dataCount: data.count)
        
        VStack(alignment: .leading, spacing: 10) {
            ForEach(0..<((data.count + 7) / 8), id: \.self) { row in
                HStack(spacing: 0) {
                    Text(String(format: "0x%02X: ", row * 8))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, 6)
                    
                    ForEach(0..<8, id: \.self) { col in
                        let index = row * 8 + col
                        if index < data.count {
                            let byte = data[index]
                            let color = highlights.first { $0.range.contains(index) }?.color ?? .primary
                            Text(String(format: "%02X", byte))
                                .font(.system(.body, design: .monospaced).bold())
                                .foregroundStyle(color)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(color.opacity(0.12))
                        } else {
                            Text("  ").padding(.horizontal, 4)
                        }
                    }
                }
            }
            if !highlights.isEmpty {
                Divider().padding(.vertical, 6)
                ForEach(highlights, id: \.label) { h in
                    HStack {
                        Circle().fill(h.color).frame(width: 8, height: 8)
                        Text(h.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .topTrailing) {
            Button {
                UIPasteboard.general.string = raw
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .bold))
                    if copied {
                        Text("Copied").font(.system(size: 10, weight: .bold)).transition(.opacity)
                    }
                }
                .foregroundStyle(copied ? .white : .primary.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(copied ? Color.green : Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
            .offset(x: 0, y: 0)
        }
    }
    
    struct Highlight {
        let range: Range<Int>
        let color: Color
        let label: String
    }
    
    private func getHighlights(for family: String, tx: TransitTransaction? = nil, dataCount: Int = 0) -> [Highlight] {
        let f = family.lowercased()
        if f.contains("namane") || f.contains("t-money") || f.contains("ks x") || f.contains("climate") || f.contains("ezl") {
            if dataCount >= 52 {
                return [
                    Highlight(range: 2..<3, color: .red, label: "Trip State"),
                    Highlight(range: 6..<8, color: .blue, label: "Sequence"),
                    Highlight(range: 11..<13, color: .brown, label: "Date Word"),
                    Highlight(range: 13..<15, color: .purple, label: "Time Word"),
                    Highlight(range: 18..<21, color: .indigo, label: "Distance"),
                    Highlight(range: 22..<24, color: .orange, label: "Main Fare"),
                    Highlight(range: 40..<42, color: .indigo, label: "Base Fare"),
                    Highlight(range: 44..<46, color: .cyan, label: "Location")
                ]
            } else {
                return [
                    Highlight(range: 0..<1, color: .red, label: "Type"),
                    Highlight(range: 2..<6, color: .green, label: "Balance After"),
                    Highlight(range: 6..<10, color: .blue, label: "NTEP (Counter)"),
                    Highlight(range: 10..<14, color: .orange, label: "Fare / Cost"),
                    Highlight(range: 14..<22, color: .cyan, label: "IDSAM (Terminal)"),
                    Highlight(range: 22..<26, color: .indigo, label: "NTSAM (Terminal Counter)"),
                    Highlight(range: 26..<33, color: .brown, label: "Timestamp (BCD)")
                ]
            }
        }
        
        let isJP = f.contains("suica") || f.contains("pasmo") || f.contains("icoca") || f.contains("kitaca") || 
                   f.contains("tobu") || f.contains("japan") || f.contains("feli") || f.contains("ic")
        if isJP && dataCount == 16 {
            let lowType = tx?.type.lowercased() ?? ""
            let isPurchase = tx?.category == .purchase || lowType.contains("purchase") || lowType.contains("goods") || lowType.contains("物販")
            
            return [
                Highlight(range: 0..<1, color: .red, label: "Console"),
                Highlight(range: 1..<2, color: tx?.iconInfo.color ?? .blue, label: "Process"),
                Highlight(range: 2..<3, color: .purple, label: "Payment"),
                Highlight(range: 3..<4, color: .pink, label: "E/E Flag"),
                Highlight(range: 4..<6, color: .orange, label: "Date"),
                Highlight(range: 6..<8, color: .cyan, label: isPurchase ? "Time" : "Entry Stn"),
                Highlight(range: 8..<10, color: .teal, label: isPurchase ? "Unk/Shop" : "Exit Stn"),
                Highlight(range: 10..<12, color: .green, label: "Balance (LE)"),
                Highlight(range: 12..<15, color: .gray, label: "Sequence"),
                Highlight(range: 15..<16, color: .brown, label: "Region")
            ]
        }
        
        return []
    }
}
