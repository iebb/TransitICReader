import SwiftUI
import MapKit
import SQLite3

private let allCardsSelection = "__all_cards__"

// MARK: - Bottom Panel State

private enum MapBottomPanel: Equatable {
    case collapsed          // Only stats bar visible
    case routes             // Stats bar + route cards
    case records            // Stats bar + visible records
    case station(String)    // Stats bar + station detail (by point ID)
}

struct RideMapView: View {
    @ObservedObject var store: CardWalletStore
    let initialCardID: String?
    let showsCardPicker: Bool

    @State private var selectedCardID: String
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671), span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8))
    @State private var screenData = RideMapScreenData.empty
    @State private var highlightedRouteID: RideMapRoute.ID?
    @State private var selectedPointID: String?
    @State private var bottomPanel: MapBottomPanel = .collapsed
    @State private var selectedTransaction: RideMapTransactionSelection?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var cachedMappableCards: [SavedCardRecord] = []

    init(store: CardWalletStore, initialCardID: String?, showsCardPicker: Bool) {
        self.store = store
        self.initialCardID = initialCardID
        self.showsCardPicker = showsCardPicker
        _selectedCardID = State(initialValue: initialCardID ?? allCardsSelection)
    }

    private var filteredCards: [SavedCardRecord] {
        if selectedCardID == allCardsSelection {
            return cachedMappableCards.isEmpty ? store.cards : cachedMappableCards
        }
        return store.cards.filter { $0.id == selectedCardID }
    }

    var body: some View {
        Group {
            if let loadError {
                RideMapPlaceholderView(
                    title: String(localized: "Map Unavailable"),
                    message: loadError
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isLoading {
                ProgressView(String(localized: "Loading map…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if screenData.routes.isEmpty && screenData.points.isEmpty {
                RideMapPlaceholderView(
                    title: String(localized: "No Mappable Trips"),
                    message: String(localized: "This card does not have enough station data to draw routes yet.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                mapContent
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: selectedCardID) {
            await reload()
        }
        .task(id: store.mapDataRevision) {
            await cacheMappableCards()
            await reload()
        }
        .sheet(item: $selectedTransaction) { selection in
            TransactionDetailView(tx: selection.transaction, cardFamily: selection.cardFamily)
        }
        .onChange(of: selectedPointID) { pointID in
            if let pointID {
                withAnimation(.easeInOut(duration: 0.25)) {
                    bottomPanel = .station(pointID)
                }
            } else if case .station = bottomPanel {
                withAnimation(.easeInOut(duration: 0.25)) {
                    bottomPanel = .collapsed
                }
            }
        }
    }

    // MARK: - Map Content

    private var mapContent: some View {
        ZStack(alignment: .top) {
            RideMapRepresentable(
                region: $region,
                selectedPointID: $selectedPointID,
                points: screenData.points,
                routes: screenData.routes,
                highlightedRouteID: highlightedRouteID
            )
            .ignoresSafeArea(edges: .bottom)

            cardPickerBar
        }
        .safeAreaInset(edge: .bottom) {
            bottomPanelView
                .background(.ultraThinMaterial)
        }
    }

    // MARK: - Card Picker (In-View Cards)

    private static let cardChipHeight: CGFloat = 28
    private static let cardChipWidth: CGFloat = cardChipHeight * (27.0 / 17.0)

    /// Card IDs visible in the current map scope (matches the Cards stat count).
    private var inViewCardIDs: Set<String> {
        Set(scopedRoutes.map(\.cardID) + scopedPoints.flatMap { $0.hits.map(\.cardID) })
    }

    /// Cards currently visible on the map, ordered by the store's card order.
    private var inViewCards: [SavedCardRecord] {
        let ids = inViewCardIDs
        return store.cards.filter { ids.contains($0.id) }
    }

    private var cardPickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if showsCardPicker {
                    cardPickerChip(
                        isAllCards: true,
                        card: nil,
                        isSelected: selectedCardID == allCardsSelection
                    ) {
                        selectedCardID = allCardsSelection
                    }
                }

                ForEach(inViewCards) { card in
                    cardPickerChip(
                        isAllCards: false,
                        card: card,
                        isSelected: showsCardPicker && selectedCardID == card.id
                    ) {
                        if showsCardPicker {
                            selectedCardID = card.id
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private static let chipCornerRadius: CGFloat = 4

    private func cardPickerChip(isAllCards: Bool, card: SavedCardRecord?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let chipShape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: 0,
            bottomTrailingRadius: Self.chipCornerRadius,
            topTrailingRadius: Self.chipCornerRadius,
            style: .continuous
        )
        return Button(action: action) {
            HStack(spacing: 0) {
                if isAllCards {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.cardChipWidth, height: Self.cardChipHeight)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous))
                } else if let card {
                    cardChipThumbnail(card: card)
                }
                Text(isAllCards ? String(localized: "All Cards") : (card?.displayTitle ?? ""))
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
                    .padding(.horizontal, 8)
                    .frame(height: Self.cardChipHeight)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .quaternarySystemFill),
                        in: chipShape
                    )
                    .overlay(
                        chipShape.strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
                    )
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func cardChipThumbnail(card: SavedCardRecord) -> some View {
        if let image = store.loadFaceImage(fileName: card.faceImageFileName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: Self.cardChipWidth, height: Self.cardChipHeight)
                .clipShape(RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                    .fill(card.color.color)
                    .frame(width: Self.cardChipWidth, height: Self.cardChipHeight)
                MarkerPreviewBadge(card: card)
                    .scaleEffect(0.7)
            }
        }
    }

    // MARK: - Bottom Panel

    @ViewBuilder
    private var bottomPanelView: some View {
        VStack(spacing: 0) {
            // Expandable panel content
            panelContent
                .transition(.move(edge: .bottom).combined(with: .opacity))

            // Stats bar (always visible)
            statsBar
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch bottomPanel {
        case .collapsed:
            EmptyView()
        case .routes:
            routesPanel
        case .records:
            recordsPanel
        case .station(let pointID):
            if let point = screenData.points.first(where: { $0.id == pointID }) {
                stationDetailPanel(point: point)
            }
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        HStack(spacing: 0) {
            statCell(
                icon: "creditcard",
                value: "\(Set(scopedRoutes.map(\.cardID) + scopedPoints.flatMap { $0.hits.map(\.cardID) }).count)",
                label: "Cards",
                isActive: false,
                action: nil
            )
            thinDivider
            statCell(
                icon: "point.topleft.down.to.point.bottomright.curvepath",
                value: "\(scopedRoutes.count)",
                label: "Routes",
                isActive: bottomPanel == .routes,
                action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedPointID = nil
                        bottomPanel = bottomPanel == .routes ? .collapsed : .routes
                    }
                }
            )
            thinDivider
            statCell(
                icon: "mappin",
                value: "\(scopedPoints.count)",
                label: "Stations",
                isActive: false,
                action: nil
            )
            thinDivider
            statCell(
                icon: "list.bullet",
                value: "\(scopedPoints.reduce(0) { $0 + $1.hits.count })",
                label: "Records",
                isActive: bottomPanel == .records,
                action: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedPointID = nil
                        bottomPanel = bottomPanel == .records ? .collapsed : .records
                    }
                }
            )
        }
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(Color(uiColor: .separator).opacity(0.3))
            .frame(width: 0.5, height: 28)
    }

    @ViewBuilder
    private func statCell(icon: String, value: String, label: LocalizedStringKey, isActive: Bool, action: (() -> Void)?) -> some View {
        let content = VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(value)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: .infinity)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    // MARK: - Routes Panel

    private var routesPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(title: String(localized: "Routes"), subtitle: String(localized: "\(scopedRoutes.count) in view")) {
                withAnimation(.easeInOut(duration: 0.25)) { bottomPanel = .collapsed }
            }

            if scopedRoutes.isEmpty {
                Text("No visible routes in this area.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(scopedRoutes) { route in
                            routeCard(route)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private func routeCard(_ route: RideMapRoute) -> some View {
        let isHighlighted = highlightedRouteID == route.id
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                highlightedRouteID = route.id
            }
            region = region(for: route.coordinates)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // Route line indicator + card
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(route.color)
                        .frame(width: 3, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(route.cardTitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        if let date = route.transaction.date {
                            Text(CardDateFormatting.formatDisplayDateTime(date, brand: ICCardBrand.from(family: route.cardFamily), resolution: CardDateFormatting.resolution(forTimeText: route.transaction.time)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Station names
                HStack(spacing: 6) {
                    Text(route.startName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(route.endName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
            }
            .frame(width: 220, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.1) : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isHighlighted ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Records Panel

    private var recordsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            let totalRecords = scopedPoints.reduce(0) { $0 + $1.hits.count }
            panelHeader(title: String(localized: "Records"), subtitle: String(localized: "\(totalRecords) in view")) {
                withAnimation(.easeInOut(duration: 0.25)) { bottomPanel = .collapsed }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    if scopedPoints.isEmpty {
                        Text("No records in the current boundary.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    } else {
                        ForEach(scopedPoints) { point in
                            recordPointGroup(point: point)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 260)
        }
    }

    private func recordPointGroup(point: RideMapPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(point.color)
                    .frame(width: 8, height: 8)
                Text(point.stationName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(point.hits.count)")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }

            ForEach(point.hits) { hit in
                Button {
                    selectedTransaction = .init(id: hit.id, transaction: hit.transaction, cardFamily: hit.cardFamily)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.cardTitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                            if let date = hit.transaction.date {
                                Text(CardDateFormatting.formatDisplayDateTime(date, brand: ICCardBrand.from(family: hit.cardFamily), resolution: CardDateFormatting.resolution(forTimeText: hit.transaction.time)))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(hit.role == "start" ? "Entry" : "Exit")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(hit.role == "start" ? .green : .orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (hit.role == "start" ? Color.green : Color.orange).opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color(uiColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Station Detail Panel

    private func stationDetailPanel(point: RideMapPoint) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(title: point.stationName, subtitle: String(localized: "\(point.count) records")) {
                selectedPointID = nil
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(point.hits) { hit in
                        Button {
                            selectedTransaction = .init(id: hit.id, transaction: hit.transaction, cardFamily: hit.cardFamily)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.cardTitle)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 6) {
                                        Text(hit.transaction.type)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let date = hit.transaction.date {
                                            Text(CardDateFormatting.formatDisplayDateTime(date, brand: ICCardBrand.from(family: hit.cardFamily), resolution: CardDateFormatting.resolution(forTimeText: hit.transaction.time)))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Spacer()
                                Text(hit.role == "start" ? "Entry" : "Exit")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(hit.role == "start" ? .green : .orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        (hit.role == "start" ? Color.green : Color.orange).opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                            .padding(10)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 220)
        }
    }

    // MARK: - Shared Panel Header

    private func panelHeader(title: String, subtitle: String, onClose: @escaping () -> Void) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Data

    private var scopedPoints: [RideMapPoint] {
        if case .station(let pointID) = bottomPanel,
           let point = screenData.points.first(where: { $0.id == pointID }) {
            return [point]
        }
        return screenData.points.filter { isVisible($0.coordinate, in: region) }
    }

    private var scopedRoutes: [RideMapRoute] {
        if case .station(let pointID) = bottomPanel {
            return screenData.routes.filter { $0.startPointID == pointID || $0.endPointID == pointID }
        }
        return screenData.routes.filter { route in
            route.coordinates.contains { isVisible($0, in: region) }
        }
    }

    private func cacheMappableCards() async {
        let cards = store.cards
        let result = await Task.detached {
            let database = StationGraphDatabase.shared
            guard database.isReady else { return [SavedCardRecord]() }
            return cards.filter { card in
                RideMapBuilder(database: database).hasMappableTrips(card: card)
            }
        }.value
        cachedMappableCards = result
    }

    private func reload() async {
        isLoading = true
        let cards = filteredCards
        let storeRef = store
        let result: (RideMapScreenData, String?) = await Task.detached {
            let database = StationGraphDatabase.shared
            guard database.isReady else {
                return (.empty, String(localized: "The bundled station database could not be loaded."))
            }
            let data = RideMapBuilder(database: database).build(cards: cards, store: storeRef)
            return (data, nil)
        }.value
        screenData = result.0
        loadError = result.1
        highlightedRouteID = screenData.routes.first?.id
        selectedPointID = nil
        withAnimation(.easeInOut(duration: 0.2)) { bottomPanel = .collapsed }
        if !screenData.allCoordinates.isEmpty {
            region = region(for: screenData.allCoordinates)
        }
        isLoading = false
    }

    private func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coordinates.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671), span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8))
        }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.35, 0.08), longitudeDelta: max((maxLon - minLon) * 1.35, 0.08))
        )
    }

    private func isVisible(_ coordinate: CLLocationCoordinate2D, in region: MKCoordinateRegion) -> Bool {
        let latDelta = region.span.latitudeDelta / 2
        let lonDelta = region.span.longitudeDelta / 2
        return coordinate.latitude >= region.center.latitude - latDelta &&
            coordinate.latitude <= region.center.latitude + latDelta &&
            coordinate.longitude >= region.center.longitude - lonDelta &&
            coordinate.longitude <= region.center.longitude + lonDelta
    }
}

// MARK: - Placeholder

private struct RideMapPlaceholderView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "map")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }
}

// MARK: - MKMapView Representable

private struct RideMapRepresentable: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var selectedPointID: String?
    let points: [RideMapPoint]
    let routes: [RideMapRoute]
    let highlightedRouteID: RideMapRoute.ID?

    func makeCoordinator() -> Coordinator {
        Coordinator(region: $region, selectedPointID: $selectedPointID)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.register(RideMapAnnotationView.self, forAnnotationViewWithReuseIdentifier: RideMapAnnotationView.reuseIdentifier)
        mapView.register(RideMapClusterAnnotationView.self, forAnnotationViewWithReuseIdentifier: RideMapClusterAnnotationView.reuseIdentifier)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.highlightedRouteID = highlightedRouteID
        coordinator.routeColors = Dictionary(uniqueKeysWithValues: routes.map { ($0.id, UIColor($0.color)) })
        coordinator.mapView = mapView

        // Diff-based annotation updates
        let existingAnnotations = Set(mapView.annotations.compactMap { ($0 as? RideMapAnnotation)?.id })
        let newPointIDs = Set(points.map(\.id))

        let toRemove = mapView.annotations.filter {
            guard let a = $0 as? RideMapAnnotation else { return false }
            return !newPointIDs.contains(a.id)
        }
        let toAdd = points.filter { !existingAnnotations.contains($0.id) }.map(RideMapAnnotation.init)

        if !toRemove.isEmpty { mapView.removeAnnotations(toRemove) }
        if !toAdd.isEmpty { mapView.addAnnotations(toAdd) }

        // Diff-based overlay updates
        let existingOverlayIDs = Set(mapView.overlays.compactMap { ($0 as? MKPolyline)?.title })
        let newRouteIDs = Set(routes.map(\.id))

        let overlaysToRemove = mapView.overlays.filter {
            guard let p = $0 as? MKPolyline, let title = p.title else { return false }
            return !newRouteIDs.contains(title)
        }
        if !overlaysToRemove.isEmpty { mapView.removeOverlays(overlaysToRemove) }

        let routesToAdd = routes.filter { !existingOverlayIDs.contains($0.id) }
        let newOverlays = routesToAdd.compactMap { route -> MKPolyline? in
            guard route.coordinates.count >= 2 else { return nil }
            var coordinates = route.coordinates
            let polyline = MKPolyline(coordinates: &coordinates, count: coordinates.count)
            polyline.title = route.id
            return polyline
        }
        if !newOverlays.isEmpty { mapView.addOverlays(newOverlays) }

        // Update highlight rendering on existing polylines
        for overlay in mapView.overlays {
            guard let polyline = overlay as? MKPolyline else { continue }
            if let renderer = mapView.renderer(for: polyline) as? MKPolylineRenderer {
                let routeID = polyline.title ?? ""
                let style = Coordinator.routeStyle(routeID: routeID, highlightedRouteID: highlightedRouteID)
                renderer.lineWidth = style.width
                renderer.alpha = style.alpha
                renderer.setNeedsDisplay()
            }
        }

        if !coordinator.region(region, approximatelyEqualTo: mapView.region) {
            mapView.setRegion(region, animated: true)
        }
        coordinator.updateLabelVisibility(on: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        @Binding var region: MKCoordinateRegion
        @Binding var selectedPointID: String?
        var highlightedRouteID: RideMapRoute.ID?
        var routeColors: [String: UIColor] = [:]
        weak var mapView: MKMapView?

        init(region: Binding<MKCoordinateRegion>, selectedPointID: Binding<String?>) {
            _region = region
            _selectedPointID = selectedPointID
        }

        /// Routes read clearly at city scale; a selected route stands out while the rest recede.
        static func routeStyle(routeID: String, highlightedRouteID: RideMapRoute.ID?) -> (width: CGFloat, alpha: CGFloat) {
            guard let highlightedRouteID else { return (3.5, 0.85) }
            return routeID == highlightedRouteID ? (6, 1.0) : (2.5, 0.3)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                let routeID = polyline.title ?? ""
                renderer.strokeColor = routeColors[routeID] ?? .systemBlue
                let style = Self.routeStyle(routeID: routeID, highlightedRouteID: highlightedRouteID)
                renderer.lineWidth = style.width
                renderer.alpha = style.alpha
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: RideMapClusterAnnotationView.reuseIdentifier) as? RideMapClusterAnnotationView)
                    ?? RideMapClusterAnnotationView(annotation: cluster, reuseIdentifier: RideMapClusterAnnotationView.reuseIdentifier)
                view.annotation = cluster
                view.glyphText = "\(cluster.memberAnnotations.count)"
                view.markerTintColor = .secondaryLabel
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.clusteringIdentifier = nil
                return view
            }

            guard let annotation = annotation as? RideMapAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: RideMapAnnotationView.reuseIdentifier) as? RideMapAnnotationView)
                ?? RideMapAnnotationView(annotation: annotation, reuseIdentifier: RideMapAnnotationView.reuseIdentifier)
            view.annotation = annotation
            view.glyphText = annotation.count > 1 ? "\(annotation.count)" : nil
            view.markerTintColor = UIColor(annotation.color)
            view.titleVisibility = .adaptive
            view.subtitleVisibility = .hidden
            view.clusteringIdentifier = RideMapAnnotationView.clusterIdentifier
            view.canShowCallout = false
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let annotation = view.annotation as? RideMapAnnotation {
                selectedPointID = annotation.id
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                let coordinates = cluster.memberAnnotations.compactMap { ($0 as? RideMapAnnotation)?.coordinate }
                if let region = region(for: coordinates) {
                    mapView.setRegion(region, animated: true)
                }
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            _ = view
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            if !region(mapView.region, approximatelyEqualTo: region) {
                region = mapView.region
            }
            updateLabelVisibility(on: mapView)
        }

        func updateLabelVisibility(on mapView: MKMapView) {
            let shouldShowLabels = mapView.region.span.latitudeDelta < 0.55
            for annotation in mapView.annotations {
                guard let view = mapView.view(for: annotation) as? MKMarkerAnnotationView else { continue }
                if annotation is MKClusterAnnotation {
                    view.titleVisibility = .hidden
                } else {
                    view.titleVisibility = shouldShowLabels ? .adaptive : .hidden
                }
            }
        }

        func region(_ lhs: MKCoordinateRegion, approximatelyEqualTo rhs: MKCoordinateRegion) -> Bool {
            let epsilon = 0.0001
            return abs(lhs.center.latitude - rhs.center.latitude) < epsilon &&
            abs(lhs.center.longitude - rhs.center.longitude) < epsilon &&
            abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < epsilon &&
            abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < epsilon
        }

        private func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
            guard let first = coordinates.first else { return nil }
            var minLat = first.latitude
            var maxLat = first.latitude
            var minLon = first.longitude
            var maxLon = first.longitude
            for coordinate in coordinates.dropFirst() {
                minLat = min(minLat, coordinate.latitude)
                maxLat = max(maxLat, coordinate.latitude)
                minLon = min(minLon, coordinate.longitude)
                maxLon = max(maxLon, coordinate.longitude)
            }
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.25, 0.02), longitudeDelta: max((maxLon - minLon) * 1.25, 0.02))
            )
        }
    }
}

// MARK: - Annotation Views

private final class RideMapAnnotationView: MKMarkerAnnotationView {
    static let reuseIdentifier = "RideMapPoint"
    static let clusterIdentifier = "RideMapCluster"
}

private final class RideMapClusterAnnotationView: MKMarkerAnnotationView {
    static let reuseIdentifier = "RideMapCluster"
}

private final class RideMapAnnotation: NSObject, MKAnnotation {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let count: Int
    let color: Color
    let hits: [RideMapPointHit]

    init(point: RideMapPoint) {
        id = point.id
        coordinate = point.coordinate
        title = point.stationName
        count = point.count
        color = point.color
        hits = point.hits
    }
}

// MARK: - Data Models

private struct RideMapScreenData {
    let points: [RideMapPoint]
    let routes: [RideMapRoute]

    static let empty = RideMapScreenData(points: [], routes: [])

    var allCoordinates: [CLLocationCoordinate2D] {
        points.map(\.coordinate) + routes.flatMap(\.coordinates)
    }
}

private struct RideMapPoint: Identifiable {
    let id: String
    let stationName: String
    let coordinate: CLLocationCoordinate2D
    let count: Int
    let color: Color
    let hits: [RideMapPointHit]
}

private struct RideMapPointHit: Identifiable {
    let id: String
    let cardID: String
    let cardTitle: String
    let cardFamily: String
    let role: String
    let transaction: TransitTransaction
}

private struct RideMapTransactionSelection: Identifiable {
    let id: String
    let transaction: TransitTransaction
    let cardFamily: String
}

private struct RideMapRoute: Identifiable {
    let id: String
    let cardID: String
    let cardTitle: String
    let cardFamily: String
    let color: Color
    let startPointID: String
    let endPointID: String
    let startName: String
    let endName: String
    let coordinates: [CLLocationCoordinate2D]
    let transaction: TransitTransaction
}

private struct StationGraphStation: Codable {
    let hexCode: String
    let stationCode: String
    let stationName: String
    let latitude: Double
    let longitude: Double
    let isPseudo: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct StationGraphEdge: Codable {
    let toStationCode: String
    let distanceKm: Double
}

private struct RideRouteCandidate {
    let transaction: TransitTransaction
    let startCode: String
    let endCode: String
    let startName: String?
    let endName: String?
    let startEventRaw: Int?
    let endEventRaw: Int?
    let addsEndpointHits: Bool
}

private struct RidePointCandidate {
    let transaction: TransitTransaction
    let lookupCode: String
    let stationName: String?
    let eventRaw: Int?
    let role: String
}

private struct KoreanMapEvent {
    let transaction: TransitTransaction
    let raw: String
    let locationCode: String
    let eventRaw: Int
    let tripCounter: Int
    let timestamp: Date?
}

private final class StationGraphDatabase {
    static let shared = StationGraphDatabase()
    private static let cacheVersion = 3

    private(set) var isReady = false
    private let pathCacheLock = NSLock()
    private var stationsByLookupCode: [String: StationGraphStation] = [:]
    private var stationsByStationCode: [String: StationGraphStation] = [:]
    private var adjacency: [String: [StationGraphEdge]] = [:]
    private var pathCache: [String: [String]] = [:]

    private init() {
        if !loadCachedGraph() {
            buildFromBundledDatabases()
            saveCachedGraph()
        }
        // Korean aliases are intentionally loaded after the persisted base graph so
        // catalog updates take effect immediately without relying on a cache-version bump.
        loadKoreanCatalog()
        loadUlaanbaatarCatalog()
        isReady = !stationsByLookupCode.isEmpty
    }

    func station(forLookupCode rawCode: String?, eventRaw: Int? = nil) -> StationGraphStation? {
        guard let rawCode else { return nil }
        let code = normalizeLookupCode(rawCode)
        if let eventRaw, let eventStation = stationsByLookupCode["\(code):\(eventRaw)"] {
            return eventStation
        }
        return stationsByLookupCode[code]
    }

    func shortestPath(from sourceCode: String, to targetCode: String) -> [StationGraphStation] {
        guard sourceCode != "0", targetCode != "0" else { return [] }
        let stationsByStationCode = self.stationsByStationCode
        let adjacency = self.adjacency

        guard stationsByStationCode[sourceCode] != nil, stationsByStationCode[targetCode] != nil else { return [] }
        if sourceCode == targetCode, let station = stationsByStationCode[sourceCode] {
            return [station]
        }

        let cacheKey = sourceCode < targetCode ? "\(sourceCode)|\(targetCode)" : "\(targetCode)|\(sourceCode)"
        pathCacheLock.lock()
        let cachedPath = pathCache[cacheKey]
        pathCacheLock.unlock()
        if let cached = cachedPath {
            let ordered = sourceCode < targetCode ? cached : cached.reversed()
            return ordered.compactMap { stationsByStationCode[$0] }
        }

        var distances: [String: Double] = [sourceCode: 0]
        var previous: [String: String] = [:]
        var frontier: [(stationCode: String, distance: Double)] = [(sourceCode, 0)]
        var visited = Set<String>()

        while !frontier.isEmpty {
            frontier.sort { $0.distance < $1.distance }
            let current = frontier.removeFirst()
            if visited.contains(current.stationCode) {
                continue
            }
            if current.stationCode == targetCode {
                break
            }
            visited.insert(current.stationCode)
            for edge in adjacency[current.stationCode, default: []] {
                let nextDistance = current.distance + edge.distanceKm
                if nextDistance < distances[edge.toStationCode, default: .greatestFiniteMagnitude] {
                    distances[edge.toStationCode] = nextDistance
                    previous[edge.toStationCode] = current.stationCode
                    frontier.append((edge.toStationCode, nextDistance))
                }
            }
        }

        guard previous[targetCode] != nil else {
            return []
        }

        var stationCodes = [targetCode]
        var cursor = targetCode
        while let prev = previous[cursor] {
            stationCodes.append(prev)
            cursor = prev
            if prev == sourceCode {
                break
            }
        }
        stationCodes.reverse()
        pathCacheLock.lock()
        pathCache[cacheKey] = sourceCode < targetCode ? stationCodes : stationCodes.reversed()
        pathCacheLock.unlock()
        return stationCodes.compactMap { stationsByStationCode[$0] }
    }

    private struct CachedGraphPayload: Codable {
        let version: Int
        let stationsByLookupCode: [String: StationGraphStation]
        let stationsByStationCode: [String: StationGraphStation]
        let adjacency: [String: [StationGraphEdge]]
    }

    private func buildFromBundledDatabases() {
        stationsByLookupCode.removeAll(keepingCapacity: true)
        stationsByStationCode.removeAll(keepingCapacity: true)
        adjacency.removeAll(keepingCapacity: true)
        pathCache.removeAll(keepingCapacity: true)
        loadJPDatabase()
        loadTUnionDatabase()
    }

    private func loadJPDatabase() {
        guard let db = openBundledDatabase() else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let query = """
            SELECT i.code,
                   CASE WHEN s.is_pseudo = 1 THEN '0' ELSE s.source_station_id END,
                   COALESCE(NULLIF(i.lookup_name, ''), s.name),
                   s.latitude, s.longitude, s.is_pseudo
            FROM station_identifiers AS i
            JOIN stations AS s ON s.id = i.station_id
            WHERE i.namespace = 'jp.felica.hex'
              AND i.event_kind = 'any'
              AND s.country_code = 'JP'
              AND s.latitude IS NOT NULL
              AND s.longitude IS NOT NULL;
            """
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let codeText = sqlite3_column_text(statement, 0),
                    let stationCodeText = sqlite3_column_text(statement, 1),
                    let stationNameText = sqlite3_column_text(statement, 2)
                else {
                    continue
                }
                let station = StationGraphStation(
                    hexCode: String(cString: codeText),
                    stationCode: String(cString: stationCodeText),
                    stationName: String(cString: stationNameText),
                    latitude: sqlite3_column_double(statement, 3),
                    longitude: sqlite3_column_double(statement, 4),
                    isPseudo: sqlite3_column_int(statement, 5) != 0
                )
                stationsByLookupCode[normalizeLookupCode(station.hexCode)] = station
                if station.stationCode != "0" && !station.isPseudo {
                    stationsByStationCode[station.stationCode] = station
                }
            }
        }
        sqlite3_finalize(statement)
        loadEdges(db: db, countryCode: "JP")
    }

    private func loadTUnionDatabase() {
        guard let db = openBundledDatabase() else { return }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let query = """
            SELECT i.code, i.code, COALESCE(NULLIF(i.lookup_name, ''), s.name),
                   s.latitude, s.longitude
            FROM station_identifiers AS i
            JOIN stations AS s ON s.id = i.station_id
            WHERE i.namespace = 'cn.tunion.station_key'
              AND i.event_kind = 'any'
              AND s.country_code = 'CN'
              AND s.latitude IS NOT NULL
              AND s.longitude IS NOT NULL;
            """
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let codeText = sqlite3_column_text(statement, 0),
                    let stationCodeText = sqlite3_column_text(statement, 1),
                    let stationNameText = sqlite3_column_text(statement, 2)
                else {
                    continue
                }
                let station = StationGraphStation(
                    hexCode: String(cString: codeText),
                    stationCode: String(cString: stationCodeText),
                    stationName: String(cString: stationNameText),
                    latitude: sqlite3_column_double(statement, 3),
                    longitude: sqlite3_column_double(statement, 4),
                    isPseudo: false
                )
                stationsByLookupCode[normalizeLookupCode(station.hexCode)] = station
                stationsByStationCode[station.stationCode] = station
            }
        }
        sqlite3_finalize(statement)
        loadEdges(db: db, countryCode: "CN")
    }

    private func loadKoreanCatalog() {
        guard let catalog = KoreanStationAliasCatalog.bundled else { return }
        for alias in catalog.locations {
            guard let latitude = alias.latitude, let longitude = alias.longitude else { continue }
            let stationCode = "kr:\(alias.mapStationID)"
            let station = StationGraphStation(
                hexCode: alias.locationCode,
                stationCode: stationCode,
                stationName: alias.localizedDisplayName,
                latitude: latitude,
                longitude: longitude,
                isPseudo: false
            )
            let lookupCode = normalizeLookupCode(alias.locationCode)
            if let allowedEventRawValues = alias.allowedEventRawValues {
                for eventRaw in allowedEventRawValues {
                    stationsByLookupCode["\(lookupCode):\(eventRaw)"] = station
                }
            } else {
                stationsByLookupCode[lookupCode] = station
            }
            stationsByStationCode[stationCode] = station
        }
    }

    private func loadUlaanbaatarCatalog() {
        guard let db = openBundledDatabase() else { return }
        defer { sqlite3_close(db) }

        let useMongolian = Locale.preferredLanguages.first?.lowercased().hasPrefix("mn") == true
        var statement: OpaquePointer?
        let query = """
            SELECT i.code, COALESCE(NULLIF(s.native_name, ''), s.name), s.name,
                   s.latitude, s.longitude
            FROM station_identifiers AS i
            JOIN stations AS s ON s.id = i.station_id
            WHERE i.namespace = 'mn.ubsmartbus.station_id'
              AND i.event_kind = 'any'
              AND s.country_code = 'MN'
              AND s.latitude IS NOT NULL
              AND s.longitude IS NOT NULL;
            """
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let stationIDText = sqlite3_column_text(statement, 0),
                    let mongolianNameText = sqlite3_column_text(statement, 1),
                    let englishNameText = sqlite3_column_text(statement, 2)
                else {
                    continue
                }
                let stationID = String(cString: stationIDText)
                let lookupCode = "MN:\(stationID)"
                let station = StationGraphStation(
                    hexCode: lookupCode,
                    stationCode: lookupCode,
                    stationName: String(cString: useMongolian ? mongolianNameText : englishNameText),
                    latitude: sqlite3_column_double(statement, 3),
                    longitude: sqlite3_column_double(statement, 4),
                    isPseudo: false
                )
                stationsByLookupCode[lookupCode] = station
                stationsByStationCode[lookupCode] = station
            }
        }
        sqlite3_finalize(statement)
    }

    private func loadCachedGraph() -> Bool {
        guard let url = cachedGraphURL(),
              let data = try? Data(contentsOf: url) else {
            return false
        }
        guard let payload = try? PropertyListDecoder().decode(CachedGraphPayload.self, from: data),
              payload.version == Self.cacheVersion else {
            return false
        }
        stationsByLookupCode = payload.stationsByLookupCode
        stationsByStationCode = payload.stationsByStationCode
        adjacency = payload.adjacency
        return !stationsByLookupCode.isEmpty
    }

    private func saveCachedGraph() {
        guard let url = cachedGraphURL() else { return }
        let payload = CachedGraphPayload(
            version: Self.cacheVersion,
            stationsByLookupCode: stationsByLookupCode,
            stationsByStationCode: stationsByStationCode,
            adjacency: adjacency
        )
        guard let data = try? PropertyListEncoder().encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private func cachedGraphURL() -> URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        let dir = base.appendingPathComponent("CardBal", isDirectory: true)
        let cacheDir = dir.appendingPathComponent("MapCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent("station-graph-v\(Self.cacheVersion).plist")
    }

    private func loadEdges(db: OpaquePointer?, countryCode: String) {
        var statement: OpaquePointer?
        let query = """
            SELECT from_station_code, to_station_code, distance_km
            FROM station_graph_edges
            WHERE country_code = ?;
            """
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bindResult = countryCode.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, transient)
        }
        guard bindResult == SQLITE_OK else { return }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let fromText = sqlite3_column_text(statement, 0),
                let toText = sqlite3_column_text(statement, 1)
            else {
                continue
            }
            let fromStation = String(cString: fromText)
            let toStation = String(cString: toText)
            let distance = sqlite3_column_double(statement, 2)
            adjacency[fromStation, default: []].append(StationGraphEdge(toStationCode: toStation, distanceKm: distance))
            adjacency[toStation, default: []].append(StationGraphEdge(toStationCode: fromStation, distanceKm: distance))
        }
    }

    private func openBundledDatabase() -> OpaquePointer? {
        guard let url = Bundle.main.url(forResource: "cardbal_transit", withExtension: "sqlite") else {
            return nil
        }
        let escapedPath = url.path.replacingOccurrences(of: "?", with: "%3F")
        let sqliteURI = "file:\(escapedPath)?mode=ro&immutable=1"
        var db: OpaquePointer?
        guard sqlite3_open_v2(sqliteURI, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            return nil
        }
        return db
    }

    private func normalizeLookupCode(_ value: String) -> String {
        value.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: "").uppercased()
    }
}

