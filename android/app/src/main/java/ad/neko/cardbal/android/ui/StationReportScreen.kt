package ad.neko.cardbal.android.ui

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Looper
import android.view.MotionEvent
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.MyLocation
import androidx.compose.material.icons.filled.Place
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import ad.neko.cardbal.android.BuildConfig
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.StationReportClient
import ad.neko.cardbal.android.data.StationReportForm
import ad.neko.cardbal.android.data.StationReportKind
import ad.neko.cardbal.android.data.StationReports
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.maplibre.android.MapLibre
import org.maplibre.android.annotations.MarkerOptions
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.camera.CameraUpdateFactory
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import java.util.Locale
import kotlin.coroutines.resume

private const val LOCATION_UNAVAILABLE = "Location access is unavailable. You can place a pin manually."
private const val LOCATION_NOT_FOUND = "Could not find your location. You can place a pin manually."
private const val SEND_FAILED = "Could not send the report. Please try again."

/** The "Report or Correct a Station" link shown on card and record details. */
@Composable
fun StationReportLink(onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .heightIn(min = 48.dp)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Place, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
        Text(tr("Report or Correct a Station"), modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.primary)
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Android port of iOS StationReportView: a missing-station or code-correction report for one saved card. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StationReportScreen(
    card: SavedCardRecord,
    stationCode: String?,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val client = remember { StationReportClient() }

    var kind by rememberSaveable { mutableStateOf(StationReportKind.Missing) }
    var stationName by rememberSaveable { mutableStateOf("") }
    var code by rememberSaveable { mutableStateOf(stationCode.orEmpty()) }
    var suggestedCode by rememberSaveable { mutableStateOf("") }
    var lines by rememberSaveable { mutableStateOf("") }
    var operatorName by rememberSaveable { mutableStateOf("") }
    var city by rememberSaveable { mutableStateOf("") }
    var country by rememberSaveable { mutableStateOf("") }
    var notes by rememberSaveable { mutableStateOf("") }
    var showMap by rememberSaveable { mutableStateOf(false) }
    // A single ID per form instance lets the server de-duplicate retries.
    val submissionId = rememberSaveable { StationReports.newSubmissionId() }
    var latitude by rememberSaveable { mutableStateOf<Double?>(null) }
    var longitude by rememberSaveable { mutableStateOf<Double?>(null) }
    var accuracyMeters by rememberSaveable { mutableStateOf<Double?>(null) }
    var locationError by rememberSaveable { mutableStateOf<String?>(null) }
    var isLocating by remember { mutableStateOf(false) }
    var isSubmitting by remember { mutableStateOf(false) }
    var errorMessage by rememberSaveable { mutableStateOf<String?>(null) }
    var successId by rememberSaveable { mutableStateOf<String?>(null) }

    val form = StationReportForm(kind, stationName, code, suggestedCode, lines, operatorName, city, country, notes)

    fun locate() {
        isLocating = true
        locationError = null
        scope.launch {
            val fix = StationReportLocator.currentLocation(context)
            isLocating = false
            if (fix == null) {
                locationError = LOCATION_NOT_FOUND
            } else {
                latitude = fix.latitude
                longitude = fix.longitude
                accuracyMeters = if (fix.hasAccuracy()) fix.accuracy.toDouble() else null
                locationError = null
            }
        }
    }
    // Permission is requested only after the user asks for the current location.
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants.values.any { it } || StationReportLocator.hasPermission(context)) {
            locate()
        } else {
            isLocating = false
            locationError = LOCATION_UNAVAILABLE
        }
    }

    fun submit() {
        if (!form.canSubmit(isSubmitting)) return
        isSubmitting = true
        errorMessage = null
        val lat = latitude
        val lon = longitude
        val payload = form.payload(
            submissionId = submissionId,
            location = if (lat != null && lon != null) StationReports.location(lat, lon, accuracyMeters) else null,
            cardFamily = card.cardFamily,
            cardIdHash = StationReports.cardIdHash(card.id),
            appVersion = BuildConfig.VERSION_NAME,
            deviceId = StationReports.deviceId(context.getSharedPreferences(StationReports.PREFERENCES, Context.MODE_PRIVATE)),
        )
        scope.launch {
            val result = withContext(Dispatchers.IO) { runCatching { client.submit(payload) } }
            isSubmitting = false
            result.onSuccess { successId = it }.onFailure { errorMessage = SEND_FAILED }
        }
    }

    BackHandler(onBack = onClose)

    Column(modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(tr("Report Station")) },
            navigationIcon = {
                IconButton(onClick = onClose) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = tr("Back"))
                }
            },
        )
        Column(
            Modifier
                .fillMaxWidth()
                .weight(1f)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            ReportSection(
                header = "Station",
                footer = "For a code correction, enter the code shown by CardBal and the correct station name. The correct code is optional.",
            ) {
                Text(tr("Report Type"), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    StationReportKind.entries.forEachIndexed { index, item ->
                        SegmentedButton(
                            selected = kind == item,
                            onClick = { kind = item },
                            shape = SegmentedButtonDefaults.itemShape(index = index, count = StationReportKind.entries.size),
                            label = { Text(tr(item.title)) },
                        )
                    }
                }
                ReportField(stationName, { stationName = it }, "Station Name", StationReports.MAX_NAME)
                ReportField(
                    code, { code = it },
                    if (kind == StationReportKind.Correction) "Code Shown by CardBal (Required)" else "Code Shown by CardBal (Optional)",
                    StationReports.MAX_CODE,
                    codeKeyboard = true,
                )
                if (kind == StationReportKind.Correction) {
                    ReportField(suggestedCode, { suggestedCode = it }, "Correct Code (Optional)", StationReports.MAX_CODE, codeKeyboard = true)
                }
            }

            ReportSection(header = "More Details (Optional)") {
                ReportField(lines, { lines = it }, "Line or Lines", StationReports.MAX_LINES)
                ReportField(operatorName, { operatorName = it }, "Operator", StationReports.MAX_NAME)
                ReportField(city, { city = it }, "City", StationReports.MAX_NAME)
                ReportField(country, { country = it }, "Country or Region", StationReports.MAX_NAME)
                ReportField(notes, { notes = it }, "Notes", StationReports.MAX_NOTES, singleLine = false)
                Footnote("Notes stay private. Do not include personal details or raw trip data.")
            }

            ReportSection(
                header = "Location (Optional)",
                footer = "Your location is never read automatically. Only a pin you choose is sent with this report.",
            ) {
                if (showMap) {
                    StationReportPinMap(
                        latitude = latitude,
                        longitude = longitude,
                        onPick = { lat, lon ->
                            latitude = lat
                            longitude = lon
                            accuracyMeters = null
                            locationError = null
                        },
                        modifier = Modifier.fillMaxWidth().height(260.dp),
                    )
                    Footnote("Tap the map to place or move a pin.")
                    Footnote("Map data © OpenStreetMap contributors")
                } else {
                    TextButton(onClick = { showMap = true }) { Text(tr("Choose a Pin on Map")) }
                }
                OutlinedButton(
                    onClick = {
                        showMap = true
                        locationError = null
                        isLocating = true
                        if (StationReportLocator.hasPermission(context)) {
                            locate()
                        } else {
                            permissionLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
                        }
                    },
                    enabled = !isLocating,
                ) {
                    if (isLocating) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Icon(Icons.Filled.MyLocation, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(tr("Use Current Location"))
                    }
                }
                val lat = latitude
                val lon = longitude
                if (lat != null && lon != null) {
                    Text(
                        String.format(Locale.ROOT, "%.5f, %.5f", lat, lon),
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    )
                    TextButton(onClick = {
                        latitude = null
                        longitude = null
                        accuracyMeters = null
                        locationError = null
                    }) {
                        Text(tr("Remove Location"), color = MaterialTheme.colorScheme.error)
                    }
                }
                locationError?.let {
                    Text(tr(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
            }

            ReportSection(header = null) {
                Footnote("Station details and an approximate pin, if selected, appear on the public request list. Notes, this card's SHA-256 ID hash, the app version, and an app-specific device ID stay private for review. The raw card ID and trip history are not sent.")
                errorMessage?.let {
                    Text(tr(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                }
                Button(
                    onClick = { submit() },
                    enabled = form.canSubmit(isSubmitting),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (isSubmitting) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    } else {
                        Text(tr("Submit Report"))
                    }
                }
            }
        }
    }

    successId?.let { id ->
        AlertDialog(
            onDismissRequest = onClose,
            title = { Text(tr("Report Received")) },
            text = { Text(tr("Reference: $id")) },
            confirmButton = {
                TextButton(onClick = onClose) { Text(tr("Done")) }
            },
        )
    }
}

@Composable
private fun ReportSection(header: String?, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        header?.let {
            Text(tr(it), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        }
        Card(
            shape = RoundedCornerShape(8.dp),
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)),
        ) {
            Column(Modifier.fillMaxWidth().padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
        }
        footer?.let { Footnote(it) }
    }
}

@Composable
private fun Footnote(text: String) {
    Text(tr(text), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun ReportField(
    value: String,
    onValueChange: (String) -> Unit,
    label: String,
    maxLength: Int,
    singleLine: Boolean = true,
    codeKeyboard: Boolean = false,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(tr(label)) },
        singleLine = singleLine,
        minLines = if (singleLine) 1 else 2,
        maxLines = if (singleLine) 1 else 5,
        isError = value.length > maxLength,
        keyboardOptions = if (codeKeyboard) {
            KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false)
        } else {
            KeyboardOptions(capitalization = KeyboardCapitalization.Sentences)
        },
        modifier = Modifier.fillMaxWidth(),
    )
}

