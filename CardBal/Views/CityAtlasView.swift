import SwiftUI
import MapKit

struct CityAtlasTabView: View {
    @ObservedObject var store: CardWalletStore

    var body: some View {
        CityAtlasView(store: store)
    }
}

private struct CityAtlasView: View {
    @ObservedObject var store: CardWalletStore

    @State private var visits: [CityAtlasVisit] = []
    @State private var provinceBoundaries: [CityAtlasBoundary] = []
    @State private var scope: CityAtlasScope = .all
    @State private var selectedCityID: String?
    @State private var focusedCityID: String?
    @State private var cameraRevision = 0
    @State private var resetCameraRevision = 0
    @State private var isLoading = true
    @State private var hasCompletedInitialLoad = false
    @State private var loadError: String?
    @State private var reloadToken = UUID()

    private var visibleVisits: [CityAtlasVisit] {
        guard let country = scope.country else { return visits }
        return visits.filter { $0.country == country }
    }

    private var visibleProvinceBoundaries: [CityAtlasBoundary] {
        guard let country = scope.country else { return provinceBoundaries }
        return provinceBoundaries.filter { $0.countryCode == country }
    }

    private var recordCount: Int {
        Set(visibleVisits.flatMap(\.evidenceIDs)).count
    }

    private var cardCount: Int {
        Set(visibleVisits.flatMap { $0.cards.map(\.id) }).count
    }

    private var cityDataRevision: String {
        let cardsRevision = store.cards.map { card in
            [
                card.id,
                card.displayTitle,
                "\(card.markerColor.red),\(card.markerColor.green),\(card.markerColor.blue)",
                "\(card.rawTransactions.count),\(card.rawTransitHistory.count)",
                "\(card.scannedAt.timeIntervalSinceReferenceDate)",
            ].joined(separator: ":")
        }
        .joined(separator: "|")
        return "\(store.mapDataRevision)|\(cardsRevision)"
    }

    private var selectedVisit: Binding<CityAtlasVisit?> {
        Binding(
            get: {
                guard let selectedCityID else { return nil }
                return visits.first { $0.id == selectedCityID }
            },
            set: { selectedCityID = $0?.id }
        )
    }