// MARK: - Route Builder

private struct RideMapBuilder {
    let database: StationGraphDatabase

    /// Quick check if a card has any mappable trips at all (without building full route data).
    func hasMappableTrips(card: SavedCardRecord) -> Bool {
        if pointCandidates(for: card).contains(where: { candidate in
            database.station(forLookupCode: candidate.lookupCode, eventRaw: candidate.eventRaw) != nil
        }) {
            return true
        }
        let candidates = routeCandidates(for: card)
        return candidates.contains { candidate in
            database.station(forLookupCode: candidate.startCode, eventRaw: candidate.startEventRaw) != nil &&
            database.station(forLookupCode: candidate.endCode, eventRaw: candidate.endEventRaw) != nil
        }
    }

    func build(cards: [SavedCardRecord], store: CardWalletStore? = nil) -> RideMapScreenData {
        var pointCounts: [String: (station: StationGraphStation, count: Int, color: Color, hits: [RideMapPointHit])] = [:]
        var routes: [RideMapRoute] = []

        for card in cards {
            // Color priority: dominant color from face image > marker color
            let color: Color = {
                if let fileName = card.faceImageFileName,
                   let image = store?.loadFaceImage(fileName: fileName),
                   let dominant = CardPhotoProcessor.dominantColor(of: image) {
                    return dominant
                }
                return card.markerColor.color
            }()
            for candidate in pointCandidates(for: card) {
                guard let station = database.station(
                    forLookupCode: candidate.lookupCode,
                    eventRaw: candidate.eventRaw
                ) else {
                    continue
                }
                let key = station.stationCode == "0" ? station.hexCode : station.stationCode
                var entry = pointCounts[key] ?? (station, 0, color, [])
                entry.count += 1
                entry.color = color
                entry.hits.append(
                    RideMapPointHit(
                        id: "\(card.id)|\(candidate.transaction.id.uuidString)|\(candidate.role)|\(key)",
                        cardID: card.id,
                        cardTitle: card.displayTitle,
                        cardFamily: card.cardFamily,
                        role: candidate.role,
                        transaction: candidate.transaction
                    )
                )
                pointCounts[key] = entry
            }
            for candidate in routeCandidates(for: card) {
                let startStation = database.station(
                    forLookupCode: candidate.startCode,
                    eventRaw: candidate.startEventRaw
                )
                let endStation = database.station(
                    forLookupCode: candidate.endCode,
                    eventRaw: candidate.endEventRaw
                )

                if candidate.addsEndpointHits, let startStation {
                    let key = startStation.stationCode == "0" ? startStation.hexCode : startStation.stationCode
                    var entry = pointCounts[key] ?? (startStation, 0, color, [])
                    entry.count += 1
                    entry.color = color
                    entry.hits.append(
                        RideMapPointHit(
                            id: "\(card.id)|\(candidate.transaction.id.uuidString)|start|\(key)",
                            cardID: card.id,
                            cardTitle: card.displayTitle,
                            cardFamily: card.cardFamily,
                            role: "start",
                            transaction: candidate.transaction
                        )
                    )
                    pointCounts[key] = entry
                }
                if candidate.addsEndpointHits, let endStation {
                    let key = endStation.stationCode == "0" ? endStation.hexCode : endStation.stationCode
                    var entry = pointCounts[key] ?? (endStation, 0, color, [])
                    entry.count += 1
                    entry.color = color
                    entry.hits.append(
                        RideMapPointHit(
                            id: "\(card.id)|\(candidate.transaction.id.uuidString)|end|\(key)",
                            cardID: card.id,
                            cardTitle: card.displayTitle,
                            cardFamily: card.cardFamily,
                            role: "end",
                            transaction: candidate.transaction
                        )
                    )
                    pointCounts[key] = entry
                }

                guard let startStation, let endStation else {
                    continue
                }

                let pathStations = database.shortestPath(from: startStation.stationCode, to: endStation.stationCode)
                let coordinates = pathStations.isEmpty ? [startStation.coordinate, endStation.coordinate] : pathStations.map(\.coordinate)
                routes.append(
                    RideMapRoute(
                        id: "\(card.id)|\(candidate.transaction.id.uuidString)|\(candidate.startCode)|\(candidate.endCode)",
                        cardID: card.id,
                        cardTitle: card.displayTitle,
                        cardFamily: card.cardFamily,
                        color: color,
                        startPointID: startStation.stationCode == "0" ? startStation.hexCode : startStation.stationCode,
                        endPointID: endStation.stationCode == "0" ? endStation.hexCode : endStation.stationCode,
                        startName: candidate.startName ?? startStation.stationName,
                        endName: candidate.endName ?? endStation.stationName,
                        coordinates: coordinates,
                        transaction: candidate.transaction
                    )
                )
            }
        }

        let points = pointCounts.map {
            RideMapPoint(
                id: $0.key,
                stationName: $0.value.station.stationName,
                coordinate: $0.value.station.coordinate,
                count: $0.value.count,
                color: $0.value.color,
                hits: $0.value.hits.sorted { lhs, rhs in
                    switch (lhs.transaction.date, rhs.transaction.date) {
                    case let (left?, right?) where left != right:
                        return left > right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    default:
                        return lhs.id > rhs.id
                    }
                }
            )
        }
        .sorted { $0.count > $1.count }

        let sortedRoutes = routes.sorted { lhs, rhs in
            switch (lhs.transaction.date, rhs.transaction.date) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return leftDate > rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id > rhs.id
            }
        }

