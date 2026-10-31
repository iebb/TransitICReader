package ad.neko.cardbal.android.ui

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import ad.neko.cardbal.android.data.CardFaceChoice
import ad.neko.cardbal.android.data.CardFacePhotoImporter
import ad.neko.cardbal.android.data.RemoteCardFaces
import ad.neko.cardbal.android.data.RemoteFaceManifest
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.withFaceChoice
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CardFacePicker(card: SavedCardRecord, onSelectFace: (String?) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val faces = RemoteCardFaces.get(context)
    val importer = remember(context) { CardFacePhotoImporter(context) }
    val scope = rememberCoroutineScope()
    val selectFace by rememberUpdatedState(onSelectFace)
    val manifest by faces.manifest.collectAsState()
    var showSheet by rememberSaveable(card.id) { mutableStateOf(false) }
    var tab by rememberSaveable(card.id) { mutableIntStateOf(0) }
    var pendingCapture by rememberSaveable(card.id) { mutableStateOf<String?>(null) }
    var externalPickerActive by rememberSaveable(card.id) { mutableStateOf(false) }
    var importing by remember(card.id) { mutableStateOf(false) }
    var galleryRevision by remember(card.id) { mutableIntStateOf(0) }
    var message by remember(card.id) { mutableStateOf<String?>(null) }
    var isError by remember(card.id) { mutableStateOf(false) }
    val busy = importing || externalPickerActive
    val currentBusy by rememberUpdatedState(busy)
    val savedFaces by produceState<List<String>>(emptyList(), card.id, showSheet, galleryRevision) {
        value = withContext(Dispatchers.IO) { savedFaceFileNames(context) }
    }
    val sections = remember(manifest, card, savedFaces) {
        (manifest ?: RemoteFaceManifest(RemoteFaceManifest.SUPPORTED_SCHEMA_VERSION)).pickerSectionsFor(card, savedFaces)
    }

    fun importPhoto(load: () -> String) {
        importing = true
        message = null
        scope.launch {
            try {
                val fileName = withContext(Dispatchers.IO) { load() }
                selectFace(fileName)
                galleryRevision += 1
                showSheet = false
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                message = "Could not import this photo. Try another image."
                isError = true
            } finally {
                importing = false
            }
        }
    }

    // Keep launchers registered while the external picker/camera is in front, even
    // after recreation. Only a successful, fully saved import changes the card.
    val galleryLauncher = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        externalPickerActive = false
        if (uri != null) {
            importPhoto { importer.importUri(uri) }
        } else {
            message = "Photo selection canceled."
            isError = false
        }
    }
    val cameraLauncher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        externalPickerActive = false
        val name = pendingCapture
        pendingCapture = null
        if (name != null) {
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.cardfaces", importer.files.captureFile(name))
            context.revokeUriPermission(uri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (success && name != null) {
            importPhoto { importer.importCapture(name) }
        } else if (success) {
            message = "Could not import this photo. Try another image."
            isError = true
        } else {
            name?.let { importer.files.discardCapture(it) }
            message = "Photo capture canceled."
            isError = false
        }
    }

    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(tr("Appearance"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        OutlinedButton(
            onClick = { showSheet = true; message = null },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Filled.Palette, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(tr("Card Face"))
        }
    }
    if (!showSheet) return

    ModalBottomSheet(
        onDismissRequest = { if (!busy) showSheet = false },
        sheetState = rememberModalBottomSheetState(
            skipPartiallyExpanded = true,
            confirmValueChange = { it != SheetValue.Hidden || !currentBusy },
        ),
        sheetGesturesEnabled = !busy,
    ) {
        Column(Modifier.fillMaxWidth().heightIn(max = LocalConfiguration.current.screenHeightDp.dp * .85f)) {
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Card Face"), style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                IconButton(onClick = { showSheet = false }, enabled = !busy) {
                    Icon(Icons.Filled.Close, contentDescription = tr("Close"))
                }
            }
            PrimaryTabRow(selectedTabIndex = tab) {
                listOf("Presets", "Gallery", "Take a Photo").forEachIndexed { index, label ->
                    Tab(selected = tab == index, onClick = { tab = index; message = null }, enabled = !busy) {
                        Text(tr(label), modifier = Modifier.padding(vertical = 14.dp, horizontal = 4.dp),
                            style = MaterialTheme.typography.labelLarge)
                    }
                }
            }
            if (importing) {
                LinearProgressIndicator(Modifier.fillMaxWidth())
                Text(tr("Importing photo..."), modifier = Modifier.padding(16.dp), style = MaterialTheme.typography.bodyMedium)
            }
            message?.let {
                Text(
                    tr(it), modifier = Modifier.padding(16.dp),
                    color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
            when (tab) {
                0 -> LazyVerticalGrid(
                    columns = GridCells.Adaptive(140.dp),
                    modifier = Modifier.fillMaxWidth().weight(1f, fill = false).selectableGroup(),
                    contentPadding = PaddingValues(16.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    item(key = "color", span = { GridItemSpan(maxLineSpan) }) {
                        FilterChip(
                            selected = sections.color.selected,
                            onClick = { selectFace(null); showSheet = false },
                            enabled = !busy,
                            label = { Text(tr("Card Color")) },
                            leadingIcon = { Icon(Icons.Filled.Palette, contentDescription = null) },
                        )
                    }
                    if (sections.matching.isNotEmpty()) {
                        item(key = "matching", span = { GridItemSpan(maxLineSpan) }) {
                            Text(tr("For This Card"), style = MaterialTheme.typography.titleSmall)
                        }
                        items(sections.matching, key = { checkNotNull(it.fileName) }) { choice ->
                            CardFaceOption(card, choice, enabled = !busy, onClick = { selectFace(choice.fileName); showSheet = false })
                        }
                    }
                    if (sections.otherPresets.isNotEmpty()) {
                        item(key = "others", span = { GridItemSpan(maxLineSpan) }) {
                            Text(tr("Other Presets"), style = MaterialTheme.typography.titleSmall)
                        }
                        items(sections.otherPresets, key = { checkNotNull(it.fileName) }) { choice ->
                            CardFaceOption(card, choice, enabled = !busy, onClick = { selectFace(choice.fileName); showSheet = false })
                        }
                    }
                }
                1 -> {
                    Button(
                        onClick = {
                            message = null
                            try {
                                externalPickerActive = true
                                galleryLauncher.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                            } catch (_: Exception) {
                                externalPickerActive = false
                                message = "Photo picker is unavailable. Try again."
                                isError = true
                            }
                        },
                        enabled = !busy,
                        modifier = Modifier.fillMaxWidth().padding(16.dp),
                    ) {
                        Icon(Icons.Filled.PhotoLibrary, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(tr("Choose From Gallery"))
                    }
                    if (sections.photos.isEmpty()) {
                        Text(
                            tr("Your saved card photos will appear here."),
                            modifier = Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        LazyVerticalGrid(
                            columns = GridCells.Adaptive(140.dp),
                            modifier = Modifier.fillMaxWidth().weight(1f, fill = false).selectableGroup(),
                            contentPadding = PaddingValues(16.dp),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                            verticalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            items(sections.photos, key = { checkNotNull(it.fileName) }) { choice ->
                                CardFaceOption(card, choice, enabled = !busy, onClick = { selectFace(choice.fileName); showSheet = false })
                            }
                        }
                    }
                }
                2 -> Column(
                    Modifier.fillMaxWidth().weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Text(tr("Take a photo of your card to use as its face."), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Button(
                        onClick = {
                            message = null
                            try {
                                val file = importer.files.createCapture()
                                pendingCapture = file.name
                                val uri = FileProvider.getUriForFile(context, "${context.packageName}.cardfaces", file)
                                externalPickerActive = true
                                cameraLauncher.launch(uri)
                            } catch (_: Exception) {
                                externalPickerActive = false
                                pendingCapture?.let { importer.files.discardCapture(it) }
                                pendingCapture = null
                                message = "Camera is unavailable. Try choosing a photo from Gallery."
                                isError = true
                            }
                        },
                        enabled = !busy, modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Filled.CameraAlt, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(tr("Take a Photo"))
                    }
                }
            }
        }
    }
}

@Composable
private fun CardFaceOption(card: SavedCardRecord, choice: CardFaceChoice, enabled: Boolean, onClick: () -> Unit) {
    val context = LocalContext.current
    val language = LocalConfiguration.current.locales[0].language
    val preview = remember(card, choice.fileName) { card.withFaceChoice(choice.fileName) }
    val remoteImage = rememberRemoteFace(preview)
    val importedImage by produceState<ImageBitmap?>(null, choice.fileName) {
        value = withContext(Dispatchers.IO) { importedFaceImageFor(context, choice.fileName, maxDimension = 400) }
    }
    val bitmap = importedImage ?: remoteImage
    val drawable = offlineDrawableFor(preview)
    val color = Color(card.color.red.toFloat(), card.color.green.toFloat(), card.color.blue.toFloat())
    val label = when {
        choice.fileName == null -> tr("Color")
        choice.entry != null -> {
            val entry = choice.entry
            entry.design.name.localizedName(language)
                ?: entry.card.name.localizedName(language)
                ?: entry.card.id
        }
        RemoteFaceManifest.publishedToken(choice.fileName) != null -> tr("Image")
        else -> tr("Photo")
    }
    Surface(
        modifier = Modifier.fillMaxWidth().selectable(choice.selected, enabled = enabled, role = Role.RadioButton, onClick = onClick),
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(
            if (choice.selected) 2.dp else 1.dp,
            if (choice.selected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outlineVariant,
        ),
    ) {
        Column(Modifier.padding(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.fillMaxWidth().aspectRatio(27f / 17f).background(color)) {
                if (bitmap != null) {
                    Image(bitmap, contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                } else if (drawable != null) {
                    Image(painterResource(drawable), contentDescription = null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                } else if (choice.fileName != null) {
                    Icon(
                        Icons.Filled.CreditCard,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.align(Alignment.Center),
                    )
                }
                if (choice.selected) {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.align(Alignment.TopEnd).padding(3.dp).size(20.dp)
                            .background(MaterialTheme.colorScheme.surface, RoundedCornerShape(10.dp)),
                    )
                }
            }
            Text(label, style = MaterialTheme.typography.labelMedium, minLines = 2, maxLines = 2, overflow = TextOverflow.Ellipsis)
            choice.entry?.card?.name.localizedName(language)?.let { name ->
                if (name != label) Text(name, style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

private fun Map<String, String>?.localizedName(language: String): String? =
    this?.get(language)?.takeIf { it.isNotBlank() }
        ?: this?.get("en")?.takeIf { it.isNotBlank() }
        ?: this?.values?.firstOrNull { it.isNotBlank() }
