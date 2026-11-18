package ad.neko.cardbal.android

import android.content.ClipData
import android.content.ClipboardManager
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Feedback
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Nfc
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Wallet
import androidx.compose.material3.AssistChip
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.zIndex
import ad.neko.cardbal.android.data.ImportErrors
import ad.neko.cardbal.android.data.AirCrashReports
import ad.neko.cardbal.android.data.CardWalletRepository
import ad.neko.cardbal.android.data.DebugLog
import ad.neko.cardbal.android.data.DualCurrencyBalance
import ad.neko.cardbal.android.data.identityAliases
import ad.neko.cardbal.android.data.KoreanTripCrowdsourcingPreferences
import ad.neko.cardbal.android.data.KoreanTripCrowdsourcingUploader
import ad.neko.cardbal.android.data.RemoteCardFaces
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.TransactionDecoder
import ad.neko.cardbal.android.data.TripReaderBackup
import ad.neko.cardbal.android.nfc.CardBalNfcReader
import ad.neko.cardbal.android.nfc.OctopusMetadataStore
import ad.neko.cardbal.android.nfc.OctopusOnlineDecoder
import ad.neko.cardbal.android.ui.tr
import ad.neko.cardbal.android.ui.cardTitle
import ad.neko.cardbal.android.ui.CardBalTheme
import ad.neko.cardbal.android.ui.CardDetailScreen
import ad.neko.cardbal.android.ui.CardFaceLibraryScreen
import ad.neko.cardbal.android.ui.DisplaySettings
import ad.neko.cardbal.android.ui.DualBalanceRows
import ad.neko.cardbal.android.ui.FeedbackScreen
import ad.neko.cardbal.android.ui.GeneralSettings
import ad.neko.cardbal.android.ui.MapViewportBounds
import ad.neko.cardbal.android.ui.RideMapSurface
import ad.neko.cardbal.android.ui.WalletCard
import ad.neko.cardbal.android.ui.WalletCardMode
import ad.neko.cardbal.android.ui.swipeUpAction
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import android.os.Build

class MainActivity : ComponentActivity() {
    private val reader: CardBalNfcReader by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        // Draw behind the bars on every API level; the bar icons follow the system dark theme.
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        DebugLog.install(noBackupFilesDir)
        // AirFeedback crash reports: a crash is saved and sent on the next launch.
        AirCrashReports.start(this)
        DisplaySettings.load(this)
        GeneralSettings.load(this)
        val sampleWallet = BuildConfig.DEBUG && Build.HARDWARE in setOf("goldfish", "ranchu") &&
            intent.getBooleanExtra("cardbal.developmentSamples", false)
        setContent {
            val repository = remember {
                CardWalletRepository(applicationContext, sampleWallet = sampleWallet).also {
                    if (sampleWallet) {
                        runCatching { it.loadDevelopmentSamples(File(filesDir, "development/sample-wallet.json").readBytes()) }
                            .onFailure { Toast.makeText(this, this.tr("Unable to load development samples"), Toast.LENGTH_LONG).show() }
                    }
                }
            }
            CardBalTheme {
                CardBalApp(activity = this, reader = reader, repository = repository)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        // With Scan on Launch off, NFC stays idle until the person taps Scan.
        if (GeneralSettings.scanOnLaunch || reader.hasStarted) reader.start(this)
    }

    override fun onPause() {
        super.onPause()
        reader.stop(this)
    }
}

private enum class Tab(val label: String) {
    Scan("Scan"), Cards("Cards"), Map("Map"), Settings("Settings")
}

@Composable
private fun CardBalApp(
    activity: ComponentActivity,
    reader: CardBalNfcReader,
    repository: CardWalletRepository,
) {
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }
    var selectedCardId by rememberSaveable { mutableStateOf<String?>(null) }
    val cards by repository.cards.collectAsState()
    val status by reader.status.collectAsState()
    val isScanning by reader.isScanning.collectAsState()
    val latestSnapshot by reader.latestSnapshot.collectAsState()
    val transactionDecoder = remember { TransactionDecoder(activity.applicationContext) }
    val selectedCard = selectedCardId?.let { id -> cards.firstOrNull { it.id == id } }

    BackHandler(enabled = selectedTab != Tab.Scan.ordinal) {
        selectedTab = Tab.Scan.ordinal
    }

