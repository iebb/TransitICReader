import SwiftUI
import MapKit
import CoreLocation
import CryptoKit

private enum StationReportKind: String, CaseIterable, Identifiable {
    case missing
    case correction

    var id: String { rawValue }
    var title: String {
        switch self {
        case .missing: return String(localized: "Missing Station")
        case .correction: return String(localized: "Code Correction")
        }
    }
}

private struct StationReportLocationPayload: Encodable {
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
}

private struct StationReportPayload: Encodable {
    let submissionId: String
    let reportType: String
    let stationName: String
    let stationCode: String?
    let suggestedCode: String?
    let lines: String?
    let `operator`: String?
    let city: String?
    let country: String?
    let notes: String?
    let location: StationReportLocationPayload?
    let cardFamily: String
    let cardIdHash: String
    let appVersion: String
    let deviceId: String
    let source: String
}

private struct StationReportResponse: Decodable {
    let id: String
}

private enum StationReportIdentity {
    private static let deviceIDKey = "stationReportDeviceID"

    static var deviceID: String {
        if let saved = UserDefaults.standard.string(forKey: deviceIDKey), UUID(uuidString: saved) != nil {
            return saved
        }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: deviceIDKey)
        return created
    }

    static func cardIDHash(for card: SavedCardRecord) -> String {
        let digest = SHA256.hash(data: Data(card.id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private final class StationReportLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var accuracyMeters: Double?
    @Published var errorMessage: String?
    @Published var isLocating = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func select(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        accuracyMeters = nil
        errorMessage = nil
    }

    func removePin() {
        coordinate = nil
        accuracyMeters = nil
        errorMessage = nil
    }

    func useCurrentLocation() {
        errorMessage = nil
        isLocating = true
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            isLocating = false
            errorMessage = String(localized: "Location access is unavailable. You can place a pin manually.")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isLocating else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            isLocating = false
            errorMessage = String(localized: "Location access is unavailable. You can place a pin manually.")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        coordinate = location.coordinate
        accuracyMeters = location.horizontalAccuracy
        isLocating = false
        errorMessage = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        isLocating = false
        errorMessage = String(localized: "Could not find your location. You can place a pin manually.")
    }
}

private struct StationReportPinMap: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D?
    let onPick: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.setRegion(
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 30, longitude: 115),
                span: MKCoordinateSpan(latitudeDelta: 80, longitudeDelta: 80)
            ),
            animated: false
        )
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap(_:)))
        tap.cancelsTouchesInView = false
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        guard let coordinate else {
            map.removeAnnotations(map.annotations)
            context.coordinator.lastCoordinate = nil
            return
        }
        if let previous = context.coordinator.lastCoordinate,
           abs(previous.latitude - coordinate.latitude) < 0.0000001,
           abs(previous.longitude - coordinate.longitude) < 0.0000001 {
            return
        }
        map.removeAnnotations(map.annotations)
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        map.addAnnotation(annotation)
        map.setRegion(
            MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)),
            animated: true
        )
        context.coordinator.lastCoordinate = coordinate
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: StationReportPinMap
        var lastCoordinate: CLLocationCoordinate2D?

        init(_ parent: StationReportPinMap) { self.parent = parent }

        @objc func didTap(_ gesture: UITapGestureRecognizer) {
            guard let map = gesture.view as? MKMapView, gesture.state == .ended else { return }
            let point = gesture.location(in: map)
            parent.onPick(map.convert(point, toCoordinateFrom: map))
        }
    }
}

struct StationReportView: View {
    let card: SavedCardRecord
    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = StationReportLocation()

    @State private var kind: StationReportKind = .missing
    @State private var stationName = ""
    @State private var stationCode: String
    @State private var suggestedCode = ""
    @State private var lines = ""
    @State private var operatorName = ""
    @State private var city = ""
    @State private var country = ""
    @State private var notes = ""
    @State private var showMap = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var successID: String?
    @State private var submissionID = UUID().uuidString.lowercased()

