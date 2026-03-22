import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Vision
import AVFoundation

struct ContentView: View {
    @StateObject private var reader = NFCTransitReader()
    @StateObject private var cardStore = CardWalletStore()

    var body: some View {
        TabView {
            ScanHomeView(reader: reader, cardStore: cardStore)
                .tabItem { Label("Scan", systemImage: "dot.radiowaves.left.and.right") }
            CardsView(store: cardStore, reader: reader)
                .tabItem { Label("Cards", systemImage: "wallet.bifold") }
            SettingsView(store: cardStore)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color.accentColor)
        .onChange(of: reader.latestSnapshot?.id) { _ in
            if let snapshot = reader.latestSnapshot {
                cardStore.upsert(snapshot: snapshot)
            }
        }
    }
}

struct ScanHomeView: View {
    @ObservedObject var reader: NFCTransitReader
    @ObservedObject var cardStore: CardWalletStore
    @State private var didAutoStartScan = false
    @State private var detailRoute: CardDetailRoute?
    @AppStorage("hideWelcomeMessage") private var hideWelcomeMessage = false

    var body: some View {
        NavigationStack {
            List {
                if !hideWelcomeMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Scan Your Transit Card", systemImage: "wave.3.right.circle.fill").font(.title3.bold())
                                Spacer()
                                Button { withAnimation { hideWelcomeMessage = true } } label: { Image(systemName: "xmark").imageScale(.small).padding(6).background(Color(uiColor: .tertiarySystemFill), in: Circle()) }
                            }
                            Text("Scan physical transit cards like Suica, ICOCA, Hayakaken, Octopus, T-money, EZL/Cashbee, China T-Union and Lignes d'Azur, or Japanese SV cards such as Edy, waon, nanaco.").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }

                if let snapshot = reader.latestSnapshot {
                    let cardToDisplay = bestDisplayCard(for: snapshot)
                    Section("Card Preview") {
                        GeometryReader { proxy in
                            let cardWidth = max(proxy.size.width, 1)
                            let cardHeight = cardWidth / (85.6 / 53.98)
                            WalletCardView(card: cardToDisplay, isExpanded: true, cardHeight: cardHeight, visiblePartHeight: cardHeight, onVisibleTap: {}, showDetails: { 
                                detailRoute = CardDetailRoute(id: cardToDisplay.id)
                            })
                        }
                        .frame(height: (UIScreen.main.bounds.width - 40) / (85.6 / 53.98))
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }

                Section("Result") {
                    if let snapshot = reader.latestSnapshot {
                        KeyValueRow(title: "Card Family", value: snapshot.cardFamily)
                        ForEach(primaryResultFields(for: snapshot)) { field in
                            KeyValueRow(title: field.title, value: field.value)
                        }
                        if let balance = snapshot.balanceText {
                            KeyValueRow(title: "Balance", value: balance)
                        }
                        KeyValueRow(title: "Scanned", value: KSX6924DateFormatting.formatRawDateForDisplay(snapshot.scannedAt))
                    } else {
                        Text("No card scanned yet.").foregroundStyle(.secondary)
                    }
                }

                if let snapshot = reader.latestSnapshot, !snapshot.rawSections.isEmpty {
                    Section("Raw Data") {
                        RawDataSectionList(snapshot: snapshot)
                    }
                }

                if let snapshot = reader.latestSnapshot,
                   snapshot.cardFamily == "Lignes d'Azur card",
                   !niceTicketFields(from: snapshot).isEmpty {
                    Section("Tickets") {
                        NiceTicketSummaryCard(snapshot: snapshot)
                        ForEach(niceTicketFields(from: snapshot)) { field in
                            KeyValueRow(title: field.title, value: field.value)
                        }
                    }
                }

                Section("Instructions") {
                    Label("Hold card at the back top of the phone", systemImage: "iphone.radiowaves.left.and.right")
                    Label("Keep card steady until scan finishes", systemImage: "hand.tap.fill")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Scan")
            .toolbar {
                ScanToolbarItem(reader: reader)
            }
            .sheet(item: $detailRoute) { route in
                NavigationStack {
                    SavedCardDetailView(cardID: route.id, store: cardStore)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailRoute = nil } } }
                }
            }
            .onAppear { 
                let scanOnLaunch = UserDefaults.standard.bool(forKey: "scanOnLaunch")
                if !didAutoStartScan {
                    if scanOnLaunch {
                        reader.startScanning()
                    }
                    didAutoStartScan = true 
                } 
            }
        }
    }

    private func bestDisplayCard(for snapshot: TransitCardSnapshot) -> SavedCardRecord {
        if let saved = cardStore.card(withID: snapshot.storageIdentifier) {
            var updated = saved
            updated.balanceText = snapshot.balanceText
            updated.balanceDetail = snapshot.balanceDetail
            updated.scannedAt = snapshot.scannedAt
            updated.resultFields = snapshot.resultFields.map(SavedCardField.init)
            return updated
        }
        return snapshot.toCard()
    }
}