    LaunchedEffect(latestSnapshot?.storageIdentifier, latestSnapshot?.scannedAt) {
        latestSnapshot?.let { snapshot ->
            repository.upsert(snapshot)
            // Eligible Korean scans share their trip records in the background unless turned off.
            KoreanTripCrowdsourcingUploader.get(activity).launch(snapshot)
        }
    }
    LaunchedEffect(Unit) {
        RemoteCardFaces.get(activity).refreshIfNeeded()
    }

    if (selectedCard != null) {
        val transactions = remember(selectedCard) { transactionDecoder.transactionsFor(selectedCard) }
        val routes = remember(selectedCard) { transactionDecoder.routesFor(selectedCard) }
        val routePoints = remember(selectedCard) { transactionDecoder.stationPinsFor(selectedCard) }
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            CardDetailScreen(
                // Its top app bars take the status bar; keep content clear of the navigation bar and cutouts.
                modifier = Modifier.windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)),
                card = selectedCard,
                transactions = transactions,
                routePoints = routePoints,
                routes = routes,
                rawExplanationFor = { tx -> transactionDecoder.rawExplanationFor(selectedCard, tx) },
                onBack = { selectedCardId = null },
                onCustomize = { change -> repository.customize(selectedCard.id, change) },
                onDelete = {
                    selectedCardId = null
                    repository.delete(selectedCard.id)
                },
            )
        }
        return
    }

    Scaffold(
        bottomBar = {
            NavigationBar {
                Tab.entries.forEachIndexed { index, tab ->
                    NavigationBarItem(
                        selected = selectedTab == index,
                        onClick = { selectedTab = index },
                        icon = {
                            Icon(
                                imageVector = when (tab) {
                                    Tab.Scan -> Icons.Filled.Nfc
                                    Tab.Cards -> Icons.Filled.Wallet
                                    Tab.Map -> Icons.Filled.Map
                                    Tab.Settings -> Icons.Filled.Settings
                                },
                                contentDescription = tr(tab.label),
                            )
                        },
                        label = { Text(tr(tab.label)) },
                    )
                }
            }
        },
    ) { padding ->
        // Consumed so top app bars inside a tab (Feedback, card faces) don't add the status bar again.
        val contentModifier = if (Tab.entries[selectedTab] == Tab.Map) {
            val bottom = PaddingValues(bottom = padding.calculateBottomPadding())
            Modifier.fillMaxSize().padding(bottom).consumeWindowInsets(bottom)
        } else {
            Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)
        }
        Surface(contentModifier, color = MaterialTheme.colorScheme.background) {
            when (Tab.entries[selectedTab]) {
                Tab.Scan -> ScanScreen(
                    latestCard = latestSnapshot?.storageIdentifier?.let { id -> cards.firstOrNull { it.id == id } ?: cards.firstOrNull { id in it.identityAliases } } ?: cards.firstOrNull(),
                    status = status,
                    isScanning = isScanning,
                    onScan = { reader.start(activity) },
                    onOpenCard = { selectedCardId = it.id },
                )
                Tab.Cards -> CardsScreen(cards = cards, onOpenCard = { selectedCardId = it.id })
                Tab.Map -> MapScreen(cards = cards, decoder = transactionDecoder, onOpenCard = { selectedCardId = it.id })
                Tab.Settings -> SettingsScreen(cards = cards, repository = repository)
            }
        }
    }
}

@Composable
private fun ScanScreen(
    latestCard: SavedCardRecord?,
    status: String,
    isScanning: Boolean,
    onScan: () -> Unit,
    onOpenCard: (SavedCardRecord) -> Unit,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        item {
            ScreenHeader(title = "Scan", subtitle = status)
        }
        item {
            ScanCardHero(
                latestCard = latestCard,
                isScanning = isScanning,
                onScan = onScan,
                onOpenCard = onOpenCard,
            )
        }
        if (latestCard != null) {
            item {
                ElevatedCard(shape = MaterialTheme.shapes.large) {
                    CardDetails(latestCard, modifier = Modifier.padding(18.dp))
                }
            }
        }
    }
}

