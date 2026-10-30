package ad.neko.cardbal.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color as AndroidColor
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.DirectionsBus
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Payments
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material.icons.filled.Train
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import ad.neko.cardbal.android.data.RawRecordExplanation
import ad.neko.cardbal.android.data.RemoteCardFaces
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.StationPoint
import ad.neko.cardbal.android.data.StationRoute
import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.data.TransitTransaction
import ad.neko.cardbal.android.data.formatCardMoney
import ad.neko.cardbal.android.data.formatTransactionAmount
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import org.maplibre.android.MapLibre
import org.maplibre.android.annotations.IconFactory
import org.maplibre.android.annotations.MarkerOptions
import org.maplibre.android.annotations.PolylineOptions
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import java.io.File
import kotlin.math.roundToInt

data class MapViewportBounds(
    val north: Double,
    val south: Double,
    val east: Double,
    val west: Double,
) {
    fun contains(point: StationPoint): Boolean {
        val latitudeMatches = point.latitude in south..north
        val longitudeMatches = if (west <= east) {
            point.longitude in west..east
        } else {
            point.longitude >= west || point.longitude <= east
        }
        return latitudeMatches && longitudeMatches
    }

    companion object {
        fun from(bounds: LatLngBounds): MapViewportBounds = MapViewportBounds(
            north = bounds.latitudeNorth,
            south = bounds.latitudeSouth,
            east = bounds.longitudeEast,
            west = bounds.longitudeWest,
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CardDetailScreen(
    card: SavedCardRecord,
    transactions: List<TransitTransaction>,
    routePoints: List<StationPoint>,
    routes: List<StationRoute>,
    rawExplanationFor: (TransitTransaction) -> RawRecordExplanation?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var selectedRecord by remember { mutableStateOf<TransitTransaction?>(null) }
    Column(modifier) {
        TopAppBar(
            title = { Text(cardTitle(card), maxLines = 1, overflow = TextOverflow.Ellipsis) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = tr("Back"))
                }
            },
        )
        LazyColumn(
            modifier = Modifier.fillMaxWidth().weight(1f),
            verticalArrangement = Arrangement.spacedBy(16.dp),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
        ) {
            item { WalletCard(card) }
            item {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AssistChip(onClick = {}, label = { Text(tr("${transactions.size} records")) })
                    AssistChip(onClick = {}, label = { Text(tr("${routePoints.size} mapped stations")) })
                }
            }
            item {
                TransitRouteMap(points = routePoints, routes = routes, modifier = Modifier.fillMaxWidth())
            }
            item {
                Text(tr("Transit records"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            }
            if (transactions.isEmpty()) {
                item {
                    Text(
                        tr("No readable transaction or transit records are stored for this card yet."),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                items(transactions, key = { it.rawData ?: "${it.type}-${it.recordNumber}" }) { tx ->
                    TransactionRow(
                        tx = tx,
                        modifier = Modifier
                            .padding(vertical = 3.dp)
                            .clickable { selectedRecord = tx }
                            .swipeUpAction { selectedRecord = tx },
                    )
                }
            }
            item {
                Text(tr("Raw fields"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                Spacer(Modifier.height(8.dp))
                card.resultFields.forEach { field ->
                    DetailTextRow(field.title, field.value)
                }
            }
        }
    }
    selectedRecord?.let { tx ->
        RecordRawBottomSheet(
            tx = tx,
            explanation = rawExplanationFor(tx),
            onDismiss = { selectedRecord = null },
        )
    }
}

@Composable
fun RideMapSurface(
    cards: List<SavedCardRecord>,
    filterCards: List<SavedCardRecord>,
    selectedCardId: String?,
    onSelectCard: (String?) -> Unit,
    points: List<StationPoint>,
    stationRoutes: List<StationRoute>,
    markerCardsByPointCode: Map<String, SavedCardRecord>,
    records: List<String>,
    routes: List<String>,
    onOpenCard: (SavedCardRecord) -> Unit,
    onViewportChanged: (MapViewportBounds) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier.fillMaxSize()) {
        TransitRouteMap(
            points = points,
            routes = stationRoutes,
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 0.dp, vertical = 0.dp),
            showContainer = false,
            onViewportChanged = onViewportChanged,
            markerCardsByPointCode = markerCardsByPointCode,
        )

        MapCardPickerBar(
            cards = filterCards,
            selectedCardId = selectedCardId,
            onSelectCard = onSelectCard,
            onOpenCard = onOpenCard,
            modifier = Modifier.align(Alignment.TopCenter),
        )

        MapBottomPanel(
            visibleCards = if (selectedCardId == null) filterCards.size else cards.count { it.id == selectedCardId },
            routes = routes,
            records = records,
            stations = points.size,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

@Composable
fun TransactionRow(tx: TransitTransaction, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(8.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        elevation = CardDefaults.cardElevation(defaultElevation = 1.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(44.dp).background(categoryColor(tx.category).copy(alpha = 0.16f), CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                Icon(categoryIcon(tx.category), contentDescription = null, tint = categoryColor(tx.category))
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(tr(tx.type), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                tx.date?.let { Text(formatDate(it, tx.issuerTimeZone), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
                tx.location?.let { Text(tr(it), style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                tx.terminalID?.let { Text(tr(it), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline, maxLines = 1) }
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                if (!tx.amountKnown || tx.amount != 0L) {
                    Text(tr(if (tx.amountKnown) formatTransactionAmount(tx) else "Fare unavailable"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                }
                tx.balanceAfter?.let {
                    Text(tr(formatCardMoney(it, tx.currencyCode, tx.fractionDigits)), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(tr("Raw"), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

@Composable
fun TransitRouteMap(
    points: List<StationPoint>,
    routes: List<StationRoute> = emptyList(),
    modifier: Modifier = Modifier,
    showContainer: Boolean = true,
    onViewportChanged: (MapViewportBounds) -> Unit = {},
    markerCardsByPointCode: Map<String, SavedCardRecord> = emptyMap(),
) {
    val content: @Composable () -> Unit = {
        Column(
            Modifier.padding(if (showContainer) 16.dp else 0.dp),
            verticalArrangement = Arrangement.spacedBy(if (showContainer) 12.dp else 0.dp),
        ) {
            var zoomLevel by remember(points) { mutableIntStateOf(0) }
            val visiblePoints = remember(points, zoomLevel) { points.visibleAtZoom(zoomLevel) }
            val visibleCodes = remember(visiblePoints) { visiblePoints.mapTo(mutableSetOf()) { it.code } }
            val visibleRoutes = remember(routes, visibleCodes) {
                routes.filter { route ->
                    val start = route.points.firstOrNull()?.code
                    val end = route.points.lastOrNull()?.code
                    start in visibleCodes || end in visibleCodes
                }
            }
            if (showContainer) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Column {
                    Text(tr("Ride map"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                    Text(
                        tr("Visible ${visiblePoints.size}/${points.size} stations"),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { zoomLevel = (zoomLevel - 1).coerceAtLeast(0) }, enabled = zoomLevel > 0) {
                        Icon(Icons.Filled.Remove, contentDescription = tr("Zoom out"))
                    }
                    Text(tr(zoomLabel(zoomLevel)), style = MaterialTheme.typography.labelLarge)
                    IconButton(onClick = { zoomLevel = (zoomLevel + 1).coerceAtMost(3) }, enabled = zoomLevel < 3) {
                        Icon(Icons.Filled.Add, contentDescription = tr("Zoom in"))
                    }
                }
            }
            if (visiblePoints.size < 2) {
                Box(
                    Modifier.fillMaxWidth().then(if (showContainer) Modifier.height(220.dp) else Modifier.fillMaxSize()).background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(if (showContainer) 8.dp else 0.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        tr(if (points.size < 2) "More resolved station records are needed to draw a route." else "Zoomed view has fewer than two visible stations."),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                MapLibreRouteMap(
                    points = visiblePoints,
                    routes = visibleRoutes,
                    modifier = if (showContainer) Modifier.fillMaxWidth().height(320.dp) else Modifier.fillMaxSize(),
                    onViewportChanged = onViewportChanged,
                    markerCardsByPointCode = markerCardsByPointCode,
                )
                if (showContainer) {
                    Text(
                        tr("Map data © OpenStreetMap contributors"),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        visiblePoints.take(8).forEach { point ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(Icons.Filled.Place, contentDescription = null, modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.primary)
                                Text(point.name, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            }
                        }
                    }
                }
            }
        }
    }
    if (showContainer) {
        Card(modifier = modifier, shape = RoundedCornerShape(8.dp)) { content() }
    } else {
        Box(modifier.background(MaterialTheme.colorScheme.background)) { content() }
    }
}

@Composable
private fun MapLibreRouteMap(
    points: List<StationPoint>,
    routes: List<StationRoute>,
    modifier: Modifier = Modifier,
    onViewportChanged: (MapViewportBounds) -> Unit = {},
    markerCardsByPointCode: Map<String, SavedCardRecord> = emptyMap(),
) {
    val context = LocalContext.current
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var styleReady by remember { mutableStateOf(false) }
    var renderedMapKey by remember { mutableStateOf<String?>(null) }
    var cameraIdleListener by remember { mutableStateOf<MapLibreMap.OnCameraIdleListener?>(null) }
    val currentOnViewportChanged = rememberUpdatedState(onViewportChanged)
    val mapContentKey = remember(points, routes) {
        points.joinToString(separator = "|") { it.code } +
            "::" + routes.joinToString(separator = "|") { it.id } +
            "::" + markerCardsByPointCode.entries.sortedBy { it.key }.joinToString(separator = "|") { "${it.key}:${it.value.id}" }
    }
    val mapView = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            onCreate(null)
            onStart()
            onResume()
            getMapAsync { mapLibreMap ->
                map = mapLibreMap
                mapLibreMap.uiSettings.isAttributionEnabled = true
                mapLibreMap.uiSettings.isLogoEnabled = false
                mapLibreMap.cameraPosition = initialCamera(points)
                val listener = MapLibreMap.OnCameraIdleListener {
                    currentOnViewportChanged.value(
                        MapViewportBounds.from(mapLibreMap.projection.visibleRegion.latLngBounds),
                    )
                }
                cameraIdleListener = listener
                mapLibreMap.addOnCameraIdleListener(listener)
                mapLibreMap.setStyle(Style.Builder().fromJson(OSM_RASTER_STYLE)) {
                    styleReady = true
                    updateMapLibreRoute(context, mapLibreMap, points, routes, markerCardsByPointCode)
                    renderedMapKey = mapContentKey
                    currentOnViewportChanged.value(
                        MapViewportBounds.from(mapLibreMap.projection.visibleRegion.latLngBounds),
                    )
                }
            }
        }
    }

    DisposableEffect(mapView) {
        onDispose {
            map?.let { currentMap ->
                cameraIdleListener?.let(currentMap::removeOnCameraIdleListener)
            }
            mapView.onPause()
            mapView.onStop()
            mapView.onDestroy()
        }
    }

    AndroidView(
        modifier = modifier
            .background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp)),
        factory = { mapView },
        update = {
            val currentMap = map
            if (styleReady && currentMap != null && renderedMapKey != mapContentKey) {
                updateMapLibreRoute(context, currentMap, points, routes, markerCardsByPointCode)
                renderedMapKey = mapContentKey
            }
        },
    )
}

@Composable
private fun MapCardPickerBar(
    cards: List<SavedCardRecord>,
    selectedCardId: String?,
    onSelectCard: (String?) -> Unit,
    onOpenCard: (SavedCardRecord) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .windowInsetsPadding(WindowInsets.statusBars)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        MapChip(
            label = tr(if (cards.isEmpty()) "No cards in view" else "All in view (${cards.size})"),
            selected = selectedCardId == null,
            onClick = { onSelectCard(null) },
        )
        cards.forEach { card ->
            MapChip(
                label = cardTitle(card),
                selected = selectedCardId == card.id,
                onClick = { onSelectCard(card.id) },
                onSwipeUp = { onOpenCard(card) },
            )
        }
    }
}

@Composable
private fun MapChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    onSwipeUp: (() -> Unit)? = null,
) {
    val bg = if (selected) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant
    val fg = if (selected) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface
    Row(
        modifier = Modifier
            .background(bg, RoundedCornerShape(4.dp))
            .then(if (onSwipeUp != null) Modifier.swipeUpAction(onSwipeUp) else Modifier)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.CreditCard, contentDescription = null, tint = fg, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(label, color = fg, style = MaterialTheme.typography.labelMedium, maxLines = 1)
    }
}

@Composable
private fun MapBottomPanel(
    visibleCards: Int,
    routes: List<String>,
    records: List<String>,
    stations: Int,
    modifier: Modifier = Modifier,
) {
    var panelMode by remember { mutableStateOf<MapPanelMode>(MapPanelMode.Collapsed) }
    Card(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(topStart = 8.dp, topEnd = 8.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column {
            if (panelMode != MapPanelMode.Collapsed) {
                val rows = when (panelMode) {
                    MapPanelMode.Routes -> routes
                    MapPanelMode.Records -> records
                    MapPanelMode.Collapsed -> emptyList()
                }
                Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(
                        tr(if (panelMode == MapPanelMode.Routes) "Visible routes" else "Visible records"),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    if (rows.isEmpty()) {
                        Text(tr("No visible items."), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodySmall)
                    } else {
                        rows.take(6).forEach { row ->
                            Text(row, style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                    }
                }
                HorizontalDivider()
            }
            Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
                MapStat("Cards", visibleCards.toString(), Icons.Filled.CreditCard)
                MapStat(
                    "Routes",
                    routes.size.toString(),
                    Icons.Filled.Map,
                    isActive = panelMode == MapPanelMode.Routes,
                    onClick = { panelMode = if (panelMode == MapPanelMode.Routes) MapPanelMode.Collapsed else MapPanelMode.Routes },
                )
                MapStat(
                    "Records",
                    records.size.toString(),
                    Icons.Filled.Train,
                    isActive = panelMode == MapPanelMode.Records,
                    onClick = { panelMode = if (panelMode == MapPanelMode.Records) MapPanelMode.Collapsed else MapPanelMode.Records },
                )
                MapStat("Stations", stations.toString(), Icons.Filled.Place)
            }
        }
    }
}

@Composable
private fun MapStat(label: String, value: String, icon: ImageVector, isActive: Boolean = false, onClick: (() -> Unit)? = null) {
    Column(
        modifier = Modifier
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .background(if (isActive) MaterialTheme.colorScheme.primaryContainer else Color.Transparent, RoundedCornerShape(6.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(icon, contentDescription = null, tint = if (isActive) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
        Text(tr(value), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
        Text(tr(label), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private enum class MapPanelMode { Collapsed, Routes, Records }

@Composable
fun RawRecordExplanationView(explanation: RawRecordExplanation, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier.fillMaxWidth().padding(start = 56.dp, end = 8.dp, bottom = 8.dp),
        shape = RoundedCornerShape(8.dp),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(tr(explanation.title), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(tr(explanation.summary), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            explanation.values.forEach { value ->
                Column {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                        Text(tr(value.title), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Text(tr(value.value), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold)
                    }
                    Text(tr(value.source), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.outline)
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RecordRawBottomSheet(
    tx: TransitTransaction,
    explanation: RawRecordExplanation?,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = false),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxWidth(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 20.dp, end = 20.dp, bottom = 32.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item {
                Text(tr(tx.type), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                tx.location?.let {
                    Text(tr(it), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            item {
                HighlightedHexView(raw = tx.rawData.orEmpty(), explanation = explanation)
            }
            if (explanation != null) {
                item {
                    RawRecordExplanationView(explanation, modifier = Modifier.fillMaxWidth())
                }
            } else {
                item {
                    Text(tr("No parser-specific explanation is available for this record yet."), color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun HighlightedHexView(raw: String, explanation: RawRecordExplanation?) {
    val clean = raw.uppercase().filter { it in '0'..'9' || it in 'A'..'F' }
    val bytes = clean.chunked(2)
    val highlights = explanation?.values.orEmpty()
    Card(shape = RoundedCornerShape(8.dp), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant)) {
        Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(tr("Highlighted Hex"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(3.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        tr("row"),
                        modifier = Modifier.width(34.dp),
                        style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace, letterSpacing = 0.sp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center,
                    )
                    repeat(8) { col ->
                        Text(
                            "%02X".format(col),
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace, letterSpacing = 0.sp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Bold,
                            textAlign = TextAlign.Center,
                        )
                    }
                }
                bytes.chunked(8).forEachIndexed { rowIndex, rowBytes ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(3.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "%02X".format(rowIndex * 8),
                            modifier = Modifier.width(34.dp),
                            style = MaterialTheme.typography.labelLarge.copy(fontFamily = FontFamily.Monospace, letterSpacing = 0.sp),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            fontWeight = FontWeight.Bold,
                            textAlign = TextAlign.Center,
                        )
                        repeat(8) { col ->
                            val byteIndex = rowIndex * 8 + col
                            val byteText = rowBytes.getOrNull(col).orEmpty()
                            val highlightIndex = highlights.indexOfFirst { value -> value.byteRange?.contains(byteIndex) == true }
                            val highlightColor = highlightIndex.takeIf { it >= 0 }?.let { rawPalette(it) }
                            Text(
                                byteText,
                                modifier = Modifier
                                    .weight(1f)
                                    .background(
                                        highlightColor?.copy(alpha = 0.24f) ?: MaterialTheme.colorScheme.surface.copy(alpha = 0.48f),
                                        RoundedCornerShape(5.dp),
                                    )
                                    .padding(horizontal = 2.dp, vertical = 4.dp),
                                style = MaterialTheme.typography.bodyLarge.copy(
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = 17.sp,
                                    lineHeight = 23.sp,
                                    letterSpacing = 0.sp,
                                ),
                                color = highlightColor ?: MaterialTheme.colorScheme.onSurface,
                                fontWeight = if (highlightColor != null) FontWeight.Bold else FontWeight.SemiBold,
                                textAlign = TextAlign.Center,
                            )
                        }
                    }
                }
            }
            explanation?.values?.take(8)?.forEachIndexed { index, value ->
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(rawPalette(index).copy(alpha = 0.10f), RoundedCornerShape(6.dp))
                        .padding(8.dp),
                    verticalAlignment = Alignment.Top,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Box(
                        Modifier.size(14.dp).background(rawPalette(index), CircleShape)
                    )
                    Column {
                        Text(tr(value.title), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.Bold)
                        Text(tr(value.value), style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                        Text(tr(value.source), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }
}

@Composable
fun ClickableCardRow(card: SavedCardRecord, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(modifier = modifier.swipeUpAction(onClick).clickable(onClick = onClick)) {
        CompactCardRow(card)
    }
}

fun Modifier.swipeUpAction(onSwipeUp: () -> Unit): Modifier = pointerInput(onSwipeUp) {
    var totalDrag = 0f
    detectVerticalDragGestures(
        onDragStart = { totalDrag = 0f },
        onVerticalDrag = { _, dragAmount -> totalDrag += dragAmount },
        onDragEnd = {
            if (totalDrag < -48f) onSwipeUp()
        },
        onDragCancel = { totalDrag = 0f },
    )
}

@Composable
private fun DetailTextRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(tr(label), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(tr(value), fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
    }
}

private fun categoryIcon(category: TransactionCategory): ImageVector = when (category) {
    TransactionCategory.bus, TransactionCategory.busOn, TransactionCategory.busOff -> Icons.Filled.DirectionsBus
    TransactionCategory.train, TransactionCategory.trainOn, TransactionCategory.trainOff, TransactionCategory.tapOn, TransactionCategory.tapOff -> Icons.Filled.Train
    TransactionCategory.topUp, TransactionCategory.refund -> Icons.Filled.Payments
    TransactionCategory.purchase, TransactionCategory.payment -> Icons.Filled.ShoppingCart
    else -> Icons.Filled.Info
}

private fun categoryColor(category: TransactionCategory): Color = when (category) {
    TransactionCategory.topUp, TransactionCategory.refund -> Color(0xFF2E7D32)
    TransactionCategory.bus, TransactionCategory.busOn, TransactionCategory.busOff -> Color(0xFF00796B)
    TransactionCategory.train, TransactionCategory.trainOn, TransactionCategory.trainOff -> Color(0xFF1565C0)
    TransactionCategory.purchase, TransactionCategory.payment -> Color(0xFF8B3D50)
    else -> Color(0xFF5F6368)
}

private fun formatDate(instant: kotlinx.datetime.Instant, issuerTimeZone: String? = null): String {
    val local = instant.toLocalDateTime(issuerTimeZone?.let(TimeZone::of) ?: TimeZone.currentSystemDefault())
    return "%04d-%02d-%02d %02d:%02d".format(local.year, local.monthNumber, local.dayOfMonth, local.hour, local.minute)
}

private fun rawPalette(index: Int): Color = when (index % 8) {
    0 -> Color(0xFF00897B)
    1 -> Color(0xFF3949AB)
    2 -> Color(0xFFD81B60)
    3 -> Color(0xFFF57C00)
    4 -> Color(0xFF43A047)
    5 -> Color(0xFF8E24AA)
    6 -> Color(0xFF546E7A)
    else -> Color(0xFFC0A000)
}

private fun List<StationPoint>.visibleAtZoom(zoomLevel: Int): List<StationPoint> {
    if (zoomLevel <= 0 || size <= 2) return this
    val centerLat = map { it.latitude }.average()
    val centerLon = map { it.longitude }.average()
    val keepFraction = when (zoomLevel) {
        1 -> 0.75
        2 -> 0.50
        else -> 0.30
    }
    val keepCount = kotlin.math.max(2, kotlin.math.ceil(size * keepFraction).toInt())
    return sortedBy {
        val dLat = it.latitude - centerLat
        val dLon = it.longitude - centerLon
        dLat * dLat + dLon * dLon
    }.take(keepCount)
}

private fun zoomLabel(zoomLevel: Int): String = when (zoomLevel) {
    0 -> "All"
    1 -> "Region"
    2 -> "Area"
    else -> "Local"
}

private const val OSM_RASTER_STYLE = """
{
  "version": 8,
  "sources": {
    "osm": {
      "type": "raster",
      "tiles": ["https://tile.openstreetmap.org/{z}/{x}/{y}.png"],
      "tileSize": 256,
      "attribution": "© OpenStreetMap contributors"
    }
  },
  "layers": [
    {
      "id": "osm",
      "type": "raster",
      "source": "osm"
    }
  ]
}
"""

private fun initialCamera(points: List<StationPoint>): CameraPosition {
    val center = if (points.isEmpty()) {
        LatLng(35.6812, 139.7671)
    } else {
        LatLng(points.map { it.latitude }.average(), points.map { it.longitude }.average())
    }
    val zoom = when {
        points.size <= 1 -> 12.0
        points.maxOf { it.latitude } - points.minOf { it.latitude } < 0.05 &&
            points.maxOf { it.longitude } - points.minOf { it.longitude } < 0.05 -> 12.0
        points.maxOf { it.latitude } - points.minOf { it.latitude } < 0.4 &&
            points.maxOf { it.longitude } - points.minOf { it.longitude } < 0.4 -> 9.0
        else -> 5.0
    }
    return CameraPosition.Builder()
        .target(center)
        .zoom(zoom)
        .build()
}

private fun updateMapLibreRoute(
    context: Context,
    map: MapLibreMap,
    points: List<StationPoint>,
    routes: List<StationRoute>,
    markerCardsByPointCode: Map<String, SavedCardRecord>,
) {
    map.clear()
    val cameraPoints = (points + routes.flatMap { it.points }).distinctBy { it.code }
    if (cameraPoints.isEmpty()) return
    val latLngs = cameraPoints.map { LatLng(it.latitude, it.longitude) }
    val iconFactory = IconFactory.getInstance(context)
    val markerIcons = markerCardsByPointCode.values.distinctBy { it.id }.associate { card ->
        card.id to iconFactory.fromBitmap(cardMarkerBitmap(context, card))
    }
    routes.forEach { route ->
        val routeLatLngs = route.points.map { LatLng(it.latitude, it.longitude) }
        if (routeLatLngs.size < 2) return@forEach
        map.addPolyline(
            PolylineOptions()
                .addAll(routeLatLngs)
                .color(AndroidColor.rgb(31, 107, 100))
                .width(5f),
        )
    }
    points.forEachIndexed { index, point ->
        val options = MarkerOptions()
            .position(LatLng(point.latitude, point.longitude))
            .title(point.name)
            .snippet(point.code)
        markerCardsByPointCode[point.code]?.let { card ->
            markerIcons[card.id]?.let(options::icon)
        }
        map.addMarker(options)
    }
    if (latLngs.size >= 2) {
        val boundsBuilder = LatLngBounds.Builder()
        latLngs.forEach(boundsBuilder::include)
        map.animateCamera(CameraUpdateFactory.newLatLngBounds(boundsBuilder.build(), 64))
    } else {
        map.animateCamera(CameraUpdateFactory.newLatLngZoom(latLngs.first(), 12.0))
    }
}

private fun cardMarkerBitmap(context: Context, card: SavedCardRecord): Bitmap {
    val width = 108
    val height = 76
    val pointerHeight = 12
    val radius = 16f
    val bitmap = Bitmap.createBitmap(width, height + pointerHeight, Bitmap.Config.ARGB_8888)
    bitmap.setHasAlpha(true)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    val cardRect = RectF(3f, 3f, width - 3f, height - 3f)
    val base = AndroidColor.rgb(
        (card.color.red.coerceIn(0.0, 1.0) * 255).roundToInt(),
        (card.color.green.coerceIn(0.0, 1.0) * 255).roundToInt(),
        (card.color.blue.coerceIn(0.0, 1.0) * 255).roundToInt(),
    )
    val darker = AndroidColor.rgb(
        (card.color.red.coerceIn(0.0, 1.0) * 178).roundToInt(),
        (card.color.green.coerceIn(0.0, 1.0) * 178).roundToInt(),
        (card.color.blue.coerceIn(0.0, 1.0) * 178).roundToInt(),
    )
    val pointerPath = Path().apply {
        moveTo(width / 2f - 11f, height - 5f)
        lineTo(width / 2f + 11f, height - 5f)
        lineTo(width / 2f, height + pointerHeight - 1f)
        close()
    }
    paint.style = Paint.Style.FILL
    paint.shader = LinearGradient(
        width / 2f,
        height - 6f,
        width / 2f,
        height + pointerHeight.toFloat(),
        base,
        darker,
        Shader.TileMode.CLAMP,
    )
    canvas.drawPath(pointerPath, paint)
    paint.shader = null

    val clip = Path().apply { addRoundRect(cardRect, radius, radius, Path.Direction.CW) }
    canvas.save()
    canvas.clipPath(clip)
    val face = cardFaceBitmap(context, card)
    if (face != null) {
        paint.alpha = 255
        paint.shader = null
        paint.color = base
        canvas.drawRect(cardRect, paint)
        drawCenterCropped(canvas, face, cardRect, paint)
    } else {
        paint.shader = LinearGradient(
            cardRect.left,
            cardRect.top,
            cardRect.right,
            cardRect.bottom,
            base,
            darker,
            Shader.TileMode.CLAMP,
        )
        canvas.drawRect(cardRect, paint)
        paint.shader = null
        paint.strokeWidth = 4f
        paint.color = AndroidColor.WHITE
        canvas.drawLine(cardRect.left + 18f, cardRect.bottom - 20f, cardRect.right - 18f, cardRect.bottom - 20f, paint)
        canvas.drawLine(cardRect.left + 18f, cardRect.bottom - 11f, cardRect.right - 38f, cardRect.bottom - 11f, paint)
    }
    canvas.restore()

    paint.style = Paint.Style.STROKE
    paint.strokeWidth = 3f
    paint.color = AndroidColor.WHITE
    canvas.drawRoundRect(cardRect, radius, radius, paint)
    canvas.drawPath(pointerPath, paint)
    paint.style = Paint.Style.FILL
    if (face == null) {
        paint.color = AndroidColor.WHITE
        canvas.drawCircle(24f, 24f, 8f, paint)
        paint.textSize = 15f
        paint.typeface = android.graphics.Typeface.DEFAULT_BOLD
        canvas.drawText(context.cardTitle(card).take(8), 38f, 30f, paint)
    }
    return bitmap
}

private fun cardFaceBitmap(context: Context, card: SavedCardRecord): Bitmap? {
    if (card.finalIsUsingImage && !card.faceImageFileName.isNullOrBlank()) {
        val cleanName = card.faceImageFileName.substringAfterLast('/').substringAfterLast('\\')
        val file = File(File(context.filesDir, "CardFaces"), cleanName)
        if (file.isFile) {
            BitmapFactory.decodeFile(file.absolutePath)?.let { return it }
        }
    }
    val drawableId = presetDrawableFor(card.faceImageFileName ?: card.cardFamily)
        ?.takeIf { card.finalIsUsingImage || card.faceImageFileName == null }
    drawableId?.let { return BitmapFactory.decodeResource(context.resources, it) }
    // Markers never download; the wallet card fetches published faces.
    val faces = RemoteCardFaces.get(context)
    return faces.manifest.value?.faceTokenFor(card)?.let(faces::cachedFace)
}

private fun drawCenterCropped(canvas: Canvas, source: Bitmap, destination: RectF, paint: Paint) {
    val sourceRatio = source.width.toFloat() / source.height.toFloat()
    val destinationRatio = destination.width() / destination.height()
    val src = if (sourceRatio > destinationRatio) {
        val cropWidth = (source.height * destinationRatio).roundToInt()
        val left = (source.width - cropWidth) / 2
        Rect(left, 0, left + cropWidth, source.height)
    } else {
        val cropHeight = (source.width / destinationRatio).roundToInt()
        val top = (source.height - cropHeight) / 2
        Rect(0, top, source.width, top + cropHeight)
    }
    canvas.drawBitmap(source, src, destination, paint)
}