struct CardsView: View {
    @ObservedObject var store: CardWalletStore
    @ObservedObject var reader: NFCTransitReader
    @State private var detailRoute: CardDetailRoute?
    @State private var previewCardID: String?

    private let stackedSpacing: CGFloat = 58
    private let expandedStackGap: CGFloat = 12
    private let cardAspectRatio: CGFloat = 85.6 / 53.98

    var body: some View {
        NavigationStack {
            Group {
                if store.cards.isEmpty {
                    ContentUnavailableView(
                        "No Cards Yet",
                        systemImage: "wallet.bifold",
                        description: Text("Scan a physical card once and it will appear here.")
                    )
                } else {
                    GeometryReader { proxy in
                        let cardWidth = max(proxy.size.width - 40, 1)
                        let cardHeight = cardWidth / cardAspectRatio

                        ScrollView {
                            ZStack(alignment: .top) {
                                ForEach(Array(store.cards.enumerated()), id: \.element.id) { index, card in
                                    WalletCardView(
                                        card: card,
                                        isExpanded: previewCardID == card.id,
                                        cardHeight: cardHeight,
                                        visiblePartHeight: visibleTapHeight(for: index, cardHeight: cardHeight),
                                        onVisibleTap: {
                                            if previewCardID == card.id {
                                                previewCardID = nil
                                            } else {
                                                store.bringToFront(card.id)
                                                previewCardID = card.id
                                            }
                                        },
                                        showDetails: { detailRoute = CardDetailRoute(id: card.id) }
                                    )
                                    .padding(.horizontal, 20)
                                    .zIndex(zIndex(for: index))
                                    .offset(y: cardOffset(for: index, cardHeight: cardHeight))
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: stackHeight(cardHeight: cardHeight), alignment: .top)
                            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.cards)
                            .padding(.bottom, proxy.safeAreaInsets.bottom + 120)
                        }
                    }
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("Cards")
            .toolbar {
                ScanToolbarItem(reader: reader)
            }
            .sheet(item: $detailRoute) { route in
                NavigationStack {
                    SavedCardDetailView(cardID: route.id, store: store)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailRoute = nil } } }
                }
            }
        }
    }

    private func stackHeight(cardHeight: CGFloat) -> CGFloat {
        if previewCardID == nil {
            return CGFloat(max(store.cards.count - 1, 0)) * stackedSpacing + cardHeight
        }
        return cardHeight + expandedStackGap + CGFloat(max(store.cards.count - 1, 0)) * stackedSpacing
    }

    private func cardOffset(for index: Int, cardHeight: CGFloat) -> CGFloat {
        if previewCardID == nil {
            return CGFloat(index) * stackedSpacing
        }
        if index == 0 {
            return 0
        }
        return cardHeight + expandedStackGap + CGFloat(index - 1) * stackedSpacing
    }

    private func zIndex(for index: Int) -> Double {
        return Double(index)
    }

    private func visibleTapHeight(for index: Int, cardHeight: CGFloat) -> CGFloat {
        if previewCardID == nil {
            return index == 0 ? cardHeight : stackedSpacing
        }
        return index == 0 ? min(cardHeight * 0.3, 76) : stackedSpacing
    }
}