@Composable
private fun CardsScreen(cards: List<SavedCardRecord>, onOpenCard: (SavedCardRecord) -> Unit) {
    if (cards.isEmpty()) {
        EmptyState("No saved cards", "Scan a card to add it to your wallet.")
        return
    }
    val transactionCount = remember(cards) { cards.sumOf { it.rawTransactions.size } }
    val tripCount = remember(cards) { cards.sumOf { it.rawTransitHistory.size } }
    var previewCardId by rememberSaveable { mutableStateOf<String?>(null) }
    val selectedCard = previewCardId?.let { id -> cards.firstOrNull { it.id == id } }
    val scrollState = rememberScrollState()
    BackHandler(enabled = selectedCard != null) {
        previewCardId = null
    }
    val stackedCards = remember(cards, previewCardId) {
        cards.filterNot { it.id == previewCardId }
    }

    LaunchedEffect(cards) {
        if (previewCardId != null && cards.none { it.id == previewCardId }) {
            previewCardId = null
        }
    }
    LaunchedEffect(previewCardId) {
        if (previewCardId != null) scrollState.animateScrollTo(0)
    }

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(scrollState)
            .padding(horizontal = 20.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        ScreenHeader(title = "Cards", subtitle = "${cards.size} saved cards")
        if (selectedCard != null) {
            // The actions sit between the selected card and the stack so nothing overlaps them.
            WalletCard(
                card = selectedCard,
                mode = WalletCardMode.Hero,
                modifier = Modifier.clickable { previewCardId = null },
            )
            SelectedCardActions(
                card = selectedCard,
                transactionCount = selectedCard.rawTransactions.size,
                tripCount = selectedCard.rawTransitHistory.size,
                onOpenCard = { onOpenCard(selectedCard) },
            )
        }
        if (stackedCards.isNotEmpty()) {
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val cardHeight = maxWidth * 17f / 27f
                val stackedSpacing = 58.dp
                Box(Modifier.fillMaxWidth().height(cardHeight + stackedSpacing * (stackedCards.size - 1))) {
                    stackedCards.forEachIndexed { index, card ->
                        WalletCard(
                            card = card,
                            mode = WalletCardMode.Hero,
                            modifier = Modifier
                                .offset(y = stackedSpacing * index)
                                .zIndex(index.toFloat())
                                .clickable { previewCardId = card.id },
                        )
                    }
                }
            }
        }
        if (selectedCard == null) {
            SummaryStrip(
                firstLabel = "Cards",
                firstValue = cards.size.toString(),
                secondLabel = "Records",
                secondValue = transactionCount.toString(),
                thirdLabel = "Trips",
                thirdValue = tripCount.toString(),
            )
        }
    }
}

@Composable
private fun SelectedCardActions(
    card: SavedCardRecord,
    transactionCount: Int,
    tripCount: Int,
    onOpenCard: () -> Unit,
) {
    ElevatedCard(
        shape = MaterialTheme.shapes.large,
        colors = androidx.compose.material3.CardDefaults.elevatedCardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        ),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    cardTitle(card),
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    tr("$transactionCount Tx · $tripCount Trips"),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                )
            }
            FilledTonalButton(onClick = onOpenCard) {
                Icon(Icons.Filled.CreditCard, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(8.dp))
                Text(tr("Details"))
            }
        }
    }
}