    var body: some View {
        ZStack {
            Color(red: 0.015, green: 0.035, blue: 0.07)
                .ignoresSafeArea()

            CityAtlasMapRepresentable(
                visits: visibleVisits,
                provinceBoundaries: visibleProvinceBoundaries,
                focusedCityID: focusedCityID,
                cameraRevision: cameraRevision,
                resetCameraRevision: resetCameraRevision,
                selectedCityID: $selectedCityID
            )
            .ignoresSafeArea(edges: .top)

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.68), location: 0),
                    .init(color: Color.black.opacity(0.15), location: 0.18),
                    .init(color: .clear, location: 0.42),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .top)

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.18), Color.black.opacity(0.64)],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)

            VStack(spacing: 0) {
                header
                Spacer(minLength: 80)
                bottomPanel
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .preferredColorScheme(.dark)
        .task(id: cityDataRevision) {
            await reload()
        }
        .sheet(item: selectedVisit) { visit in
            CityAtlasDetailSheet(visit: visit)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EAST ASIA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.58))
                    Text("Transit Atlas")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                }

                Spacer()

                Button {
                    focusedCityID = nil
                    resetCameraRevision &+= 1
                    cameraRevision &+= 1
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset East Asia view")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(CityAtlasScope.allCases) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scope = item
                            }
                            focusedCityID = nil
                            cameraRevision &+= 1
                        } label: {
                            HStack(spacing: 6) {
                                if let country = item.country {
                                    Circle()
                                        .fill(country.tint)
                                        .frame(width: 7, height: 7)
                                }
                                Text(item.title)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(scope == item ? Color.black : Color.white.opacity(0.86))
                            .padding(.horizontal, 11)
                            .frame(height: 30)
                            .background(
                                scope == item ? Color.white : Color.black.opacity(0.32),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(.white.opacity(scope == item ? 0 : 0.18), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        if isLoading {
            HStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("Linking transit records to cities…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(16)
            .cityAtlasGlass()
        } else if let loadError {
            VStack(alignment: .leading, spacing: 7) {
                Label("City map unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cityAtlasGlass()
        } else if visits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your cities will glow here", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Scan a supported Chinese, Japanese, or Korean transit card. Cities are added only when a saved record has a reliable location match.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cityAtlasGlass()
        } else if visibleVisits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No matched cities in \(scope.title)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Unresolved records stay off the map until their city can be matched with confidence.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .cityAtlasGlass()
        } else {
            VStack(spacing: 13) {
                HStack(spacing: 0) {
                    CityAtlasStat(value: "\(visibleVisits.count)", label: "Cities")
                    CityAtlasStat(value: "\(recordCount)", label: "Records")
                    CityAtlasStat(value: "\(cardCount)", label: "Cards")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleVisits) { visit in
                            Button {
                                focusedCityID = visit.id
                                cameraRevision &+= 1
                            } label: {
                                HStack(spacing: 9) {
                                    ZStack {
                                        Circle()
                                            .fill(visit.country.tint.opacity(0.22))
                                            .frame(width: 27, height: 27)
                                        Circle()
                                            .fill(visit.country.tint)
                                            .frame(width: 8, height: 8)
                                            .shadow(color: visit.country.tint.opacity(0.8), radius: 5)
                                    }

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(visit.displayName)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                        Text(cityAtlasRecordCountText(visit.recordCount))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.white.opacity(0.55))
                                    }
                                }
                                .foregroundStyle(.white)
                                .padding(.leading, 7)
                                .padding(.trailing, 11)
                                .frame(height: 42)
                                .background(
                                    focusedCityID == visit.id
                                        ? visit.country.tint.opacity(0.2)
                                        : Color.white.opacity(0.065),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().strokeBorder(
                                        focusedCityID == visit.id
                                            ? visit.country.tint.opacity(0.65)
                                            : Color.white.opacity(0.1),
                                        lineWidth: 0.75
                                    )
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                Text(
                                    verbatim: [
                                        visit.displayName,
                                        cityAtlasRecordCountText(visit.recordCount),
                                        cityAtlasCardCountText(visit.cards.count),
                                    ].joined(separator: ", ")
                                )
                            )
                        }
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                    Text("Only high-confidence city matches are illuminated")
                    Spacer()
                    Text("BOUNDARIES")
                        .fontWeight(.bold)
                        .tracking(0.7)
                }
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
            }
            .padding(14)
            .cityAtlasGlass()
        }
    }

    @MainActor
    private func reload() async {
        let token = UUID()
        reloadToken = token
        isLoading = true
        loadError = nil
        let cards = store.cards

        let result = await Task.detached(priority: .userInitiated) {
            Result { try CityAtlasVisitResolver().resolve(cards: cards) }
        }.value

        guard !Task.isCancelled, reloadToken == token else { return }
        switch result {
        case .success(let resolution):
            visits = resolution.visits
            provinceBoundaries = resolution.provinceBoundaries
            if let focusedCityID, !resolution.visits.contains(where: { $0.id == focusedCityID }) {
                self.focusedCityID = nil
            }
        case .failure(let error):
            visits = []
            provinceBoundaries = []
            loadError = error.localizedDescription
        }
        isLoading = false
        if !hasCompletedInitialLoad {
            hasCompletedInitialLoad = true
            resetCameraRevision &+= 1
        }
        cameraRevision &+= 1
    }
}

private struct CityAtlasStat: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.52))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private func cityAtlasRecordCountText(_ count: Int) -> String {
    if count == 1 {
        return String(localized: "1 record")
    }
    return String.localizedStringWithFormat(
        NSLocalizedString("%lld records", comment: "Number of transit records"),
        count
    )
}

private func cityAtlasCardCountText(_ count: Int) -> String {
    if count == 1 {
        return String(localized: "1 card")
    }
    return String.localizedStringWithFormat(
        NSLocalizedString("%lld cards", comment: "Number of transit cards"),
        count
    )
}

