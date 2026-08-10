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
    @State private var provinceVisits: [CityAtlasVisit] = []
    @State private var cityBoundaries: [CityAtlasBoundary] = []
    @State private var provinceBoundaries: [CityAtlasBoundary] = []
    @State private var countryExtentBoundaries: [CityAtlasBoundary] = []
    @State private var cityReferenceLines: [CityAtlasReferenceLineBatch] = []
    @State private var provinceReferenceLines: [CityAtlasReferenceLineBatch] = []
    @State private var scope: CityAtlasScope = .all
    @State private var boundaryLevel: CityAtlasBoundaryLevel = .province
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

    private var visibleProvinceVisits: [CityAtlasVisit] {
        guard let country = scope.country else { return provinceVisits }
        return provinceVisits.filter { $0.country == country }
    }

    private var visibleDisplayVisits: [CityAtlasVisit] {
        boundaryLevel == .province ? visibleProvinceVisits : visibleVisits
    }

    private var visibleProvinceBoundaries: [CityAtlasBoundary] {
        guard let country = scope.country else { return provinceBoundaries }
        return provinceBoundaries.filter { $0.countryCode == country }
    }

    private var visibleCityBoundaries: [CityAtlasBoundary] {
        guard let country = scope.country else { return cityBoundaries }
        return cityBoundaries.filter { $0.countryCode == country }
    }

    private var visibleReferenceBoundaries: [CityAtlasBoundary] {
        switch boundaryLevel {
        case .province: return visibleProvinceBoundaries
        case .city: return visibleCityBoundaries
        }
    }

    private var visibleReferenceLines: [CityAtlasReferenceLineBatch] {
        let batches = boundaryLevel == .province
            ? provinceReferenceLines
            : cityReferenceLines
        guard let country = scope.country else { return batches }
        return batches.filter { $0.countryCode == country }
    }

    private var recordCount: Int {
        Set(visibleDisplayVisits.flatMap(\.recordEvidenceIDs)).count
    }

    private var cardCount: Int {
        Set(visibleDisplayVisits.flatMap { $0.cards.map(\.id) }).count
    }

    private var placeCountLabel: LocalizedStringKey {
        boundaryLevel == .province ? "Provinces" : "Cities"
    }

    private var loadingPlaceLabel: LocalizedStringKey {
        boundaryLevel == .province ? "Loading provinces…" : "Loading cities…"
    }

    private var unavailablePlaceLabel: LocalizedStringKey {
        boundaryLevel == .province ? "Province map unavailable" : "City map unavailable"
    }

    private var emptyPlaceLabel: LocalizedStringKey {
        boundaryLevel == .province ? "Your provinces will glow here" : "Your cities will glow here"
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
                return visibleDisplayVisits.first { $0.id == selectedCityID }
            },
            set: { selectedCityID = $0?.id }
        )
    }

    var body: some View {
        ZStack {
            Color(red: 0.015, green: 0.035, blue: 0.07)
                .ignoresSafeArea()

            CityAtlasMapRepresentable(
                visits: visibleDisplayVisits,
                referenceBoundaries: visibleReferenceBoundaries,
                referenceLines: visibleReferenceLines,
                countryExtentBoundaries: countryExtentBoundaries,
                scope: scope,
                boundaryLevel: boundaryLevel,
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
                    .padding(.horizontal, 16)
                Spacer(minLength: 80)
                bottomPanel
            }
            .padding(.top, 8)
            .zIndex(1)
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
                        .font(.system(.title2, design: .default, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Spacer()

                Button {
                    scope = .all
                    focusedCityID = nil
                    selectedCityID = nil
                    resetCameraRevision &+= 1
                    cameraRevision &+= 1
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.36))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset East Asia view")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(CityAtlasScope.allCases) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scope = item
                            }
                            focusedCityID = nil
                            selectedCityID = nil
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
                            .foregroundStyle(scope == item ? Color.white : Color.white.opacity(0.66))
                            .padding(.horizontal, 1)
                            .frame(height: 36)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(scope == item ? Color.white : Color.clear)
                                    .frame(height: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(scope == item ? .isSelected : [])
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    Text("BOUNDARIES")
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.46))

                    ForEach(CityAtlasBoundaryLevel.allCases) { item in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                boundaryLevel = item
                            }
                            focusedCityID = nil
                            selectedCityID = nil
                            cameraRevision &+= 1
                        } label: {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(
                                    boundaryLevel == item ? Color.white : Color.white.opacity(0.58)
                                )
                                .padding(.horizontal, 6)
                                .frame(minWidth: 44, minHeight: 28)
                                .contentShape(Rectangle())
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(boundaryLevel == item ? Color.white : Color.clear)
                                        .frame(height: 2)
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(boundaryLevel == item ? .isSelected : [])
                    }

                    Spacer(minLength: 0)
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
                Text(loadingPlaceLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .cityAtlasRail()
        } else if let loadError {
            VStack(alignment: .leading, spacing: 7) {
                Label(unavailablePlaceLabel, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .cityAtlasRail()
        } else if visits.isEmpty && provinceVisits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(emptyPlaceLabel, systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Scan a supported transit card.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .cityAtlasRail()
        } else if visibleDisplayVisits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if boundaryLevel == .province {
                    Text("No provinces in \(scope.title)")
                        .font(.headline)
                        .foregroundStyle(.white)
                } else {
                    Text("No cities in \(scope.title)")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                Text("No saved transit records appear here yet.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .cityAtlasRail()
        } else {
            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    CityAtlasStat(value: "\(visibleDisplayVisits.count)", label: placeCountLabel)
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 0.5, height: 30)
                    CityAtlasStat(value: "\(recordCount)", label: "Records")
                    Rectangle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 0.5, height: 30)
                    CityAtlasStat(value: "\(cardCount)", label: "Cards")
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(visibleDisplayVisits) { visit in
                            Button {
                                focusedCityID = visit.id
                                cameraRevision &+= 1
                            } label: {
                                HStack(spacing: 9) {
                                    Rectangle()
                                        .fill(visit.country.tint)
                                        .frame(width: 3, height: 27)
                                        .shadow(color: visit.country.tint.opacity(0.55), radius: 3)

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
                                .padding(.horizontal, 10)
                                .frame(height: 44)
                                .background(
                                    focusedCityID == visit.id
                                        ? visit.country.tint.opacity(0.14)
                                        : Color.white.opacity(0.045)
                                )
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(
                                            focusedCityID == visit.id
                                                ? visit.country.tint
                                                : Color.white.opacity(0.12)
                                        )
                                        .frame(height: focusedCityID == visit.id ? 2 : 0.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(focusedCityID == visit.id ? .isSelected : [])
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
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .cityAtlasRail()
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
            provinceVisits = resolution.provinceVisits
            cityBoundaries = resolution.cityBoundaries
            provinceBoundaries = resolution.provinceBoundaries
            countryExtentBoundaries = resolution.countryExtentBoundaries
            cityReferenceLines = resolution.cityReferenceLines
            provinceReferenceLines = resolution.provinceReferenceLines
            let placeIDs = Set(
                resolution.visits.map(\.id) + resolution.provinceVisits.map(\.id)
            )
            if let focusedCityID, !placeIDs.contains(focusedCityID) {
                self.focusedCityID = nil
            }
            if let selectedCityID, !placeIDs.contains(selectedCityID) {
                self.selectedCityID = nil
            }
        case .failure(let error):
            visits = []
            provinceVisits = []
            cityBoundaries = []
            provinceBoundaries = []
            countryExtentBoundaries = []
            cityReferenceLines = []
            provinceReferenceLines = []
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
                .font(.system(.title3, design: .default, weight: .semibold).monospacedDigit())
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
            }
            .navigationTitle(visit.displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension View {
    func cityAtlasRail() -> some View {
        background(Color(red: 0.025, green: 0.045, blue: 0.075).opacity(0.94))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(height: 0.5)
            }
    }
}

// MARK: - Map

private struct CityAtlasMapRepresentable: UIViewRepresentable {
    // The normal camera stays close; data-derived country extents may zoom out farther.
    static let defaultEastAsiaDistance: CLLocationDistance = 14_000_000
    static let maximumEastAsiaDistance: CLLocationDistance = 30_000_000

    let visits: [CityAtlasVisit]
    let referenceBoundaries: [CityAtlasBoundary]
    let referenceLines: [CityAtlasReferenceLineBatch]
    let countryExtentBoundaries: [CityAtlasBoundary]
    let scope: CityAtlasScope
    let boundaryLevel: CityAtlasBoundaryLevel
    let focusedCityID: String?
    let cameraRevision: Int
    let resetCameraRevision: Int
    @Binding var selectedCityID: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.preferredConfiguration = Self.globeConfiguration()
        mapView.overrideUserInterfaceStyle = .dark
        mapView.delegate = context.coordinator
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.isZoomEnabled = true
        mapView.showsBuildings = true
        mapView.showsCompass = true

        let eastAsia = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 32, longitude: 109),
            span: MKCoordinateSpan(latitudeDelta: 52, longitudeDelta: 92)
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
        if !(mapView.preferredConfiguration is MKHybridMapConfiguration) {
            mapView.preferredConfiguration = Self.globeConfiguration()
        }
        context.coordinator.parent = self
        context.coordinator.updateMap(mapView)
    }

    private static func globeConfiguration() -> MKMapConfiguration {
        let configuration = MKHybridMapConfiguration(elevationStyle: .realistic)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        return configuration
    }

    static let allScopeAnchors = [
        CLLocationCoordinate2D(latitude: 43.0618, longitude: 141.3545), // Sapporo
        CLLocationCoordinate2D(latitude: 34.3416, longitude: 108.9398), // Xi'an
        CLLocationCoordinate2D(latitude: 45.8038, longitude: 126.5340), // Harbin
        CLLocationCoordinate2D(latitude: 47.9189, longitude: 106.9176), // Ulaanbaatar
        CLLocationCoordinate2D(latitude: 10.8231, longitude: 106.6297), // Ho Chi Minh City
    ]

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
        private var selectedOverlay: MKMultiPolygon?
        private var selectedBoundaryID: String?

        init(parent: CityAtlasMapRepresentable) {
            self.parent = parent
        }

        func updateMap(_ mapView: MKMapView) {
            let visitSignature = parent.visits
                .map { "\($0.id):\($0.recordCount):\($0.cards.count)" }
                .joined(separator: "|")
            let referenceSignature = parent.referenceLines
                .map(\.signature)
                .sorted()
                .joined(separator: "|")
            let signature = "scope=\(parent.scope.id)|level=\(parent.boundaryLevel.id)|references=\(referenceSignature)|visits=\(visitSignature)"

            if signature != renderedSignature {
                renderedSignature = signature
                rebuildOverlays(on: mapView)
            }
            updateSelectedOverlay(on: mapView)

            guard parent.cameraRevision != lastCameraRevision else { return }
            lastCameraRevision = parent.cameraRevision
            if parent.resetCameraRevision != lastResetCameraRevision {
                lastResetCameraRevision = parent.resetCameraRevision
                focusOnAllCountries(mapView: mapView)
                return
            }
            if let focusedCityID = parent.focusedCityID,
               let visit = visitByID[focusedCityID] {
                focus(on: visit, mapView: mapView)
            } else if let country = parent.scope.country {
                let countryExtent = parent.countryExtentBoundaries.filter {
                    $0.countryCode == country
                }
                focus(
                    on: countryExtent.isEmpty ? parent.referenceBoundaries : countryExtent,
                    mapView: mapView
                )
            } else {
                focusOnAllCountries(mapView: mapView)
            }
        }

        private func focusOnAllCountries(mapView: MKMapView) {
            focus(
                on: parent.countryExtentBoundaries,
                extraCoordinates: CityAtlasMapRepresentable.allScopeAnchors,
                mapView: mapView
            )
        }

        private func rebuildOverlays(on mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations)
            styles.removeAll(keepingCapacity: true)
            visitByID = Dictionary(uniqueKeysWithValues: parent.visits.map { ($0.id, $0) })
            selectedOverlay = nil
            selectedBoundaryID = nil

            var referenceOverlays: [MKMultiPolyline] = []
            var glowPolygons: [CityAtlasCountry: [MKPolygon]] = [:]
            var glowOverlays: [MKMultiPolygon] = []
            var fillOverlays: [MKPolygon] = []
            var annotations: [CityAtlasAnnotation] = []

            for batch in parent.referenceLines.sorted(by: { $0.sortKey < $1.sortKey }) {
                let referenceOverlay = MKMultiPolyline(batch.makeMapPolylines())
                styles[ObjectIdentifier(referenceOverlay)] = referenceStyle(
                    for: batch.countryCode,
                    level: parent.boundaryLevel
                )
                referenceOverlays.append(referenceOverlay)
            }

            var visitedMasks: [String: CityAtlasVisitedMask] = [:]
            for visit in parent.visits {
                let boundary = visit.boundary

                if var mask = visitedMasks[boundary.id] {
                    mask.evidenceIDs.formUnion(visit.evidenceIDs)
                    visitedMasks[boundary.id] = mask
                } else {
                    visitedMasks[boundary.id] = CityAtlasVisitedMask(
                        boundary: boundary,
                        country: visit.country,
                        evidenceIDs: visit.evidenceIDs
                    )
                }
            }

            for mask in visitedMasks.values.sorted(by: { $0.boundary.id < $1.boundary.id }) {
                let baseAlpha = min(
                    0.56,
                    0.30 + log2(Double(mask.recordCount) + 1) * 0.06
                )
                let visibleAlpha: CGFloat
                switch (parent.boundaryLevel, mask.country) {
                case (_, .china): visibleAlpha = baseAlpha
                case (.province, .japan): visibleAlpha = max(0.40, baseAlpha)
                case (.city, .japan): visibleAlpha = max(0.36, baseAlpha)
                case (.province, .korea): visibleAlpha = max(0.40, baseAlpha)
                case (.city, .korea): visibleAlpha = max(0.44, baseAlpha)
                case (.province, .mongolia): visibleAlpha = max(0.40, baseAlpha)
                case (.city, .mongolia): visibleAlpha = max(0.44, baseAlpha)
                }
                let fillAlpha = visibleAlpha

                for fill in mask.boundary.makeMapPolygons() {
                    styles[ObjectIdentifier(fill)] = CityAtlasOverlayStyle(
                        color: mask.country.uiTint,
                        fillAlpha: fillAlpha,
                        strokeAlpha: 0,
                        lineWidth: 0
                    )
                    fillOverlays.append(fill)
                }
                glowPolygons[mask.country, default: []].append(
                    contentsOf: mask.boundary.makeMapPolygons()
                )
            }

            for country in CityAtlasCountry.allCases {
                guard let polygons = glowPolygons[country], !polygons.isEmpty else { continue }
                let glow = MKMultiPolygon(polygons)
                styles[ObjectIdentifier(glow)] = CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.24,
                    lineWidth: glowLineWidth(
                        for: country,
                        level: parent.boundaryLevel
                    ),
                    overviewLineWidth: overviewGlowLineWidth(
                        for: country,
                        level: parent.boundaryLevel
                    )
                )
                glowOverlays.append(glow)
            }

            for visit in parent.visits {
                annotations.append(CityAtlasAnnotation(visit: visit))
            }

            mapView.addOverlays(glowOverlays, level: .aboveRoads)
            mapView.addOverlays(fillOverlays, level: .aboveRoads)
            // Keep the generated, de-duplicated linework above map labels so it
            // remains legible at close zoom without rebuilding overlays.
            mapView.addOverlays(referenceOverlays, level: .aboveLabels)
            mapView.addAnnotations(annotations)
        }

        private func updateSelectedOverlay(on mapView: MKMapView) {
            guard selectedBoundaryID != parent.selectedCityID else { return }
            if let selectedOverlay {
                mapView.removeOverlay(selectedOverlay)
                styles.removeValue(forKey: ObjectIdentifier(selectedOverlay))
            }
            selectedOverlay = nil
            selectedBoundaryID = parent.selectedCityID

            guard let selectedBoundaryID,
                  let visit = visitByID[selectedBoundaryID] else { return }
            let polygons = visit.boundary.makeMapPolygons()
            guard !polygons.isEmpty else { return }

            let overlay = MKMultiPolygon(polygons)
            styles[ObjectIdentifier(overlay)] = CityAtlasOverlayStyle(
                color: visit.country.uiTint,
                fillAlpha: 0,
                strokeAlpha: 0.40,
                lineWidth: parent.boundaryLevel == .province ? 8 : 6.5,
                overviewLineWidth: parent.boundaryLevel == .province ? 1.8 : 1.5
            )
            selectedOverlay = overlay
            mapView.addOverlay(overlay, level: .aboveLabels)
        }

        private func glowLineWidth(
            for country: CityAtlasCountry,
            level: CityAtlasBoundaryLevel
        ) -> CGFloat {
            switch (level, country) {
            case (.province, .china): return 7
            case (.province, .japan), (.province, .korea), (.province, .mongolia): return 6
            case (.city, .china), (.city, .japan), (.city, .korea), (.city, .mongolia): return 5.5
            }
        }

        private func overviewGlowLineWidth(
            for country: CityAtlasCountry,
            level: CityAtlasBoundaryLevel
        ) -> CGFloat {
            switch (level, country) {
            case (.province, .china): return 1.5
            case (.province, .japan), (.province, .korea), (.province, .mongolia): return 1.4
            case (.city, .china), (.city, .japan), (.city, .korea), (.city, .mongolia): return 1.25
            }
        }

        private func referenceStyle(
            for country: CityAtlasCountry,
            level: CityAtlasBoundaryLevel
        ) -> CityAtlasOverlayStyle {
            switch (level, country) {
            case (.province, .china):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.88,
                    lineWidth: 2.2,
                    overviewLineWidth: 0.85
                )
            case (.province, .japan):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.82,
                    lineWidth: 2.0,
                    overviewLineWidth: 0.75
                )
            case (.province, .korea):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.90,
                    lineWidth: 2.1,
                    overviewLineWidth: 0.80
                )
            case (.province, .mongolia):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.90,
                    lineWidth: 2.1,
                    overviewLineWidth: 0.80
                )
            case (.city, .china):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.82,
                    lineWidth: 1.75,
                    overviewLineWidth: 0.55
                )
            case (.city, .japan):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.78,
                    lineWidth: 1.6,
                    overviewLineWidth: 0.50
                )
            case (.city, .korea):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.88,
                    lineWidth: 1.8,
                    overviewLineWidth: 0.60
                )
            case (.city, .mongolia):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.88,
                    lineWidth: 1.8,
                    overviewLineWidth: 0.60
                )
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multiPolyline = overlay as? MKMultiPolyline,
               let style = styles[ObjectIdentifier(multiPolyline)] {
                return configured(
                    CityAtlasAdaptiveMultiPolylineRenderer(
                        multiPolyline: multiPolyline,
                        overviewLineWidth: style.overviewLineWidth,
                        detailLineWidth: style.lineWidth
                    ),
                    style: style
                )
            }
            if let multiPolygon = overlay as? MKMultiPolygon,
               let style = styles[ObjectIdentifier(multiPolygon)] {
                return configured(
                    CityAtlasAdaptiveMultiPolygonRenderer(
                        multiPolygon: multiPolygon,
                        overviewLineWidth: style.overviewLineWidth,
                        detailLineWidth: style.lineWidth
                    ),
                    style: style
                )
            }
            if let polygon = overlay as? MKPolygon,
               let style = styles[ObjectIdentifier(polygon)] {
                return configured(
                    MKPolygonRenderer(polygon: polygon),
                    style: style
                )
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
            if parent.boundaryLevel == .province {
                focus(
                    on: [visit.boundary],
                    mapView: mapView
                )
                return
            }

            let renderedCoordinates = visit.boundary.outerCoordinatesForBounds
            let renderedBounds = renderedCoordinates.dropFirst().reduce(
                into: (
                    minLongitude: renderedCoordinates.first?.longitude ?? visit.boundary.minLongitude,
                    minLatitude: renderedCoordinates.first?.latitude ?? visit.boundary.minLatitude,
                    maxLongitude: renderedCoordinates.first?.longitude ?? visit.boundary.maxLongitude,
                    maxLatitude: renderedCoordinates.first?.latitude ?? visit.boundary.maxLatitude
                )
            ) { bounds, coordinate in
                bounds.minLongitude = min(bounds.minLongitude, coordinate.longitude)
                bounds.minLatitude = min(bounds.minLatitude, coordinate.latitude)
                bounds.maxLongitude = max(bounds.maxLongitude, coordinate.longitude)
                bounds.maxLatitude = max(bounds.maxLatitude, coordinate.latitude)
            }
            let width = max(abs(renderedBounds.maxLongitude - renderedBounds.minLongitude), 0.08)
            let height = max(abs(renderedBounds.maxLatitude - renderedBounds.minLatitude), 0.08)
            let distance = min(max(max(width, height) * 145_000, 70_000), 1_250_000)
            let camera = MKMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(
                    latitude: (renderedBounds.minLatitude + renderedBounds.maxLatitude) / 2,
                    longitude: (renderedBounds.minLongitude + renderedBounds.maxLongitude) / 2
                ),
                fromDistance: distance,
                pitch: distance < 300_000 ? 58 : 48,
                heading: 350
            )
            mapView.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
        }

        private func focus(
            on boundaries: [CityAtlasBoundary],
            extraCoordinates: [CLLocationCoordinate2D] = [],
            mapView: MKMapView
        ) {
            var visibleRect = MKMapRect.null
            for boundary in boundaries {
                for polygon in boundary.makeMapPolygons() {
                    visibleRect = visibleRect.isNull
                        ? polygon.boundingMapRect
                        : visibleRect.union(polygon.boundingMapRect)
                }
            }

            for coordinate in extraCoordinates {
                let point = MKMapPoint(coordinate)
                let pointRect = MKMapRect(x: point.x, y: point.y, width: 1, height: 1)
                visibleRect = visibleRect.isNull ? pointRect : visibleRect.union(pointRect)
            }

            guard !visibleRect.isNull, !visibleRect.isEmpty else {
                mapView.setCamera(
                    CityAtlasMapRepresentable.eastAsiaCamera,
                    animated: !UIAccessibility.isReduceMotionEnabled
                )
                return
            }

            let countries = Set(boundaries.map(\.countryCode))
            let country = countries.count == 1 ? countries.first : nil
            let expansionRatio: Double
            switch country {
            case .china: expansionRatio = 0.08
            case nil: expansionRatio = 0.06
            case .mongolia: expansionRatio = 0.04
            case .japan, .korea: expansionRatio = 0
            }
            if expansionRatio > 0 {
                let horizontalMargin = visibleRect.size.width * expansionRatio
                let verticalMargin = visibleRect.size.height * expansionRatio
                visibleRect = MKMapRect(
                    x: visibleRect.origin.x - horizontalMargin,
                    y: visibleRect.origin.y - verticalMargin,
                    width: visibleRect.size.width + horizontalMargin * 2,
                    height: visibleRect.size.height + verticalMargin * 2
                )
            }

            let horizontalPadding: CGFloat = country == nil ? 28 : 56
            let edgePadding = UIEdgeInsets(
                top: mapView.safeAreaInsets.top + 152,
                left: horizontalPadding,
                bottom: mapView.safeAreaInsets.bottom + 150,
                right: horizontalPadding
            )
            mapView.setVisibleMapRect(
                visibleRect,
                edgePadding: edgePadding,
                animated: false
            )

            let camera = mapView.camera.copy() as! MKMapCamera
            camera.heading = 0
            camera.pitch = country == .china ? 34 : country == nil ? 30 : 42
            camera.centerCoordinateDistance *= country == nil ? 1.04 : 1.12
            mapView.setCamera(camera, animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }
}