        return RideMapScreenData(points: points, routes: sortedRoutes)
    }

    private func routeCandidates(for card: SavedCardRecord) -> [RideRouteCandidate] {
        // Decode each protocol with its own family; combined Octopus cards
        // still contain Chinese entry/exit events that can form routes.
        if let apps = card.applications, apps.contains(where: { $0.isTUnion || $0.isCityUnion }) {
            return tUnionRouteCandidates(for: card)
        }
        let brand = ICCardBrand.from(family: card.cardFamily)
        if brand.isKorean {
            return koreanRouteCandidates(for: card)
        }
        if brand == .tUnion {
            return tUnionRouteCandidates(for: card)
        }

        let source = card.transitHistory.isEmpty ? card.transactions : card.transitHistory + card.transactions
        var seen = Set<String>()
        var result: [RideRouteCandidate] = []
        for transaction in sortTransactionsByRecency(source) {
            let hasRoute = transaction.entryStationCode != nil && transaction.exitStationCode != nil
            if !hasRoute {
                continue
            }
            let key = [
                card.id,
                transaction.rawData ?? "",
                transaction.entryStationCode ?? "",
                transaction.exitStationCode ?? "",
                transaction.type,
                transaction.date?.ISO8601Format() ?? "",
                transaction.recordNumber.map(String.init) ?? "",
            ].joined(separator: "|")
            if seen.insert(key).inserted {
                result.append(
                    RideRouteCandidate(
                        transaction: transaction,
                        startCode: transaction.entryStationCode ?? "",
                        endCode: transaction.exitStationCode ?? "",
                        startName: transaction.entryStation,
                        endName: transaction.exitStation,
                        startEventRaw: nil,
                        endEventRaw: nil,
                        addsEndpointHits: true
                    )
                )
            }
        }
        return result
    }

    private func tUnionRouteCandidates(for card: SavedCardRecord) -> [RideRouteCandidate] {
        let chronological = card.transitHistory.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return false
            case (nil, _?):
                return true
            default:
                return (lhs.recordNumber ?? 0) < (rhs.recordNumber ?? 0)
            }
        }

        var openEntry: TransitTransaction?
        var candidates: [RideRouteCandidate] = []

        for transaction in chronological {
            switch transaction.category {
            case .trainOn, .busOn:
                openEntry = transaction
            case .trainOff, .busOff:
                guard
                    let entry = openEntry,
                    let startCode = entry.entryStationCode,
                    let endCode = transaction.exitStationCode
                else {
                    continue
                }
                candidates.append(
                    RideRouteCandidate(
                        transaction: transaction,
                        startCode: startCode,
                        endCode: endCode,
                        startName: entry.entryStation,
                        endName: transaction.exitStation,
                        startEventRaw: nil,
                        endEventRaw: nil,
                        addsEndpointHits: true
                    )
                )
                openEntry = nil
            default:
                continue
            }
        }

        return candidates.reversed()
    }

    private func pointCandidates(for card: SavedCardRecord) -> [RidePointCandidate] {
        guard ICCardBrand.from(family: card.cardFamily).isKorean else { return [] }
        return koreanMapEvents(for: card).map { event in
            RidePointCandidate(
                transaction: event.transaction,
                lookupCode: event.locationCode,
                stationName: event.eventRaw == 0
                    ? event.transaction.entryStation
                    : event.transaction.exitStation,
                eventRaw: event.eventRaw,
                role: event.eventRaw == 0 ? "start" : "end"
            )
        }
    }

    private func koreanRouteCandidates(for card: SavedCardRecord) -> [RideRouteCandidate] {
        let events = koreanMapEvents(for: card)
            .filter { $0.timestamp != nil }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp {
                    return lhs.timestamp! < rhs.timestamp!
                }
                return lhs.raw < rhs.raw
            }
        var usedAlightings = Set<Int>()
        var candidates: [RideRouteCandidate] = []

        for (index, boarding) in events.enumerated() where boarding.eventRaw == 0 {
            guard let boardedAt = boarding.timestamp else { continue }
            for candidateIndex in events.indices where candidateIndex > index {
                guard !usedAlightings.contains(candidateIndex) else { continue }
                let alighting = events[candidateIndex]
                guard alighting.eventRaw == 1, let alightedAt = alighting.timestamp else { continue }
                let interval = alightedAt.timeIntervalSince(boardedAt)
                if interval < 0 { continue }
                if interval > 8 * 60 * 60 { break }
                guard alighting.tripCounter == boarding.tripCounter else { continue }
                usedAlightings.insert(candidateIndex)
                candidates.append(
                    RideRouteCandidate(
                        transaction: alighting.transaction,
                        startCode: boarding.locationCode,
                        endCode: alighting.locationCode,
                        startName: boarding.transaction.entryStation,
                        endName: alighting.transaction.exitStation,
                        startEventRaw: boarding.eventRaw,
                        endEventRaw: alighting.eventRaw,
                        addsEndpointHits: false
                    )
                )
                break
            }
        }
        return candidates.reversed()
    }

    private func koreanMapEvents(for card: SavedCardRecord) -> [KoreanMapEvent] {
        let transactions = card.transitHistory + card.transactions
        var seenRaw = Set<String>()
        var events: [KoreanMapEvent] = []
        for transaction in transactions {
            guard let rawData = transaction.rawData else { continue }
            let raw = rawData.uppercased().filter(\.isHexDigit)
            guard seenRaw.insert(raw).inserted else { continue }
            let data = Data(hexString: raw)
            guard data.count >= KoreanTransitTimestampDecoder.recordLength else { continue }
            let record = data.count == KoreanTransitTimestampDecoder.recordLength
                ? data
                : data.subdata(in: 0..<KoreanTransitTimestampDecoder.recordLength)
            let eventRaw = Int(record[2])
            guard eventRaw == 0 || eventRaw == 1 else { continue }
            events.append(
                KoreanMapEvent(
                    transaction: transaction,
                    raw: record.hexString.uppercased(),
                    locationCode: record.subdata(in: 5..<11).hexString.uppercased(),
                    eventRaw: eventRaw,
                    tripCounter: Int(record[4]),
                    timestamp: KoreanTransitTimestampDecoder.decode(record)?.date
                )
            )
        }
        return events
    }
}