/** MapLibre pin picker: starts over East Asia like iOS (30, 115; ~80° span) and zooms to ~0.025° on a pin. */
@SuppressLint("ClickableViewAccessibility")
@Composable
private fun StationReportPinMap(
    latitude: Double?,
    longitude: Double?,
    onPick: (Double, Double) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val currentOnPick = rememberUpdatedState(onPick)
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var styleReady by remember { mutableStateOf(false) }
    var renderedPin by remember { mutableStateOf<Pair<Double, Double>?>(null) }
    val mapView = remember {
        MapLibre.getInstance(context)
        MapView(context).apply {
            // Keep pans and taps on the map instead of the scrolling form.
            setOnTouchListener { view, event ->
                if (event.actionMasked == MotionEvent.ACTION_DOWN) view.parent?.requestDisallowInterceptTouchEvent(true)
                false
            }
            onCreate(null)
            onStart()
            onResume()
            getMapAsync { mapLibreMap ->
                map = mapLibreMap
                mapLibreMap.uiSettings.isAttributionEnabled = true
                mapLibreMap.uiSettings.isLogoEnabled = false
                mapLibreMap.uiSettings.isRotateGesturesEnabled = false
                mapLibreMap.cameraPosition = CameraPosition.Builder()
                    .target(LatLng(30.0, 115.0))
                    .zoom(0.75)
                    .build()
                mapLibreMap.addOnMapClickListener { point ->
                    StationReports.location(point.latitude, point.longitude)?.let {
                        currentOnPick.value(it.latitude, it.longitude)
                    }
                    true
                }
                mapLibreMap.setStyle(Style.Builder().fromJson(OSM_RASTER_STYLE)) {
                    styleReady = true
                }
            }
        }
    }

    DisposableEffect(mapView) {
        onDispose {
            mapView.onPause()
            mapView.onStop()
            mapView.onDestroy()
        }
    }

    AndroidView(
        modifier = modifier.background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(8.dp)),
        factory = { mapView },
        update = {
            val currentMap = map
            val pin = if (latitude != null && longitude != null) latitude to longitude else null
            if (styleReady && currentMap != null && pin != renderedPin) {
                currentMap.clear()
                if (pin != null) {
                    val target = LatLng(pin.first, pin.second)
                    currentMap.addMarker(MarkerOptions().position(target))
                    val update = runCatching {
                        val bounds = LatLngBounds.Builder()
                            .include(LatLng((pin.first + 0.0125).coerceAtMost(85.0), pin.second + 0.0125))
                            .include(LatLng((pin.first - 0.0125).coerceAtLeast(-85.0), pin.second - 0.0125))
                            .build()
                        CameraUpdateFactory.newLatLngBounds(bounds, 0)
                    }.getOrElse { CameraUpdateFactory.newLatLngZoom(target, 12.5) }
                    currentMap.animateCamera(update)
                }
                renderedPin = pin
            }
        },
    )
}