private struct CityAtlasOverlayStyle {
    let color: UIColor
    let fillAlpha: CGFloat
    let strokeAlpha: CGFloat
    let lineWidth: CGFloat
    let overviewLineWidth: CGFloat

    init(
        color: UIColor,
        fillAlpha: CGFloat,
        strokeAlpha: CGFloat,
        lineWidth: CGFloat,
        overviewLineWidth: CGFloat? = nil
    ) {
        self.color = color
        self.fillAlpha = fillAlpha
        self.strokeAlpha = strokeAlpha
        self.lineWidth = lineWidth
        self.overviewLineWidth = overviewLineWidth ?? lineWidth
    }
}

private enum CityAtlasAdaptiveStroke {
    // MapKit's conventional zoom level is log2(zoomScale) + 20. Interpolate
    // inside the renderer so zooming never rebuilds or invalidates overlays.
    private static let overviewZoomLevel = 3.0
    private static let detailZoomLevel = 5.2

    static func apply(
        to context: CGContext,
        zoomScale: MKZoomScale,
        overviewLineWidth: CGFloat,
        detailLineWidth: CGFloat
    ) {
        let zoomLevel = log2(max(Double(zoomScale), Double.leastNormalMagnitude)) + 20
        let linearProgress = max(
            0,
            min(1, (zoomLevel - overviewZoomLevel) / (detailZoomLevel - overviewZoomLevel))
        )
        let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        let screenLineWidth = overviewLineWidth
            + (detailLineWidth - overviewLineWidth) * CGFloat(progress)
        context.setLineWidth(screenLineWidth / max(CGFloat(zoomScale), .leastNonzeroMagnitude))
    }
}