@Composable
private fun MapScreen(cards: List<SavedCardRecord>, decoder: TransactionDecoder, onOpenCard: (SavedCardRecord) -> Unit) {
    val context = LocalContext.current
    var selectedMapCardId by rememberSaveable { mutableStateOf<String?>(null) }
    var mapViewport by remember { mutableStateOf<MapViewportBounds?>(null) }
    BackHandler(enabled = selectedMapCardId != null) {
        selectedMapCardId = null
    }
    val scopedCards = remember(cards, selectedMapCardId) {
        selectedMapCardId?.let { id -> cards.filter { it.id == id } } ?: cards
    }
    val cachedMapData = remember(cards) {
        cards.mapNotNull { card -> decoder.cachedMapDataFor(card)?.let { card.id to it } }.toMap()
    }
    val mapData by produceState(initialValue = cachedMapData, cards) {
        value = withContext(Dispatchers.Default) {
            cards.associate { card -> card.id to decoder.mapDataFor(card) }
        }
    }
    val cardStationPoints = remember(cards, mapData) {
        cards.associate { card -> card.id to mapData[card.id]?.pins.orEmpty() }
    }
    val viewportCards = remember(cards, cardStationPoints, mapViewport, selectedMapCardId) {
        val cardsWithMappedTransactions = cards.filter { card ->
            cardStationPoints[card.id].orEmpty().isNotEmpty()
        }
        val inViewport = mapViewport?.let { bounds ->
            cardsWithMappedTransactions.filter { card ->
                cardStationPoints[card.id].orEmpty().any(bounds::contains)
            }
        } ?: cardsWithMappedTransactions
        val selectedCard = selectedMapCardId?.let { id -> cards.firstOrNull { it.id == id } }
        if (selectedCard != null && inViewport.none { it.id == selectedCard.id }) {
            listOf(selectedCard) + inViewport
        } else {
            inViewport
        }
    }
    val stationRoutes = remember(scopedCards, mapData) { scopedCards.flatMap { mapData[it.id]?.routes.orEmpty() } }
    val allPoints = remember(scopedCards, mapData) { scopedCards.flatMap { mapData[it.id]?.pins.orEmpty() }.distinctBy { it.code } }
    val markerCardsByPointCode = remember(scopedCards, mapData) {
        buildMap {
            scopedCards.forEach { card ->
                mapData[card.id]?.pins.orEmpty().forEach { point ->
                    putIfAbsent(point.code, card)
                }
            }
        }
    }
    val transactions = remember(scopedCards, mapData) {
        scopedCards.flatMap { card -> mapData[card.id]?.transactions.orEmpty().map { card to it } }
    }
    val recordRows = remember(transactions) {
        transactions.map { (card, tx) ->
            "${context.cardTitle(card)}: ${context.tr(tx.type)}${tx.location?.let { " · ${context.tr(it)}" } ?: ""}"
        }
    }
    val routeRows = remember(stationRoutes) {
        stationRoutes.map { it.title }
    }
    RideMapSurface(
        cards = cards,
        filterCards = viewportCards,
        selectedCardId = selectedMapCardId,
        onSelectCard = { selectedMapCardId = it },
        points = allPoints,
        stationRoutes = stationRoutes,
        markerCardsByPointCode = markerCardsByPointCode,
        records = recordRows,
        routes = routeRows,
        onOpenCard = onOpenCard,
        onViewportChanged = { mapViewport = it },
        modifier = Modifier.fillMaxSize(),
    )
}

