import SwiftUI

struct CardFaceLibraryView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        List {
            let assets = store.faceAssets()
            if assets.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                    Text("No Face Assets")
                        .font(.title2.bold())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .listRowBackground(Color.clear)
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
                    VStack(spacing: 20) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                        Text("No Saved Images")
                            .font(.title2.bold())
                        Text("Add a card image first, then you can reuse it here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var dragOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var brightness: Double = 0.0
    @State private var contrast: Double = 1.0
    @State private var rotation: Double = 0.0
    @State private var vPerspective: Double = 0.0
    @State private var hPerspective: Double = 0.0
    @State private var activeTab: Int = 0 // 0: Crop, 1: Adjust, 2: Perspective
    
    private let cardAspectRatio: CGFloat = 85.6 / 53.98
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Preview Area
                    ZStack {
                        // Anchored base to prevent huge images from pushing layout width
                        Color.clear.frame(width: 320, height: 320 / cardAspectRatio)
                            .overlay(renderableView)
                        
                        // Theatrical Mask
                        Color.black.opacity(0.5)
                            .mask(
                                Rectangle()
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .frame(width: 320, height: 320 / cardAspectRatio)
                                            .blendMode(.destinationOut)
                                    )
                            )
                            .compositingGroup()
                        
                        // Card Guide Border
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: 320, height: 320 / cardAspectRatio)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { val in
                                dragOffset = val.translation
                            }
                            .onEnded { val in
                                offset = CGSize(width: offset.width + val.translation.width, height: offset.height + val.translation.height)
                                dragOffset = .zero
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { val in
                                scale = lastScale * val
                            }
                            .onEnded { val in
                                lastScale = scale
                            }
                    )
                    
