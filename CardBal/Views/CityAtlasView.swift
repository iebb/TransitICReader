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
    @State private var cityBoundaries: [CityAtlasBoundary] = []
    @State private var provinceBoundaries: [CityAtlasBoundary] = []
    @State private var provinceBoundaryByCityID: [String: String] = [:]
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

    private var visibleDisplayVisits: [CityAtlasVisit] {
        guard boundaryLevel == .province else { return visibleVisits }

        let provincesByID = Dictionary(
            uniqueKeysWithValues: visibleProvinceBoundaries.map { ($0.id, $0) }
        )
        let groupedCities = Dictionary(grouping: visibleVisits) { visit in
            provinceBoundaryByCityID[visit.id]
        }

        return groupedCities.compactMap { provinceID, cityVisits -> CityAtlasVisit? in
            guard let provinceID, let province = provincesByID[provinceID] else { return nil }

            let evidenceIDs = cityVisits.reduce(into: Set<String>()) { result, visit in
                result.formUnion(visit.evidenceIDs)
            }
            var cardsByID: [String: CityAtlasCardVisit] = [:]
            for card in cityVisits.flatMap(\.cards) {
                if let existing = cardsByID[card.id] {
                    cardsByID[card.id] = CityAtlasCardVisit(
                        id: existing.id,
                        title: existing.title,
                        color: existing.color,
                        recordCount: existing.recordCount + card.recordCount
                    )
                } else {
                    cardsByID[card.id] = card
                }
            }
            let cards = cardsByID.values.sorted {
                if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }

            return CityAtlasVisit(
                id: provinceID,
                boundary: province,
                country: province.countryCode,
                recordCount: evidenceIDs.count,
                evidenceIDs: evidenceIDs,
                cards: cards,
                lastVisited: cityVisits.compactMap(\.lastVisited).max(),
                displayNameOverride: province.provinceDisplayName
            )
        }
        .sorted {
            if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
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

    private var recordCount: Int {
        Set(visibleDisplayVisits.flatMap(\.evidenceIDs)).count
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
                            .padding(.horizontal, 1)
                            .frame(height: 28)
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
        } else if visits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(emptyPlaceLabel, systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Scan a supported Chinese, Japanese, or Korean transit card.")
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
            cityBoundaries = resolution.cityBoundaries
            provinceBoundaries = resolution.provinceBoundaries
            provinceBoundaryByCityID = resolution.provinceBoundaryByCityID
            let placeIDs = Set(
                resolution.visits.map(\.id) + resolution.provinceBoundaries.map(\.id)
            )
            if let focusedCityID, !placeIDs.contains(focusedCityID) {
                self.focusedCityID = nil
            }
            if let selectedCityID, !placeIDs.contains(selectedCityID) {
                self.selectedCityID = nil
            }
        case .failure(let error):
            visits = []
            cityBoundaries = []
            provinceBoundaries = []
            provinceBoundaryByCityID = [:]
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
    // Portrait framing keeps HCMC, Xi'an, Harbin, and Sapporo clear of the map edges.
    static let defaultEastAsiaDistance: CLLocationDistance = 14_000_000
    static let maximumEastAsiaDistance: CLLocationDistance = 15_000_000

    let visits: [CityAtlasVisit]
    let referenceBoundaries: [CityAtlasBoundary]
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
            let referenceSignature = parent.referenceBoundaries.map(\.id).sorted().joined(separator: "|")
            let signature = "scope=\(parent.scope.id)|level=\(parent.boundaryLevel.id)|references=\(referenceSignature)|visits=\(visitSignature)|selected=\(parent.selectedCityID ?? "")"

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
            } else if parent.scope.country != nil {
                focus(
                    on: parent.referenceBoundaries,
                    detail: parent.boundaryLevel.renderDetail,
                    mapView: mapView
                )
            } else {
                mapView.setCamera(
                    CityAtlasMapRepresentable.eastAsiaCamera,
                    animated: !UIAccessibility.isReduceMotionEnabled
                )
            }
        }

        private func rebuildOverlays(on mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations)
            styles.removeAll(keepingCapacity: true)
            visitByID = Dictionary(uniqueKeysWithValues: parent.visits.map { ($0.id, $0) })

            var referencePolygons: [CityAtlasCountry: [MKPolygon]] = [:]
            var referenceOverlays: [MKMultiPolygon] = []
            var fillOverlays: [MKPolygon] = []
            var annotations: [CityAtlasAnnotation] = []

            for boundary in parent.referenceBoundaries.sorted(by: { $0.id < $1.id }) {
                let polygons = boundary.renderCoordinateRings(
                    detail: parent.boundaryLevel.renderDetail
                ).compactMap { ring -> MKPolygon? in
                    guard ring.count >= 3 else { return nil }
                    var coordinates = ring
                    return MKPolygon(coordinates: &coordinates, count: coordinates.count)
                }
                referencePolygons[boundary.countryCode, default: []].append(contentsOf: polygons)
            }

            for country in CityAtlasCountry.allCases {
                guard let polygons = referencePolygons[country], !polygons.isEmpty else { continue }
                let referenceOverlay = MKMultiPolygon(polygons)
                styles[ObjectIdentifier(referenceOverlay)] = referenceStyle(
                    for: country,
                    level: parent.boundaryLevel
                )
                referenceOverlays.append(referenceOverlay)
            }

            var visitedMasks: [String: CityAtlasVisitedMask] = [:]
            for visit in parent.visits {
                let boundary = visit.boundary

                if var mask = visitedMasks[boundary.id] {
                    mask.evidenceIDs.formUnion(visit.evidenceIDs)
                    mask.isSelected = mask.isSelected || visit.id == parent.selectedCityID
                    visitedMasks[boundary.id] = mask
                } else {
                    visitedMasks[boundary.id] = CityAtlasVisitedMask(
                        boundary: boundary,
                        country: visit.country,
                        evidenceIDs: visit.evidenceIDs,
                        isSelected: visit.id == parent.selectedCityID
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
                case (.province, .japan): visibleAlpha = max(0.34, baseAlpha)
                case (.city, .japan): visibleAlpha = max(0.36, baseAlpha)
                case (.province, .korea): visibleAlpha = max(0.40, baseAlpha)
                case (.city, .korea): visibleAlpha = max(0.44, baseAlpha)
                }
                let fillAlpha = mask.isSelected ? min(visibleAlpha + 0.10, 0.66) : visibleAlpha
                let strokeAlpha: CGFloat
                let lineWidth: CGFloat
                switch (parent.boundaryLevel, mask.country) {
                case (_, .china):
                    strokeAlpha = 0.96
                    lineWidth = mask.isSelected ? 4 : 2.4
                case (.province, .japan):
                    strokeAlpha = 0.92
                    lineWidth = mask.isSelected ? 2.6 : 1.8
                case (.city, .japan):
                    strokeAlpha = 0.92
                    lineWidth = mask.isSelected ? 2.4 : 1.6
                case (.province, .korea):
                    strokeAlpha = 0.96
                    lineWidth = mask.isSelected ? 2.8 : 2.2
                case (.city, .korea):
                    strokeAlpha = 0.96
                    lineWidth = mask.isSelected ? 2.4 : 1.8
                }

                for ring in mask.boundary.renderCoordinateRings(
                    detail: parent.boundaryLevel.renderDetail
                ) where ring.count >= 3 {
                    var coordinates = ring
                    let fill = MKPolygon(coordinates: &coordinates, count: coordinates.count)
                    styles[ObjectIdentifier(fill)] = CityAtlasOverlayStyle(
                        color: mask.country.uiTint,
                        fillAlpha: fillAlpha,
                        strokeAlpha: strokeAlpha,
                        lineWidth: lineWidth
                    )
                    fillOverlays.append(fill)
                }
            }

            for visit in parent.visits {
                annotations.append(CityAtlasAnnotation(visit: visit))
            }

            mapView.addOverlays(fillOverlays, level: .aboveRoads)
            mapView.addOverlays(referenceOverlays, level: .aboveRoads)
            mapView.addAnnotations(annotations)
        }

        private func referenceStyle(
            for country: CityAtlasCountry,
            level: CityAtlasBoundaryLevel
        ) -> CityAtlasOverlayStyle {
            switch (level, country) {
            case (.province, .china):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0.03,
                    strokeAlpha: 0.58,
                    lineWidth: 1.25
                )
            case (.province, .japan):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.42,
                    lineWidth: 0.9
                )
            case (.province, .korea):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.60,
                    lineWidth: 1.15
                )
            case (.city, .china):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0.012,
                    strokeAlpha: 0.4,
                    lineWidth: 0.75
                )
            case (.city, .japan):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.28,
                    lineWidth: 0.55
                )
            case (.city, .korea):
                return CityAtlasOverlayStyle(
                    color: country.uiTint,
                    fillAlpha: 0,
                    strokeAlpha: 0.50,
                    lineWidth: 0.90
                )
            }
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

        private func focus(
            on boundaries: [CityAtlasBoundary],
            detail: CityAtlasBoundaryDetail,
            mapView: MKMapView
        ) {
            var visibleRect = MKMapRect.null
            for boundary in boundaries {
                for ring in boundary.renderCoordinateRings(detail: detail) where ring.count >= 3 {
                    var coordinates = ring
                    let polygon = MKPolygon(coordinates: &coordinates, count: coordinates.count)
                    visibleRect = visibleRect.isNull
                        ? polygon.boundingMapRect
                        : visibleRect.union(polygon.boundingMapRect)
                }
            }

            guard !visibleRect.isNull, !visibleRect.isEmpty else {
                mapView.setCamera(
                    CityAtlasMapRepresentable.eastAsiaCamera,
                    animated: !UIAccessibility.isReduceMotionEnabled
                )
                return
            }

            let camera = mapView.camera.copy() as! MKMapCamera
            camera.heading = 0
            camera.pitch = 34
            mapView.setCamera(camera, animated: false)
            mapView.setVisibleMapRect(
                visibleRect,
                edgePadding: UIEdgeInsets(
                    top: mapView.safeAreaInsets.top + 152,
                    left: 56,
                    bottom: mapView.safeAreaInsets.bottom + 150,
                    right: 56
                ),
                animated: !UIAccessibility.isReduceMotionEnabled
            )
        }
    }
}