private final class CityAtlasAdaptiveMultiPolylineRenderer: MKMultiPolylineRenderer {
    private let overviewLineWidth: CGFloat
    private let detailLineWidth: CGFloat

    init(
        multiPolyline: MKMultiPolyline,
        overviewLineWidth: CGFloat,
        detailLineWidth: CGFloat
    ) {
        self.overviewLineWidth = overviewLineWidth
        self.detailLineWidth = detailLineWidth
        super.init(overlay: multiPolyline)
    }

    override init(overlay: any MKOverlay) {
        overviewLineWidth = 0
        detailLineWidth = 0
        super.init(overlay: overlay)
    }

    override func applyStrokeProperties(to context: CGContext, atZoomScale zoomScale: MKZoomScale) {
        super.applyStrokeProperties(to: context, atZoomScale: zoomScale)
        CityAtlasAdaptiveStroke.apply(
            to: context,
            zoomScale: zoomScale,
            overviewLineWidth: overviewLineWidth,
            detailLineWidth: detailLineWidth
        )
    }
}

private final class CityAtlasAdaptiveMultiPolygonRenderer: MKMultiPolygonRenderer {
    private let overviewLineWidth: CGFloat
    private let detailLineWidth: CGFloat

    init(
        multiPolygon: MKMultiPolygon,
        overviewLineWidth: CGFloat,
        detailLineWidth: CGFloat
    ) {
        self.overviewLineWidth = overviewLineWidth
        self.detailLineWidth = detailLineWidth
        super.init(overlay: multiPolygon)
    }

