import SwiftUI

struct CardFaceLibraryView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        List {
            let assets = store.faceAssets()
            if assets.isEmpty {
                ContentUnavailableView("No Face Assets", systemImage: "photo.on.rectangle")
            } else {
                ForEach(assets) { asset in
                    HStack {
                        if let img = store.loadFaceImage(fileName: asset.fileName) {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 80, height: 50)
                                .cornerRadius(8)
                        }
                        VStack(alignment: .leading) {
                            Text(asset.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if store.isFaceAssetUsed(asset.fileName) {
                                Text("In Use")
                                    .font(.caption2)
                                    .padding(4)
                                    .background(Color.green.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        Spacer()
                        if !store.isFaceAssetUsed(asset.fileName) {
                            Button(role: .destructive) { store.deleteFaceAsset(asset.fileName) } label: {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Face Library")
    }
}

struct SavedFaceAssetPickerSheet: View {
    let store: CardWalletStore
    let excludingFileName: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 12)
    ]

    private var assets: [SavedFaceAsset] {
        store.faceAssets().filter { $0.fileName != excludingFileName }
    }

    var body: some View {
        NavigationStack {
            Group {
                if assets.isEmpty {
                    ContentUnavailableView(
                        "No Saved Images",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text("Add a card image first, then you can reuse it here.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(assets) { asset in
                                Button {
                                    onSelect(asset.fileName)
                                } label: {
                                    preview(fileName: asset.fileName)
                                        .padding(10)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Reuse Design")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func preview(fileName: String) -> some View {
        if let faceImage = store.loadFaceImage(fileName: fileName) {
            Image(uiImage: faceImage)
                .resizable()
                .scaledToFill()
                .aspectRatio(85.6 / 53.98, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .aspectRatio(85.6 / 53.98, contentMode: .fit)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }
}

struct EditableFaceImage: Identifiable {
    let id = UUID()
    let image: UIImage

    init(image: UIImage) {
        self.image = image
    }
}

struct FaceImageEditorSheet: View {
    let image: UIImage
    let onCancel: () -> Void
    let onSave: (UIImage) -> Void
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var brightness: Double = 0.0
    @State private var contrast: Double = 1.0

    var body: some View {
        NavigationStack {
            VStack {
                ZStack {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 320, height: 200).clipped()
                        .brightness(brightness).contrast(contrast)
                        .scaleEffect(scale).offset(offset)
                        .gesture(DragGesture().onChanged { offset = $0.translation }.onEnded { _ in })
                }.frame(width: 320, height: 200).overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.accentColor, lineWidth: 2))

                VStack {
                    Slider(value: $brightness, in: -0.5...0.5) { Text("Brightness") }
                    Slider(value: $contrast, in: 0.5...1.5) { Text("Contrast") }
                    Slider(value: $scale, in: 1.0...3.0) { Text("Scale") }
                }.padding()

                Button("Save") { onSave(image) }.buttonStyle(.borderedProminent)
            }
            .navigationTitle("Crop Card Face")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) } }
        }
    }
}

struct MarkerPreviewBadge: View {
    let card: SavedCardRecord

    var body: some View {
        ZStack {
            Group {
                if card.markerShape == .circle {
                    Circle()
                        .fill(card.markerColor.color)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(card.markerColor.color)
                }
            }
            .frame(width: 24, height: 24)

            if let markerSymbolName = card.markerSymbolName {
                if markerSymbolName.hasPrefix("sf:") {
                    Image(systemName: String(markerSymbolName.dropFirst(3)))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(card.markerOuterColor.color)
                } else if markerSymbolName.hasPrefix("txt:") {
                    Text(String(markerSymbolName.dropFirst(4)))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(card.markerOuterColor.color)
                }
            }
        }
    }
}

struct MarkerEditorSheet: View {
    let cardID: String
    @ObservedObject var store: CardWalletStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let card = store.card(withID: cardID) {
                List {
                    Section {
                        Picker("Shape", selection: Binding(get: { card.markerShape }, set: { store.setMarkerShape($0, for: card.id) })) {
                            Text("Circle").tag(SavedCardMarkerShape.circle); Text("Square").tag(SavedCardMarkerShape.square)
                        }.pickerStyle(.segmented)
                    }
                    Section("Colors") {
                        ColorPicker("Shape Color", selection: Binding(get: { card.markerColor.color }, set: { store.setMarkerColor($0, for: card.id) }))
                        ColorPicker("Symbol Color", selection: Binding(get: { card.markerOuterColor.color }, set: { store.setMarkerOuterColor($0, for: card.id) }))
                    }
                }
                .navigationTitle("Card Icon")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }
}

struct KeyValueRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
