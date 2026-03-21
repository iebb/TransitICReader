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
            CardsView(store: cardStore)
                .tabItem { Label("Cards", systemImage: "wallet.bifold") }
            SettingsView(store: cardStore)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Color.accentColor)
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
                                Label("CardBal Transit", systemImage: "wave.3.right.circle.fill").font(.title3.bold())
                                Spacer()
                                Button { withAnimation { hideWelcomeMessage = true } } label: { Image(systemName: "xmark").imageScale(.small).padding(6).background(Color(uiColor: .tertiarySystemFill), in: Circle()) }
                            }
                            Text("Scan physical transit cards like Suica, Octopus, T-money, and EZL/Cashbee.").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }

                Section("Result") {
                    if let snapshot = reader.latestSnapshot {
                        KeyValueRow(title: "Card Family", value: snapshot.cardFamily)
                        KeyValueRow(title: "Balance", value: snapshot.balanceText ?? "No balance")
                        KeyValueRow(title: "Scanned", value: snapshot.scannedAt.formatted(date: .abbreviated, time: .standard))
                        if let detail = snapshot.balanceDetail {
                            Text(detail).font(.footnote).foregroundStyle(.secondary).padding(.vertical, 2)
                        }
                    } else {
                        Text("No card scanned yet.").foregroundStyle(.secondary)
                    }
                }

                if let snapshot = reader.latestSnapshot, let savedCard = cardStore.card(withID: snapshot.storageIdentifier) {
                    Section("Saved Card") {
                        WalletCardView(card: savedCard, isExpanded: true, cardHeight: 200, visiblePartHeight: 120, onVisibleTap: {}, showDetails: { detailRoute = CardDetailRoute(id: savedCard.id) })
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }

                Section("Instructions") {
                    Label("Hold card at the back top of the phone", systemImage: "iphone.radiowaves.left.and.right")
                    Label("Keep card steady until scan finishes", systemImage: "hand.tap.fill")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Scan")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { reader.startScanning() } label: { Label("Start Scan", systemImage: "plus.circle.fill").font(.headline) }
                }
            }
            .sheet(item: $detailRoute) { route in
                NavigationStack {
                    SavedCardDetailView(cardID: route.id, store: cardStore)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailRoute = nil } } }
                }
            }
            .onAppear { if !didAutoStartScan { reader.startScanning(); didAutoStartScan = true } }
        }
    }
}

struct CardsView: View {
    @ObservedObject var store: CardWalletStore
    @State private var detailRoute: CardDetailRoute?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 20) {
                    if store.cards.isEmpty {
                        ContentUnavailableView("No Cards Saved", systemImage: "wallet.bifold", description: Text("Your scanned cards will appear here."))
                    } else {
                        ForEach(store.cards) { card in
                            WalletCardView(card: card, isExpanded: true, cardHeight: 200, visiblePartHeight: 120, onVisibleTap: {}, showDetails: { detailRoute = CardDetailRoute(id: card.id) })
                        }
                    }
                }.padding(16)
            }
            .navigationTitle("Wallet")
            .sheet(item: $detailRoute) { route in
                NavigationStack {
                    SavedCardDetailView(cardID: route.id, store: store)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailRoute = nil } } }
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: CardWalletStore
    var body: some View {
        NavigationStack {
            List {
                Section("Backup") {
                    Button { /* Export action */ } label: { Label("Export Backup", systemImage: "square.and.arrow.up") }
                    Button { /* Import action */ } label: { Label("Import Backup", systemImage: "square.and.arrow.down") }
                }
                Section("Information") {
                    HStack { Text("App Version"); Spacer(); Text("1.5.0").foregroundStyle(.secondary) }
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
    var storageIdentifier: String { "\(technology)|\(rawIdentifierValue)" }
}

#Preview { ContentView() }
