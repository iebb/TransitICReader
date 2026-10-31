import SwiftUI
import PhotosUI

struct SavedCardDetailView: View {
    let cardID: String
    @ObservedObject var store: CardWalletStore
    var initialSelection: CardDetailRoute.Selection = .settings
    @Environment(\.dismiss) private var dismiss

    @State private var viewSelection: CardDetailRoute.Selection = .settings
    @State private var draftDeleteConfirmation = false
    @State private var activeHistoryItem: HistorySheetItem?
    @State private var pendingDeletions: Set<String> = []
    @State private var calypsoOnlineLookup: CalypsoOnlineLookupState = .idle

    init(cardID: String, store: CardWalletStore, initialSelection: CardDetailRoute.Selection = .settings) {
        self.cardID = cardID
        self.store = store
        self.initialSelection = initialSelection
        _viewSelection = State(initialValue: initialSelection)
    }

    var body: some View {
        if let card = store.card(withID: cardID) {
            detailContent(card: card)
                .sheet(item: $activeHistoryItem) { item in
                    QuickHistorySheet(mode: item.mode, card: item.card, store: store)
                }
        }
    }

    private func detailContent(card: SavedCardRecord) -> some View {
        cardDetailList(card: card)
            .navigationTitle(card.localizedDisplayTitle)
    }