/** Platform LocationManager only (no Google Play services); callers check permission first. */
internal object StationReportLocator {
    private const val FIX_TIMEOUT_MILLIS = 20_000L

    fun hasPermission(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    suspend fun currentLocation(context: Context): Location? {
        if (!hasPermission(context)) return null
        val manager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return null
        val fine = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        val providers = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add(LocationManager.FUSED_PROVIDER)
            if (fine) add(LocationManager.GPS_PROVIDER)
            add(LocationManager.NETWORK_PROVIDER)
        }.filter { provider ->
            try {
                manager.isProviderEnabled(provider)
            } catch (_: RuntimeException) {
                false
            }
        }
        for (provider in providers) {
            withTimeoutOrNull(FIX_TIMEOUT_MILLIS) { singleFix(context, manager, provider) }?.let { return it }
        }
        return null
    }

    @SuppressLint("MissingPermission")
    private suspend fun singleFix(context: Context, manager: LocationManager, provider: String): Location? =
        suspendCancellableCoroutine { continuation ->
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val signal = CancellationSignal()
                    continuation.invokeOnCancellation { signal.cancel() }
                    manager.getCurrentLocation(provider, signal, context.mainExecutor) { location: Location? ->
                        if (continuation.isActive) continuation.resume(location)
                    }
                } else {
                    val listener = object : LocationListener {
                        override fun onLocationChanged(location: Location) {
                            if (continuation.isActive) continuation.resume(location)
                        }

                        override fun onProviderDisabled(provider: String) {
                            if (continuation.isActive) continuation.resume(null)
                        }

                        override fun onProviderEnabled(provider: String) {}

                        // Abstract before API 30, so it must be implemented for older devices.
                        @Deprecated("Deprecated in Android")
                        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
                    }
                    continuation.invokeOnCancellation { manager.removeUpdates(listener) }
                    @Suppress("DEPRECATION")
                    manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                }
            } catch (_: SecurityException) {
                if (continuation.isActive) continuation.resume(null)
            } catch (_: IllegalArgumentException) {
                if (continuation.isActive) continuation.resume(null)
            }
        }
}