    override init(overlay: any MKOverlay) {
        overviewLineWidth = 0
        detailLineWidth = 0
        super.init(overlay: overlay)
    }

    override func applyStrokeProperties(to context: CGContext, atZoomScale zoomScale: MKZoomScale) {
        super.applyStrokeProperties(to: context, atZoomScale: zoomScale)
        CityAtlasAdaptiveStroke.apply(
            to: context,
            zoomScale: zoomScale,
            overviewLineWidth: overviewLineWidth,
            detailLineWidth: detailLineWidth
        )
    }
}

private struct CityAtlasVisitedMask {
    let boundary: CityAtlasBoundary
    let country: CityAtlasCountry
    var evidenceIDs: Set<String>

    var recordCount: Int { evidenceIDs.count }
}

private final class CityAtlasAnnotation: NSObject, MKAnnotation {
    let cityID: String
    let cityName: String
    let recordCount: Int
    let country: CityAtlasCountry
    let tint: UIColor
    let coordinate: CLLocationCoordinate2D

    init(visit: CityAtlasVisit) {
        cityID = visit.id
        cityName = visit.displayName
        recordCount = visit.recordCount
        country = visit.country
        tint = visit.country.uiTint
        coordinate = visit.boundary.centerCoordinate
        super.init()
    }
}

private final class CityAtlasAnnotationView: MKAnnotationView {
    private let dot = UIView()
    private let label = UILabel()
    private let plate = UIView()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .rectangle
        displayPriority = .defaultHigh
        canShowCallout = false

        plate.backgroundColor = UIColor(red: 0.025, green: 0.045, blue: 0.075, alpha: 0.86)
        plate.layer.cornerRadius = 3
        plate.layer.borderWidth = 0.5
        plate.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        plate.clipsToBounds = true
        plate.addSubview(label)
        addSubview(plate)
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
        let plateWidth = min(max(labelSize.width + 14, 56), 178)
        frame = CGRect(x: 0, y: 0, width: plateWidth + 20, height: 30)
        let placesLabelOnLeft: Bool
        if annotation.country == .china {
            placesLabelOnLeft = annotation.coordinate.longitude >= 110
        } else if annotation.country == .mongolia {
            placesLabelOnLeft = annotation.coordinate.longitude >= 107
        } else {
            placesLabelOnLeft = annotation.coordinate.longitude >= 132
        }
        dot.frame = CGRect(
            x: placesLabelOnLeft ? plateWidth + 10 : 0,
            y: 10,
            width: 10,
            height: 10
        )
        dot.layer.cornerRadius = 5
        dot.backgroundColor = annotation.tint
        dot.layer.shadowColor = annotation.tint.cgColor
        plate.frame = CGRect(
            x: placesLabelOnLeft ? 6 : 14,
            y: 3,
            width: plateWidth,
            height: 24
        )
        label.frame = plate.bounds
        centerOffset = CGPoint(
            x: (bounds.width / 2 - 5) * (placesLabelOnLeft ? -1 : 1),
            y: 0
        )
        accessibilityLabel = "\(annotation.cityName), \(cityAtlasRecordCountText(annotation.recordCount))"
        isAccessibilityElement = true
    }
}

// MARK: - Visit resolution

private enum CityAtlasCountry: String, Decodable, CaseIterable, Hashable {
    case china = "CN"
    case japan = "JP"
    case korea = "KR"
    case mongolia = "MN"

    var title: String {
        switch self {
        case .china: return String(localized: "China")
        case .japan: return String(localized: "Japan")
        case .korea: return String(localized: "South Korea")
        case .mongolia: return String(localized: "Mongolia")
        }
    }

    var tint: Color {
        switch self {
        case .china: return Color(red: 1.0, green: 0.38, blue: 0.25)
        case .japan: return Color(red: 0.25, green: 0.78, blue: 1.0)
        case .korea: return Color(red: 0.65, green: 0.55, blue: 1.0)
        case .mongolia: return Color(red: 0.95, green: 0.68, blue: 0.24)
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
        case .mongolia: return .umoney
        }
    }
}

private enum CityAtlasScope: String, CaseIterable, Identifiable {
    case all
    case china
    case japan
    case korea
    case mongolia

    var id: String { rawValue }

    var country: CityAtlasCountry? {
        switch self {
        case .all: return nil
        case .china: return .china
        case .japan: return .japan
        case .korea: return .korea
        case .mongolia: return .mongolia
        }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .china: return String(localized: "China")
        case .japan: return String(localized: "Japan")
        case .korea: return String(localized: "Korea")
        case .mongolia: return String(localized: "Mongolia")
        }
    }
}

private enum CityAtlasBoundaryLevel: String, CaseIterable, Identifiable {
    case province
    case city

    var id: String { rawValue }

    var title: String {
        switch self {
        case .province: return String(localized: "Province")
        case .city: return String(localized: "City")
        }
    }

}

private struct CityAtlasVisit: Identifiable {
    let id: String
    let boundary: CityAtlasBoundary
    let country: CityAtlasCountry
    let recordCount: Int
    let evidenceIDs: Set<String>
    let recordEvidenceIDs: Set<String>
    let cards: [CityAtlasCardVisit]
    let lastVisited: Date?
    let displayNameOverride: String?

    var displayName: String {
        displayNameOverride.flatMap(normalizedName)
            ?? normalizedName(boundary.name)
            ?? normalizedName(boundary.nativeName)
            ?? String(localized: "City")
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

private struct CityAtlasReferenceLineBatch: Decodable {
    let countryCode: CityAtlasCountry
    let bucket: String
    let lines: [[[Double]]]

    private enum CodingKeys: String, CodingKey {
        case countryCode
        case bucket
        case lines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        countryCode = try container.decode(CityAtlasCountry.self, forKey: .countryCode)
        bucket = try container.decode(String.self, forKey: .bucket)
        lines = try container.decode([[[Double]]].self, forKey: .lines)

        guard !bucket.isEmpty,
              !lines.isEmpty,
              lines.allSatisfy({ line in
                  line.count >= 2 && line.allSatisfy { point in
                      point.count == 2 && point.allSatisfy(\.isFinite)
                  }
              }) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Reference-line batches require a bucket and valid two-point lines."
                )
            )
        }
    }

    var sortKey: String { "\(countryCode.rawValue):\(bucket)" }

    var signature: String {
        let vertexCount = lines.reduce(0) { $0 + $1.count }
        return "\(sortKey):\(lines.count):\(vertexCount)"
    }

    func makeMapPolylines() -> [MKPolyline] {
        lines.map { line in
            var coordinates = line.map {
                CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0])
            }
            return MKPolyline(coordinates: &coordinates, count: coordinates.count)
        }
    }
}

private struct CityAtlasBoundaryComponent: Decodable {
    let outer: [[Double]]
    let holes: [[[Double]]]
}

private struct CityAtlasCoordinateComponent {
    let outer: [CLLocationCoordinate2D]
    let holes: [[CLLocationCoordinate2D]]
}

private struct CityAtlasBoundary: Decodable {
    let id: String
    let countryCode: CityAtlasCountry
    let subdivisionCode: String?
    let name: String
    let nativeName: String
    let center: [Double]
    let bbox: [Double]
    let components: [CityAtlasBoundaryComponent]

    private enum CodingKeys: String, CodingKey {
        case id
        case countryCode
        case subdivisionCode
        case name
        case nativeName
        case center
        case bbox
        case components
        case polygons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        countryCode = try container.decode(CityAtlasCountry.self, forKey: .countryCode)
        subdivisionCode = try container.decodeIfPresent(String.self, forKey: .subdivisionCode)
        name = try container.decode(String.self, forKey: .name)
        nativeName = try container.decode(String.self, forKey: .nativeName)
        center = try container.decode([Double].self, forKey: .center)
        bbox = try container.decode([Double].self, forKey: .bbox)
        if let decodedComponents = try container.decodeIfPresent(
            [CityAtlasBoundaryComponent].self,
            forKey: .components
        ) {
            components = decodedComponents
        } else {
            let legacyPolygons = try container.decode([[[Double]]].self, forKey: .polygons)
            components = legacyPolygons.map {
                CityAtlasBoundaryComponent(outer: $0, holes: [])
            }
        }
    }

    var centerCoordinate: CLLocationCoordinate2D {
        guard center.count >= 2 else {
            return CLLocationCoordinate2D(latitude: 34.5, longitude: 124.5)
        }
        return CLLocationCoordinate2D(latitude: center[1], longitude: center[0])
    }