    private func cardDetailList(card: SavedCardRecord) -> some View {
        List {
            if viewSelection == .settings {
                Section {
                    cardPreviewSection(card: card)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section {
                    NavigationLink {
                        CardCustomizeView(cardID: card.id, store: store)
                    } label: {
                        Label("Customize Card", systemImage: "paintbrush.pointed")
                    }
                }

                Section("Card Information") {
                    cardInfoSection(card: card)
                }

                if let applications = card.applications, applications.count > 1 {
                    Section {
                        ForEach(applications) { application in
                            DisclosureGroup(Localizer.localize(application.label)) {
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
                        preview: SharePreview("\(card.localizedDisplayTitle) Hex Export")
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
                    store: store,
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
    private func cardInfoSection(card: SavedCardRecord) -> some View {
        if !card.visibleBalance.isEmpty {
            BalanceRows(balance: card.visibleBalance, dual: DualCurrencyBalance(applications: card.applications))
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
                             Text(Localizer.localize(field.title)).font(.caption).foregroundStyle(.secondary)
                             Spacer()
                             Text(Localizer.localize(field.value)).font(.caption).foregroundStyle(.primary)
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
                Text(Localizer.localize(message))
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

/// Restyles a saved card while the live result stays pinned above the controls.
struct CardCustomizeView: View {
    let cardID: String
    @ObservedObject var store: CardWalletStore

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var pendingFaceImage: UIImage?
    @State private var pendingAutoCroppedImage: UIImage?
    @State private var isShowingMarkerSheet = false
    @State private var isShowingSNScanner = false
    @State private var draftTitle: String?
    @State private var draftSerialNumber: String?
    @State private var titleTask: Task<Void, Never>?
    @State private var snTask: Task<Void, Never>?

    private static let swatches: [(name: LocalizedStringKey, color: SavedCardColor)] = [
        ("Green", SavedCardColor(red: 0.13, green: 0.64, blue: 0.36)),
        ("Blue", SavedCardColor(red: 0.23, green: 0.45, blue: 0.94)),
        ("Red", SavedCardColor(red: 0.90, green: 0.25, blue: 0.18)),
        ("Purple", SavedCardColor(red: 0.63, green: 0.40, blue: 0.91)),
        ("Cyan", SavedCardColor(red: 0.10, green: 0.66, blue: 0.87)),
        ("Orange", SavedCardColor(red: 0.96, green: 0.57, blue: 0.12)),
        ("Graphite", SavedCardColor(red: 0.23, green: 0.24, blue: 0.27))
    ]

    var body: some View {
        if let card = store.card(withID: cardID) {
            customizeList(card: card)
                .navigationTitle("Customize Card")
                .navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $isShowingMarkerSheet) {
                    MarkerEditorSheet(cardID: card.id, store: store)
                }
                .sheet(isPresented: $isShowingSNScanner) {
                    snScannerSheet(card: card)
                }
                .fullScreenCover(isPresented: $isShowingCamera) {
                    ImagePicker { image in processPhoto(image) }
                }
                .sheet(item: editableFaceImageBinding()) { editable in
                    faceImageEditorSheet(editable: editable, card: card)
                }
                .onChange(of: selectedPhotoItem) { newValue in
                    handlePhotoSelection(newValue)
                }
        }
    }

    private func customizeList(card: SavedCardRecord) -> some View {
        let isPhotoFace = card.finalIsUsingImage && store.loadFaceImage(fileName: card.faceImageFileName) != nil
        return List {
            Section {
                faceCarousel(card: card)
                    .listRowInsets(EdgeInsets(top: 14, leading: 0, bottom: 12, trailing: 0))
                HStack(spacing: 10) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { isShowingCamera = true } label: {
                            Label("Take Photo", systemImage: "camera")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline.weight(.semibold))
            } header: {
                Text("Card Face")
            } footer: {
                Text("Pick a color, a bundled card design or your own photo.")
            }

            if isPhotoFace {
                Section {
                    Toggle("Frosted Header", isOn: Binding(get: { card.finalFrostedHeader }, set: { store.setFrostedHeader($0, for: card.id) }))
                    Picker("Text Contrast", selection: Binding(get: { card.imageFaceEnhancer }, set: { store.setImageFaceEnhancer($0, for: card.id) })) {
                        Text("Shade").tag(ImageFaceEnhancer.mask)
                        Text("Shadow").tag(ImageFaceEnhancer.border)
                        Text("None").tag(ImageFaceEnhancer.none)
                    }
                    Toggle("Show Name", isOn: Binding(get: { !card.finalHideTitle }, set: { store.setHideTitleOnImage(!$0, for: card.id) }))
                } header: {
                    Text("Photo")
                } footer: {
                    Text("Frosted Header blurs the top of the design so the name and balance stay clear of its logos.")
                }
            } else {
                Section("Color") {
                    swatchRow(card: card)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
                Section("Style") {
                    HStack(spacing: 14) {
                        ForEach(SavedCardDesign.allCases) { design in
                            faceTile(Text(LocalizedStringKey(design.title)), isSelected: card.design == design) {
                                store.setDesign(design, for: card.id)
                            } face: {
                                Rectangle().fill(card.colorFace(design: design))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                LabeledContent("Name") {
                    TextField("Name", text: titleBinding(card: card), prompt: Text(Localizer.localize(defaultTitle(card: card))))
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }
                LabeledContent("Card Number") {
                    HStack(spacing: 10) {
                        TextField("Card Number", text: snBinding(card: card))
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .submitLabel(.done)
                        if card.technology == "FeliCa" && card.systemCode == "0003" {
                            Button { isShowingSNScanner = true } label: {
                                Image(systemName: "barcode.viewfinder")
                                    .font(.title3)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("Scan Card Number"))
                        }
                    }
                }
                Toggle("Show Card Number", isOn: Binding(get: { !card.finalHideSN }, set: { store.setHideSerialNumber(!$0, for: card.id) }))
            } header: {
                Text("Text on Card")
            } footer: {
                Text("Leave the name empty to use the card's own name.")
            }

            Section {
                Button { isShowingMarkerSheet = true } label: {
                    HStack {
                        Text("Card Icon").foregroundStyle(.primary)
                        Spacer()
                        MarkerPreviewBadge(card: card)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Shown next to the card name and on the ride map.")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            livePreview(card: card)
        }
    }

    private func livePreview(card: SavedCardRecord) -> some View {
        WalletCardLayout {
            GeometryReader { proxy in
                // Compact history chips keep the smaller preview from wrapping.
                WalletCardView(
                    card: card,
                    store: store,
                    isExpanded: false,
                    cardHeight: proxy.size.height,
                    visiblePartHeight: 0,
                    onVisibleTap: {},
                    showDetails: {},
                    showTransactions: {},
                    showTransit: {}
                )
            }
        }
        .frame(maxWidth: 300)
        .allowsHitTesting(false)
        .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func faceCarousel(card: SavedCardRecord) -> some View {
        let current = card.faceImageFileName
        let currentToken = current.flatMap(RemoteFaceManifest.publishedToken(for:))
        let presets = store.presets()
        let savedFaces = store.faceAssets().filter { $0.fileName != current }
        let remoteFaces = store.remoteFaceEntries(for: card)
        let currentMatches = remoteFaces.matched.contains { $0.token == currentToken }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                faceTile(Text("Color"), isSelected: !card.finalIsUsingImage) {
                    store.setIsUsingImage(false, for: card.id)
                } face: {
                    Rectangle().fill(card.colorFace())
                }

                remoteFaceTiles(remoteFaces.matched, card: card)

                if let current, !currentMatches, let image = store.loadFaceImage(fileName: current) {
                    let presetName = presets.first { $0.fileName == current }?.name ?? store.remoteFaceTitle(for: current)
                    faceTile(presetName.map { Text(verbatim: $0) } ?? Text("Photo"), isSelected: card.finalIsUsingImage) {
                        store.setIsUsingImage(true, for: card.id)
                    } face: {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                } else if let currentToken, !currentMatches, let name = store.remoteFaceTitle(for: currentToken) {
                    faceTile(Text(verbatim: name), isSelected: card.finalIsUsingImage) {
                        store.setIsUsingImage(true, for: card.id)
                    } face: {
                        RemoteFaceThumbnail(token: currentToken)
                    }
                }

                ForEach(savedFaces) { asset in
                    if let image = store.loadFaceImage(fileName: asset.fileName) {
                        faceTile(Text("Photo"), isSelected: false) {
                            store.applyFaceAsset(asset.fileName, to: card.id)
                        } face: {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                }

                ForEach(store.unpublishedPresets().filter {
                    $0.fileName != current && RemoteFaceManifest.publishedToken(for: $0.fileName) != current
                }) { preset in
                    if let image = UIImage(named: preset.fileName) {
                        faceTile(Text(verbatim: preset.name), isSelected: false) {
                            store.applyPreset(preset, to: card.id)
                        } face: {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                }

                remoteFaceTiles(remoteFaces.others.filter { $0.token != currentToken }, card: card)
            }
            .padding(.horizontal, 16)
        }
    }

    private func remoteFaceTiles(_ entries: [RemoteFaceManifest.Entry], card: SavedCardRecord) -> some View {
        ForEach(entries) { entry in
            faceTile(Text(verbatim: entry.title()), isSelected: card.finalIsUsingImage &&
                     entry.token == card.faceImageFileName.flatMap(RemoteFaceManifest.publishedToken(for:))) {
                store.applyRemoteFace(entry.token, to: card.id)
            } face: {
                RemoteFaceThumbnail(token: entry.token)
            }
        }
    }

    private func faceTile<Face: View>(_ title: Text, isSelected: Bool, action: @escaping () -> Void, @ViewBuilder face: () -> Face) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button(action: action) {
            VStack(spacing: 7) {
                face()
                    .frame(width: 92, height: 92 / WalletCardLayout.aspectRatio)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .padding(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                    )
                title
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 98)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func swatchRow(card: SavedCardRecord) -> some View {
        let isCustom = !Self.swatches.contains { isSameColor($0.color, card.color) }
        return HStack(spacing: 0) {
            ForEach(Self.swatches.indices, id: \.self) { index in
                let swatch = Self.swatches[index]
                let isSelected = isSameColor(swatch.color, card.color)
                Button {
                    store.setColor(swatch.color.color, for: card.id)
                } label: {
                    Circle()
                        .fill(swatch.color.color)
                        .frame(width: 28, height: 28)
                        .padding(3)
                        .overlay(Circle().strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(swatch.name))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            ColorPicker("Custom Color", selection: Binding(get: { card.color.color }, set: { store.setColor($0, for: card.id) }), supportsOpacity: false)
                .labelsHidden()
                .padding(3)
                .overlay(Circle().strokeBorder(isCustom ? Color.primary : .clear, lineWidth: 2))
                .frame(maxWidth: .infinity)
        }
    }

    private func isSameColor(_ lhs: SavedCardColor, _ rhs: SavedCardColor) -> Bool {
        abs(lhs.red - rhs.red) < 0.02 && abs(lhs.green - rhs.green) < 0.02 && abs(lhs.blue - rhs.blue) < 0.02
    }

    private func defaultTitle(card: SavedCardRecord) -> String {
        var uncustomized = card
        uncustomized.customTitle = nil
        return uncustomized.displayTitle
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

    private func processPhoto(_ image: UIImage) {
        Task {
            let result = await CardPhotoProcessor.process(image)
            await MainActor.run {
                pendingFaceImage = result.original
                pendingAutoCroppedImage = result.autoCropped
            }
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item = item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                processPhoto(image)
            }
            await MainActor.run { selectedPhotoItem = nil }
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

/// Downloads a published face when its tile scrolls into view.
private struct RemoteFaceThumbnail: View {
    let token: String
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: token) {
            image = await RemoteCardFaceCatalog.shared.image(for: token)
            failed = image == nil
        }
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
                    Text(contract.titleProduct?.nonEmpty ?? String(localized: "Contract"))
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
