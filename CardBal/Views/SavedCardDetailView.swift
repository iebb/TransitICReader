import SwiftUI
import PhotosUI

struct SavedCardDetailView: View {
    private enum AppearanceMode: String, CaseIterable, Identifiable {
        case image = "Image", colors = "Colors"
        var id: String { rawValue }
    }

    let cardID: String
    @ObservedObject var store: CardWalletStore
    var initialSelection: CardDetailRoute.Selection = .settings
    @Environment(\.dismiss) private var dismiss

    @State private var viewSelection: CardDetailRoute.Selection = .settings
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var pendingFaceImage: UIImage?
    @State private var pendingAutoCroppedImage: UIImage?
    @State private var appearanceMode: AppearanceMode = .colors
    @State private var isShowingMarkerSheet = false
    @State private var isShowingSNScanner = false
    @State private var isShowingSavedFacePicker = false
    @State private var draftTitle: String?
    @State private var draftSerialNumber: String?
    @State private var titleTask: Task<Void, Never>?
    @State private var snTask: Task<Void, Never>?
    @State private var draftDeleteConfirmation = false
    @State private var activeHistoryItem: HistorySheetItem?
    @State private var pendingDeletions: Set<String> = []
    @State private var calypsoOnlineLookup: CalypsoOnlineLookupState = .idle

    var body: some View {
        if let card = store.card(withID: cardID) {
            detailContent(card: card)
                .onAppear { viewSelection = initialSelection }
                .sheet(item: $activeHistoryItem) { item in
                    QuickHistorySheet(mode: item.mode, card: item.card, store: store)
                }
        }
    }

    private func detailContent(card: SavedCardRecord) -> some View {
        cardDetailList(card: card)
            .navigationTitle(card.displayTitle)
            .onAppear { appearanceMode = card.finalIsUsingImage ? .image : .colors }
            .sheet(isPresented: $isShowingSNScanner) {
                snScannerSheet(card: card)
            }
            .sheet(isPresented: $isShowingMarkerSheet) {
                markerEditorSheet(card: card)
            }
            .sheet(isPresented: $isShowingSavedFacePicker) {
                savedFacePickerSheet(card: card)
            }
            .onChange(of: selectedPhotoItem) { newValue in
                handlePhotoSelection(newValue)
            }
            .fullScreenCover(isPresented: $isShowingCamera) {
                ImagePicker { image in
                    Task {
                        let result = await CardPhotoProcessor.process(image)
                        await MainActor.run {
                            pendingFaceImage = result.original
                            pendingAutoCroppedImage = result.autoCropped
                        }
                    }
                }
            }
            .sheet(item: editableFaceImageBinding()) { editable in
                faceImageEditorSheet(editable: editable, card: card)
            }
    }

