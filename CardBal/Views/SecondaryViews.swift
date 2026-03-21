import SwiftUI

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
