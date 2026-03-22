import SwiftUI
import Vision
import AVFoundation

struct FeliCaSNScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onRecognized: (String) -> Void
    var body: some View {
        NavigationStack {
            SNCameraView(onRecognized: { sn in onRecognized(sn); dismiss() })
                .ignoresSafeArea()
                .navigationTitle("Scan Card Back")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct SNCameraView: UIViewControllerRepresentable {
    let onRecognized: (String) -> Void
    func makeUIViewController(context: Context) -> SNScannerViewController {
        let vc = SNScannerViewController(); vc.onRecognized = onRecognized; return vc
    }
    func updateUIViewController(_ uiViewController: SNScannerViewController, context: Context) {}
}

private class SNScannerViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onRecognized: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let output = AVCaptureVideoDataOutput()
    private let sequenceHandler = VNSequenceRequestHandler()
    private var isFound = false

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
        let overlay = UIView(frame: view.bounds); overlay.backgroundColor = .clear; view.addSubview(overlay)
        let mask = UIView(frame: view.bounds); mask.backgroundColor = UIColor.black.withAlphaComponent(0.5); view.addSubview(mask)
        let cutout = UIView(); cutout.layer.borderColor = UIColor.white.cgColor; cutout.layer.borderWidth = 2; cutout.layer.cornerRadius = 12; cutout.backgroundColor = .clear; view.addSubview(cutout)
        cutout.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            cutout.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cutout.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cutout.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.8),
            cutout.heightAnchor.constraint(equalTo: cutout.widthAnchor, multiplier: 0.25)
        ])
    }

    private func setupCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input); output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "visionQueue")); session.addOutput(output)
        previewLayer = AVCaptureVideoPreviewLayer(session: session); previewLayer.frame = view.layer.bounds; previewLayer.videoGravity = .resizeAspectFill; view.layer.addSublayer(previewLayer)
        DispatchQueue.global().async { self.session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isFound, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNRecognizeTextRequest { [weak self] request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                guard let normalized = self?.normalizedFeliCaSN(from: text) else { continue }
                self?.isFound = true
                DispatchQueue.main.async { self?.onRecognized?(normalized) }
                return
            }
        }
        request.recognitionLevel = .accurate; try? sequenceHandler.perform([request], on: pixelBuffer)
    }

    private func normalizedFeliCaSN(from text: String) -> String? {
        let normalized = text.uppercased().filter {
            $0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        }
        guard normalized.count == 17 else { return nil }
        return SavedCardRecord.formattedFeliCaSerial(normalized, cardFamily: "")
    }
}
