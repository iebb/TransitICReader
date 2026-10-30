import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Vision
import AVFoundation

enum KoreanTripCrowdsourcingPreferences {
    static let enabledKey = "koreanTripCrowdsourcingEnabled"
    static let promptedKey = "koreanTripCrowdsourcingPrompted"
    static let endpointKey = "koreanTripCrowdsourcingEndpoint"
    static let uploadedHashesKey = "koreanTripCrowdsourcingUploadedHashes"
}

struct KoreanTripCrowdsourcingRecord: Codable {
    let dedupHash: String
    let hashedCardID: String
    let cardIDLast4: String
    let bytes0508: String
    let bytes090A: String
    let allBytes: String
    let cardFamily: String
}

private struct KoreanTripCrowdsourcingEnvelope: Codable {
    let records: [KoreanTripCrowdsourcingRecord]
    let source: String
    let appVersion: String
}

private struct KoreanTripCrowdsourcingResponse: Decodable {
    let accepted: Int?
    let duplicates: Int?
}

struct CardBalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum KoreanTripCrowdsourcing {
    static func isEligible(snapshot: TransitCardSnapshot) -> Bool {
        guard snapshot.technology == "ISO7816" else { return false }
        guard snapshot.brand == .tmoney || snapshot.brand == .ezl else { return false }
        guard !snapshot.rawTransitHistory.isEmpty else { return false }
        return stableCardID(for: snapshot) != nil
    }

    static func stableCardID(for snapshot: TransitCardSnapshot) -> String? {
        let raw = (snapshot.realSerialNumber?.isEmpty == false ? snapshot.realSerialNumber : snapshot.identifierValue) ?? snapshot.rawIdentifierValue
        let normalized = normalizeCardID(raw)
        return normalized.isEmpty ? nil : normalized
    }

    static func makeRecords(from snapshot: TransitCardSnapshot) -> [KoreanTripCrowdsourcingRecord] {
        guard let stableCardID = stableCardID(for: snapshot) else { return [] }
        let hashedCardID = sha256Hex(stableCardID)
        let last4 = String(stableCardID.suffix(4))

        return snapshot.rawTransitHistory.compactMap { hex in
            let normalizedHex = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let data = Data(hexString: normalizedHex)
            guard !data.isEmpty else { return nil }

            let bytes0508 = data.count >= 9 ? data.subdata(in: 5..<9).hexString.uppercased() : ""
            let bytes090A = data.count >= 11 ? data.subdata(in: 9..<11).hexString.uppercased() : ""
            let dedupHash = sha256Hex(stableCardID + normalizedHex)

            return KoreanTripCrowdsourcingRecord(
                dedupHash: dedupHash,
                hashedCardID: hashedCardID,
                cardIDLast4: last4,
                bytes0508: bytes0508,
                bytes090A: bytes090A,
                allBytes: normalizedHex,
                cardFamily: snapshot.cardFamily
            )
        }
    }

    private static func normalizeCardID(_ value: String?) -> String {
        (value ?? "")
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

actor KoreanTripCrowdsourcingUploader {
    static let shared = KoreanTripCrowdsourcingUploader()

    private let session: URLSession = .shared
    private var uploadedHashes: Set<String>

    private init() {
        uploadedHashes = Set(UserDefaults.standard.stringArray(forKey: KoreanTripCrowdsourcingPreferences.uploadedHashesKey) ?? [])
    }

    func uploadEligibleRecords(from snapshot: TransitCardSnapshot) async {
        guard UserDefaults.standard.bool(forKey: KoreanTripCrowdsourcingPreferences.enabledKey) else { return }
        guard KoreanTripCrowdsourcing.isEligible(snapshot: snapshot) else { return }
        guard let endpointString = UserDefaults.standard.string(forKey: KoreanTripCrowdsourcingPreferences.endpointKey),
              let url = URL(string: endpointString) else { return }

        let freshRecords = KoreanTripCrowdsourcing.makeRecords(from: snapshot).filter { !uploadedHashes.contains($0.dedupHash) }
        guard !freshRecords.isEmpty else { return }

        let envelope = KoreanTripCrowdsourcingEnvelope(
            records: freshRecords,
            source: "cardbal-ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(envelope)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return
            }

            _ = try? JSONDecoder().decode(KoreanTripCrowdsourcingResponse.self, from: data)
            for record in freshRecords {
                uploadedHashes.insert(record.dedupHash)
            }
            UserDefaults.standard.set(Array(uploadedHashes.prefix(5000)), forKey: KoreanTripCrowdsourcingPreferences.uploadedHashesKey)
        } catch {
            return
        }
    }
}

struct ContentView: View {
    @StateObject private var reader = NFCTransitReader()
    @StateObject private var cardStore = CardWalletStore()

