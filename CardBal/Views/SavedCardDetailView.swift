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

    var body: some View {
        if let card = store.card(withID: cardID) {
            detailContent(card: card)
                .onAppear { viewSelection = initialSelection }
                .sheet(item: $activeHistoryItem) { item in
                    QuickHistorySheet(mode: item.mode, card: item.card)
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
                    pendingFaceImage = image
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
                
                Section("Settings") {
                        titleSection(card: card)
                    }

                    Section("Card Information") {
                        cardInfoSection(card: card)
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
        WalletCardView(
            card: card,
            isExpanded: true,
            cardHeight: (UIScreen.main.bounds.width - 32) / (27.0 / 17.0),
            visiblePartHeight: 92,
            onVisibleTap: {},
            showDetails: {},
            showTransactions: { activeHistoryItem = HistorySheetItem(mode: .transactions, card: card) },
            showTransit: { activeHistoryItem = HistorySheetItem(mode: .transit, card: card) }
        )
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
        KeyValueRow(title: "Technology", value: card.technology)
        if let city = card.issuingCity { KeyValueRow(title: "Issuing City", value: city) }
        if let type = card.cardTypeStr { KeyValueRow(title: "Card Type", value: type) }
        if let issue = card.issueDateStr { KeyValueRow(title: "Issue Date", value: issue) }
        if let expiry = card.expiryDateStr { KeyValueRow(title: "Expiry Date", value: expiry) }
        
        if card.technology == "FeliCa", let sc = card.systemCode {
            KeyValueRow(title: "System Code", value: sc)
        }
        
        if !card.resultFields.isEmpty {
             DisclosureGroup("All Decoded Metadata") {
                 VStack(alignment: .leading, spacing: 10) {
                     ForEach(card.resultFields) { field in
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
    private func transactionsSection(card: SavedCardRecord) -> some View {
        Section("Transactions") {
            let sorted = card.transactions.sorted { t1, t2 in
                if let r1 = t1.recordNumber, let r2 = t2.recordNumber {
                    return r1 > r2
                }
                return (t1.date ?? Date.distantPast) > (t2.date ?? Date.distantPast)
            }
            if sorted.isEmpty {
                Text("No records found").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(sorted) { tx in
                    TransitTransactionRow(tx: tx, cardFamily: card.cardFamily)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func transitHistorySection(card: SavedCardRecord) -> some View {
        Section("Transit Activity") {
            let sorted = card.transitHistory.sorted { t1, t2 in
                if let r1 = t1.recordNumber, let r2 = t2.recordNumber {
                    return r1 > r2
                }
                return (t1.date ?? Date.distantPast) > (t2.date ?? Date.distantPast)
            }
            if sorted.isEmpty {
                Text("No records found").foregroundStyle(.secondary).font(.subheadline)
            } else {
                ForEach(sorted) { tx in
                    TransitTransactionRow(tx: tx, cardFamily: card.cardFamily)
                        .padding(.vertical, 4)
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
                await MainActor.run { pendingFaceImage = image }
            }
            await MainActor.run { selectedPhotoItem = nil }
        }
    }

    private func editableFaceImageBinding() -> Binding<EditableFaceImage?> {
        Binding(
            get: { pendingFaceImage.map(EditableFaceImage.init) },
            set: { newValue in
                pendingFaceImage = newValue?.image
            }
        )
    }

    private func snScannerSheet(card: SavedCardRecord) -> some View {
        FeliCaSNScannerView { sn in
            store.setRealSerialNumber(sn, for: card.id)
        }
    }

    private func markerEditorSheet(card: SavedCardRecord) -> some View {
        MarkerEditorSheet(cardID: card.id, store: store)
    }

    private func faceImageEditorSheet(editable: EditableFaceImage, card: SavedCardRecord) -> some View {
        FaceImageEditorSheet(
            image: editable.image,
            onCancel: { pendingFaceImage = nil },
            onSave: { image in
                store.setFaceImage(image, for: card.id)
                pendingFaceImage = nil
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
