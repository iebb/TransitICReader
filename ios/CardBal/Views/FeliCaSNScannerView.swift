import SwiftUI
import Vision
import AVFoundation

struct ScanFragment: Identifiable {
    let id = UUID()
    let text: String
    let rect: CGRect
    let image: UIImage?
}

struct FeliCaSNScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onRecognized: (String) -> Void
    var onPhotoTaken: ((UIImage) -> Void)? = nil

    @State private var p1 = "" // AA111
    @State private var p2 = "" // X111
    @State private var p3 = "" // 1111
    @State private var p4 = "" // 1111

    @State private var p1Confirmed = false
    @State private var p2Confirmed = false
    @State private var p3Confirmed = false
    @State private var p4Confirmed = false

    @State private var cameraVC: SNScannerViewController?
    @State private var isCapturing = false
    @State private var actionsMeasuredHeight: CGFloat = 44

    private var fullSN: String {
        "\(p1)\(p2)\(p3)\(p4)"
    }

    private var isValid: Bool {
        fullSN.count == 17 && fullSN.range(of: "^[A-Z]{2}[0-9]{3}[A-Z0-9][0-9]{3}[0-9]{8}$", options: .regularExpression) != nil
    }

    // Stable latching to prevent flickering "swipe-up" button
    @State private var wasValidOnce = false

    var body: some View {
        NavigationStack {
            GeometryReader { available in
                scannerWithActions(maxActionsHeight: available.size.height * 0.45)
            }
            .background(.black)
            .navigationTitle("Scan Card S/N")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scannerWithActions(maxActionsHeight: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            scannerContent.safeAreaBar(edge: .bottom) {
                scannerActions(maxHeight: maxActionsHeight)
            }
        } else {
            scannerContent.safeAreaInset(edge: .bottom, spacing: 0) {
                scannerActions(maxHeight: maxActionsHeight)
                    .background(.ultraThinMaterial)
            }
        }
    }

    private var scannerContent: some View {
        GeometryReader { proxy in
            let guide = guideFrame(in: proxy)
            ZStack {
                SNCameraView(onRecognized: { sn in
                    updateWith(sn, xPos: nil)
                },
                onFragments: { fragments in
                    for f in fragments {
                        let cardWidth = guide.width
                        let serialWidth = cardWidth * (50.0 / 85.6)
                        let serialStart = guide.maxX - serialWidth
                        updateWith(f.text, xPos: serialWidth > 0 ? (f.rect.midX - serialStart) / serialWidth : nil)
                    }
                },
                onVCReady: { vc in
                    cameraVC = vc
                })

                // Cutout and Skeleton UI
                let cardW = guide.width
                let cardH = cardW / (85.6 / 54.0)
                let snBoxW = cardW * (50.0 / 85.6)
                let snBoxH = cardH * (7.0 / 54.0)
                let snCornerRadius = min(16, snBoxH / 2)

                let cardCenterY = guide.midY
                let snBoxX = guide.maxX - snBoxW
                let snBoxY = cardCenterY + cardH/2 - snBoxH

                ZStack {
                    // Dimmed background
                    Rectangle().fill(.black.opacity(0.4)).ignoresSafeArea()
                        .mask(
                            ZStack {
                                Rectangle().ignoresSafeArea()
                                // Card outline cutout
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .frame(width: cardW, height: cardH)
                                    .position(x: guide.midX, y: cardCenterY)
                                    .blendMode(.destinationOut)
                            }
                        )

                    // Full Card Outline (Ghosted)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.white.opacity(0.2), lineWidth: 1)
                        .frame(width: cardW, height: cardH)
                        .position(x: guide.midX, y: cardCenterY)

                    // SN Focus Box (Active)
                    Path { path in
                        let rect = CGRect(x: snBoxX, y: snBoxY, width: snBoxW, height: snBoxH)
                        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                        path.addArc(center: CGPoint(x: rect.maxX - snCornerRadius, y: rect.maxY - snCornerRadius), radius: snCornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.closeSubpath()
                    }
                    .stroke(isValid ? .green : .white.opacity(0.5), lineWidth: 2)
                    .background {
                         Path { path in
                            let rect = CGRect(x: snBoxX, y: snBoxY, width: snBoxW, height: snBoxH)
                            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                            path.addArc(center: CGPoint(x: rect.maxX - snCornerRadius, y: rect.maxY - snCornerRadius), radius: snCornerRadius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                            path.closeSubpath()
                        }
                        .fill(.white.opacity(0.05))
                    }

                    // Skeleton hint with live filling
                    HStack(spacing: 0) {
                        partView(p1, placeholder: "JK233", width: cardW * (14.0 / 85.6), isConfirmed: p1Confirmed) { if !p1.isEmpty { p1Confirmed.toggle(); triggerHaptic() } }
                        partView(p2, placeholder: "A456", width: cardW * (12.0 / 85.6), isConfirmed: p2Confirmed) { if !p2.isEmpty { p2Confirmed.toggle(); triggerHaptic() } }
                        partView(p3, placeholder: "1234", width: cardW * (12.0 / 85.6), isConfirmed: p3Confirmed) { if !p3.isEmpty { p3Confirmed.toggle(); triggerHaptic() } }
                        partView(p4, placeholder: "8888", width: cardW * (12.0 / 85.6), isConfirmed: p4Confirmed) { if !p4.isEmpty { p4Confirmed.toggle(); triggerHaptic() } }
                    }
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .position(x: snBoxX + snBoxW/2, y: snBoxY + snBoxH/2)
                    .onChange(of: isValid) { valid in
                        if valid { withAnimation { wasValidOnce = true } }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scannerActions(maxHeight: CGFloat) -> some View {
        if onPhotoTaken != nil || wasValidOnce {
            ScrollView {
                VStack(spacing: 12) {
                    // Photo capture button (always visible when callback is provided)
                    if onPhotoTaken != nil {
                        Button {
                            capturePhoto()
                        } label: {
                            HStack {
                                Image(systemName: "camera.fill")
                                Text("Save as Card Face")
                            }
                            .font(.subheadline.bold())
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .frame(minHeight: 44)
                            .background(.ultraThinMaterial, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .disabled(isCapturing)
                        .opacity(isCapturing ? 0.5 : 1)
                    }

                    // Confirm S/N Button
                    if wasValidOnce {
                        Button {
                            if isValid {
                                onRecognized(fullSN)
                                dismiss()
                            } else {
                                withAnimation { wasValidOnce = false }
                            }
                        } label: {
                            HStack {
                                Text("Confirm S/N")
                                Image(systemName: "checkmark.circle.fill")
                            }
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(isValid ? Color.green : Color.gray, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { actions in
                        Color.clear.preference(key: ActionsHeightKey.self, value: actions.size.height)
                    }
                }
            }
            .frame(maxHeight: min(actionsMeasuredHeight, maxHeight))
            .onPreferenceChange(ActionsHeightKey.self) { actionsMeasuredHeight = $0 }
        }
    }

    private struct ActionsHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 44
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private func guideFrame(in proxy: GeometryProxy) -> CGRect {
        var available = CGRect(origin: .zero, size: proxy.size)
        // Older SDKs cannot type-check the iOS 27.1 reserved-region API.
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            // Physical positions are used below, so do not mirror the hardware regions in RTL.
            for region in proxy.reservedRegions(kind: .division, layoutDirectionBehavior: .fixed) {
                let fold = available.intersection(region.frame)
                guard !fold.isNull else { continue }
                let candidates: [CGRect]
                if fold.height > fold.width {
                    candidates = [
                        CGRect(x: available.minX, y: available.minY,
                               width: max(0, fold.minX - available.minX), height: available.height),
                        CGRect(x: fold.maxX, y: available.minY,
                               width: max(0, available.maxX - fold.maxX), height: available.height)
                    ]
                } else {
                    candidates = [
                        CGRect(x: available.minX, y: available.minY,
                               width: available.width, height: max(0, fold.minY - available.minY)),
                        CGRect(x: available.minX, y: fold.maxY,
                               width: available.width, height: max(0, available.maxY - fold.maxY))
                    ]
                }
                available = candidates.max { $0.width * $0.height < $1.width * $1.height } ?? available
            }
        }
        #endif
        // System bars and actions have already reserved their space before this measurement.
        let width = min(max(available.width - 32, 0),
                        max(available.height - 32, 0) * (85.6 / 54.0), 480)
        let height = width / (85.6 / 54.0)
        return CGRect(x: available.midX - width / 2, y: available.midY - height / 2,
                      width: width, height: height)
    }

    private func capturePhoto() {
        guard let vc = cameraVC, !isCapturing else { return }
        isCapturing = true
        vc.capturePhoto { image in
            Task {
                let result = await CardPhotoProcessor.process(image)
                let finalImage = result.autoCropped ?? image
                await MainActor.run {
                    isCapturing = false
                    onPhotoTaken?(finalImage)
                    triggerHaptic()
                }
            }
        }
    }
    
    @ViewBuilder
    private func partView(_ value: String, placeholder: String, width: CGFloat, isConfirmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                // Text stays inside the focus box
                if value.isEmpty {
                    Text(placeholder).foregroundStyle(.white.opacity(0.15))
                        .frame(width: width)
                } else {
                    Text(value)
                        .foregroundStyle(.white)
                        .padding(.vertical, 4)
                        .frame(width: width)
                        .background(isConfirmed ? Color.green : Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                }
            }
        }
    }
    
    private func updateWith(_ text: String, xPos: CGFloat?) {
        if text.count == 17 {
            if !p1Confirmed { p1 = String(text.prefix(5)) }
            if !p2Confirmed { p2 = String(text.dropFirst(5).prefix(4)) }
            if !p3Confirmed { p3 = String(text.dropFirst(9).prefix(4)) }
            if !p4Confirmed { p4 = String(text.suffix(4)) }
            triggerHaptic()
            return
        }
        
        // P1: AA111 (5 chars)
        if text.count == 5 && text.range(of: "^[A-Z]{2}[0-9]{3}$", options: .regularExpression) != nil {
            if !p1Confirmed { p1 = text; triggerHaptic() }
        } 
        else if text.count == 4 {
            if let x = xPos {
                let relX = x
                if relX < 0.35 { // P2 
                    if !p2Confirmed { p2 = text; triggerHaptic() }
                } else if relX < 0.68 { // P3
                    if !p3Confirmed { p3 = text; triggerHaptic() }
                } else { // P4
                    if !p4Confirmed { p4 = text; triggerHaptic() }
                }
            }
        }
    }
    
    private func triggerHaptic() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

private struct SNCameraView: UIViewControllerRepresentable {
    let onRecognized: (String) -> Void
    let onFragments: ([ScanFragment]) -> Void
    let onVCReady: (SNScannerViewController) -> Void

    func makeUIViewController(context: Context) -> SNScannerViewController {
        let vc = SNScannerViewController()
        vc.onRecognized = onRecognized
        vc.onFragments = onFragments
        DispatchQueue.main.async { onVCReady(vc) }
        return vc
    }
    func updateUIViewController(_ uiViewController: SNScannerViewController, context: Context) {
        // Refresh callbacks so OCR uses the current container after resizing.
        uiViewController.onRecognized = onRecognized
        uiViewController.onFragments = onFragments
    }
}

class SNScannerViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    var onRecognized: ((String) -> Void)?
    var onFragments: (([ScanFragment]) -> Void)?

    private let session = AVCaptureSession()
    private(set) var previewLayer: AVCaptureVideoPreviewLayer!
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let sequenceHandler = VNSequenceRequestHandler()
    private var isFound = false
    private var photoCaptureCompletion: ((UIImage) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "visionQueue"))
        session.addOutput(videoOutput)
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        DispatchQueue.global().async { self.session.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    /// Capture a still photo from the live camera.
    func capturePhoto(completion: @escaping (UIImage) -> Void) {
        photoCaptureCompletion = completion
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.photoCaptureCompletion?(image)
            self?.photoCaptureCompletion = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isFound, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation: CGImagePropertyOrientation = .right

        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

            DispatchQueue.main.async {
                guard let self = self, !self.isFound else { return }
                var detected: [ScanFragment] = []

                for observation in observations {
                    let candidates = observation.topCandidates(1)
                    for candidate in candidates {
                        let text = candidate.string.uppercased().filter { "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".contains($0) }

                        if text.count == 17 && text.range(of: "^[A-Z]{2}[0-9]{3}[A-Z0-9][0-9]{3}[0-9]{8}$", options: .regularExpression) != nil {
                            self.onRecognized?(text)
                        }

                        if self.isFragment(text) {
                            let box = observation.boundingBox

                            let metadataRect = CGRect(x: box.minX, y: 1.0 - box.maxY, width: box.width, height: box.height)
                            let screenRect = self.previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
                            detected.append(ScanFragment(text: text, rect: screenRect, image: nil))
                            break
                        }
                    }
                }
                if !detected.isEmpty {
                    self.onFragments?(detected)
                }
            }
        }

        // Keep Vision's full-frame default: resizing or an active fold can move the guide
        // outside a fixed normalized ROI. Existing serial/fragment validation still applies.
        request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
        try? sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
    }

    private func isFragment(_ text: String) -> Bool {
        if text.count == 5 && text.range(of: "^[A-Z]{2}[0-9]{3}$", options: .regularExpression) != nil { return true }
        if text.count == 4 && text.range(of: "^[A-Z0-9][0-9]{3}$", options: .regularExpression) != nil { return true }
        if text.count == 4 && text.range(of: "^[0-9]{4}$", options: .regularExpression) != nil { return true }
        return false
    }
}