private struct CityAtlasDetailSheet: View {
    let visit: CityAtlasVisit

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(visit.country.tint.opacity(0.18))
                                .frame(width: 52, height: 52)
                            Circle()
                                .fill(visit.country.tint)
                                .frame(width: 14, height: 14)
                                .shadow(color: visit.country.tint.opacity(0.7), radius: 8)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visit.displayName)
                                .font(.title3.bold())
                            if visit.nativeName != visit.displayName {
                                Text(visit.nativeName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text(visit.country.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }

                Section("Transit footprint") {
                    LabeledContent("Records", value: "\(visit.recordCount)")
                    LabeledContent("Cards", value: "\(visit.cards.count)")
                    if let lastVisited = visit.lastVisited {
                        LabeledContent("Latest record") {
                            Text(
                                CardDateFormatting.formatDisplayDate(
                                    lastVisited,
                                    brand: visit.country.dateBrand
                                )
                            )
                        }
                    }
                }

                Section("Cards") {
                    ForEach(visit.cards) { card in
                        HStack {
                            Circle()
                                .fill(card.color.color)
                                .frame(width: 10, height: 10)
                            Text(card.title)
                            Spacer()
                            Text("\(card.recordCount)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("A city is shown only when the saved transit record can be linked to this boundary. Unknown and ambiguous records are deliberately excluded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(visit.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension View {
    func cityAtlasGlass() -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.28), radius: 18, y: 7)
    }
}

// MARK: - Map

private struct CityAtlasMapRepresentable: UIViewRepresentable {
    // Portrait framing keeps HCMC, Xi'an, Harbin, and Sapporo clear of the map edges.
    static let defaultEastAsiaDistance: CLLocationDistance = 14_000_000
    static let maximumEastAsiaDistance: CLLocationDistance = 15_000_000

    let visits: [CityAtlasVisit]
    let provinceBoundaries: [CityAtlasBoundary]
    let focusedCityID: String?
    let cameraRevision: Int
    let resetCameraRevision: Int
    @Binding var selectedCityID: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        let configuration = MKStandardMapConfiguration(
            elevationStyle: .realistic,
            emphasisStyle: .muted
        )
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        mapView.preferredConfiguration = configuration
        mapView.overrideUserInterfaceStyle = .dark
        mapView.delegate = context.coordinator
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.isZoomEnabled = true
        mapView.showsBuildings = true
        mapView.showsCompass = true

        let eastAsia = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 34.5, longitude: 120),
            span: MKCoordinateSpan(latitudeDelta: 36, longitudeDelta: 70)
        )
        mapView.cameraBoundary = MKMapView.CameraBoundary(coordinateRegion: eastAsia)
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: 18_000,
            maxCenterCoordinateDistance: Self.maximumEastAsiaDistance
        )
        mapView.camera = Self.eastAsiaCamera
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateMap(mapView)
    }

    static let eastAsiaCamera = MKMapCamera(
        lookingAtCenter: CLLocationCoordinate2D(latitude: 28.5, longitude: 124),
        fromDistance: defaultEastAsiaDistance,
        pitch: 38,
        heading: 0
    )

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CityAtlasMapRepresentable
        private var renderedSignature = ""
        private var lastCameraRevision = -1
        private var lastResetCameraRevision = -1
        private var styles: [ObjectIdentifier: CityAtlasOverlayStyle] = [:]
        private var visitByID: [String: CityAtlasVisit] = [:]

        init(parent: CityAtlasMapRepresentable) {
            self.parent = parent
        }

        func updateMap(_ mapView: MKMapView) {
            let visitSignature = parent.visits
                .map { "\($0.id):\($0.recordCount):\($0.cards.count)" }
                .joined(separator: "|")
            let provinceSignature = parent.provinceBoundaries.map(\.id).joined(separator: "|")
            let signature = "\(provinceSignature)|visits=\(visitSignature)|selected=\(parent.selectedCityID ?? "")"

            if signature != renderedSignature {
                renderedSignature = signature
                rebuildOverlays(on: mapView)
            }

            guard parent.cameraRevision != lastCameraRevision else { return }
            lastCameraRevision = parent.cameraRevision
            if parent.resetCameraRevision != lastResetCameraRevision {
                lastResetCameraRevision = parent.resetCameraRevision
                mapView.setCamera(
                    CityAtlasMapRepresentable.eastAsiaCamera,
                    animated: !UIAccessibility.isReduceMotionEnabled
                )
                return
            }
            if let focusedCityID = parent.focusedCityID,
               let visit = visitByID[focusedCityID] {
                focus(on: visit, mapView: mapView)
            } else if parent.visits.isEmpty {
                mapView.setCamera(CityAtlasMapRepresentable.eastAsiaCamera, animated: true)
            } else {
                focus(on: parent.visits, mapView: mapView)
            }
        }

        private func rebuildOverlays(on mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations)
            styles.removeAll(keepingCapacity: true)
            visitByID = Dictionary(uniqueKeysWithValues: parent.visits.map { ($0.id, $0) })

            var provinceOverlays: [MKMultiPolygon] = []
            var glowOverlays: [MKPolygon] = []
            var fillOverlays: [MKPolygon] = []
            var annotations: [CityAtlasAnnotation] = []

            for province in parent.provinceBoundaries {
                let polygons = province.coordinateRings.compactMap { ring -> MKPolygon? in
                    guard ring.count >= 3 else { return nil }
                    var coordinates = ring
                    return MKPolygon(coordinates: &coordinates, count: coordinates.count)
                }
                guard !polygons.isEmpty else { continue }
                let provinceOverlay = MKMultiPolygon(polygons)
                styles[ObjectIdentifier(provinceOverlay)] = CityAtlasOverlayStyle(
                    color: province.countryCode.uiTint,
                    fillAlpha: 0.035,
                    strokeAlpha: 0.58,
                    lineWidth: 1.25
                )
                provinceOverlays.append(provinceOverlay)
            }

            for visit in parent.visits {
                let isSelected = visit.id == parent.selectedCityID
                let alpha = min(0.42, 0.15 + log2(Double(visit.recordCount) + 1) * 0.055)
                for ring in visit.boundary.coordinateRings where ring.count >= 3 {
                    var coordinates = ring
                    let glow = MKPolygon(coordinates: &coordinates, count: coordinates.count)
                    styles[ObjectIdentifier(glow)] = CityAtlasOverlayStyle(
                        color: visit.country.uiTint,
                        fillAlpha: 0,
                        strokeAlpha: isSelected ? 0.34 : 0.2,
                        lineWidth: isSelected ? 13 : 9
                    )
                    glowOverlays.append(glow)

                    let fill = MKPolygon(coordinates: &coordinates, count: coordinates.count)
                    styles[ObjectIdentifier(fill)] = CityAtlasOverlayStyle(
                        color: visit.country.uiTint,
                        fillAlpha: isSelected ? min(alpha + 0.12, 0.55) : alpha,
                        strokeAlpha: 0.95,
                        lineWidth: isSelected ? 4 : 2.2
                    )
                    fillOverlays.append(fill)
                }

                annotations.append(CityAtlasAnnotation(visit: visit))
            }

            mapView.addOverlays(provinceOverlays, level: .aboveRoads)
            mapView.addOverlays(glowOverlays, level: .aboveLabels)
            mapView.addOverlays(fillOverlays, level: .aboveLabels)
            mapView.addAnnotations(annotations)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multiPolygon = overlay as? MKMultiPolygon,
               let style = styles[ObjectIdentifier(multiPolygon)] {
                return configured(
                    MKMultiPolygonRenderer(multiPolygon: multiPolygon),
                    style: style
                )
            }
            if let polygon = overlay as? MKPolygon,
               let style = styles[ObjectIdentifier(polygon)] {
                return configured(MKPolygonRenderer(polygon: polygon), style: style)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func configured(
            _ renderer: MKOverlayPathRenderer,
            style: CityAtlasOverlayStyle
        ) -> MKOverlayRenderer {
            renderer.fillColor = style.color.withAlphaComponent(style.fillAlpha)
            renderer.strokeColor = style.color.withAlphaComponent(style.strokeAlpha)
            renderer.lineWidth = style.lineWidth
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? CityAtlasAnnotation else { return nil }
            let identifier = "CityAtlasAnnotation"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? CityAtlasAnnotationView)
                ?? CityAtlasAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.configure(annotation)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? CityAtlasAnnotation else { return }
            parent.selectedCityID = annotation.cityID
            if let visit = visitByID[annotation.cityID] {
                focus(on: visit, mapView: mapView)
            }
        }

        private func focus(on visit: CityAtlasVisit, mapView: MKMapView) {
            let bbox = visit.boundary.bounds
            let width = max(abs(bbox.maxLongitude - bbox.minLongitude), 0.08)
            let height = max(abs(bbox.maxLatitude - bbox.minLatitude), 0.08)
            let distance = min(max(max(width, height) * 145_000, 70_000), 1_250_000)
            let camera = MKMapCamera(
                lookingAtCenter: visit.boundary.centerCoordinate,
                fromDistance: distance,
                pitch: distance < 300_000 ? 58 : 48,
                heading: 350
            )
            mapView.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
        }

        private func focus(on visits: [CityAtlasVisit], mapView: MKMapView) {
            guard let first = visits.first else {
                mapView.setCamera(CityAtlasMapRepresentable.eastAsiaCamera, animated: true)
                return
            }
            var minLatitude = first.boundary.minLatitude
            var maxLatitude = first.boundary.maxLatitude
            var minLongitude = first.boundary.minLongitude
            var maxLongitude = first.boundary.maxLongitude

            for visit in visits.dropFirst() {
                minLatitude = min(minLatitude, visit.boundary.minLatitude)
                maxLatitude = max(maxLatitude, visit.boundary.maxLatitude)
                minLongitude = min(minLongitude, visit.boundary.minLongitude)
                maxLongitude = max(maxLongitude, visit.boundary.maxLongitude)
            }

            let center = CLLocationCoordinate2D(
                latitude: (minLatitude + maxLatitude) / 2,
                longitude: (minLongitude + maxLongitude) / 2
            )
            let latitudeSpan = max(maxLatitude - minLatitude, 1.4)
            let longitudeSpan = max(maxLongitude - minLongitude, 1.4)
            let distance = min(
                max(
                    max(latitudeSpan * 185_000, longitudeSpan * 400_000),
                    5_700_000
                ),
                9_800_000
            )
            let camera = MKMapCamera(
                lookingAtCenter: center,
                fromDistance: distance,
                pitch: distance < 1_500_000 ? 52 : 42,
                heading: 350
            )
            mapView.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}

private struct CityAtlasOverlayStyle {
    let color: UIColor
    let fillAlpha: CGFloat
    let strokeAlpha: CGFloat
    let lineWidth: CGFloat
}

private final class CityAtlasAnnotation: NSObject, MKAnnotation {
    let cityID: String
    let cityName: String
    let recordCount: Int
    let tint: UIColor
    let coordinate: CLLocationCoordinate2D

    init(visit: CityAtlasVisit) {
        cityID = visit.id
        cityName = visit.displayName
        recordCount = visit.recordCount
        tint = visit.country.uiTint
        coordinate = visit.boundary.centerCoordinate
        super.init()
    }
}

private final class CityAtlasAnnotationView: MKAnnotationView {
    private let dot = UIView()
    private let label = UILabel()
    private let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        canShowCallout = false

        pill.layer.cornerRadius = 11
        pill.layer.cornerCurve = .continuous
        pill.clipsToBounds = true
        pill.contentView.addSubview(label)
        addSubview(pill)
        addSubview(dot)

        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 1

        dot.layer.borderWidth = 2
        dot.layer.borderColor = UIColor.white.withAlphaComponent(0.88).cgColor
        dot.layer.shadowOpacity = 0.9
        dot.layer.shadowRadius = 7
        dot.layer.shadowOffset = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ annotation: CityAtlasAnnotation) {
        label.text = "\(annotation.cityName)  \(annotation.recordCount)"
        let labelSize = label.sizeThatFits(CGSize(width: 170, height: 22))
        let pillWidth = min(max(labelSize.width + 16, 58), 180)
        frame = CGRect(x: 0, y: 0, width: pillWidth + 20, height: 30)
        let placesLabelOnLeft = annotation.coordinate.longitude >= 132
        dot.frame = CGRect(
            x: placesLabelOnLeft ? pillWidth + 10 : 0,
            y: 10,
            width: 10,
            height: 10
        )
        dot.layer.cornerRadius = 5
        dot.backgroundColor = annotation.tint
        dot.layer.shadowColor = annotation.tint.cgColor
        pill.frame = CGRect(
            x: placesLabelOnLeft ? 6 : 14,
            y: 3,
            width: pillWidth,
            height: 24
        )
        label.frame = pill.bounds
        centerOffset = CGPoint(
            x: (bounds.width / 2 - 5) * (placesLabelOnLeft ? -1 : 1),
            y: 0
        )
        accessibilityLabel = "\(annotation.cityName), \(cityAtlasRecordCountText(annotation.recordCount))"
        isAccessibilityElement = true
    }
}

