import SwiftUI
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Result of card photo processing — carries both the auto-corrected and original images.
struct CardPhotoResult {
    let original: UIImage
    let autoCropped: UIImage?   // nil when no card rectangle was detected
    let didDetectCard: Bool
}

/// Automatically detects a card rectangle in a photo and applies perspective correction + quality enhancement.
enum CardPhotoProcessor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let cardAspectRatio: CGFloat = 27.0 / 17.0  // standard card W:H

    /// Process a captured photo and return both versions for the user to choose.
    static func process(_ image: UIImage) async -> CardPhotoResult {
        guard let cgImage = image.cgImage else {
            return CardPhotoResult(original: image, autoCropped: nil, didDetectCard: false)
        }

        // 1. Detect the card rectangle
        let corners = await detectRectangle(in: cgImage)

        guard let corners = corners else {
            return CardPhotoResult(original: image, autoCropped: nil, didDetectCard: false)
        }

        var ciImage = CIImage(cgImage: cgImage)
        let imageSize = ciImage.extent

        // 2. Map normalized Vision coordinates → pixel coordinates
        let tl = CGPoint(x: corners.topLeft.x * imageSize.width, y: corners.topLeft.y * imageSize.height)
        let tr = CGPoint(x: corners.topRight.x * imageSize.width, y: corners.topRight.y * imageSize.height)
        let bl = CGPoint(x: corners.bottomLeft.x * imageSize.width, y: corners.bottomLeft.y * imageSize.height)
        let br = CGPoint(x: corners.bottomRight.x * imageSize.width, y: corners.bottomRight.y * imageSize.height)

        // 3. Perspective correction from the 4 detected corners
        let correction = CIFilter.perspectiveCorrection()
        correction.inputImage = ciImage
        correction.topLeft = tl
        correction.topRight = tr
        correction.bottomLeft = bl
        correction.bottomRight = br
        if let corrected = correction.outputImage {
            ciImage = corrected
        }

        // 4. Detect orientation — if the corrected image is taller than wide, rotate 90° for landscape card
        let correctedExtent = ciImage.extent
        let detectedRatio = correctedExtent.width / correctedExtent.height
        if detectedRatio < 1.0 {
            // Portrait-oriented card detected → rotate to landscape
            ciImage = ciImage.oriented(.right)
        }

        // 5. Crop to exact 27:17 card aspect ratio
        ciImage = cropToCardAspect(ciImage)

        // 6. Enhance: sharpen + auto-adjust
        ciImage = enhance(ciImage)

        // 7. Render
        guard let outputCG = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return CardPhotoResult(original: image, autoCropped: nil, didDetectCard: false)
        }
        let autoImage = UIImage(cgImage: outputCG)
        return CardPhotoResult(original: image, autoCropped: autoImage, didDetectCard: true)
    }

    private static func detectRectangle(in cgImage: CGImage) async -> VNRectangleObservation? {
        await withCheckedContinuation { continuation in
            let request = VNDetectRectanglesRequest { request, error in
                let observation = (request.results as? [VNRectangleObservation])?
                    .sorted(by: { $0.confidence > $1.confidence })
                    .first(where: { $0.confidence > 0.5 })
                continuation.resume(returning: observation)
            }
            request.minimumConfidence = 0.3
            request.maximumObservations = 5
            request.minimumAspectRatio = 1.2
            request.maximumAspectRatio = 2.0
            request.minimumSize = 0.15

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Center-crop a CIImage to the standard card aspect ratio (27:17).
    private static func cropToCardAspect(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let currentRatio = extent.width / extent.height
        let targetRatio = cardAspectRatio
        let cropRect: CGRect
        if currentRatio > targetRatio {
            // Too wide — crop width
            let newWidth = extent.height * targetRatio
            let xOffset = (extent.width - newWidth) / 2 + extent.origin.x
            cropRect = CGRect(x: xOffset, y: extent.origin.y, width: newWidth, height: extent.height)
        } else {
            // Too tall — crop height
            let newHeight = extent.width / targetRatio
            let yOffset = (extent.height - newHeight) / 2 + extent.origin.y
            cropRect = CGRect(x: extent.origin.x, y: yOffset, width: extent.width, height: newHeight)
        }
        return image.cropped(to: cropRect)
    }

    private static func enhance(_ image: CIImage) -> CIImage {
        var result = image

        // Shadow reduction: lift shadows without blowing highlights
        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = result
        toneCurve.point0 = CGPoint(x: 0.0, y: 0.04)  // Lift pure black
        toneCurve.point1 = CGPoint(x: 0.15, y: 0.22)  // Brighten shadows
        toneCurve.point2 = CGPoint(x: 0.5, y: 0.52)   // Slight midtone lift
        toneCurve.point3 = CGPoint(x: 0.85, y: 0.84)  // Keep highlights stable
        toneCurve.point4 = CGPoint(x: 1.0, y: 1.0)
        if let lifted = toneCurve.outputImage {
            result = lifted
        }

        // Edge-aware sharpening via unsharp mask
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = result
        sharpen.radius = 1.5
        sharpen.intensity = 0.6
        if let sharpened = sharpen.outputImage {
            result = sharpened
        }

        // Slight local contrast boost via color controls
        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = result
        colorControls.contrast = 1.05
        colorControls.saturation = 1.05
        colorControls.brightness = 0.0
        if let adjusted = colorControls.outputImage {
            result = adjusted
        }

        return result
    }

    /// Extracts the most vivid "signature" color from the image — ignoring whites, silvers, grays, and blacks.
    static func dominantColor(of image: UIImage) -> Color? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let ctx = CIContext()
        let sampleSize = 32
        var bitmap = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        ctx.render(ciImage, toBitmap: &bitmap, rowBytes: sampleSize * 4, bounds: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize), format: .RGBA8, colorSpace: nil)

        // Bucket colors by top 4 bits of each channel
        var buckets: [[Int]: (count: Int, rSum: Int, gSum: Int, bSum: Int)] = [:]
        for i in stride(from: 0, to: bitmap.count, by: 4) {
            let r = Int(bitmap[i])
            let g = Int(bitmap[i+1])
            let b = Int(bitmap[i+2])
            let key = [r >> 4, g >> 4, b >> 4]
            let existing = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (existing.count + 1, existing.rSum + r, existing.gSum + g, existing.bSum + b)
        }

        // Score each bucket: saturation × count — pick the most vivid signature color
        var bestScore = 0.0
        var bestColor: (r: Double, g: Double, b: Double)?

        for bucket in buckets.values {
            guard bucket.count > 0 else { continue }
            let r = Double(bucket.rSum) / Double(bucket.count) / 255.0
            let g = Double(bucket.gSum) / Double(bucket.count) / 255.0
            let b = Double(bucket.bSum) / Double(bucket.count) / 255.0
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let sat = maxC > 0 ? (maxC - minC) / maxC : 0

            // Reject white → silver (bright and desaturated)
            if lum > 0.65 && sat < 0.20 { continue }
            // Reject dark grey → black (dim and desaturated)
            if lum < 0.20 && sat < 0.25 { continue }
            // Reject mid grays
            if sat < 0.15 { continue }

            let score = sat * Double(bucket.count)
            if score > bestScore {
                bestScore = score
                bestColor = (r, g, b)
            }
        }

        guard let c = bestColor else { return nil }
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

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
    let onSelectPreset: (CardPreset) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 140), spacing: 12)
    ]

    private var assets: [SavedFaceAsset] {
        store.faceAssets().filter { $0.fileName != excludingFileName }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Section {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(store.presets()) { preset in
                                Button {
                                    onSelectPreset(preset)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        if let img = UIImage(named: preset.fileName) {
                                            Image(uiImage: img)
                                                .resizable()
                                                .scaledToFill()
                                                .aspectRatio(27.0 / 17.0, contentMode: .fit)
                                                .frame(maxWidth: .infinity)
                                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        }
                                        Text(preset.name).font(.caption.bold()).lineLimit(1).foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("Presets").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 4)
                    }

                    if !assets.isEmpty {
                        Section {
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
                        } header: {
                            Text("Saved Designs").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 4)
                        }
                    }
                }
                .padding(16)
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
                .aspectRatio(27.0 / 17.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .aspectRatio(27.0 / 17.0, contentMode: .fit)
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
    let autoCroppedImage: UIImage?   // nil = no card was detected
    let onCancel: () -> Void
    let onSave: (UIImage) -> Void

    @State private var isAutoMode: Bool = true
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
    @State private var hasAppliedAutoZoom = false

    private let cardAspectRatio: CGFloat = 27.0 / 17.0
    private let cardWidth: CGFloat = 320
    private var cardHeight: CGFloat { cardWidth / cardAspectRatio }

    /// The image currently being edited — auto-cropped or original.
    private var activeImage: UIImage {
        (isAutoMode ? autoCroppedImage : nil) ?? image
    }

    /// Whether the user can toggle between auto/manual.
    private var canToggleAuto: Bool { autoCroppedImage != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Preview Area
                    ZStack {
                        Color.clear.frame(width: cardWidth, height: cardHeight)
                            .overlay(renderableView)

                        // Theatrical Mask
                        Color.black.opacity(0.5)
                            .mask(
                                Rectangle()
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .frame(width: cardWidth, height: cardHeight)
                                            .blendMode(.destinationOut)
                                    )
                            )
                            .compositingGroup()

                        // Card Guide Border
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white, lineWidth: 2)
                            .frame(width: cardWidth, height: cardHeight)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { val in dragOffset = val.translation }
                            .onEnded { val in
                                offset = CGSize(width: offset.width + val.translation.width,
                                                height: offset.height + val.translation.height)
                                dragOffset = .zero
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { val in scale = lastScale * val }
                            .onEnded { _ in lastScale = scale }
                    )

                    // Controls Area
                    VStack(spacing: 12) {
                        // Auto / Manual toggle (only when card was detected)
                        if canToggleAuto {
                            autoManualToggle
                        }

                        if !isAutoMode || !canToggleAuto {
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
                        } else {
                            // Auto mode: show only brightness/contrast fine-tune
                            adjustControls
                                .padding(.horizontal)
                                .frame(height: 100)
                        }

                        Divider().background(Color.white.opacity(0.2))

                        HStack {
                            Button("Cancel", action: onCancel).foregroundStyle(.white.opacity(0.8))
                            Spacer()
                            Button("Reset") { reset() }.foregroundStyle(.gray)
                        }
                        .padding()
                    }
                    .background(Color(uiColor: .systemBackground).colorScheme(.dark))
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation {
                            rotation = (rotation + 90).truncatingRemainder(dividingBy: 360)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "rotate.right")
                            Text("Rotate")
                        }
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.15), in: Capsule())
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Edit card face").foregroundStyle(.white).bold()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { saveCroppedImage() } label: {
                        Text("Save").bold()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { applyAutoZoomIfNeeded() }
            .onChange(of: isAutoMode) { _ in applyAutoZoomIfNeeded() }
        }
    }

    // MARK: - Auto / Manual Toggle

    @ViewBuilder
    private var autoManualToggle: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isAutoMode = true; resetTransforms() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                    Text("Auto")
                }
                .font(.subheadline.bold())
                .foregroundStyle(isAutoMode ? .white : .gray)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(isAutoMode ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
            }

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isAutoMode = false; resetTransforms() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hand.draw")
                    Text("Manual")
                }
                .font(.subheadline.bold())
                .foregroundStyle(!isAutoMode ? .white : .gray)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(!isAutoMode ? Color.accentColor : Color.white.opacity(0.1), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Controls

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

    // MARK: - Auto Zoom

    /// Computes scale so `activeImage` fills the card guide frame, accounting for aspect ratio.
    private func autoFitScale(for img: UIImage) -> CGFloat {
        let imgW = img.size.width
        let imgH = img.size.height
        guard imgW > 0, imgH > 0 else { return 1.0 }
        let imgAspect = imgW / imgH
        // scaledToFill: the shorter dimension touches the frame edge
        if imgAspect > cardAspectRatio {
            // Image is wider → height is the limiting dimension
            return cardHeight / (cardWidth / imgAspect)
        } else {
            // Image is taller → width is the limiting dimension
            return cardWidth / (cardHeight * imgAspect)
        }
    }

    private func applyAutoZoomIfNeeded() {
        let fitScale: CGFloat
        if isAutoMode && canToggleAuto {
            // Auto mode: image is already perspective-corrected and cropped to card — show full, no extra zoom
            fitScale = 1.0
        } else {
            fitScale = autoFitScale(for: activeImage)
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = fitScale
            lastScale = fitScale
            offset = .zero
            dragOffset = .zero
        }
    }

    // MARK: - Reset

    private func resetTransforms() {
        offset = .zero
        dragOffset = .zero
        brightness = 0.0
        contrast = 1.0
        rotation = 0.0
        vPerspective = 0.0
        hPerspective = 0.0
        hasAppliedAutoZoom = false
        // Auto zoom will be triggered by onChange/onAppear
    }

    private func reset() {
        withAnimation {
            resetTransforms()
            isAutoMode = canToggleAuto
        }
        applyAutoZoomIfNeeded()
    }

    // MARK: - Renderable View

    @ViewBuilder
    private var renderableView: some View {
        Image(uiImage: activeImage)
            .resizable()
            .aspectRatio(contentMode: isAutoMode && canToggleAuto ? .fit : .fill)
            .brightness(brightness)
            .contrast(contrast)
            .rotationEffect(.degrees(rotation))
            .projectionEffect(perspectiveTransform)
            .scaleEffect(scale)
            .offset(CGSize(width: offset.width + dragOffset.width,
                           height: offset.height + dragOffset.height))
    }

    private var perspectiveTransform: ProjectionTransform {
        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / 1000
        transform = CATransform3DRotate(transform, vPerspective, 1, 0, 0)
        transform = CATransform3DRotate(transform, hPerspective, 0, 1, 0)
        return ProjectionTransform(transform)
    }

    // MARK: - Save

    private func saveCroppedImage() {
        let renderer = ImageRenderer(content:
            renderableView
                .frame(width: cardWidth, height: cardHeight)
        )
        renderer.scale = 3.0
        guard let uiImage = renderer.uiImage else { onSave(activeImage); return }

        // Final sharpen pass for crisp output
        guard let ciInput = CIImage(image: uiImage) else { onSave(uiImage); return }
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = ciInput
        sharpen.radius = 1.0
        sharpen.intensity = 0.4
        guard let sharpened = sharpen.outputImage,
              let cgOut = CIContext().createCGImage(sharpened, from: sharpened.extent) else {
            onSave(uiImage); return
        }
        onSave(UIImage(cgImage: cgOut, scale: uiImage.scale, orientation: uiImage.imageOrientation))
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
            // Titles are English keys; look them up so rows follow the app language.
            Text(LocalizedStringKey(title)).foregroundStyle(.secondary)
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
struct QuickHistorySheet: View {
    let mode: HistoryMode
    let card: SavedCardRecord
    let store: CardWalletStore?
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletions: Set<String> = []

    enum HistoryMode {
        case transactions, transit
    }

    var body: some View {
        NavigationStack {
            List {
                if mode == .transactions {
                    transactionsSection
                } else {
                    transitSection
                }
            }
            .navigationTitle(mode == .transactions ? "Transactions" : "Transit Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var transactionsSection: some View {
        Section {
            let sorted = sortTransactionsByRecency(card.transactions)
                .filter { tx in tx.rawData.map { !pendingDeletions.contains($0) } ?? true }
            if sorted.isEmpty {
                Text("No records found").foregroundStyle(.secondary)
            } else {
                ForEach(sorted, id: \.stableID) { tx in
                    TransitTransactionRow(tx: tx, cardFamily: card.cardFamily, reportCard: card)
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let rawData = tx.rawData, let store {
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

    private var transitSection: some View {
        Section {
            let sorted = sortTransactionsByRecency(card.transitHistory)
                .filter { tx in tx.rawData.map { !pendingDeletions.contains($0) } ?? true }
            if sorted.isEmpty {
                Text("No records found").foregroundStyle(.secondary)
            } else {
                ForEach(sorted, id: \.stableID) { tx in
                    TransitTransactionRow(tx: tx, cardFamily: card.cardFamily, reportCard: card)
                        .padding(.vertical, 4)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if let rawData = tx.rawData, let store {
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
}

struct HistorySheetItem: Identifiable {
    let id = UUID()
    let mode: QuickHistorySheet.HistoryMode
    let card: SavedCardRecord
}