    private var coordinateComponents: [CityAtlasCoordinateComponent] {
        components.compactMap { component in
            let outer = Self.coordinates(from: component.outer)
            guard outer.count >= 3 else { return nil }
            return CityAtlasCoordinateComponent(
                outer: outer,
                holes: component.holes
                    .map(Self.coordinates(from:))
                    .filter { $0.count >= 3 }
            )
        }
    }

    var outerCoordinatesForBounds: [CLLocationCoordinate2D] {
        coordinateComponents.flatMap(\.outer)
    }

    func makeMapPolygons() -> [MKPolygon] {
        coordinateComponents.map { component in
            let holes = component.holes.map { ring -> MKPolygon in
                var coordinates = ring
                return MKPolygon(coordinates: &coordinates, count: coordinates.count)
            }
            var coordinates = component.outer
            return MKPolygon(
                coordinates: &coordinates,
                count: coordinates.count,
                interiorPolygons: holes.isEmpty ? nil : holes
            )
        }
    }

    var provinceDisplayName: String {
        preferredDisplayName.strippingCityAtlasSuffixes([
            " Special Administrative Region",
            " Autonomous Region",
            " Municipality",
            " Prefecture",
            " Province",
        ])
    }

    func cityDisplayName(in province: CityAtlasBoundary?) -> String {
        let cityName = preferredDisplayName.strippingCityAtlasSuffixes([" City"])
        guard let province,
              cityName.caseInsensitiveCompare(province.provinceDisplayName) == .orderedSame else {
            return cityName
        }

        switch countryCode {
        case .japan:
            return "\(cityName) City"
        case .china where province.preferredDisplayName.hasCityAtlasSuffix(" Province"):
            return "\(cityName) City"
        case .china, .korea, .mongolia:
            return cityName
        }
    }

    private var preferredDisplayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, trimmedName.caseInsensitiveCompare("none") != .orderedSame {
            return trimmedName
        }
        let trimmedNativeName = nativeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedNativeName.isEmpty ? String(localized: "City") : trimmedNativeName
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let bounds = bounds
        guard coordinate.longitude >= bounds.minLongitude,
              coordinate.longitude <= bounds.maxLongitude,
              coordinate.latitude >= bounds.minLatitude,
              coordinate.latitude <= bounds.maxLatitude else {
            return false
        }
        return coordinateComponents.contains { component in
            Self.contains(coordinate, in: component.outer)
                && !component.holes.contains { Self.contains(coordinate, in: $0) }
        }
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> Double {
        if contains(coordinate) { return 0 }
        return coordinateComponents.reduce(Double.infinity) { componentNearest, component in
            ([component.outer] + component.holes).reduce(componentNearest) { ringNearest, ring in
                guard ring.count >= 2 else { return ringNearest }
                return min(
                    ringNearest,
                    zip(ring, ring.dropFirst()).reduce(Double.infinity) { distance, segment in
                        min(
                            distance,
                            Self.segmentDistance(
                                from: coordinate,
                                to: segment.0,
                                and: segment.1
                            )
                        )
                    }
                )
            }
        }
    }

