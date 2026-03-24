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
    
    @State private var p1 = "" // AA111
    @State private var p2 = "" // X111
    @State private var p3 = "" // 1111
    @State private var p4 = "" // 1111
    
    @State private var p1Confirmed = false
    @State private var p2Confirmed = false
    @State private var p3Confirmed = false
    @State private var p4Confirmed = false
    
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
            ZStack {
                SNCameraView(onRecognized: { sn in 
                    updateWith(sn, xPos: nil)
                }, 
                onFragments: { fragments in
                    for f in fragments {
                        updateWith(f.text, xPos: f.rect.midX)
                    }
                })
                .ignoresSafeArea()
                
                // Cutout and Skeleton UI
                GeometryReader { proxy in
                    let cardW = proxy.size.width * 0.88
                    let cardH = cardW / (85.6 / 54.0)
                    let snBoxW = cardW * (50.0 / 85.6)
                    let snBoxH = cardH * (7.0 / 54.0)
                    
                    let cardCenterY = proxy.size.height / 2 - 40
                    let snBoxX = (proxy.size.width + cardW)/2 - snBoxW
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
                                        .position(x: proxy.size.width/2, y: cardCenterY)
                                        .blendMode(.destinationOut)
                                }
                            )
                        
                        // Full Card Outline (Ghosted)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                            .frame(width: cardW, height: cardH)
                            .position(x: proxy.size.width/2, y: cardCenterY)
                        
                        // SN Focus Box (Active)
                        Path { path in
                            let rect = CGRect(x: snBoxX, y: snBoxY, width: snBoxW, height: snBoxH)
                            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                            path.addArc(center: CGPoint(x: rect.maxX - 16, y: rect.maxY - 16), radius: 16, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
                            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                            path.closeSubpath()
                        }
                        .stroke(isValid ? .green : .white.opacity(0.5), lineWidth: 2)
                        .background {
                             Path { path in
                                let rect = CGRect(x: snBoxX, y: snBoxY, width: snBoxW, height: snBoxH)
                                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                                path.addArc(center: CGPoint(x: rect.maxX - 16, y: rect.maxY - 16), radius: 16, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
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
                        
                        // Confirm Button
                        if wasValidOnce {
                            VStack {
                                Spacer()
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
                                    .frame(maxWidth: .infinity)
                                    .background(isValid ? Color.green : Color.gray, in: RoundedRectangle(cornerRadius: 14))
                                    .foregroundStyle(.white)
                                }
                                .padding(24)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .onAppear {
                        // Pass geometry data to VC if needed, but currently handled via X position mapping
                    }
                    .onChange(of: proxy.size) { _ in }
                }
            }
            .navigationTitle("Scan Card S/N")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
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
                let screenW = UIScreen.main.bounds.width
                let cardW = screenW * 0.88
                let snBoxW = cardW * (50.0 / 85.6)
                let snBoxXStart = (screenW + cardW)/2 - snBoxW
                
                let relX = (x - snBoxXStart) / snBoxW
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
    
    func makeUIViewController(context: Context) -> SNScannerViewController {
        let vc = SNScannerViewController()
        vc.onRecognized = onRecognized
        vc.onFragments = onFragments
        return vc
    }
    func updateUIViewController(_ uiViewController: SNScannerViewController, context: Context) {}
}

private class SNScannerViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onRecognized: ((String) -> Void)?
    var onFragments: (([ScanFragment]) -> Void)?
    
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let output = AVCaptureVideoDataOutput()
    private let sequenceHandler = VNSequenceRequestHandler()
    private var isFound = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "visionQueue"))
        session.addOutput(output)
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.layer.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        DispatchQueue.global().async { self.session.startRunning() }
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
        
        // Use a wide enough ROI to capture all parts, but still restricted to SN area
        // Normalized [0,1] from Bottom-Left of oriented image
        // In .right orientation, sensor top (0.0) is screen right. sensor bottom (1.0) is screen left?
        // Let's use a wide ROI to avoid misalignment issues
        request.regionOfInterest = CGRect(x: 0, y: 0.2, width: 1.0, height: 0.3)
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