// MARK: - Visit resolution

private enum CityAtlasCountry: String, Decodable, CaseIterable {
    case china = "CN"
    case japan = "JP"
    case korea = "KR"

    var title: String {
        switch self {
        case .china: return String(localized: "China")
        case .japan: return String(localized: "Japan")
        case .korea: return String(localized: "South Korea")
        }
    }

    var tint: Color {
        switch self {
        case .china: return Color(red: 1.0, green: 0.38, blue: 0.25)
        case .japan: return Color(red: 0.25, green: 0.78, blue: 1.0)
        case .korea: return Color(red: 0.65, green: 0.55, blue: 1.0)
        }
    }

    var uiTint: UIColor {
        UIColor(tint)
    }

    var dateBrand: ICCardBrand {
        switch self {
        case .china: return .tUnion
        case .japan: return .suica
        case .korea: return .tmoney
        }
    }
}

private enum CityAtlasScope: String, CaseIterable, Identifiable {
    case all
    case china
    case japan
    case korea

    var id: String { rawValue }

    var country: CityAtlasCountry? {
        switch self {
        case .all: return nil
        case .china: return .china
        case .japan: return .japan
        case .korea: return .korea
        }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .china: return String(localized: "China")
        case .japan: return String(localized: "Japan")
        case .korea: return String(localized: "Korea")
        }
    }
}