    var approximateAreaSquareKilometers: Double {
        coordinateComponents.reduce(0) { total, component in
            let outerArea = Self.approximateAreaSquareKilometers(of: component.outer)
            let holeArea = component.holes.reduce(0) {
                $0 + Self.approximateAreaSquareKilometers(of: $1)
            }
            return total + max(0, outerArea - holeArea)
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

    private static func coordinates(from points: [[Double]]) -> [CLLocationCoordinate2D] {
        points.compactMap { point in
            guard point.count >= 2 else { return nil }
            return CLLocationCoordinate2D(latitude: point[1], longitude: point[0])
        }
    }

    private static func approximateAreaSquareKilometers(
        of ring: [CLLocationCoordinate2D]
    ) -> Double {
        guard ring.count >= 3 else { return 0 }
        let meanLatitude = ring.reduce(0) { $0 + $1.latitude } / Double(ring.count)
        let longitudeScale = 111.32 * cos(meanLatitude * .pi / 180)
        let latitudeScale = 110.574
        var twiceArea = 0.0
        for index in ring.indices {
            let nextIndex = ring.index(after: index) == ring.endIndex
                ? ring.startIndex
                : ring.index(after: index)
            let left = ring[index]
            let right = ring[nextIndex]
            twiceArea += (left.longitude * longitudeScale) * (right.latitude * latitudeScale)
                - (right.longitude * longitudeScale) * (left.latitude * latitudeScale)
        }
        return abs(twiceArea) / 2
    }

    private static func contains(
        _ coordinate: CLLocationCoordinate2D,
        in ring: [CLLocationCoordinate2D]
    ) -> Bool {
        guard ring.count >= 3 else { return false }
        var isInside = false
        var previous = ring[ring.index(before: ring.endIndex)]
        for current in ring {
            if (current.latitude > coordinate.latitude) != (previous.latitude > coordinate.latitude) {
                let intersectionLongitude = (previous.longitude - current.longitude)
                    * (coordinate.latitude - current.latitude)
                    / (previous.latitude - current.latitude)
                    + current.longitude
                if coordinate.longitude < intersectionLongitude {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside
    }

    private static func segmentDistance(
        from point: CLLocationCoordinate2D,
        to left: CLLocationCoordinate2D,
        and right: CLLocationCoordinate2D
    ) -> Double {
        let longitudeScale = cos(point.latitude * .pi / 180)
        let px = point.longitude * longitudeScale
        let py = point.latitude
        let ax = left.longitude * longitudeScale
        let ay = left.latitude
        let bx = right.longitude * longitudeScale
        let by = right.latitude
        let dx = bx - ax
        let dy = by - ay
        guard dx != 0 || dy != 0 else { return hypot(px - ax, py - ay) }
        let projection = max(
            0,
            min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy))
        )
        return hypot(px - (ax + projection * dx), py - (ay + projection * dy))
    }
}

private extension String {
    func hasCityAtlasSuffix(_ suffix: String) -> Bool {
        lowercased().hasSuffix(suffix.lowercased())
    }

    func strippingCityAtlasSuffixes(_ suffixes: [String]) -> String {
        for suffix in suffixes where hasCityAtlasSuffix(suffix) {
            return String(dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return self
    }
}

private struct CityAtlasBoundaryCatalog: Decodable {
    let version: Int
    let boundaries: [CityAtlasBoundary]
    let referenceLines: [CityAtlasReferenceLineBatch]
    let japanStationToBoundary: [String: String]
    let chinaCityToBoundary: [String: String]
    let koreaModeToBoundary: [String: String]
    let koreaLocationToBoundary: [String: String]
    let mongoliaStationToBoundary: [String: String]
    let mongoliaCityToProvince: [String: String]
}

private struct CityAtlasProvinceCatalog: Decodable {
    let version: Int
    let boundaries: [CityAtlasBoundary]
    let referenceLines: [CityAtlasReferenceLineBatch]
}

private struct ChinaTransitCoverageCatalog: Decodable {
    let version: Int
    let scope: ChinaTransitCoverageScope
    let supportedProvinceNames: [String]
    let referenceBoundaryToProvince: [String: String]
    let tUnion: ChinaTransitCoverageNamespace
    let cityUnion: ChinaTransitCoverageNamespace
}

private struct ChinaTransitCoverageScope: Decodable {
    let excludedProvinceNames: [String]
}

private struct ChinaTransitCoverageNamespace: Decodable {
    let excludedCityBoundaryCodes: [String]
    let cityToProvince: [String: String]
    let cityToBoundaryAlias: [String: String]
    let provinceOnlyCityCodes: [String]
}

private struct JapanTransitCoverageCatalog: Decodable {
    let version: Int
    let supportedPrefectures: [JapanTransitCoveragePrefecture]
}

private struct JapanTransitCoveragePrefecture: Decodable {
    let code: String
    let name: String
}

private struct CityAtlasResolution {
    let visits: [CityAtlasVisit]
    let provinceVisits: [CityAtlasVisit]
    let cityBoundaries: [CityAtlasBoundary]
    let provinceBoundaries: [CityAtlasBoundary]
    let countryExtentBoundaries: [CityAtlasBoundary]
    let cityReferenceLines: [CityAtlasReferenceLineBatch]
    let provinceReferenceLines: [CityAtlasReferenceLineBatch]
}

private struct CityAtlasProvinceResolution {
    let boundaries: [CityAtlasBoundary]
    let provinceBoundaryByCityID: [String: String]
}

private struct CityAtlasVisitAccumulator {
    var evidenceIDs = Set<String>()
    var recordEvidenceIDs = Set<String>()
    var cardEvidenceCounts: [String: Int] = [:]
    var lastVisited: Date?

    mutating func add(
        evidenceID: String,
        cardID: String,
        date: Date?,
        countsAsRecord: Bool = true
    ) {
        guard evidenceIDs.insert(evidenceID).inserted else { return }
        cardEvidenceCounts[cardID, default: 0] += countsAsRecord ? 1 : 0
        if countsAsRecord {
            recordEvidenceIDs.insert(evidenceID)
        }
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
        ), let chinaCoverageURL = Bundle.main.url(
            forResource: "ChinaTransitCoverage",
            withExtension: "json"
        ), let japanCoverageURL = Bundle.main.url(
            forResource: "JapanTransitCoverage",
            withExtension: "json"
        ) else {
            throw CityAtlasResolverError.missingCatalog
        }
        guard let cityData = try? Data(contentsOf: cityURL),
              let provinceData = try? Data(contentsOf: provinceURL),
              let chinaCoverageData = try? Data(contentsOf: chinaCoverageURL),
              let japanCoverageData = try? Data(contentsOf: japanCoverageURL),
              let catalog = try? JSONDecoder().decode(CityAtlasBoundaryCatalog.self, from: cityData),
              let provinceCatalog = try? JSONDecoder().decode(CityAtlasProvinceCatalog.self, from: provinceData),
              let chinaCoverage = try? JSONDecoder().decode(
                ChinaTransitCoverageCatalog.self,
                from: chinaCoverageData
              ),
              let japanCoverage = try? JSONDecoder().decode(
                JapanTransitCoverageCatalog.self,
                from: japanCoverageData
              ) else {
            throw CityAtlasResolverError.unreadableCatalog
        }
        guard catalog.version == 2 else {
            throw CityAtlasResolverError.unsupportedCatalog(catalog.version)
        }
        guard provinceCatalog.version == 2 else {
            throw CityAtlasResolverError.unsupportedCatalog(provinceCatalog.version)
        }
        guard chinaCoverage.version == 1 else {
            throw CityAtlasResolverError.unsupportedCatalog(chinaCoverage.version)
        }
        guard japanCoverage.version == 1 else {
            throw CityAtlasResolverError.unsupportedCatalog(japanCoverage.version)
        }

        let excludedChinaProvinceNames = Set(
            chinaCoverage.scope.excludedProvinceNames.map { $0.lowercased() }
        )
        let supportedJapanSubdivisionCodes = Set(
            japanCoverage.supportedPrefectures.map(\.code)
        )
        let supportedJapanCityBoundaryIDs = Set(
            catalog.japanStationToBoundary.values
        )
        let supportedKoreaCityBoundaryIDs = Set(
            catalog.koreaLocationToBoundary.values
        ).union(catalog.koreaModeToBoundary.values)
        let supportedMongoliaCityBoundaryIDs = Set(
            catalog.mongoliaStationToBoundary.values
        )
        let catalogBoundaryIDs = Set(catalog.boundaries.map(\.id))
        let retainedChinaBoundaryIDs = Set(
            catalog.boundaries.lazy
                .filter { $0.countryCode == .china }
                .map(\.id)
        )
        let excludedChinaCityBoundaryCodes = Set(
            chinaCoverage.tUnion.excludedCityBoundaryCodes
        )
        let retainedChinaCityToBoundary = Dictionary(
            uniqueKeysWithValues: catalog.chinaCityToBoundary.compactMap { entry in
                retainedChinaBoundaryIDs.contains(entry.value)
                    ? (entry.key, entry.value)
                    : nil
            }
        )
        let supportedChinaCityCodes = Set(retainedChinaCityToBoundary.keys)
            .subtracting(excludedChinaCityBoundaryCodes)
        let retainedChinaReferenceBoundaryIDs = Set(
            chinaCoverage.referenceBoundaryToProvince.keys.filter(
                retainedChinaBoundaryIDs.contains
            )
        )
        let supportedChinaBoundaryIDs = Set(
            supportedChinaCityCodes.compactMap { retainedChinaCityToBoundary[$0] }
        ).union(retainedChinaReferenceBoundaryIDs)
        guard !supportedChinaCityCodes.isEmpty,
              !supportedJapanCityBoundaryIDs.isEmpty,
              !supportedKoreaCityBoundaryIDs.isEmpty,
              !supportedMongoliaCityBoundaryIDs.isEmpty,
              supportedJapanCityBoundaryIDs.isSubset(of: catalogBoundaryIDs),
              supportedKoreaCityBoundaryIDs.isSubset(of: catalogBoundaryIDs),
              supportedMongoliaCityBoundaryIDs.isSubset(of: catalogBoundaryIDs),
              Set(catalog.mongoliaCityToProvince.keys) == supportedMongoliaCityBoundaryIDs,
              excludedChinaCityBoundaryCodes.allSatisfy({
                  catalog.chinaCityToBoundary[$0] != nil
              }),
              supportedChinaBoundaryIDs == retainedChinaBoundaryIDs else {
            throw CityAtlasResolverError.unreadableCatalog
        }
        let supportedCityBoundaries = catalog.boundaries.filter { boundary in
            switch boundary.countryCode {
            case .china:
                return supportedChinaBoundaryIDs.contains(boundary.id)
            case .japan:
                return supportedJapanCityBoundaryIDs.contains(boundary.id)
                    && boundary.subdivisionCode.map(supportedJapanSubdivisionCodes.contains) == true
            case .korea:
                return supportedKoreaCityBoundaryIDs.contains(boundary.id)
            case .mongolia:
                return supportedMongoliaCityBoundaryIDs.contains(boundary.id)
            }
        }
        let chinaProvinceNameByCityBoundaryID = try chinaProvinceNameByCityBoundaryID(
            catalog: catalog,
            coverage: chinaCoverage
        )
        let eligibleProvinceBoundaries = provinceCatalog.boundaries.filter { boundary in
            switch boundary.countryCode {
            case .china:
                return !excludedChinaProvinceNames.contains(boundary.name.lowercased())
            case .japan:
                return boundary.subdivisionCode.map(supportedJapanSubdivisionCodes.contains) == true
            case .korea:
                return true
            case .mongolia:
                return true
            }
        }
        let provinceResolution = try supportedProvinceResolution(
            eligibleProvinceBoundaries,
            cityBoundaries: supportedCityBoundaries,
            chinaProvinceNameByCityBoundaryID: chinaProvinceNameByCityBoundaryID,
            supportedChinaProvinceNames: Set(
                chinaCoverage.supportedProvinceNames.map { $0.lowercased() }
            ),
            supportedJapanSubdivisionCodes: supportedJapanSubdivisionCodes,
            mongoliaCityToProvince: catalog.mongoliaCityToProvince
        )

        let boundaries = Dictionary(
            uniqueKeysWithValues: supportedCityBoundaries.map { ($0.id, $0) }
        )
        let provinceBoundariesByID = Dictionary(
            uniqueKeysWithValues: provinceResolution.boundaries.map { ($0.id, $0) }
        )
        let chinaProvinceBoundaryByName: [String: String] = Dictionary(
            uniqueKeysWithValues: provinceResolution.boundaries.compactMap {
                guard $0.countryCode == .china else { return nil }
                return ($0.name, $0.id)
            }
        )
        let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let ulaanbaatarBoundaryID = supportedCityBoundaries.first {
            $0.countryCode == .mongolia
                && $0.name.caseInsensitiveCompare("Ulaanbaatar") == .orderedSame
        }?.id
        var accumulators: [String: CityAtlasVisitAccumulator] = [:]
        var provinceAccumulators: [String: CityAtlasVisitAccumulator] = [:]

        for card in cards {
            let brand = ICCardBrand.from(family: card.cardFamily)
            let region = brand.region
            let normalizedFamily = card.cardFamily
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let isCityUnion = normalizedFamily.contains("city union")
            let hasChinaTransitApplication = region == .china
                || normalizedFamily.contains("t-union")
                || normalizedFamily.contains("tunion")
                || isCityUnion
            if isSupportedJapaneseTransitCard(card, region: region) {
                addJapaneseEvidence(
                    from: card,
                    lookup: catalog.japanStationToBoundary,
                    provinceBoundaryByCityID: provinceResolution.provinceBoundaryByCityID,
                    accumulators: &accumulators,
                    provinceAccumulators: &provinceAccumulators
                )
            }
            if brand == .octopus,
               let hongKongBoundaryID = retainedChinaCityToBoundary["9101"] {
                addOctopusEvidence(
                    from: card,
                    boundaryID: hongKongBoundaryID,
                    provinceBoundaryByCityID: provinceResolution.provinceBoundaryByCityID,
                    accumulators: &accumulators,
                    provinceAccumulators: &provinceAccumulators
                )
            }
            if brand == .umoney, let ulaanbaatarBoundaryID {
                addUMoneyEvidence(
                    from: card,
                    boundaryID: ulaanbaatarBoundaryID,
                    provinceBoundaryByCityID: provinceResolution.provinceBoundaryByCityID,
                    accumulators: &accumulators,
                    provinceAccumulators: &provinceAccumulators
                )
            }

            if hasChinaTransitApplication {
                addChineseEvidence(
                    from: card,
                    lookup: retainedChinaCityToBoundary,
                    coverage: isCityUnion ? chinaCoverage.cityUnion : chinaCoverage.tUnion,
                    provinceBoundaryByCityID: provinceResolution.provinceBoundaryByCityID,
                    provinceBoundaryByName: chinaProvinceBoundaryByName,
                    accumulators: &accumulators,
                    provinceAccumulators: &provinceAccumulators
                )
            }
            if region == .korea {
                addKoreanEvidence(
                    from: card,
                    locationLookup: catalog.koreaLocationToBoundary,
                    modeLookup: catalog.koreaModeToBoundary,
                    provinceBoundaryByCityID: provinceResolution.provinceBoundaryByCityID,
                    accumulators: &accumulators,
                    provinceAccumulators: &provinceAccumulators
                )
            }
        }

        let visits = makeVisits(
            from: accumulators,
            boundariesByID: boundaries,
            cardsByID: cardsByID
        ) { boundaryID, boundary in
            boundary.cityDisplayName(
                in: provinceResolution.provinceBoundaryByCityID[boundaryID].flatMap {
                    provinceBoundariesByID[$0]
                }
            )
        }

        let provinceVisits = makeVisits(
            from: provinceAccumulators,
            boundariesByID: provinceBoundariesByID,
            cardsByID: cardsByID
        ) { _, boundary in
            boundary.provinceDisplayName
        }

        return CityAtlasResolution(
            visits: visits,
            provinceVisits: provinceVisits,
            cityBoundaries: supportedCityBoundaries,
            provinceBoundaries: provinceResolution.boundaries,
            countryExtentBoundaries: provinceResolution.boundaries,
            cityReferenceLines: catalog.referenceLines,
            provinceReferenceLines: provinceCatalog.referenceLines
        )
    }

    private func chinaProvinceNameByCityBoundaryID(
        catalog: CityAtlasBoundaryCatalog,
        coverage: ChinaTransitCoverageCatalog
    ) throws -> [String: String] {
        let chinaBoundaryIDs = Set(
            catalog.boundaries.lazy
                .filter { $0.countryCode == .china }
                .map(\.id)
        )
        var provinceNameByBoundaryID = Dictionary(
            uniqueKeysWithValues: coverage.referenceBoundaryToProvince.compactMap { entry in
                chinaBoundaryIDs.contains(entry.key)
                    ? (entry.key, entry.value)
                    : nil
            }
        )

        for namespace in [coverage.tUnion, coverage.cityUnion] {
            let provinceOnlyCityCodes = Set(namespace.provinceOnlyCityCodes)
            let excludedCityBoundaryCodes = Set(namespace.excludedCityBoundaryCodes)
            guard provinceOnlyCityCodes.isSubset(of: Set(namespace.cityToProvince.keys)),
                  provinceOnlyCityCodes.isDisjoint(with: Set(namespace.cityToBoundaryAlias.keys)),
                  excludedCityBoundaryCodes.allSatisfy({
                      catalog.chinaCityToBoundary[$0] != nil
                  }) else {
                throw CityAtlasResolverError.unreadableCatalog
            }
            for (cityCode, provinceName) in namespace.cityToProvince {
                if provinceOnlyCityCodes.contains(cityCode) {
                    continue
                }
                let boundaryCode = namespace.cityToBoundaryAlias[cityCode] ?? cityCode
                guard let boundaryID = catalog.chinaCityToBoundary[boundaryCode] else {
                    throw CityAtlasResolverError.unreadableCatalog
                }
                guard chinaBoundaryIDs.contains(boundaryID) else { continue }
                if let existingProvinceName = provinceNameByBoundaryID[boundaryID],
                   existingProvinceName != provinceName {
                    throw CityAtlasResolverError.unreadableCatalog
                }
                provinceNameByBoundaryID[boundaryID] = provinceName
            }
        }

        let supportedProvinceNames = Set(
            coverage.supportedProvinceNames.map { $0.lowercased() }
        )
        let resolvedProvinceNames = Set(
            provinceNameByBoundaryID.values.map { $0.lowercased() }
        )
        guard Set(provinceNameByBoundaryID.keys) == chinaBoundaryIDs,
              resolvedProvinceNames == supportedProvinceNames else {
            throw CityAtlasResolverError.unreadableCatalog
        }
        return provinceNameByBoundaryID
    }

    private func makeVisits(
        from accumulators: [String: CityAtlasVisitAccumulator],
        boundariesByID: [String: CityAtlasBoundary],
        cardsByID: [String: SavedCardRecord],
        displayNameOverride: (String, CityAtlasBoundary) -> String?
    ) -> [CityAtlasVisit] {
        accumulators.compactMap { boundaryID, accumulator -> CityAtlasVisit? in
            guard let boundary = boundariesByID[boundaryID] else { return nil }
            let cardVisits = accumulator.cardEvidenceCounts.compactMap {
                cardID, count -> CityAtlasCardVisit? in
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
                recordCount: accumulator.recordEvidenceIDs.count,
                evidenceIDs: accumulator.evidenceIDs,
                recordEvidenceIDs: accumulator.recordEvidenceIDs,
                cards: cardVisits,
                lastVisited: accumulator.lastVisited,
                displayNameOverride: displayNameOverride(boundaryID, boundary)
            )
        }
        .sorted {
            if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func supportedProvinceResolution(
        _ provinces: [CityAtlasBoundary],
        cityBoundaries: [CityAtlasBoundary],
        chinaProvinceNameByCityBoundaryID: [String: String],
        supportedChinaProvinceNames: Set<String>,
        supportedJapanSubdivisionCodes: Set<String>,
        mongoliaCityToProvince: [String: String]
    ) throws -> CityAtlasProvinceResolution {
        let provincesByCountry = Dictionary(grouping: provinces, by: \.countryCode)
        let provinceAreas = Dictionary(
            uniqueKeysWithValues: provinces.map { ($0.id, $0.approximateAreaSquareKilometers) }
        )
        var supportedIDs = Set(
            provinces.lazy
                .filter {
                    $0.countryCode == .japan
                        && $0.subdivisionCode.map(supportedJapanSubdivisionCodes.contains) == true
                }
                .map(\.id)
        )
        supportedIDs.formUnion(
            provinces.lazy
                .filter { $0.countryCode == .mongolia }
                .map(\.id)
        )
        var provinceBoundaryByCityID: [String: String] = [:]
        let japaneseProvinceIDBySubdivisionCode = Dictionary(
            uniqueKeysWithValues: provinces.compactMap { province -> (String, String)? in
                guard province.countryCode == .japan,
                      let subdivisionCode = province.subdivisionCode else { return nil }
                return (subdivisionCode, province.id)
            }
        )
        let chinaProvinceIDByName = Dictionary(
            uniqueKeysWithValues: provinces.compactMap { province -> (String, String)? in
                guard province.countryCode == .china else { return nil }
                return (province.name.lowercased(), province.id)
            }
        )

        for city in cityBoundaries {
            if city.countryCode == .china {
                guard let provinceName = chinaProvinceNameByCityBoundaryID[city.id],
                      supportedChinaProvinceNames.contains(provinceName.lowercased()),
                      let provinceID = chinaProvinceIDByName[provinceName.lowercased()] else {
                    throw CityAtlasResolverError.unreadableCatalog
                }
                supportedIDs.insert(provinceID)
                provinceBoundaryByCityID[city.id] = provinceID
                continue
            }
            if city.countryCode == .japan,
               let subdivisionCode = city.subdivisionCode,
               let provinceID = japaneseProvinceIDBySubdivisionCode[subdivisionCode] {
                provinceBoundaryByCityID[city.id] = provinceID
                continue
            }
            if city.countryCode == .mongolia {
                guard let provinceID = mongoliaCityToProvince[city.id],
                      provincesByCountry[.mongolia]?.contains(where: {
                          $0.id == provinceID
                      }) == true else {
                    throw CityAtlasResolverError.unreadableCatalog
                }
                supportedIDs.insert(provinceID)
                provinceBoundaryByCityID[city.id] = provinceID
                continue
            }
            guard let candidates = provincesByCountry[city.countryCode], !candidates.isEmpty else { continue }
            let center = city.centerCoordinate
            let containing = candidates.filter { $0.contains(center) }
            let selected: CityAtlasBoundary?
            if !containing.isEmpty {
                selected = containing.min { left, right in
                    let leftArea = provinceAreas[left.id] ?? 0
                    let rightArea = provinceAreas[right.id] ?? 0
                    if leftArea != rightArea {
                        return leftArea < rightArea
                    }
                    return left.id < right.id
                }
            } else {
                selected = candidates.min { left, right in
                    let leftDistance = left.distance(to: center)
                    let rightDistance = right.distance(to: center)
                    if leftDistance != rightDistance { return leftDistance < rightDistance }
                    let leftArea = provinceAreas[left.id] ?? 0
                    let rightArea = provinceAreas[right.id] ?? 0
                    if leftArea != rightArea {
                        return leftArea < rightArea
                    }
                    return left.id < right.id
                }
            }
            if let selected {
                supportedIDs.insert(selected.id)
                provinceBoundaryByCityID[city.id] = selected.id
            }
        }

        let resolvedChinaProvinceNames = Set(
            provinces.lazy
                .filter { $0.countryCode == .china && supportedIDs.contains($0.id) }
                .map { $0.name.lowercased() }
        )
        guard resolvedChinaProvinceNames == supportedChinaProvinceNames else {
            throw CityAtlasResolverError.unreadableCatalog
        }

        return CityAtlasProvinceResolution(
            boundaries: provinces.filter { supportedIDs.contains($0.id) },
            provinceBoundaryByCityID: provinceBoundaryByCityID
        )
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
        provinceBoundaryByCityID: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator],
        provinceAccumulators: inout [String: CityAtlasVisitAccumulator]
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
                addEvidence(
                    boundaryID: boundaryID,
                    evidenceID: evidenceID,
                    cardID: card.id,
                    date: transaction.date,
                    provinceBoundaryByCityID: provinceBoundaryByCityID,
                    accumulators: &accumulators,
                    provinceAccumulators: &provinceAccumulators
                )
            }
        }
    }

    private func addChineseEvidence(
        from card: SavedCardRecord,
        lookup: [String: String],
        coverage: ChinaTransitCoverageNamespace,
        provinceBoundaryByCityID: [String: String],
        provinceBoundaryByName: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator],
        provinceAccumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        let supportedBoundaryCodes = Set(lookup.keys)
            .subtracting(coverage.excludedCityBoundaryCodes)
        let provinceOnlyCodes = Set(coverage.provinceOnlyCityCodes)

        for raw in Set(card.rawTransitHistory.map(normalizedRaw)) {
            let data = Data(hexString: raw)
            guard data.count >= 48 else { continue }
            let cityID = data.subdata(in: 32..<34).hexString.uppercased()
            let compactDateTime = data.subdata(in: 25..<32).hexString
            let amount = data.subdata(in: 17..<21).hexString.uppercased()
            addChineseCityCodeEvidence(
                cityID: cityID,
                evidenceID: "\(card.id)|china|\(cityID)|\(compactDateTime)|\(amount)",
                cardID: card.id,
                date: CardDateFormatting.parseCompactDateTime(
                    compactDateTime,
                    format: "yyyyMMddHHmmss",
                    brand: .tUnion
                ),
                lookup: lookup,
                coverage: coverage,
                supportedBoundaryCodes: supportedBoundaryCodes,
                provinceOnlyCodes: provinceOnlyCodes,
                provinceBoundaryByCityID: provinceBoundaryByCityID,
                provinceBoundaryByName: provinceBoundaryByName,
                accumulators: &accumulators,
                provinceAccumulators: &provinceAccumulators
            )
        }

        for raw in Set(card.rawTransactions.map(normalizedRaw)) {
            let data = Data(hexString: raw)
            guard data.count >= 23, data[9] == 0x06 || data[9] == 0x09 else { continue }
            let terminal = data.subdata(in: 10..<16).hexString.uppercased()
            let cityID = String(terminal.prefix(4))
            let compactDateTime = data.subdata(in: 16..<23).hexString
            let amount = data.subdata(in: 5..<9).hexString.uppercased()
            addChineseCityCodeEvidence(
                cityID: cityID,
                evidenceID: "\(card.id)|china|\(cityID)|\(compactDateTime)|\(amount)",
                cardID: card.id,
                date: CardDateFormatting.parseCompactDateTime(
                    compactDateTime,
                    format: "yyyyMMddHHmmss",
                    brand: .tUnion
                ),
                lookup: lookup,
                coverage: coverage,
                supportedBoundaryCodes: supportedBoundaryCodes,
                provinceOnlyCodes: provinceOnlyCodes,
                provinceBoundaryByCityID: provinceBoundaryByCityID,
                provinceBoundaryByName: provinceBoundaryByName,
                accumulators: &accumulators,
                provinceAccumulators: &provinceAccumulators
            )
        }
    }

    private func addChineseCityCodeEvidence(
        cityID: String,
        evidenceID: String,
        cardID: String,
        date: Date?,
        lookup: [String: String],
        coverage: ChinaTransitCoverageNamespace,
        supportedBoundaryCodes: Set<String>,
        provinceOnlyCodes: Set<String>,
        provinceBoundaryByCityID: [String: String],
        provinceBoundaryByName: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator],
        provinceAccumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        let normalizedCityID = cityID.uppercased()
        guard let provinceName = coverage.cityToProvince[normalizedCityID] else { return }

        if provinceOnlyCodes.contains(normalizedCityID) {
            guard let provinceBoundaryID = provinceBoundaryByName[provinceName] else { return }
            provinceAccumulators[
                provinceBoundaryID,
                default: CityAtlasVisitAccumulator()
            ].add(
                evidenceID: evidenceID,
                cardID: cardID,
                date: date
            )
            return
        }

        let cityBoundaryCode = coverage.cityToBoundaryAlias[normalizedCityID]
            ?? normalizedCityID
        guard supportedBoundaryCodes.contains(cityBoundaryCode),
              let boundaryID = lookup[cityBoundaryCode] else { return }
        addEvidence(
            boundaryID: boundaryID,
            evidenceID: evidenceID,
            cardID: cardID,
            date: date,
            provinceBoundaryByCityID: provinceBoundaryByCityID,
            accumulators: &accumulators,
            provinceAccumulators: &provinceAccumulators
        )
    }

    private func addOctopusEvidence(
        from card: SavedCardRecord,
        boundaryID: String,
        provinceBoundaryByCityID: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator],
        provinceAccumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        addEvidence(
            boundaryID: boundaryID,
            evidenceID: "\(card.id)|octopus-card",
            cardID: card.id,
            date: nil,
            countsAsRecord: false,
            provinceBoundaryByCityID: provinceBoundaryByCityID,
            accumulators: &accumulators,
            provinceAccumulators: &provinceAccumulators
        )
    }