                    // Controls Area
                    VStack(spacing: 16) {
                        Picker("Mode", selection: $activeTab) {
                            Image(systemName: "crop").tag(0)
                            Image(systemName: "slider.horizontal.3").tag(1)
                            Image(systemName: "skew").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        
                        Group {
                            if activeTab == 0 {
                                cropControls
                            } else if activeTab == 1 {
                                adjustControls
                            } else {
                                perspectiveControls
                            }
                        }
                        .padding(.horizontal)
                        .frame(height: 100)
                        
                        Divider().background(Color.white.opacity(0.2))
                        
                        HStack {
                            Button("Cancel", action: onCancel).foregroundStyle(.white)
                            Spacer()
                            Button("Reset") { reset() }.foregroundStyle(.gray)
                            Spacer()
                            Button { saveCroppedImage() } label: {
                                Text("Done").bold().padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(Color.white, in: Capsule())
                                    .foregroundStyle(.black)
                            }
                        }
                        .padding()
                    }
                    .background(Color(uiColor: .systemBackground).colorScheme(.dark))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { Text("Edit card face").foregroundStyle(.white).bold() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { withAnimation { rotation = (rotation + 90).truncatingRemainder(dividingBy: 360) } } label: {
                        Image(systemName: "rotate.right").foregroundStyle(.white)
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var cropControls: some View {
        VStack {
            Text("Zoom").font(.caption).foregroundStyle(.secondary)
            Slider(value: $scale, in: 0.5...8.0).tint(.white)
        }
    }
    
    @ViewBuilder
    private var adjustControls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "sun.max.fill").font(.caption2).foregroundStyle(.secondary)
                    Text("Brightness").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                Slider(value: $brightness, in: -0.5...0.5).tint(.white)
            }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "circle.lefthalf.filled").font(.caption2).foregroundStyle(.secondary)
                    Text("Contrast").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
                Slider(value: $contrast, in: 0.5...1.5).tint(.white)
            }
        }
    }
    
    @ViewBuilder
    private var perspectiveControls: some View {
        VStack(spacing: 8) {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "arrow.up.and.down.square").font(.caption2).foregroundStyle(.secondary)
                    #if os(iOS)
                    Text("Vertical").font(.caption2).foregroundStyle(.secondary)
                    #endif
                    Spacer()
                }
                Slider(value: $vPerspective, in: -0.3...0.3).tint(.white)
            }
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "arrow.left.and.right.square").font(.caption2).foregroundStyle(.secondary)
                    #if os(iOS)
                    Text("Horizontal").font(.caption2).foregroundStyle(.secondary)
                    #endif
                    Spacer()
                }
                Slider(value: $hPerspective, in: -0.3...0.3).tint(.white)
            }
        }
    }
    
    private func reset() {
        withAnimation {
            offset = .zero
            dragOffset = .zero
            scale = 1.0
            lastScale = 1.0
            brightness = 0.0
            contrast = 1.0
            rotation = 0.0
            vPerspective = 0.0
            hPerspective = 0.0
        }
    }
    
    @ViewBuilder
    private var renderableView: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .brightness(brightness)
            .contrast(contrast)
            .rotationEffect(.degrees(rotation))
            .projectionEffect(perspectiveTransform)
            .scaleEffect(scale)
            .offset(CGSize(width: offset.width + dragOffset.width, height: offset.height + dragOffset.height))
    }
    
    private var perspectiveTransform: ProjectionTransform {
        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 1000
        transform = CATransform3DRotate(transform, vPerspective, 1, 0, 0)
        transform = CATransform3DRotate(transform, hPerspective, 0, 1, 0)
        return ProjectionTransform(transform)
    }
    
    private func saveCroppedImage() {
        let renderer = ImageRenderer(content: 
            renderableView
                .frame(width: 320, height: 320 / cardAspectRatio)
        )
        renderer.scale = 3.0
        if let uiImage = renderer.uiImage {
            onSave(uiImage)
        } else {
            onSave(image)
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
                } else if markerSymbolName.hasPrefix("txt:") {
                    Text(String(markerSymbolName.dropFirst(4)))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
            } else {
                Image(systemName: "slash.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(card.markerOuterColor.color)
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

                    Section("Icon Symbol") {
                        let icons = [
                            "sf:bus.fill", "sf:tram.fill", "sf:train.side.front.car", "sf:ferry.fill", "sf:bicycle",
                            "sf:creditcard.fill", "sf:star.fill", "sf:heart.fill", "sf:tag.fill", "sf:briefcase.fill",
                            "sf:map.fill", "sf:mappin", "sf:house.fill", "sf:lock.fill", "sf:iphone", "sf:bolt.fill",
                            "sf:leaf.fill", "sf:ticket.fill", "sf:bag.fill", "sf:cart.fill", "sf:airplane",
                            "sf:antenna.radiowaves.left.and.right", "sf:camera.fill", "sf:flashlight.on.fill",
                            "sf:music.note", "sf:video.fill", "sf:gamecontroller.fill", "sf:building.fill",
                            "sf:fuelpump.fill", "sf:cup.and.saucer.fill", "sf:pawprint.fill", "sf:graduationcap.fill"
                        ]
                        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { "txt:\($0)" }
                        let numbers = "0123456789".map { "txt:\($0)" }
                        let candidates = icons + letters + numbers
                        
                        let columns = [GridItem(.adaptive(minimum: 44))]
                        LazyVGrid(columns: columns, spacing: 10) {
                            Button {
                                store.setMarkerSymbolName(nil, for: card.id)
                            } label: {
                                ZStack {
                                    if card.markerShape == .circle {
                                        Circle()
                                            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    } else {
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4]))
                                    }
                                    Image(systemName: "slash.circle")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)

                            ForEach(candidates, id: \.self) { id in
                                iconButton(id, card: card)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .navigationTitle("Card Icon")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
        }
    }

    @ViewBuilder
    private func iconButton(_ id: String, card: SavedCardRecord) -> some View {
        Button {
            store.setMarkerSymbolName(id, for: card.id)
        } label: {
            ZStack {
                let isSelected = id == card.markerSymbolName
                let shapeColor = isSelected ? card.markerColor.color : Color(uiColor: .secondarySystemFill)
                
                if card.markerShape == .circle {
                    Circle().fill(shapeColor)
                } else {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(shapeColor)
                }
                
                if id.hasPrefix("sf:") {
                    Image(systemName: String(id.dropFirst(3))).font(.title3)
                } else {
                    Text(String(id.dropFirst(4))).font(.title3.bold())
                }
            }
            .frame(width: 44, height: 44)
            .foregroundStyle(id == card.markerSymbolName ? card.markerOuterColor.color : .primary)
        }
        .buttonStyle(.plain)
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

struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType = .camera
    var didFinish: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = sourceType
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.didFinish(image) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}