    init(card: SavedCardRecord, stationCode: String? = nil) {
        self.card = card
        _stationCode = State(initialValue: stationCode ?? "")
    }

    private func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func optional(_ value: String) -> String? { let value = trimmed(value); return value.isEmpty ? nil : value }

    private var canSubmit: Bool {
        !isSubmitting && !trimmed(stationName).isEmpty && stationName.count <= 120 &&
        (kind != .correction || !trimmed(stationCode).isEmpty) && stationCode.count <= 64 &&
        suggestedCode.count <= 64 && lines.count <= 240 && operatorName.count <= 120 &&
        city.count <= 120 && country.count <= 120 && notes.count <= 1200
    }

    var body: some View {
        Form {
            Section {
                Picker("Report Type", selection: $kind) {
                    ForEach(StationReportKind.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                TextField("Station Name", text: $stationName)
                TextField(kind == .correction ? "Code Shown by CardBal (Required)" : "Code Shown by CardBal (Optional)", text: $stationCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                if kind == .correction {
                    TextField("Correct Code (Optional)", text: $suggestedCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Station")
            } footer: {
                Text("For a code correction, enter the code shown by CardBal and the correct station name. The correct code is optional.")
            }

            Section("More Details (Optional)") {
                TextField("Line or Lines", text: $lines)
                TextField("Operator", text: $operatorName)
                TextField("City", text: $city)
                TextField("Country or Region", text: $country)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...5)
                Text("Notes stay private. Do not include personal details or raw trip data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if showMap {
                    StationReportPinMap(coordinate: location.coordinate) { coordinate in
                        location.select(coordinate)
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Tap the map to place or move a pin.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Choose a Pin on Map") { showMap = true }
                }
                Button {
                    showMap = true
                    location.useCurrentLocation()
                } label: {
                    if location.isLocating {
                        ProgressView()
                    } else {
                        Label("Use Current Location", systemImage: "location")
                    }
                }
                .disabled(location.isLocating)
                if let coordinate = location.coordinate {
                    Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(.footnote.monospacedDigit())
                    Button("Remove Location", role: .destructive) { location.removePin() }
                }
                if let message = location.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Location (Optional)")
            } footer: {
                Text("Your location is never read automatically. Only a pin you choose is sent with this report.")
            }

            Section {
                Text("Station details and an approximate pin, if selected, appear on the public request list. Notes, this card's SHA-256 ID hash, the app version, and an app-specific device ID stay private for review. The raw card ID and trip history are not sent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting { ProgressView() } else { Text("Submit Report") }
                }
                .disabled(!canSubmit)
            }
        }
        .navigationTitle("Report Station")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Report Received", isPresented: Binding(
            get: { successID != nil },
            set: { if !$0 { successID = nil } }
        )) {
            Button("Done") { dismiss() }
        } message: {
            Text("Reference: \(successID ?? "")")
        }
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let selectedLocation = location.coordinate.map {
            StationReportLocationPayload(
                latitude: $0.latitude,
                longitude: $0.longitude,
                accuracyMeters: location.accuracyMeters
            )
        }
        let payload = StationReportPayload(
            submissionId: submissionID,
            reportType: kind.rawValue,
            stationName: trimmed(stationName),
            stationCode: optional(stationCode),
            suggestedCode: kind == .correction ? optional(suggestedCode) : nil,
            lines: optional(lines),
            operator: optional(operatorName),
            city: optional(city),
            country: optional(country),
            notes: optional(notes),
            location: selectedLocation,
            cardFamily: card.cardFamily,
            cardIdHash: StationReportIdentity.cardIDHash(for: card),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            deviceId: StationReportIdentity.deviceID,
            source: "ios"
        )

        do {
            guard let url = URL(string: "https://cardbal.ieb.app/api/v1/station-reports") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("CardBal-iOS/\(payload.appVersion)", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                errorMessage = String(localized: "Could not send the report. Please try again.")
                return
            }
            successID = try JSONDecoder().decode(StationReportResponse.self, from: data).id
        } catch {
            errorMessage = String(localized: "Could not send the report. Please try again.")
        }
    }
}