private struct CityAtlasOverlayStyle {
    let color: UIColor
    let fillAlpha: CGFloat
    let strokeAlpha: CGFloat
    let lineWidth: CGFloat
}

private struct CityAtlasVisitedMask {
    let boundary: CityAtlasBoundary
    let country: CityAtlasCountry
    var evidenceIDs: Set<String>
    var isSelected: Bool

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

    var renderDetail: CityAtlasBoundaryDetail {
        switch self {
        case .province: return .province
        case .city: return .city
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
        case .china, .korea:
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

    func renderCoordinateRings(detail: CityAtlasBoundaryDetail) -> [[CLLocationCoordinate2D]] {
        let rings = coordinateRings.filter { $0.count >= 3 }
        guard countryCode != .china, !rings.isEmpty else { return rings }

        let measured = rings.map { ring in
            (ring: ring, area: Self.approximateAreaSquareKilometers(of: ring))
        }
        let largestArea = measured.map(\.area).max() ?? 0
        let minimumArea = detail.minimumSecondaryAreaSquareKilometers(for: countryCode)
        let minimumRatio = detail.minimumSecondaryAreaRatio(for: countryCode)
        let tolerance = detail.simplificationTolerance(for: countryCode)

        return measured.compactMap { item in
            let isLargest = item.area == largestArea
            let isMeaningfulPart = item.area >= minimumArea || (
                largestArea > 0 && item.area / largestArea >= minimumRatio
            )
            guard isLargest || isMeaningfulPart else { return nil }
            return Self.simplify(item.ring, tolerance: tolerance)
        }
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let bounds = bounds
        guard coordinate.longitude >= bounds.minLongitude,
              coordinate.longitude <= bounds.maxLongitude,
              coordinate.latitude >= bounds.minLatitude,
              coordinate.latitude <= bounds.maxLatitude else {
            return false
        }
        return coordinateRings.contains { Self.contains(coordinate, in: $0) }
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> Double {
        if contains(coordinate) { return 0 }
        return coordinateRings.reduce(Double.infinity) { nearest, ring in
            guard ring.count >= 2 else { return nearest }
            return min(
                nearest,
                zip(ring, ring.dropFirst()).reduce(Double.infinity) { distance, segment in
                    min(distance, Self.segmentDistance(from: coordinate, to: segment.0, and: segment.1))
                }
            )
        }
    }

    var approximateAreaSquareKilometers: Double {
        coordinateRings.reduce(0) { $0 + Self.approximateAreaSquareKilometers(of: $1) }
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

    private static func approximateAreaSquareKilometers(
        of ring: [CLLocationCoordinate2D]
    ) -> Double {
        guard ring.count >= 3 else { return 0 }
        let meanLatitude = ring.reduce(0) { $0 + $1.latitude } / Double(ring.count)
        let longitudeScale = 111.32 * cos(meanLatitude * .pi / 180)
        let latitudeScale = 110.574
        var twiceArea = 0.0
        for index in ring.indices {
            let nextIndex = ring.index(after: index) == ring.endIndex ? ring.startIndex : ring.index(after: index)
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
        let projection = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        return hypot(px - (ax + projection * dx), py - (ay + projection * dy))
    }

    private static func simplify(
        _ ring: [CLLocationCoordinate2D],
        tolerance: Double
    ) -> [CLLocationCoordinate2D] {
        guard tolerance > 0 else { return ring }
        var points = ring
        if let first = points.first, let last = points.last,
           first.latitude == last.latitude, first.longitude == last.longitude {
            points.removeLast()
        }
        points = points.reduce(into: []) { result, point in
            guard let last = result.last,
                  last.latitude == point.latitude,
                  last.longitude == point.longitude else {
                result.append(point)
                return
            }
        }
        guard points.count > 3 else { return points }

        let toleranceSquared = tolerance * tolerance
        var kept = Set([0, points.count - 1])
        var pending = [(0, points.count - 1)]
        while let segment = pending.popLast() {
            let (start, end) = segment
            guard end > start + 1 else { continue }
            var furthestIndex: Int?
            var furthestDistance = -1.0
            for index in (start + 1)..<end {
                let distance = perpendicularDistanceSquared(
                    from: points[index],
                    to: points[start],
                    and: points[end]
                )
                if distance > furthestDistance {
                    furthestDistance = distance
                    furthestIndex = index
                }
            }
            if let furthestIndex, furthestDistance > toleranceSquared {
                kept.insert(furthestIndex)
                pending.append((start, furthestIndex))
                pending.append((furthestIndex, end))
            }
        }

        let simplified = kept.sorted().map { points[$0] }
        return simplified.count >= 3 ? simplified : points
    }

    private static func perpendicularDistanceSquared(
        from point: CLLocationCoordinate2D,
        to left: CLLocationCoordinate2D,
        and right: CLLocationCoordinate2D
    ) -> Double {
        let dx = right.longitude - left.longitude
        let dy = right.latitude - left.latitude
        guard dx != 0 || dy != 0 else {
            return pow(point.longitude - left.longitude, 2) + pow(point.latitude - left.latitude, 2)
        }
        let numerator = dy * point.longitude - dx * point.latitude
            + right.longitude * left.latitude - right.latitude * left.longitude
        return numerator * numerator / (dx * dx + dy * dy)
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

private enum CityAtlasBoundaryDetail {
    case city
    case province

    func simplificationTolerance(for country: CityAtlasCountry) -> Double {
        switch (self, country) {
        case (.province, .japan): return 0.010
        case (.province, .korea): return 0.0125
        case (.city, .japan): return 0.005
        case (.city, .korea): return 0.0075
        case (_, .china): return 0
        }
    }

    func minimumSecondaryAreaSquareKilometers(for country: CityAtlasCountry) -> Double {
        switch (self, country) {
        case (.province, .japan): return 25
        case (.province, .korea): return 75
        case (.city, .japan): return 5
        case (.city, .korea): return 12
        case (_, .china): return 0
        }
    }

    func minimumSecondaryAreaRatio(for country: CityAtlasCountry) -> Double {
        switch (self, country) {
        case (.province, .japan), (.city, .japan): return 0.01
        case (.province, .korea), (.city, .korea): return 0.01
        case (_, .china): return 0
        }
    }
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
    let cityBoundaries: [CityAtlasBoundary]
    let provinceBoundaries: [CityAtlasBoundary]
    let provinceBoundaryByCityID: [String: String]
}

private struct CityAtlasProvinceResolution {
    let boundaries: [CityAtlasBoundary]
    let provinceBoundaryByCityID: [String: String]
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

        let eligibleProvinceBoundaries = provinceCatalog.boundaries.filter { boundary in
            boundary.countryCode != .china || !boundary.name.localizedCaseInsensitiveContains("Taiwan")
        }
        let provinceResolution = supportedProvinceResolution(
            eligibleProvinceBoundaries,
            cityBoundaries: catalog.boundaries
        )

        let boundaries = Dictionary(uniqueKeysWithValues: catalog.boundaries.map { ($0.id, $0) })
        let provinceBoundariesByID = Dictionary(
            uniqueKeysWithValues: provinceResolution.boundaries.map { ($0.id, $0) }
        )
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
                lastVisited: accumulator.lastVisited,
                displayNameOverride: boundary.cityDisplayName(
                    in: provinceResolution.provinceBoundaryByCityID[boundaryID].flatMap {
                        provinceBoundariesByID[$0]
                    }
                )
            )
        }
        .sorted {
            if $0.recordCount != $1.recordCount { return $0.recordCount > $1.recordCount }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return CityAtlasResolution(
            visits: visits,
            cityBoundaries: catalog.boundaries,
            provinceBoundaries: provinceResolution.boundaries,
            provinceBoundaryByCityID: provinceResolution.provinceBoundaryByCityID
        )
    }

    private func supportedProvinceResolution(
        _ provinces: [CityAtlasBoundary],
        cityBoundaries: [CityAtlasBoundary]
    ) -> CityAtlasProvinceResolution {
        let provincesByCountry = Dictionary(grouping: provinces, by: \.countryCode)
        let provinceAreas = Dictionary(
            uniqueKeysWithValues: provinces.map { ($0.id, $0.approximateAreaSquareKilometers) }
        )
        var supportedIDs = Set<String>()
        var provinceBoundaryByCityID: [String: String] = [:]

        for city in cityBoundaries {
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