private struct CityAtlasVisit: Identifiable {
    let id: String
    let boundary: CityAtlasBoundary
    let country: CityAtlasCountry
    let recordCount: Int
    let evidenceIDs: Set<String>
    let cards: [CityAtlasCardVisit]
    let lastVisited: Date?

    var displayName: String {
        normalizedName(boundary.name) ?? normalizedName(boundary.nativeName) ?? String(localized: "City")
    }

    var nativeName: String {
        normalizedName(boundary.nativeName) ?? displayName
    }

    private func normalizedName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("none") != .orderedSame else {
            return nil
        }
        return trimmed
    }
}

private struct CityAtlasCardVisit: Identifiable {
    let id: String
    let title: String
    let color: SavedCardColor
    let recordCount: Int
}

private struct CityAtlasBoundary: Decodable {
    let id: String
    let countryCode: CityAtlasCountry
    let name: String
    let nativeName: String
    let center: [Double]
    let bbox: [Double]
    let polygons: [[[Double]]]

    var centerCoordinate: CLLocationCoordinate2D {
        guard center.count >= 2 else {
            return CLLocationCoordinate2D(latitude: 34.5, longitude: 124.5)
        }
        return CLLocationCoordinate2D(latitude: center[1], longitude: center[0])
    }

    var coordinateRings: [[CLLocationCoordinate2D]] {
        polygons.map { ring in
            ring.compactMap { point in
                guard point.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
            }
        }
    }