struct SettingsView: View {
    @ObservedObject var store: CardWalletStore
    @AppStorage("scanOnLaunch") private var scanOnLaunch = false
    @AppStorage("dateFormat") private var dateFormat = "yyyy-MM-dd"
    @AppStorage("snDisplayMode") private var snDisplayMode = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Card Faces") {
                    NavigationLink {
                        CardFaceLibraryView(store: store)
                    } label: {
                        Label("Manage Card Faces", systemImage: "photo.stack")
                    }
                }
                Section("Backup") {
                    if store.isSyncing {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: store.syncProgress)
                                .tint(.accentColor)
                            if let msg = store.syncMessage {
                                Text(msg)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .transition(.opacity)
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button { store.backupToiCloud() } label: { Label("Backup to iCloud", systemImage: "icloud.and.arrow.up") }
                        Button { store.restoreFromiCloud() } label: { Label("Restore from iCloud", systemImage: "icloud.and.arrow.down") }
                    }
                }
                Section("App Settings") {
                    Toggle("Scan on Launch", isOn: $scanOnLaunch)
                    Picker("Date Format", selection: $dateFormat) {
                        Text("YYYY-MM-DD").tag("yyyy-MM-dd")
                        Text("DD/MM/YYYY").tag("dd/MM/yyyy")
                        Text("MM/DD/YYYY").tag("MM/dd/yyyy")
                        Text("Abbreviated").tag("MMM d, yyyy")
                    }
                }
                Section("Privacy") {
                    Picker("Serial Number Display", selection: $snDisplayMode) {
                        Text("Full").tag(0)
                        Text("Masked (Last Digits)").tag(1)
                        Text("Hidden").tag(2)
                    }
                }
                Section("Information") {
                    HStack { Text("App Version"); Spacer(); Text("1.5.1").foregroundStyle(.secondary) }
                    Text("CardBal is an unofficial reader for transit cards. It does not use official APIs for ticketing.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

struct CardDetailRoute: Identifiable { let id: String }


func loadCardFaceImage(fileName: String) -> UIImage? {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let url = base.appendingPathComponent("CardBal/CardFaces", isDirectory: true).appendingPathComponent(fileName)
    return UIImage(contentsOfFile: url.path)
}

extension TransitCardSnapshot {
    var storageIdentifier: String {
        // Japanese FeliCa cards use stable IDm. 
        // Korean ISO7816 cards can use randomized UIDs, so favor internal SN.
        if technology == "ISO7816", let sn = realSerialNumber {
            return "\(technology)|\(sn)"
        }
        return "\(technology)|\(rawIdentifierValue)"
    }
    func toCard() -> SavedCardRecord {
        SavedCardRecord(snapshot: self)
    }
}

#Preview { ContentView() }

private func primaryResultFields(for snapshot: TransitCardSnapshot) -> [ResultField] {
    guard snapshot.cardFamily == "Lignes d'Azur card" else { return snapshot.resultFields }
    let ticketTitles = Set(niceTicketFieldTitles)
    return snapshot.resultFields.filter { !ticketTitles.contains($0.title) }
}

private func niceTicketFields(from snapshot: TransitCardSnapshot) -> [ResultField] {
    guard snapshot.cardFamily == "Lignes d'Azur card" else { return [] }
    let ticketTitles = Set(niceTicketFieldTitles)
    return snapshot.resultFields.filter { ticketTitles.contains($0.title) }
}

private let niceTicketFieldTitles = [
    "Loaded Tickets",
    "Ticket",
    "Ticket Family",
    "Contract Serial Number",
    "Product Code",
    "Sold At",
    "Remaining Trips",
    "Valid Until",
    "Last Ticket Event",
    "Route",
    "Ticket Status"
]

private struct NiceTicketSummaryCard: View {
    let snapshot: TransitCardSnapshot

    var body: some View {
        let ticket = value(for: "Ticket")
        let remainingTrips = value(for: "Remaining Trips")
        let validUntil = value(for: "Card Valid Until") ?? value(for: "Valid Until")

        if ticket != nil || remainingTrips != nil || validUntil != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ticket")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let ticket {
                    Text(ticket)
                        .font(.title3.weight(.semibold))
                }
                HStack(spacing: 12) {
                    if let remainingTrips {
                        ticketMetric(title: "Remaining", value: remainingTrips)
                    }
                    if let validUntil {
                        ticketMetric(title: "Valid Until", value: validUntil)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func value(for title: String) -> String? {
        snapshot.resultFields.first(where: { $0.title == title })?.value
    }

    @ViewBuilder
    private func ticketMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RawDataSectionList: View {
    let snapshot: TransitCardSnapshot

    var body: some View {
        ForEach(snapshot.rawSections) { section in
            DisclosureGroup(section.title) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.fields) { field in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(field.value)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 6)
            }
        }
    }
}

struct ScanToolbarItem: ToolbarContent {
    @ObservedObject var reader: NFCTransitReader
    
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { reader.startScanning(options: [.iso18092, .iso14443, .iso15693]) } label: { Label("All Protocols", systemImage: "bolt.fill") }
                Button { reader.startScanning(options: [.iso18092]) } label: { Label("FeliCa", systemImage: "wave.3.left") }
                Button { reader.startScanning(options: [.iso14443]) } label: { Label("ISO 14443", systemImage: "creditcard.fill") }
            } label: {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .imageScale(.large)
            } primaryAction: {
                reader.startScanning()
            }
            .disabled(reader.isScanning)
        }
    }
}