    @State private var selectedTab: Int = {
        #if targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["CARDBAL_PREVIEW_TAB"],
           let tab = Int(value), (0...4).contains(tab) { return tab }
        #endif
        return 0
    }()
    @State private var showKoreanCrowdsourcingPrompt = false
    @State private var pendingKoreanCrowdsourcingSnapshot: TransitCardSnapshot?
    @AppStorage(KoreanTripCrowdsourcingPreferences.enabledKey) private var koreanTripCrowdsourcingEnabled = false
    @AppStorage(KoreanTripCrowdsourcingPreferences.promptedKey) private var koreanTripCrowdsourcingPrompted = false

    var body: some View {
        TabView(selection: $selectedTab) {
            ScanHomeView(reader: reader, cardStore: cardStore)
                .tabItem {
                    Label("Scan", systemImage: "sensor.tag.radiowaves.forward.fill")
                }
                .tag(0)
            
            CardsView(store: cardStore, reader: reader)
                .tabItem {
                    Label("Cards", systemImage: "wallet.bifold.fill")
                }
                .tag(1)

            RideMapTabView(store: cardStore)
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(2)

            CityAtlasTabView(store: cardStore)
                .tabItem {
                    Label("Cities", systemImage: "globe.asia.australia.fill")
                }
                .tag(3)

            SettingsView(store: cardStore, reader: reader)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
        .modifier(AdaptiveTabPlacement())
        .tint(Color.accentColor)
        .onChange(of: reader.latestSnapshot?.id) { _ in
            if let snapshot = reader.latestSnapshot {
                cardStore.upsert(snapshot: snapshot)
                handleKoreanCrowdsourcing(for: snapshot)
            }
        }
        .alert("Join Korean Card Crowdsourcing?", isPresented: $showKoreanCrowdsourcingPrompt, presenting: pendingKoreanCrowdsourcingSnapshot) { snapshot in
            Button("Not Now", role: .cancel) {
                koreanTripCrowdsourcingPrompted = true
                koreanTripCrowdsourcingEnabled = false
                pendingKoreanCrowdsourcingSnapshot = nil
            }
            Button("Opt In") {
                koreanTripCrowdsourcingPrompted = true
                koreanTripCrowdsourcingEnabled = true
                Task {
                    await KoreanTripCrowdsourcingUploader.shared.uploadEligibleRecords(from: snapshot)
                }
                pendingKoreanCrowdsourcingSnapshot = nil
            }
        } message: { _ in
            Text("Upload technical trip records from eligible Korean cards such as T-money and EZL/Cashbee to help analyze South Korea trip record formats. Uploaded data includes a deduplication hash, a hashed card ID, the last 4 characters of the card ID, bytes 0x05-0x08, bytes 0x09-0x0A, and the full raw record bytes. This uses HTTPS and can be turned off or on at any time in Settings.")
        }
    }

    private func handleKoreanCrowdsourcing(for snapshot: TransitCardSnapshot) {
        guard KoreanTripCrowdsourcing.isEligible(snapshot: snapshot) else { return }
        if !koreanTripCrowdsourcingPrompted {
            pendingKoreanCrowdsourcingSnapshot = snapshot
            showKoreanCrowdsourcingPrompt = true
            return
        }
        guard koreanTripCrowdsourcingEnabled else { return }
        Task {
            await KoreanTripCrowdsourcingUploader.shared.uploadEligibleRecords(from: snapshot)
        }
    }
}

private struct AdaptiveTabPlacement: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.defaultTabBarPlacement(.sidebar)
        } else if #available(iOS 18.0, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

struct ScanHomeView: View {
    @ObservedObject var reader: NFCTransitReader
    @ObservedObject var cardStore: CardWalletStore
    @State private var activeHistoryItem: HistorySheetItem?
    @State private var isShowingSNScanner = false
    @State private var didAutoStartScan = false
    @State private var detailRoute: CardDetailRoute?
    @State private var calypsoOnlineLookup: CalypsoOnlineLookupState = .idle
    @AppStorage("hideWelcomeMessage") private var hideWelcomeMessage = false
    @AppStorage("scanOnLaunch") private var scanOnLaunch = true

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
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(Text("Dismiss"))
                            }
                            Text("Reads Suica, PASMO, ICOCA and other Japanese IC cards, nanaco, Rakuten Edy and WAON, T-money, EZL and Cashbee, U-Money, Octopus, China T-Union and City Union cards, and Lignes d’Azur.").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }

                Section("Card Reader") {
                    if !reader.requiresExternalReader {
                        Picker("Read Using", selection: $reader.prefersExternalReader) {
                            Text("iPhone NFC").tag(false)
                            Text("External Reader").tag(true)
                        }
                            .pickerStyle(.segmented)
                            .disabled(reader.isScanning)
                    }
                    if reader.requiresExternalReader {
                        Label("iPad and macOS require an external NFC card reader.", systemImage: "cable.connector")
                            .font(.subheadline)
                    }
                    if reader.usesExternalReader {
                        if !reader.isNFCAvailable {
                            Text("Connect a compatible USB smart-card reader.").foregroundStyle(.secondary)
                        }
                        if !reader.externalReaderNames.isEmpty || reader.selectedExternalReaderName != nil {
                            Picker("Reader", selection: $reader.selectedExternalReaderName) {
                                Text("Automatic").tag(nil as String?)
                                if let selected = reader.selectedExternalReaderName, !reader.externalReaderNames.contains(selected) {
                                    Text("\(selected) — Disconnected").tag(Optional(selected))
                                }
                                ForEach(reader.externalReaderNames, id: \.self) { name in
                                    Text(name).tag(Optional(name))
                                }
                            }.disabled(reader.isScanning)
                        }
                    } else {
                        Label("Hold the card near the top of your iPhone.", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if reader.showsScanStatus {
                        Label(reader.statusMessage, systemImage: reader.statusSymbol)
                            .foregroundStyle(reader.statusColor)
                            .font(.footnote)
                    } else if !reader.isNFCAvailable && !reader.usesExternalReader {
                        Text("NFC reading is not available.")
                            .foregroundStyle(.secondary).font(.footnote)
                    }
                    if reader.usesExternalReader && reader.isScanning {
                        Button("Cancel Scan") { reader.cancelExternalScan() }
                    }
                }

                if let snapshot = reader.latestSnapshot {
                    let cardToDisplay = bestDisplayCard(for: snapshot)
                    Section("Card Preview") {
                        WalletCardLayout {
                            GeometryReader { proxy in
                                let cardHeight = proxy.size.height
                                WalletCardView(
                                    card: cardToDisplay,
                                    isExpanded: true,
                                    cardHeight: cardHeight,
                                    visiblePartHeight: cardHeight,
                                    onVisibleTap: {},
                                    showDetails: { detailRoute = CardDetailRoute(id: cardToDisplay.id) },
                                    showTransactions: { activeHistoryItem = HistorySheetItem(mode: .transactions, card: cardToDisplay) },
                                    showTransit: { activeHistoryItem = HistorySheetItem(mode: .transit, card: cardToDisplay) }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        .sheet(item: $activeHistoryItem) { item in
                            QuickHistorySheet(mode: item.mode, card: item.card, store: cardStore)
                        }
                    }

                    Section("Result") {
                        KeyValueRow(title: "Card Family", value: snapshot.cardFamily)
                        
                        // Explicitly separate IDm and Physical S/N for FeliCa
                        if snapshot.technology == "FeliCa" {
                            KeyValueRow(title: "IDm", value: snapshot.identifierValue)
                        }
                        
                        ForEach(primaryResultFields(for: snapshot).filter { $0.title != "Card Number (IDm)" && $0.title != "IDm" }) { field in
                            KeyValueRow(title: field.title, value: field.value)
                        }
                        if let balance = snapshot.balanceText {
                            KeyValueRow(title: "Balance", value: balance)
                        }
                        KeyValueRow(title: "Scanned", value: KSX6924DateFormatting.formatRawDateForDisplay(snapshot.scannedAt))
                        
                        // Physical SN link/edit logic
                        let f = snapshot.cardFamily.lowercased()
                        if snapshot.technology == "FeliCa" && (snapshot.systemCode == "0003" || f.contains("japan") || f.contains("suica") || f.contains("pasmo") || f.contains("ic")) {
                            let sn = cardStore.card(withID: snapshot.storageIdentifier)?.realSerialNumber
                            HStack {
                                Label("Physical S/N", systemImage: "barcode.viewfinder").foregroundStyle(.secondary)
                                Spacer()
                                if let sn = sn {
                                    HStack(spacing: 8) {
                                        TextField("XX123 A456...", text: Binding(get: { sn }, set: { cardStore.setRealSerialNumber($0, for: snapshot.storageIdentifier) }))
                                            .multilineTextAlignment(.trailing)
                                            .textFieldStyle(.plain)
                                            .font(.system(.body, design: .monospaced))
                                        
                                        Button { isShowingSNScanner = true } label: {
                                            Image(systemName: "barcode.viewfinder").font(.caption)
                                        }.buttonStyle(.bordered).controlSize(.mini)
                                    }
                                } else {
                                    Button("Scan to Link") { isShowingSNScanner = true }
                                        .font(.caption.bold())
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }

                    if !snapshot.transactions.isEmpty {
                        Section("Recent Transactions") {
                            let sorted = sortTransactionsByRecency(snapshot.transactions)
                            ForEach(sorted) { tx in
                                TransitTransactionRow(tx: tx, cardFamily: snapshot.cardFamily, reportCard: cardToDisplay)
                                    .padding(.vertical, 4)
                            }
                        }
                    }

                    if !snapshot.transitHistory.isEmpty {
                        Section("Transit Activity") {
                            let sorted = sortTransactionsByRecency(snapshot.transitHistory)
                            ForEach(sorted) { tx in
                                TransitTransactionRow(tx: tx, cardFamily: snapshot.cardFamily, reportCard: cardToDisplay)
                                    .padding(.vertical, 4)
                            }
                        }
                    }

                    if !snapshot.rawSections.isEmpty {
                        Section("Raw Data") {
                            RawDataSectionList(snapshot: snapshot)
                        }
                    }
                    
                    if snapshot.cardFamily == "Lignes d'Azur card",
                       !niceTicketFields(from: snapshot).isEmpty {
                        Section("Tickets") {
                            NiceTicketSummaryCard(snapshot: snapshot)
                            ForEach(niceTicketFields(from: snapshot)) { field in
                                KeyValueRow(title: field.title, value: field.value)
                            }
                        }
                    }

                    if cardToDisplay.isCalypsoCard {
                        calypsoOnlineSection(card: cardToDisplay)
                    }
                } else if !reader.isScanning {
                    Section {
                        ScanPromptView(isExternal: reader.usesExternalReader, isReady: reader.isNFCAvailable) { reader.startScanning() }
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if reader.isScanning {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Scanning Card...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    }
                }

                Section("How to Scan") {
                    if reader.usesExternalReader {
                        Label("Place one card on the external reader, then press Scan.", systemImage: "externaldrive.connected.to.line.below")
                    } else {
                        Label("Hold the card flat against the top of your iPhone", systemImage: "iphone.radiowaves.left.and.right")
                    }
                    Label("Keep it still until the scan finishes", systemImage: "hand.raised.fill")
                    Label("For Apple Wallet cards, turn on Service Mode on the other device", systemImage: "wallet.pass")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("Scan")
            .toolbar {
                ScanToolbarItem(reader: reader)
            }
            .sheet(item: $detailRoute) { route in
                NavigationStack {
                    SavedCardDetailView(cardID: route.id, store: cardStore, initialSelection: route.tab)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailRoute = nil } } }
                }
                .presentationDetents(route.tab == .settings ? [.large] : [.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingSNScanner) {
                if let snapshot = reader.latestSnapshot {
                    FeliCaSNScannerView { sn in
                        cardStore.setRealSerialNumber(sn, for: snapshot.storageIdentifier)
                    }
                }
            }
            .onAppear { 
                guard !didAutoStartScan else { return }
                didAutoStartScan = true
                guard scanOnLaunch else { return }
                guard reader.isNFCAvailable else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard scanOnLaunch else { return }
                    guard reader.isNFCAvailable else { return }
                    reader.startScanning()
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

    @ViewBuilder
    private func calypsoOnlineSection(card: SavedCardRecord) -> some View {
        Section("Internet Query") {
            let serial = card.calypsoOnlineSerialNumber
            Button {
                checkCalypsoOnline(card: card)
            } label: {
                Label("Check Online", systemImage: "network")
            }
            .disabled(serial == nil || calypsoOnlineLookup.isLoading)

            if serial == nil {
                Text("No Nice card serial number decoded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch calypsoOnlineLookup {
            case .idle:
                EmptyView()
            case .loading:
                HStack {
                    ProgressView()
                    Text("Checking...")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
            case .loaded(let details):
                CalypsoOnlineSummaryView(details: details)
            }
        }
    }

    private func checkCalypsoOnline(card: SavedCardRecord) {
        guard let serial = card.calypsoOnlineSerialNumber else { return }
        calypsoOnlineLookup = .loading
        Task {
            do {
                let details = try await CalypsoOnlineClient.lookup(
                    mediaSerialNumber: serial,
                    mediaUnicity: card.calypsoMediaUnicity
                )
                await MainActor.run {
                    calypsoOnlineLookup = .loaded(details)
                }
            } catch {
                await MainActor.run {
                    calypsoOnlineLookup = .failed(error.localizedDescription)
                }
            }
        }
    }
}

struct CardsView: View {
    @ObservedObject var store: CardWalletStore
    @ObservedObject var reader: NFCTransitReader
    @State private var detailRoute: CardDetailRoute?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var previewCardID: String?
    @State private var activeHistoryItem: HistorySheetItem?

    private let stackedSpacing: CGFloat = 64
    private let expandedStackGap: CGFloat = 12
    private let cardAspectRatio: CGFloat = 27.0 / 17.0

    var body: some View {
        NavigationStack {
            Group {
                if store.cards.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "wallet.bifold")
                            .font(.system(size: 80))
                            .foregroundStyle(.secondary)
                        Text("No Cards Yet")
                            .font(.title.bold())
                        Text("Scan a physical card once and it will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { proxy in
                        let availableWidth = max(proxy.size.width - 40, 1)
                        let usesGrid = availableWidth >= 620 && !dynamicTypeSize.isAccessibilitySize
                        let cardWidth = min(availableWidth, WalletCardLayout.maximumWidth)
                        let cardHeight = cardWidth / cardAspectRatio

                        ScrollView {
                            if usesGrid {
                                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                                    ForEach(store.cards) { card in
                                        WalletCardLayout {
                                            GeometryReader { cardProxy in
                                                walletCard(card, height: cardProxy.size.height, expanded: true, visibleHeight: 0)
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: WalletCardLayout.maximumWidth * 2 + 20)
                                .padding(.horizontal, 20)
                                .frame(maxWidth: .infinity)
                            } else {
                                ZStack(alignment: .top) {
                                    ForEach(Array(store.cards.enumerated()), id: \.element.id) { index, card in
                                        walletCard(card, height: cardHeight, expanded: previewCardID == card.id,
                                                   visibleHeight: visibleTapHeight(for: index, cardHeight: cardHeight))
                                            .zIndex(zIndex(for: index))
                                            .offset(y: cardOffset(for: index, cardHeight: cardHeight))
                                    }
                                }
                                .frame(width: cardWidth, height: stackHeight(cardHeight: cardHeight), alignment: .top)
                                .frame(maxWidth: .infinity)
                                .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.cards)
                            }
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 20) }
                        .sheet(item: $activeHistoryItem) { item in
                            QuickHistorySheet(mode: item.mode, card: item.card, store: store)
                        }
                    }
                }
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Cards")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.cards.isEmpty {
                        NavigationLink {
                            ReorderCardsView(store: store)
                        } label: {
                            Image(systemName: "list.number")
                                .imageScale(.medium)
                                .accessibilityLabel(Text("Reorder Cards"))
                        }
                    }
                }
                ScanToolbarItem(reader: reader)
            }
            .sheet(item: $detailRoute) { route in
                NavigationStack {
                    SavedCardDetailView(cardID: route.id, store: store, initialSelection: route.tab)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { detailRoute = nil } } }
                }
            }
        }
    }

    private func walletCard(_ card: SavedCardRecord, height: CGFloat, expanded: Bool, visibleHeight: CGFloat) -> some View {
        WalletCardView(
            card: card,
            isExpanded: expanded,
            cardHeight: height,
            visiblePartHeight: visibleHeight,
            onVisibleTap: {
                if previewCardID == card.id {
                    previewCardID = nil
                } else {
                    store.bringToFront(card.id)
                    previewCardID = card.id
                }
            },
            showDetails: { detailRoute = CardDetailRoute(id: card.id) },
            showTransactions: { activeHistoryItem = HistorySheetItem(mode: .transactions, card: card) },
            showTransit: { activeHistoryItem = HistorySheetItem(mode: .transit, card: card) }
        )
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

struct RideMapTabView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        NavigationStack {
            RideMapView(store: store, initialCardID: nil, showsCardPicker: true)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: CardWalletStore
    @ObservedObject var reader: NFCTransitReader
    @AppStorage("scanOnLaunch") private var scanOnLaunch = true
    @AppStorage("dateFormat") private var dateFormat = "yyyy-MM-dd"
    @AppStorage("cardTimeZonePreference") private var cardTimeZonePreference = CardTimeZonePreference.issuer.rawValue
    @AppStorage("snDisplayMode") private var snDisplayMode = 0
    @AppStorage(KoreanTripCrowdsourcingPreferences.enabledKey) private var koreanTripCrowdsourcingEnabled = false
    @AppStorage(KoreanTripCrowdsourcingPreferences.promptedKey) private var koreanTripCrowdsourcingPrompted = false
    @AppStorage(DeveloperModePreferences.enabledKey) private var developerModeEnabled = false
    @State private var backupDocument = CardBalBackupDocument()
    @State private var isExportingBackup = false
    @State private var isImportingBackup = false
    @State private var backupMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Scan on Launch", isOn: $scanOnLaunch)
                    NavigationLink { displaySettings } label: {
                        Label("Display", systemImage: "calendar.badge.clock")
                    }
                    NavigationLink { CardFaceLibraryView(store: store) } label: {
                        Label("Card Faces", systemImage: "photo.stack")
                    }
                }
                Section {
                    NavigationLink { backupSettings } label: {
                        Label("Backup", systemImage: "icloud")
                    }
                    NavigationLink { privacySettings } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                }
                Section {
                    NavigationLink { advancedSettings } label: {
                        HStack {
                            Label("Advanced", systemImage: "slider.horizontal.3")
                            if developerModeEnabled {
                                Spacer()
                                Text("On").foregroundStyle(.secondary)
                            }
                        }
                    }
                    NavigationLink { aboutSettings } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
                Section("Community") {
                    Link(destination: URL(string: "https://cardb.al/support/")!) {
                        Label("Support", systemImage: "questionmark.circle")
                    }
                    Link(destination: URL(string: "https://github.com/iebb/TransitICReader")!) {
                        Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: URL(string: "https://t.me/cardbal")!) {
                        Label("Telegram Group", systemImage: "paperplane")
                    }
                }
                Section("Station Data") {
                    Link(destination: URL(string: "https://cardbal.ieb.app")!) {
                        Label("View Station Requests", systemImage: "mappin.and.ellipse")
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .fileExporter(
            isPresented: $isExportingBackup,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "cardbal-backup"
        ) { result in
            switch result {
            case .success:
                backupMessage = "Backup exported."
            case .failure(let error):
                backupMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $isImportingBackup,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let data = try Data(contentsOf: url)
                    let importResult = try store.importBackup(data)
                    backupMessage = "Imported \(importResult.imported) cards (\(importResult.replaced) replaced)."
                } catch {
                    backupMessage = "Import failed: \(error.localizedDescription)"
                }
            case .failure(let error):
                backupMessage = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private var displaySettings: some View {
        List {
            Section {
                Picker("Date Format", selection: $dateFormat) {
                    Text("YYYY-MM-DD").tag("yyyy-MM-dd")
                    Text("DD/MM/YYYY").tag("dd/MM/yyyy")
                    Text("MM/DD/YYYY").tag("MM/dd/yyyy")
                    Text("Abbreviated").tag("MMM d, yyyy")
                }
            }
            Section {
                Picker("Card Time Zone", selection: $cardTimeZonePreference) {
                    Text("Card Issuer's Time Zone").tag(CardTimeZonePreference.issuer.rawValue)
                    Text("Current Time Zone").tag(CardTimeZonePreference.current.rawValue)
                }
            } footer: {
                Text("China T-Union uses China Standard Time, Korean cards use Korea Standard Time, and U-Money uses Ulaanbaatar time when issuer time is selected.")
            }
        }
        .navigationTitle("Display")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var backupSettings: some View {
        List {
            Section("iCloud") {
                Button { store.backupToiCloud() } label: {
                    Label("Backup to iCloud", systemImage: "icloud.and.arrow.up")
                }
                .disabled(store.isSyncing)
                Button { store.restoreFromiCloud() } label: {
                    Label("Restore from iCloud", systemImage: "icloud.and.arrow.down")
                }
                .disabled(store.isSyncing)
                if store.isSyncing {
                    ProgressView(value: store.syncProgress)
                        .tint(.accentColor)
                }
                if let message = store.syncMessage {
                    Text(LocalizedStringKey(message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("File Backup") {
                Button {
                    if let data = store.exportBackup() {
                        backupDocument = CardBalBackupDocument(data: data)
                        isExportingBackup = true
                    }
                } label: {
                    Label("Export Backup", systemImage: "square.and.arrow.up")
                }
                .disabled(store.isSyncing)
                Button { isImportingBackup = true } label: {
                    Label("Import Backup", systemImage: "square.and.arrow.down")
                }
                .disabled(store.isSyncing)
                if let backupMessage {
                    Text(backupMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Backup")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var privacySettings: some View {
        List {
            Section {
                Picker("Serial Number Display", selection: $snDisplayMode) {
                    Text("Full").tag(0)
                    Text("Masked (Last Digits)").tag(1)
                    Text("Hidden").tag(2)
                }
            }
            Section {
                Toggle("Help Improve Korean Cards", isOn: Binding(
                    get: { koreanTripCrowdsourcingEnabled },
                    set: { newValue in
                        koreanTripCrowdsourcingPrompted = true
                        koreanTripCrowdsourcingEnabled = newValue
                    }
                ))
                DisclosureGroup("What is shared?") {
                    Text("When enabled, eligible T-money and EZL/Cashbee scans upload technical trip records for format analysis. Uploaded fields are a dedup hash of card ID plus raw bytes, a hashed card ID, the last 4 characters of the card ID, bytes 0x05-0x08, bytes 0x09-0x0A, and the full raw bytes. Uploads use HTTPS and you can disable this at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Optional. Share Korean card records to help improve decoding.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var advancedSettings: some View {
        List {
            Section {
                Toggle("Developer Mode", isOn: $developerModeEnabled)
            } footer: {
                Text("When enabled, KS X 6924 scans probe all SFIs with read-only APDUs and preserve every readable record and short-EF binary block in Raw Data. Scans take longer.")
            }
        }
        .navigationTitle("Advanced")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aboutSettings: some View {
        List {
            Section("Information") {
                HStack {
                    Text("App Version")
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
                Text("CardBal is an unofficial reader for transit cards. It does not use official APIs for ticketing.").font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                NavigationLink { creditsSettings } label: {
                    Text("Credits")
                }
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var creditsSettings: some View {
        List {
            Section("Credits") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Singapore station names and locations: LTA Train Station Codes and Chinese Names and TrainStation, accessed 31 October 2026, under the Singapore Open Data Licence v1.0. Country outline: Natural Earth (public domain).")
                        .font(.footnote)
                    Link("Singapore station data and licence", destination: URL(string: "https://datamall.lta.gov.sg/content/datamall/en/SingaporeOpenDataLicence.html")!)
                        .font(.footnote)

                    Text("Japan station data is based on Seo-4d696b75/station_database with supplemental matching against station20240426.csv.")
                        .font(.footnote)
                    Link("Open station_database on GitHub", destination: URL(string: "https://github.com/Seo-4d696b75/station_database")!)
                        .font(.footnote)
                    Text("China T-Union station data is based on domosekai/tripreader-data, the original source used by downstream projects.")
                        .font(.footnote)
                    Text("Licensed under Creative Commons Attribution 4.0 International.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Open tripreader-data on GitHub", destination: URL(string: "https://github.com/domosekai/tripreader-data")!)
                        .font(.footnote)
                    Link("Open CC BY 4.0 License", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                        .font(.footnote)
                    Text("OpenStreetMap geocoding and derived coordinates use OpenStreetMap data.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Open OpenStreetMap Copyright Page", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.footnote)
                    Text("East Asia city and province boundaries use geoBoundaries gbOpen data under CC BY 4.0. Japanese boundaries include OpenStreetMap-derived geometry under ODbL 1.0; supported Chinese city boundaries also use OpenStreetMap.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Open geoBoundaries", destination: URL(string: "https://www.geoboundaries.org/")!)
                        .font(.footnote)
                    Text("Korean station names and coordinates use the reviewed iebb/korean-stations export.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    DisclosureGroup("Korean public-data attributions") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Korean station data uses public datasets from KORAIL, MOLIT, Seoul, Busan, KRIC, Korea National Railway, Seoul Metro, and Daegu Transportation Corporation. Original source terms apply; Seoul open data is attributed under KOGL Type 1.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Link("Open MOLIT station data", destination: URL(string: "https://www.data.go.kr/data/15128614/fileData.do")!)
                            Text("Seoul Metropolitan Government · 서울시 역사마스터 정보 (2026) · KOGL Type 1")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Link("Open 서울시 역사마스터 정보", destination: URL(string: "https://data.seoul.go.kr/dataList/OA-21232/S/1/datasetView.do?tab=A")!)
                            Text("Seoul Metro · 서울교통공사_역명다국어표기_20260326 (2026) · KOGL Type 1")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Link("Open 서울교통공사 역명다국어표기", destination: URL(string: "https://www.data.go.kr/data/15044232/fileData.do")!)
                            Text("Seoul Big Data Campus · 서울시 대중교통 및 지하철 1회권 승하차 데이터 - 지하철정보.csv (2017–2026)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Link("Open Seoul Big Data station source", destination: URL(string: "https://bigdata.seoul.go.kr/data/selectSampleData.do?r_id=P213&sample_data_seq=13")!)
                            Link("Open Busan bus data", destination: URL(string: "https://www.data.go.kr/data/15092750/openapi.do")!)
                            Link("Open Busan station data", destination: URL(string: "https://www.data.go.kr/data/15043686/fileData.do")!)
                            Link("Open KRIC station data", destination: URL(string: "https://data.kric.go.kr/rips/M_01_01/detail.do?id=32")!)
                            Link("Open Daegu station data", destination: URL(string: "https://www.data.go.kr/data/15061835/fileData.do")!)
                            Link("Open KOGL Type 1 terms", destination: URL(string: "https://www.kogl.or.kr/info/licenseType1.do")!)
                        }
                    }
                    Text("Korean transport modes use KORAIL's KOTRIS public-transport code table.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Link("Open KORAIL KOTRIS data source", destination: URL(string: "https://www.data.go.kr/data/15121099/fileData.do")!)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("Credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CardDetailRoute: Identifiable {
    enum Selection { case settings, transactions, transit }
    let id: String
    var tab: Selection = .settings
}

struct ArchiveButton: View {
    let title: String
    let color: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}


func loadCardFaceImage(fileName: String) -> UIImage? {
    // 1. Try loading from Assets first (for presets)
    if let assetImage = UIImage(named: fileName) {
        return assetImage
    }
    
    // 2. Fallback to local file system
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let url = base.appendingPathComponent("CardBal/CardFaces", isDirectory: true).appendingPathComponent(fileName)
    return UIImage(contentsOfFile: url.path)
}

extension TransitCardSnapshot {
    var storageIdentifier: String {
        if let applications, let primary = TransitApplication.primary(in: applications) {
            return primary.identityAlias
        }
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
    return snapshot.resultFields.filter { field in
        !ticketTitles.contains(field.title) && !niceSuppressedFieldTitles.contains(field.title)
    }
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

let niceSuppressedFieldTitles = [
    "Media Serial Number",
    "Media Unicity"
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
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(field.value)
                                    .font(.footnote.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Button {
                                UIPasteboard.general.string = field.value
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Copy \(field.title)"))
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    static func systemCodeRow(_ codes: [String]) -> RawDataField {
        RawDataField(title: "System Codes", value: codes.joined(separator: ", "))
    }
}

/// Empty-state call to action on the Scan tab.
struct ScanPromptView: View {
    var isExternal = false
    var isReady = true
    let startScan: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.12)).frame(width: 112, height: 112)
                Circle().stroke(Color.accentColor.opacity(0.25), lineWidth: 1).frame(width: 140, height: 140)
                Image(systemName: "wave.3.right")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: 144)
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Ready to Read a Card")
                    .font(.title3.weight(.semibold))
                Text(isExternal ? String(localized: "Place a card on your selected external reader, then choose Scan.") : String(localized: "Hold a supported card to the top of your iPhone to read its balance, history and details."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: startScan) {
                Label("Scan a Card", systemImage: "sensor.tag.radiowaves.forward.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .disabled(!isReady)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct ScanToolbarItem: ToolbarContent {
    @ObservedObject var reader: NFCTransitReader
    
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                reader.startScanning()
            } label: {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .imageScale(.large)
                    .foregroundStyle(.primary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(reader.isScanning || !reader.isNFCAvailable)
            .accessibilityLabel(Text("Scan a Card"))
            .contextMenu {
                Button { reader.startScanning(options: [.iso18092, .iso14443, .iso15693]) } label: { Label("All Protocols", systemImage: "bolt.fill") }
                Button { reader.startScanning(options: [.iso18092]) } label: { Label("FeliCa", systemImage: "wave.3.left") }
                Button { reader.startScanning(options: [.iso14443]) } label: { Label("ISO 14443", systemImage: "creditcard.fill") }
            }
        }
    }
}

struct ReorderCardsView: View {
    @ObservedObject var store: CardWalletStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(store.cards) { card in
                HStack(spacing: 12) {
                    if let img = store.loadFaceImage(fileName: card.faceImageFileName), card.finalIsUsingImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 32, height: 20)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(card.color.color)
                            .frame(width: 32, height: 20)
                    }
                    
                    Text(card.displayTitle)
                        .font(.body.weight(.medium))                                                   
                    
                    Spacer()
                    
                    Text(card.privacyFormattedSerialNumber(mode: 1))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .onMove { from, to in
                store.moveCard(fromOffsets: from, toOffset: to)
            }
        }
        .navigationTitle("Order")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }
}