    var bounds: (minLongitude: Double, minLatitude: Double, maxLongitude: Double, maxLatitude: Double) {
        guard bbox.count >= 4 else {
            let center = centerCoordinate
            return (
                center.longitude - 0.2,
                center.latitude - 0.2,
                center.longitude + 0.2,
                center.latitude + 0.2
            )
        }
        return (bbox[0], bbox[1], bbox[2], bbox[3])
    }

    var minLongitude: Double { bounds.minLongitude }
    var minLatitude: Double { bounds.minLatitude }
    var maxLongitude: Double { bounds.maxLongitude }
    var maxLatitude: Double { bounds.maxLatitude }
}

private struct CityAtlasBoundaryCatalog: Decodable {
    let version: Int
    let boundaries: [CityAtlasBoundary]
    let japanStationToBoundary: [String: String]
    let chinaCityToBoundary: [String: String]
    let koreaModeToBoundary: [String: String]
    let koreaLocationToBoundary: [String: String]
}

private struct CityAtlasProvinceCatalog: Decodable {
    let version: Int
    let boundaries: [CityAtlasBoundary]
}

private struct CityAtlasResolution {
    let visits: [CityAtlasVisit]
    let provinceBoundaries: [CityAtlasBoundary]
}

private struct CityAtlasVisitAccumulator {
    var evidenceIDs = Set<String>()
    var cardEvidenceCounts: [String: Int] = [:]
    var lastVisited: Date?