    private func cardDetailList(card: SavedCardRecord) -> some View {
        List {
            if viewSelection == .settings {
                Section {
                    cardPreviewSection(card: card)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                
                Section("Card Information") {
                    cardInfoSection(card: card)
                }

                if let applications = card.applications, applications.count > 1 {
                    Section {
                        ForEach(applications) { application in
                            DisclosureGroup(application.label) {
                                if let number = application.serialNumber {
                                    KeyValueRow(title: "Card Number", value: number)
                                }
                                KeyValueRow(title: "Balance", value: application.balanceText ?? String(localized: "Unavailable"))
                                if let balanceReadAt = application.balanceReadAt {
                                    KeyValueRow(title: "Balance Read", value: KSX6924DateFormatting.formatRawDateForDisplay(balanceReadAt))
                                }
                                ForEach(application.fields.filter { $0.title != "Card Number" }) { field in
                                    KeyValueRow(title: field.title, value: field.value)
                                }
                            }
                        }
                    } header: {
                        Text("Card Applications")
                    } footer: {
                        Text("Balances are shown as reported by each application and are not added together.")
                    }
                }

                if card.supportsRideMap {
                    Section("Map") {
                        NavigationLink {
                            RideMapView(store: store, initialCardID: card.id, showsCardPicker: false)
                        } label: {
                            Label("View Ride Map", systemImage: "map")
                        }
                    }
                }

                Section("Export") {
                    ShareLink(
                        item: card.fullHexExportText,
                        preview: SharePreview("\(card.displayTitle) Hex Export")
                    ) {
                        Label("Export Full Hex Data", systemImage: "square.and.arrow.up")
                    }
                }

                if card.isCalypsoCard {
                    calypsoOnlineSection(card: card)
                }

                Section("Station Data") {
                    NavigationLink {
                        StationReportView(card: card)
                    } label: {
                        Label("Report or Correct a Station", systemImage: "mappin.and.ellipse")
                    }
                }

                Section("Customize") {
                    titleSection(card: card)
                }

                Section("Appearance") {
                    appearanceSection(card: card)
                }

                Section {
                        Button("Delete Card", role: .destructive) {
                            draftDeleteConfirmation = true
                        }
                    }
                } else if viewSelection == .transactions {
                    transactionsSection(card: card)
                } else if viewSelection == .transit {
                    transitHistorySection(card: card)
                }
        }
        .alert("Delete Card?", isPresented: $draftDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteCard(card.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved card from your wallet.")
        }
    }

    @ViewBuilder
    private func cardPreviewSection(card: SavedCardRecord) -> some View {
        WalletCardLayout {
            GeometryReader { proxy in
                WalletCardView(
                    card: card,
                    isExpanded: true,
                    cardHeight: proxy.size.height,
                    visiblePartHeight: 0,
                    onVisibleTap: {},
                    showDetails: {},
                    showTransactions: { activeHistoryItem = HistorySheetItem(mode: .transactions, card: card) },
                    showTransit: { activeHistoryItem = HistorySheetItem(mode: .transit, card: card) }
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func titleSection(card: SavedCardRecord) -> some View {
        Button { isShowingMarkerSheet = true } label: {
            HStack { 
                Text("Icon").foregroundStyle(.primary)
                Spacer()
                MarkerPreviewBadge(card: card)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary) 
            }
        }.buttonStyle(.plain)

        HStack { 
            Text("Name").foregroundStyle(.secondary)
            Spacer()
            TextField("Card Title", text: titleBinding(card: card))
                .multilineTextAlignment(.trailing) 
        }

        HStack { 
            Text("S/N").foregroundStyle(.secondary)
            Spacer()
            TextField("S/N", text: snBinding(card: card))
                .multilineTextAlignment(.trailing)
            if card.technology == "FeliCa" && card.systemCode == "0003" { 
                Button { isShowingSNScanner = true } label: { 
                    Image(systemName: "barcode.viewfinder").font(.title3).foregroundStyle(Color.accentColor) 
                }.buttonStyle(.plain) 
            } 
        }

        Toggle("Hide Title", isOn: Binding(get: { card.finalHideTitle }, set: { store.setHideTitleOnImage($0, for: card.id) }))
        Toggle("Hide Serial Number", isOn: Binding(get: { card.finalHideSN }, set: { store.setHideSerialNumber($0, for: card.id) }))
    }

    @ViewBuilder
    private func cardInfoSection(card: SavedCardRecord) -> some View {
        if !card.visibleBalance.isEmpty {
            KeyValueRow(title: "Balance", value: card.visibleBalance)
        }
        KeyValueRow(title: "Last Scanned", value: KSX6924DateFormatting.formatRawDateForDisplay(card.scannedAt))
        KeyValueRow(title: "Technology", value: card.technology == "ISO7816" ? "ISO 7816" : card.technology)
        if let brand = card.region ?? card.resultFields.first(where: { $0.title == "Brand" })?.value,
           !brand.isEmpty {
            KeyValueRow(title: "Brand", value: brand)
        }
        if let city = card.issuingCity { KeyValueRow(title: "Issuing City", value: city) }
        if let type = card.cardTypeStr { KeyValueRow(title: "Card Type", value: type) }
        if let issue = card.issueDateStr { KeyValueRow(title: "Issue Date", value: issue) }
        if let expiry = card.expiryDateStr { KeyValueRow(title: "Expiry Date", value: expiry) }
        
        if card.technology == "FeliCa", let sc = card.systemCode {
            KeyValueRow(title: "System Code", value: sc)
        }
        
        let metadataFields = card.resultFields.filter { !card.isCalypsoCard || !niceSuppressedFieldTitles.contains($0.title) }
        if !metadataFields.isEmpty {
             DisclosureGroup("All Decoded Metadata") {
                 VStack(alignment: .leading, spacing: 10) {
                     ForEach(metadataFields) { field in
                         HStack {
                             Text(field.title).font(.caption).foregroundStyle(.secondary)
                             Spacer()
                             Text(field.value).font(.caption).foregroundStyle(.primary)
                         }
                     }
                 }.padding(.vertical, 4)
             }
        }
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

            if let serial {
                KeyValueRow(title: "Media Serial Number", value: serial)
                KeyValueRow(title: "Media Unicity", value: "\(card.calypsoMediaUnicity)")
            } else {
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

    @ViewBuilder
    private func transactionsSection(card: SavedCardRecord) -> some View {
        Section("Transactions") {
            let sorted = sortTransactionsByRecency(card.transactions)
                .filter { tx in tx.rawData.map { !pendingDeletions.contains($0) } ?? true }
            if sorted.isEmpty {
                Text("No records found").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(sorted, id: \.stableID) { tx in
                    TransitTransactionRow(tx: tx, cardFamily: card.cardFamily, reportCard: card)
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let rawData = tx.rawData {
                                Button(role: .destructive) {
                                    pendingDeletions.insert(rawData)
                                    store.deleteLocalRecord(cardID: card.id, kind: .transactions, rawData: rawData, sourceRecordIDs: tx.sourceRecordIDs)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func transitHistorySection(card: SavedCardRecord) -> some View {
        Section("Transit Activity") {
            let sorted = sortTransactionsByRecency(card.transitHistory)
                .filter { tx in tx.rawData.map { !pendingDeletions.contains($0) } ?? true }
            if sorted.isEmpty {
                Text("No records found").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(sorted, id: \.stableID) { tx in
                    TransitTransactionRow(tx: tx, cardFamily: card.cardFamily, reportCard: card)
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let rawData = tx.rawData {
                                Button(role: .destructive) {
                                    pendingDeletions.insert(rawData)
                                    store.deleteLocalRecord(cardID: card.id, kind: .transit, rawData: rawData, sourceRecordIDs: tx.sourceRecordIDs)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder
    private func appearanceSection(card: SavedCardRecord) -> some View {
        Picker("Design Type", selection: $appearanceMode) { 
            Text("Colors").tag(AppearanceMode.colors)
            Text("Image").tag(AppearanceMode.image) 
        }
        .pickerStyle(.segmented)
        .onChange(of: appearanceMode) { mode in
            store.setIsUsingImage(mode == .image, for: card.id)
        }

        if appearanceMode == .image {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) { 
                Label("Choose From Gallery", systemImage: "photo") 
            }
            Button {
                isShowingSavedFacePicker = true
            } label: {
                Label("Choose From Preset Designs", systemImage: "square.stack.3d.up")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) { 
                Button { isShowingCamera = true } label: { Label("Take Photo", systemImage: "camera") } 
            }
            if card.faceImageFileName != nil {
                Button(role: .destructive) { store.removeFaceImage(for: card.id); appearanceMode = .colors } label: {
                    Label("Remove Current Photo", systemImage: "trash")
                }
            }
        } else {
            ColorPicker("Card Color", selection: Binding(get: { card.color.color }, set: { store.setColor($0, for: card.id) }), supportsOpacity: false)
            Picker("Style", selection: Binding(get: { card.design }, set: { store.setDesign($0, for: card.id) })) { 
                ForEach(SavedCardDesign.allCases) { d in Text(d.title).tag(d) } 
            }
        }
    }

    private func titleBinding(card: SavedCardRecord) -> Binding<String> {
        Binding(
            get: { draftTitle ?? card.customTitle ?? "" },
            set: { v in 
                draftTitle = v
                titleTask?.cancel()
                titleTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled { store.setCustomTitle(v, for: card.id) }
                }
            }
        )
    }

    private func snBinding(card: SavedCardRecord) -> Binding<String> {
        Binding(
            get: {
                draftSerialNumber ?? card.customDisplaySerialNumber ?? card.cardNumber ?? card.identifierValue
            },
            set: { v in 
                draftSerialNumber = v
                snTask?.cancel()
                snTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled { store.setCustomDisplaySerialNumber(v, for: card.id) }
                }
            }
        )
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                let result = await CardPhotoProcessor.process(image)
                await MainActor.run {
                    pendingFaceImage = result.original
                    pendingAutoCroppedImage = result.autoCropped
                }
            }
            await MainActor.run { selectedPhotoItem = nil }
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

    private func editableFaceImageBinding() -> Binding<EditableFaceImage?> {
        Binding(
            get: { pendingFaceImage.map(EditableFaceImage.init) },
            set: { newValue in
                pendingFaceImage = newValue?.image
                if newValue == nil { pendingAutoCroppedImage = nil }
            }
        )
    }

    private func snScannerSheet(card: SavedCardRecord) -> some View {
        FeliCaSNScannerView(
            onRecognized: { sn in
                store.setRealSerialNumber(sn, for: card.id)
            },
            onPhotoTaken: { image in
                pendingFaceImage = image
                pendingAutoCroppedImage = image  // Already processed by CardPhotoProcessor
            }
        )
    }

    private func markerEditorSheet(card: SavedCardRecord) -> some View {
        MarkerEditorSheet(cardID: card.id, store: store)
    }

    private func faceImageEditorSheet(editable: EditableFaceImage, card: SavedCardRecord) -> some View {
        FaceImageEditorSheet(
            image: editable.image,
            autoCroppedImage: pendingAutoCroppedImage,
            onCancel: { pendingFaceImage = nil; pendingAutoCroppedImage = nil },
            onSave: { image in
                store.setFaceImage(image, for: card.id)
                pendingFaceImage = nil
                pendingAutoCroppedImage = nil
            }
        )
    }

    private func savedFacePickerSheet(card: SavedCardRecord) -> some View {
        SavedFaceAssetPickerSheet(
            store: store,
            excludingFileName: card.faceImageFileName,
            onSelect: { fileName in
                store.applyFaceAsset(fileName, to: card.id)
                isShowingSavedFacePicker = false
            },
            onSelectPreset: { preset in
                store.applyPreset(preset, to: card.id)
                isShowingSavedFacePicker = false
            }
        )
    }
}

enum CalypsoOnlineLookupState {
    case idle
    case loading
    case loaded(CalypsoOnlineMediaDetails)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

struct CalypsoOnlineSummaryView: View {
    let details: CalypsoOnlineMediaDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KeyValueRow(title: "Status", value: details.statusText)
            if let expirationDate = details.expirationDateDisplay {
                KeyValueRow(title: "Expires", value: expirationDate)
            }
            if let contractNumber = details.contractNumber {
                KeyValueRow(title: "Contracts", value: "\(contractNumber)")
            }

            ForEach(Array(details.contracts.enumerated()), id: \.offset) { _, contract in
                VStack(alignment: .leading, spacing: 6) {
                    Text(contract.titleProduct?.nonEmpty ?? "Contract")
                        .font(.subheadline.weight(.semibold))
                    if let remaining = contract.remainingTripsText {
                        KeyValueRow(title: "Remaining Trips", value: remaining)
                    }
                    if let status = contract.statusValidity?.nonEmpty {
                        KeyValueRow(title: "Validity", value: status)
                    }
                    if let saleDate = contract.saleDateDisplay {
                        KeyValueRow(title: "Sale Date", value: saleDate)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

enum CalypsoOnlineClient {
    static func lookup(mediaSerialNumber: String, mediaUnicity: Int) async throws -> CalypsoOnlineMediaDetails {
        var request = URLRequest(url: URL(string: "https://rce.rla.mobeepass.net/v1/rla/sales/managermediasdetails")!)
        request.httpMethod = "POST"
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("6abd9289-b305-4646-ba8e-e67ab081594e", forHTTPHeaderField: "x-api-key")
        request.setValue("1.4.5", forHTTPHeaderField: "x-application-version")
        request.httpBody = try JSONEncoder().encode(CalypsoOnlineRequest(
            mediaType: "Csc",
            mediaUnicity: mediaUnicity,
            mediaSerialNumber: mediaSerialNumber,
            ContextWebApi: CalypsoOnlineContext(
                AccessType: "Mobile",
                CultureName: "en",
                AccessMode: "ConnectedMedia",
                SessionId: "ticketingnfcsdk.NO_SESSION_ID",
                SalesMode: "CAD"
            )
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.nonEmpty ?? "Online check failed."
            throw CalypsoOnlineError.requestFailed(message)
        }

        let decoded = try JSONDecoder().decode(CalypsoOnlineResponse.self, from: data)
        return decoded.mediaInfoWebApiDetails
    }
}

enum CalypsoOnlineError: LocalizedError {
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let message): return message
        }
    }
}

struct CalypsoOnlineRequest: Encodable {
    let mediaType: String
    let mediaUnicity: Int
    let mediaSerialNumber: String
    let ContextWebApi: CalypsoOnlineContext
}

struct CalypsoOnlineContext: Encodable {
    let AccessType: String
    let CultureName: String
    let AccessMode: String
    let SessionId: String
    let SalesMode: String
}

struct CalypsoOnlineResponse: Decodable {
    let mediaInfoWebApiDetails: CalypsoOnlineMediaDetails
}

struct CalypsoOnlineMediaDetails: Decodable {
    let mediaSerialNumber: String
    let isBlacklisted: Bool
    let isLocked: Bool
    let isInvalid: Bool
    let expirationDate: String?
    let contractNumber: Int?
    let endPeriodState: String?
    let contractInfo: [CalypsoOnlineContract]?

    var contracts: [CalypsoOnlineContract] {
        contractInfo ?? []
    }

    var statusText: String {
        if isInvalid { return "Invalid" }
        if isLocked { return "Locked" }
        if isBlacklisted { return "Blacklisted" }
        return endPeriodState?.nonEmpty ?? "Valid"
    }

    var expirationDateDisplay: String? {
        expirationDate?.datePrefix
    }
}

struct CalypsoOnlineContract: Decodable {
    let titleProduct: String?
    let saleDate: String?
    let statusValidity: String?
    let sold: Int?
    let soldType: String?

    var remainingTripsText: String? {
        guard soldType?.lowercased() == "travels", let sold else { return nil }
        return "\(sold)"
    }

    var saleDateDisplay: String? {
        saleDate?.datePrefix
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var datePrefix: String? {
        guard let nonEmpty else { return nil }
        return String(nonEmpty.prefix(10))
    }
}