@Composable
private fun SettingsScreen(cards: List<SavedCardRecord>, repository: CardWalletRepository) {
    val context = LocalContext.current
    var showsFaceLibrary by rememberSaveable { mutableStateOf(false) }
    if (showsFaceLibrary) {
        CardFaceLibraryScreen(cards = cards, onBack = { showsFaceLibrary = false })
        return
    }
    var showsFeedback by rememberSaveable { mutableStateOf(false) }
    if (showsFeedback) {
        FeedbackScreen(onBack = { showsFeedback = false })
        return
    }
    val octopusPreferences = remember(context) { context.getSharedPreferences("octopus", 0) }
    var octopusOnlineEnabled by remember { mutableStateOf(octopusPreferences.getBoolean("octopusOnlineEnabled", true)) }
    var octopusCardUpdatesEnabled by remember { mutableStateOf(octopusPreferences.getBoolean("octopusCardUpdatesEnabled", false)) }
    val koreanTripPreferences = remember(context) {
        context.getSharedPreferences(KoreanTripCrowdsourcingPreferences.PREFERENCES, 0)
    }
    var koreanTripCrowdsourcingEnabled by remember {
        mutableStateOf(koreanTripPreferences.getBoolean(KoreanTripCrowdsourcingPreferences.ENABLED_KEY, true))
    }
    var showsKoreanTripDetails by rememberSaveable { mutableStateOf(false) }
    // Scans may have added lines since Settings was last shown.
    var debugLogIsEmpty by remember { mutableStateOf(DebugLog.shared.isEmpty) }
    var debugLogMessage by remember { mutableStateOf<String?>(null) }
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("application/json"),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.openOutputStream(uri)?.use { output ->
                output.write(repository.exportBackup())
            } ?: error("Unable to open export destination")
        }.onSuccess {
            Toast.makeText(context, context.tr("CardBal backup exported"), Toast.LENGTH_SHORT).show()
        }.onFailure {
            Toast.makeText(context, context.tr("Export failed: ${it.localizedMessage}"), Toast.LENGTH_LONG).show()
        }
    }
    val importLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        runCatching {
            val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
                input.readBytes()
            } ?: error("Unable to open selected backup")
            repository.importBackup(bytes)
        }.onSuccess { result ->
            Toast.makeText(
                context,
                context.tr("Imported ${result.imported} cards (${result.replaced} replaced)"),
                Toast.LENGTH_LONG,
            ).show()
        }.onFailure {
            val message = if (ImportErrors.isFileAccessDenied(it)) context.tr(ImportErrors.FILE_ACCESS_DENIED)
                else context.tr("Import failed: ${it.localizedMessage}")
            Toast.makeText(context, message, Toast.LENGTH_LONG).show()
        }
    }
    val scope = rememberCoroutineScope()
    var isImportingTripReader by remember { mutableStateOf(false) }
    val tripReaderLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        isImportingTripReader = true
        scope.launch {
            val message = runCatching {
                val plan = withContext(Dispatchers.IO) {
                    context.contentResolver.openInputStream(uri)?.use { TripReaderBackup.importPlan(context, it) }
                        ?: error("Unable to open selected backup")
                }
                if (plan.snapshots.isEmpty()) {
                    "No China T-Union or City Union cards were found in this Trip Reader backup."
                } else {
                    repository.importSnapshots(plan.snapshots)
                    val skipped = if (plan.skippedCards > 0) " " + context.tr("Skipped ${plan.skippedCards} cards of other types.") else ""
                    context.tr("Imported ${plan.snapshots.size} cards and ${plan.recordCount} records from Trip Reader.") + skipped
                }
            }.getOrElse {
                if (ImportErrors.isFileAccessDenied(it)) ImportErrors.FILE_ACCESS_DENIED else "Import failed: ${it.localizedMessage}"
            }
            isImportingTripReader = false
            Toast.makeText(context, context.tr(message), Toast.LENGTH_LONG).show()
        }
    }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp),
    ) {
        item {
            Text(tr("Settings"), style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.SemiBold)
        }
        item {
            SettingsSection(title = "Scan") {
                SettingsSwitchRow("Scan on Launch", GeneralSettings.scanOnLaunch, GeneralSettings::updateScanOnLaunch)
            }
        }
        item {
            SettingsSection(title = "Display") {
                SettingsChoiceRow(
                    label = "Date Format",
                    options = DisplaySettings.dateFormats,
                    selected = DisplaySettings.dateFormat,
                    onSelect = DisplaySettings::updateDateFormat,
                )
                SettingsChoiceRow(
                    label = "Card Time Zone",
                    options = listOf(true to "Card Issuer's Time Zone", false to "Current Time Zone"),
                    selected = DisplaySettings.usesIssuerTimeZone,
                    onSelect = DisplaySettings::updateUsesIssuerTimeZone,
                )
                Text(
                    tr("China T-Union uses China Standard Time, Korean cards use Korea Standard Time, and U-Money uses Ulaanbaatar time when issuer time is selected."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                SettingsActionRow(label = "Card Faces", icon = Icons.Filled.PhotoLibrary, enabled = true, onClick = { showsFaceLibrary = true })
            }
        }
        item {
            SettingsSection(title = "Backup") {
                SettingsActionRow(
                    label = "Export Backup",
                    icon = Icons.Filled.Upload,
                    enabled = cards.isNotEmpty() && !isImportingTripReader,
                    onClick = { exportLauncher.launch("cardbal-backup.json") },
                )
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                SettingsActionRow(
                    label = "Import Backup",
                    icon = Icons.Filled.Download,
                    enabled = !isImportingTripReader,
                    onClick = { importLauncher.launch(arrayOf("application/json", "application/octet-stream", "*/*")) },
                )
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                SettingsActionRow(
                    label = if (isImportingTripReader) "Importing..." else "Import Trip Reader Backup",
                    icon = Icons.Filled.Download,
                    enabled = !isImportingTripReader,
                    onClick = {
                        tripReaderLauncher.launch(arrayOf("application/x-sqlite3", "application/vnd.sqlite3", "application/octet-stream", "*/*"))
                    },
                )
            }
        }
        item {
            SettingsSection(title = "Privacy") {
                // Builds without an enquiry endpoint do not offer Octopus Online at all.
                if (BuildConfig.OCTOPUS_ENQUIRY_BASE_URL.isNotBlank()) {
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(tr("Octopus Online"), modifier = Modifier.weight(1f))
                        Switch(
                            checked = octopusOnlineEnabled,
                            onCheckedChange = {
                                octopusOnlineEnabled = it
                                octopusPreferences.edit().putBoolean("octopusOnlineEnabled", it).apply()
                            },
                            modifier = Modifier.semantics { contentDescription = context.tr("Octopus Online") },
                        )
                    }
                    Text(
                        tr("Use online enquiry to save the card number and balance offset. Saved information remains available offline."),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (octopusOnlineEnabled) {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text(tr("Allow Card Updates"), modifier = Modifier.weight(1f))
                            Switch(
                                checked = octopusCardUpdatesEnabled,
                                onCheckedChange = {
                                    octopusCardUpdatesEnabled = it
                                    octopusPreferences.edit().putBoolean("octopusCardUpdatesEnabled", it).apply()
                                },
                                modifier = Modifier.semantics { contentDescription = context.tr("Allow Card Updates") },
                            )
                        }
                        Text(
                            tr("Lets Octopus Online change information stored on your card, such as exchange rates. CardBal can't see or undo these changes. When this is off, Octopus Online only reads your card."),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Text(
                    tr("Scans are stored on this device."),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
                SettingsChoiceRow(
                    label = "Serial Number Display",
                    options = listOf(0 to "Full", 1 to "Masked (Last Digits)", 2 to "Hidden"),
                    selected = DisplaySettings.serialNumberMode,
                    onSelect = DisplaySettings::updateSerialNumberMode,
                )
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text(tr("Help Improve Korean Cards"), modifier = Modifier.weight(1f))
                    Switch(
                        checked = koreanTripCrowdsourcingEnabled,
                        onCheckedChange = {
                            koreanTripCrowdsourcingEnabled = it
                            koreanTripPreferences.edit().putBoolean(KoreanTripCrowdsourcingPreferences.ENABLED_KEY, it).apply()
                        },
                        modifier = Modifier.semantics { contentDescription = context.tr("Help Improve Korean Cards") },
                    )
                }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable(role = Role.Button) { showsKoreanTripDetails = !showsKoreanTripDetails }
                        .heightIn(min = 48.dp)
                        .semantics { stateDescription = context.tr(if (showsKoreanTripDetails) "Expanded" else "Collapsed") },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(tr("What is shared?"), modifier = Modifier.weight(1f), color = MaterialTheme.colorScheme.primary)
                    Icon(
                        if (showsKoreanTripDetails) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                    )
                }
                if (showsKoreanTripDetails) {
                    Text(
                        tr("When enabled, eligible T-money and EZL/Cashbee scans upload technical trip records for format analysis. Uploaded fields are a dedup hash of card ID plus raw bytes, a hashed card ID, the last 4 characters of the card ID, bytes 0x05-0x08, bytes 0x09-0x0A, and the full raw bytes. Uploads use HTTPS and you can disable this at any time."),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    tr("Optional. Share Korean card records to help improve decoding."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        item {
            SettingsSection(title = "Advanced") {
                SettingsSwitchRow("Developer Mode", GeneralSettings.developerModeEnabled, GeneralSettings::updateDeveloperMode)
                Text(
                    tr("When enabled, KS X 6924 scans probe all SFIs with read-only APDUs and preserve every readable record and short-EF binary block in Raw Data. Scans take longer."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        item {
            // Always shown: the log stays on this device and is copied only when the person taps Copy.
            SettingsSection(title = "Troubleshooting") {
                SettingsActionRow(
                    label = "Copy Debug Log",
                    icon = Icons.Filled.ContentCopy,
                    enabled = !debugLogIsEmpty,
                    onClick = {
                        val octopus = OctopusMetadataStore(context.getSharedPreferences(OctopusMetadataStore.PREFERENCES, 0))
                        val text = DebugLog.shared.exportText(debugEnvironment(), listOf(OctopusOnlineDecoder.debugSummary(octopus)))
                        context.getSystemService(ClipboardManager::class.java)
                            ?.setPrimaryClip(ClipData.newPlainText(DebugLog.TITLE, text))
                        debugLogMessage = "Debug log copied."
                    },
                )
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                SettingsActionRow(
                    label = "Clear Debug Log",
                    icon = Icons.Filled.Delete,
                    enabled = !debugLogIsEmpty,
                    destructive = true,
                    onClick = {
                        DebugLog.shared.clear()
                        debugLogIsEmpty = true
                        debugLogMessage = "Debug log cleared."
                    },
                )
                (debugLogMessage ?: "No scans recorded yet.".takeIf { debugLogIsEmpty })?.let {
                    Text(tr(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Text(
                    tr("Records recent scan steps on this device to help fix reading problems. It's copied only when you tap Copy, and card numbers are shortened."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        item {
            // AirFeedback: the message and screenshots go to the developer; crashes are sent by AirCrashReports.
            SettingsSection(title = "Feedback") {
                SettingsActionRow(label = "Send Feedback", icon = Icons.Filled.Feedback, enabled = true, onClick = { showsFeedback = true })
                Text(
                    tr("Report a problem or share an idea, with screenshots if you like. CardBal also sends crash reports automatically."),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        item {
            SettingsSection(title = "Community") {
                SettingsLinkRow("Support", "cardb.al/support", "https://cardb.al/support/")
                SettingsLinkRow("GitHub", "iebb/TransitICReader", "https://github.com/iebb/TransitICReader")
                SettingsLinkRow("Telegram Group", "t.me/cardbal", "https://t.me/cardbal")
            }
        }
        item {
            SettingsSection(title = "Information") {
                SettingsInfoRow("App", "CardBal Android")
                SettingsInfoRow("Version", BuildConfig.VERSION_NAME)
                Text(
                    tr("Unofficial transit card reader."),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
                Text(
                    tr("Sources: JPStationCodes, station_database, Trip Reader and © OpenStreetMap contributors."),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
        item {
            SettingsSection(title = "Credits") {
                Text(tr("Macau Pass decoding is adapted from TU-Reader (MIT), copyright 2026 HaoTian22."),
                    style = MaterialTheme.typography.bodySmall)
                SettingsLinkRow("TU-Reader source and licence", "HaoTian22/TU-Reader", "https://github.com/HaoTian22/TU-Reader")
                Text(tr("Clipper decoding is adapted from FareBot and Metrodroid (GPL-3.0-or-later)."),
                    style = MaterialTheme.typography.bodySmall)
                SettingsLinkRow("FareBot source and licence", "codebutler/farebot", "https://github.com/codebutler/farebot")
                Text(tr("Clipper station data attributions"), style = MaterialTheme.typography.titleSmall)
                Text(remember(context) { ad.neko.cardbal.android.data.ClipperTransitCatalog.get(context).notice },
                    style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun SettingsSection(
    title: String,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(tr(title), style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            content()
        }
    }
}

@Composable
private fun SettingsActionRow(label: String, icon: ImageVector, enabled: Boolean, destructive: Boolean = false, onClick: () -> Unit) {
    val color = when {
        !enabled -> MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
        destructive -> MaterialTheme.colorScheme.error
        else -> MaterialTheme.colorScheme.primary
    }
    Row(
        Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = onClick).heightIn(min = 48.dp).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(22.dp))
        Text(tr(label), color = color, style = MaterialTheme.typography.bodyLarge)
    }
}

@Composable
private fun SettingsSwitchRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val context = LocalContext.current
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(tr(label), modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            modifier = Modifier.semantics { contentDescription = context.tr(label) },
        )
    }
}

/** The copied log's App, System and Device lines: the device model only, no identifiers. */
private fun debugEnvironment(): List<String> = listOf(
    "App: ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
    "System: Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
    "Device: ${Build.MANUFACTURER} ${Build.MODEL}",
)

@Composable
private fun <T> SettingsChoiceRow(label: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = options.firstOrNull { it.first == selected }?.second.orEmpty()
    Box(Modifier.fillMaxWidth()) {
        Row(
            Modifier
                .fillMaxWidth()
                .clickable { expanded = true }
                .heightIn(min = 48.dp)
                .padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(tr(label), style = MaterialTheme.typography.bodyLarge)
            Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    tr(selectedLabel),
                    color = MaterialTheme.colorScheme.primary,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Icon(Icons.Filled.ExpandMore, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            }
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.align(Alignment.TopEnd)) {
            options.forEach { (value, optionLabel) ->
                DropdownMenuItem(
                    text = { Text(tr(optionLabel)) },
                    onClick = {
                        expanded = false
                        onSelect(value)
                    },
                )
            }
        }
    }
}

@Composable
private fun SettingsLinkRow(label: String, value: String, url: String) {
    val uriHandler = LocalUriHandler.current
    Row(
        Modifier
            .fillMaxWidth()
            .clickable { runCatching { uriHandler.openUri(url) } }
            .heightIn(min = 48.dp)
            .padding(vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(tr(label), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                tr(value),
                color = MaterialTheme.colorScheme.primary,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Spacer(Modifier.size(6.dp))
            Icon(
                Icons.AutoMirrored.Filled.OpenInNew,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

@Composable
private fun SettingsInfoRow(label: String, value: String) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(tr(label), color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        Text(
            tr(value),
            modifier = Modifier.padding(start = 16.dp),
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun CardDetails(card: SavedCardRecord, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(tr("Card details"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
        DetailRow("Technology", card.technology)
        DetailRow("Family", card.cardFamily)
        DetailRow(card.identifierLabel, card.identifierValue)
        card.systemCode?.let { DetailRow("System Code", it) }
        card.selectedAID?.let { DetailRow("Selected AID", it) }
        // An Octopus – China T-Union card with a reported rate shows both balances and the rate.
        val dual = remember(card.applications) { DualCurrencyBalance.from(card.applications) }
        if (dual != null && card.visibleBalance.isNotEmpty()) DualBalanceRows(card.visibleBalance, dual)
        card.balanceScopeNote?.let {
            Text(tr(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ScreenHeader(title: String, subtitle: String? = null) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(tr(title), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Black)
            if (subtitle != null) {
                Text(
                    tr(subtitle),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun ScanCardHero(
    latestCard: SavedCardRecord?,
    isScanning: Boolean,
    onScan: () -> Unit,
    onOpenCard: (SavedCardRecord) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (latestCard == null) Modifier.height(260.dp) else Modifier)
                .clickable { onScan() },
        ) {
            if (latestCard != null) {
                WalletCard(
                    card = latestCard,
                    mode = WalletCardMode.Hero,
                    modifier = Modifier.swipeUpAction { onOpenCard(latestCard) },
                )
            } else {
                EmptyWalletCard(isScanning = isScanning)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            AssistChip(
                onClick = onScan,
                label = { Text(tr(if (isScanning) "NFC active" else "NFC idle")) },
                leadingIcon = { Icon(Icons.Filled.Nfc, contentDescription = null) },
            )
            latestCard?.let {
                AssistChip(
                    onClick = { onOpenCard(it) },
                    label = { Text(tr("${it.rawTransactions.size} Tx / ${it.rawTransitHistory.size} Trips")) },
                    leadingIcon = { Icon(Icons.Filled.CreditCard, contentDescription = null) },
                )
            }
        }
    }
}

@Composable
private fun EmptyWalletCard(isScanning: Boolean) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(260.dp)
            .background(
                Brush.linearGradient(
                    listOf(
                        MaterialTheme.colorScheme.primary,
                        MaterialTheme.colorScheme.tertiary,
                        Color(0xFF202533),
                    ),
                ),
                MaterialTheme.shapes.extraLarge,
            )
            .padding(22.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(
                    Modifier
                        .size(42.dp)
                        .background(Color.White.copy(alpha = 0.20f), CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Nfc, contentDescription = null, tint = Color.White)
                }
                Text(
                    tr("CardBal"),
                    color = Color.White,
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Black,
                )
            }
            Column {
                Text(
                    tr(if (isScanning) "NFC active" else "Transit card"),
                    color = Color.White,
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Black,
                )
                Text(
                    tr("FeliCa / ISO7816"),
                    color = Color.White.copy(alpha = 0.78f),
                    style = MaterialTheme.typography.titleMedium,
                )
            }
        }
    }
}

@Composable
private fun SummaryStrip(
    firstLabel: String,
    firstValue: String,
    secondLabel: String,
    secondValue: String,
    thirdLabel: String,
    thirdValue: String,
) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        SummaryMetric(firstLabel, firstValue, Modifier.weight(1f))
        SummaryMetric(secondLabel, secondValue, Modifier.weight(1f))
        SummaryMetric(thirdLabel, thirdValue, Modifier.weight(1f))
    }
}

@Composable
private fun SummaryMetric(label: String, value: String, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = MaterialTheme.shapes.large,
        color = MaterialTheme.colorScheme.secondaryContainer,
        contentColor = MaterialTheme.colorScheme.onSecondaryContainer,
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(tr(value), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Black, maxLines = 1)
            Text(tr(label), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSecondaryContainer.copy(alpha = 0.76f))
        }
    }
}

@Composable
private fun DetailRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(tr(label), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(tr(value), fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun EmptyState(title: String, subtitle: String) {
    Column(
        Modifier.fillMaxSize().padding(28.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text(tr(title), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text(tr(subtitle), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