    mutating func add(evidenceID: String, cardID: String, date: Date?) {
        guard evidenceIDs.insert(evidenceID).inserted else { return }
        cardEvidenceCounts[cardID, default: 0] += 1
        if let date, lastVisited == nil || date > lastVisited! {
            lastVisited = date
        }
    }
}

private enum CityAtlasResolverError: LocalizedError {
    case missingCatalog
    case unreadableCatalog
    case unsupportedCatalog(Int)

    var errorDescription: String? {
        switch self {
        case .missingCatalog:
            return String(localized: "The bundled East Asia city boundaries are missing.")
        case .unreadableCatalog:
            return String(localized: "The bundled East Asia city boundaries could not be read.")
        case .unsupportedCatalog(let version):
            return String(localized: "Unsupported city boundary data version \(version).")
        }
    }
}

private struct CityAtlasVisitResolver {
    func resolve(cards: [SavedCardRecord]) throws -> CityAtlasResolution {
        guard let cityURL = Bundle.main.url(
            forResource: "EastAsiaCityBoundaries",
            withExtension: "json"
        ), let provinceURL = Bundle.main.url(
            forResource: "EastAsiaProvinceBoundaries",
            withExtension: "json"
        ) else {
            throw CityAtlasResolverError.missingCatalog
        }
        guard let cityData = try? Data(contentsOf: cityURL),
              let provinceData = try? Data(contentsOf: provinceURL),
              let catalog = try? JSONDecoder().decode(CityAtlasBoundaryCatalog.self, from: cityData),
              let provinceCatalog = try? JSONDecoder().decode(CityAtlasProvinceCatalog.self, from: provinceData) else {
            throw CityAtlasResolverError.unreadableCatalog
        }
        guard catalog.version == 1 else {
            throw CityAtlasResolverError.unsupportedCatalog(catalog.version)
        }
        guard provinceCatalog.version == 1 else {
            throw CityAtlasResolverError.unsupportedCatalog(provinceCatalog.version)
        }

        let provinceBoundaries = provinceCatalog.boundaries.filter { boundary in
            boundary.countryCode != .china || !boundary.name.localizedCaseInsensitiveContains("Taiwan")
        }

        let boundaries = Dictionary(uniqueKeysWithValues: catalog.boundaries.map { ($0.id, $0) })
        let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        var accumulators: [String: CityAtlasVisitAccumulator] = [:]

        for card in cards {
            let region = ICCardBrand.from(family: card.cardFamily).region
            if isSupportedJapaneseTransitCard(card, region: region) {
                addJapaneseEvidence(
                    from: card,
                    lookup: catalog.japanStationToBoundary,
                    accumulators: &accumulators
                )
            }

            switch region {
            case .china:
                addChineseEvidence(
                    from: card,
                    lookup: catalog.chinaCityToBoundary,
                    accumulators: &accumulators
                )
            case .korea:
                addKoreanEvidence(
                    from: card,
                    locationLookup: catalog.koreaLocationToBoundary,
                    accumulators: &accumulators
                )
            default:
                break
            }
        }

        let visits = accumulators.compactMap { boundaryID, accumulator -> CityAtlasVisit? in
            guard let boundary = boundaries[boundaryID] else { return nil }
            let cardVisits = accumulator.cardEvidenceCounts.compactMap { cardID, count -> CityAtlasCardVisit? in
                guard let card = cardsByID[cardID] else { return nil }
                return CityAtlasCardVisit(
                    id: card.id,
                    title: card.displayTitle,
                    color: card.markerColor,
                    recordCount: count
                )
            }
            .sorted {
                if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }

            return CityAtlasVisit(
                id: boundaryID,
                boundary: boundary,
                country: boundary.countryCode,
                recordCount: accumulator.evidenceIDs.count,
                evidenceIDs: accumulator.evidenceIDs,
                cards: cardVisits,
                lastVisited: accumulator.lastVisited
            )
        }
        .sorted {
            if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return CityAtlasResolution(visits: visits, provinceBoundaries: provinceBoundaries)
    }

    private func isSupportedJapaneseTransitCard(
        _ card: SavedCardRecord,
        region: ICCardRegion
    ) -> Bool {
        if region == .japan {
            return true
        }

        let family = card.cardFamily
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["japan transit ic", "iruca", "paspy", "sapica"].contains(family) {
            return true
        }

        guard card.technology.caseInsensitiveCompare("FeliCa") == .orderedSame else {
            return false
        }
        let systemCode = (card.systemCode ?? "")
            .uppercased()
            .filter(\.isHexDigit)
        return ["0003", "80DE", "8592", "865E"].contains(systemCode)
    }

    private func addJapaneseEvidence(
        from card: SavedCardRecord,
        lookup: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        // Standard 090F records carry the full five-hex area + line + station code.
        // The shorter 108F/10CB activity tokens can collide across regions, so they
        // stay off the city map until the decoder can prove a unique full code.
        for transaction in card.transactions {
            let normalized = normalizedRaw(transaction.rawData)
            let rawEvidence = normalized.isEmpty ? transaction.stableID : normalized
            let codes = [transaction.entryStationCode, transaction.exitStationCode]
                .compactMap { $0 }
            let boundaryIDs = Set(codes.compactMap { lookup[normalizedJapaneseStationCode($0)] })

            for boundaryID in boundaryIDs {
                let evidenceID = "\(card.id)|\(rawEvidence)"
                accumulators[boundaryID, default: CityAtlasVisitAccumulator()].add(
                    evidenceID: evidenceID,
                    cardID: card.id,
                    date: transaction.date
                )
            }
        }
    }

    private func addChineseEvidence(
        from card: SavedCardRecord,
        lookup: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        let rawRecords = Set(card.rawTransitHistory.map(normalizedRaw))
        for raw in rawRecords {
            let data = Data(hexString: raw)
            let cityID: String?
            let date: Date?

            if data.count >= 48 {
                cityID = data.subdata(in: 32..<34).hexString.uppercased()
                let compactDateTime = data.subdata(in: 25..<32).hexString
                date = CardDateFormatting.parseCompactDateTime(
                    compactDateTime,
                    format: "yyyyMMddHHmmss",
                    brand: .tUnion
                )
            } else if data.count >= 23 {
                let terminal = data.subdata(in: 10..<16).hexString.uppercased()
                cityID = String(terminal.prefix(4))
                let compactDateTime = data.subdata(in: 16..<23).hexString
                date = CardDateFormatting.parseCompactDateTime(
                    compactDateTime,
                    format: "yyyyMMddHHmmss",
                    brand: .tUnion
                )
            } else {
                cityID = nil
                date = nil
            }

            guard let cityID,
                  let boundaryID = lookup[cityID.uppercased()] else {
                continue
            }
            let evidenceID = "\(card.id)|\(raw)"
            accumulators[boundaryID, default: CityAtlasVisitAccumulator()].add(
                evidenceID: evidenceID,
                cardID: card.id,
                date: date
            )
        }
    }

    private func addKoreanEvidence(
        from card: SavedCardRecord,
        locationLookup: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        let rawRecords = Set(card.rawTransitHistory.map(normalizedRaw))
        for raw in rawRecords {
            let data = Data(hexString: raw)
            guard data.count == 52, data[2] == 0x00 || data[2] == 0x01 else {
                continue
            }

            let locationCode = data.subdata(in: 5..<11).hexString.uppercased()
            guard let boundaryID = locationLookup[locationCode] else { continue }

            let evidenceID = "\(card.id)|\(raw)"
            accumulators[boundaryID, default: CityAtlasVisitAccumulator()].add(
                evidenceID: evidenceID,
                cardID: card.id,
                date: KoreanTransitTimestampDecoder.decode(data)?.date
            )
        }
    }

    private func normalizedJapaneseStationCode(_ value: String) -> String {
        var normalized = value
            .replacingOccurrences(of: "0x", with: "", options: [.caseInsensitive])
            .uppercased()
            .filter(\.isHexDigit)
        if normalized.count < 5 {
            normalized = String(repeating: "0", count: 5 - normalized.count) + normalized
        }
        return normalized
    }

    private func normalizedRaw(_ value: String?) -> String {
        (value ?? "")
            .uppercased()
            .filter(\.isHexDigit)
    }
}