    private func addUMoneyEvidence(
        from card: SavedCardRecord,
        boundaryID: String,
        provinceBoundaryByCityID: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator],
        provinceAccumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        // A U-Money card proves Ulaanbaatar network use, but the card's
        // seven-digit BCD stop token does not yet have a verified crosswalk to
        // the eight- and nine-digit UB Smart Bus station IDs. Keep this at
        // card-level evidence rather than fabricating a Töv municipality visit.
        addEvidence(
            boundaryID: boundaryID,
            evidenceID: "\(card.id)|umoney-card",
            cardID: card.id,
            date: nil,
            countsAsRecord: false,
            provinceBoundaryByCityID: provinceBoundaryByCityID,
            accumulators: &accumulators,
            provinceAccumulators: &provinceAccumulators
        )
    }

    private func addKoreanEvidence(
        from card: SavedCardRecord,
        locationLookup: [String: String],
        modeLookup: [String: String],
        provinceBoundaryByCityID: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator],
        provinceAccumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        let rawRecords = Set(card.rawTransitHistory.map(normalizedRaw))
        for raw in rawRecords {
            let data = Data(hexString: raw)
            guard data.count == 52, data[2] == 0x00 || data[2] == 0x01 else {
                continue
            }

            let locationCode = data.subdata(in: 5..<11).hexString.uppercased()
            let modeCode = String((Int(data[9]) << 8) | Int(data[10]))
            guard let boundaryID = locationLookup[locationCode] ?? modeLookup[modeCode] else {
                continue
            }

            let evidenceID = "\(card.id)|\(raw)"
            addEvidence(
                boundaryID: boundaryID,
                evidenceID: evidenceID,
                cardID: card.id,
                date: KoreanTransitTimestampDecoder.decode(data)?.date,
                provinceBoundaryByCityID: provinceBoundaryByCityID,
                accumulators: &accumulators,
                provinceAccumulators: &provinceAccumulators
            )
        }
    }

    private func addEvidence(
        boundaryID: String,
        evidenceID: String,
        cardID: String,
        date: Date?,
        countsAsRecord: Bool = true,
        provinceBoundaryByCityID: [String: String],
        accumulators: inout [String: CityAtlasVisitAccumulator],
        provinceAccumulators: inout [String: CityAtlasVisitAccumulator]
    ) {
        accumulators[boundaryID, default: CityAtlasVisitAccumulator()].add(
            evidenceID: evidenceID,
            cardID: cardID,
            date: date,
            countsAsRecord: countsAsRecord
        )
        guard let provinceBoundaryID = provinceBoundaryByCityID[boundaryID] else { return }
        provinceAccumulators[
            provinceBoundaryID,
            default: CityAtlasVisitAccumulator()
        ].add(
            evidenceID: evidenceID,
            cardID: cardID,
            date: date,
            countsAsRecord: countsAsRecord
        )
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
