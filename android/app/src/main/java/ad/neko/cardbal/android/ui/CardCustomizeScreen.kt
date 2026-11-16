package ad.neko.cardbal.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Block
import androidx.compose.material.icons.filled.Colorize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import ad.neko.cardbal.android.data.ImageFaceEnhancer
import ad.neko.cardbal.android.data.SavedCardColor
import ad.neko.cardbal.android.data.SavedCardDesign
import ad.neko.cardbal.android.data.SavedCardMarkerShape
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.withFaceChoice
import java.io.File
import kotlin.math.abs
import kotlinx.coroutines.delay

private val cardSwatches = listOf(
    "Green" to SavedCardColor(0.13, 0.64, 0.36),
    "Blue" to SavedCardColor(0.23, 0.45, 0.94),
    "Red" to SavedCardColor(0.90, 0.25, 0.18),
    "Purple" to SavedCardColor(0.63, 0.40, 0.91),
    "Cyan" to SavedCardColor(0.10, 0.66, 0.87),
    "Orange" to SavedCardColor(0.96, 0.57, 0.12),
    "Graphite" to SavedCardColor(0.23, 0.24, 0.27),
)

private val markerSwatches = listOf("Black" to SavedCardColor.Black, "White" to SavedCardColor.White) + cardSwatches

/** Whether the card shows a design or photo, which switches the options to the iOS Photo section. */
@Composable
private fun showsImageFace(card: SavedCardRecord): Boolean {
    val context = LocalContext.current
    val imported = remember(card.faceImageFileName, card.finalIsUsingImage) {
        val name = card.faceImageFileName?.substringAfterLast('/')?.substringAfterLast('\\')
        card.finalIsUsingImage && !name.isNullOrBlank() && File(File(context.filesDir, "CardFaces"), name).isFile
    }
    val remote = rememberRemoteFace(card)
    return imported || remote != null || offlineDrawableFor(card) != null
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CardCustomizeScreen(
    card: SavedCardRecord,
    onBack: () -> Unit,
    onCustomize: ((SavedCardRecord) -> SavedCardRecord) -> Unit,
    modifier: Modifier = Modifier,
) {
    var editingIcon by rememberSaveable(card.id) { mutableStateOf(false) }
    if (editingIcon) {
        CardIconScreen(card = card, onBack = { editingIcon = false }, onCustomize = onCustomize, modifier = modifier)
        return
    }
    BackHandler(onBack = onBack)
    val isPhotoFace = showsImageFace(card)
    Column(modifier) {
        TopAppBar(
            title = { Text(tr("Customize Card")) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = tr("Back"))
                }
            },
        )
        // The preview stays in place while the options scroll, as on iOS.
        Box(Modifier.fillMaxWidth().padding(top = 4.dp, bottom = 12.dp), contentAlignment = Alignment.Center) {
            WalletCard(card, Modifier.widthIn(max = 300.dp))
        }
        LazyColumn(
            modifier = Modifier.fillMaxWidth().weight(1f),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 24.dp),
        ) {
            item {
                CustomizeSection("Card Face", footer = "Choose a preset, a photo from your gallery, or take a photo.") {
                    CardFacePicker(
                        card = card,
                        onSelectFace = { fileName -> onCustomize { it.withFaceChoice(fileName) } },
                        showsHeader = false,
                    )
                }
            }
            if (isPhotoFace) {
                item {
                    CustomizeSection(
                        "Photo",
                        footer = "Frosted Header blurs the top of the design so the name and balance stay clear of its logos.",
                    ) {
                        SwitchRow("Frosted Header", card.finalFrostedHeader) { on -> onCustomize { it.copy(frostedHeader = on) } }
                        Text(tr("Text Contrast"))
                        ChoiceRow(
                            options = listOf(ImageFaceEnhancer.mask to "Shade", ImageFaceEnhancer.border to "Shadow", ImageFaceEnhancer.none to "None"),
                            selected = card.imageFaceEnhancer,
                            onSelect = { enhancer -> onCustomize { it.copy(imageFaceEnhancer = enhancer) } },
                        )
                        SwitchRow("Show Name", !card.finalHideTitle) { on -> onCustomize { it.copy(hideTitleOnImage = !on) } }
                    }
                }
            } else {
                item {
                    CustomizeSection("Color") {
                        ColorSwatchRow(cardSwatches, card.color) { color -> onCustomize { it.copy(color = color) } }
                    }
                }
                item {
                    CustomizeSection("Style") {
                        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            SavedCardDesign.entries.forEach { design ->
                                StyleTile(card, design, selected = card.design == design) {
                                    onCustomize { it.copy(design = design) }
                                }
                            }
                        }
                    }
                }
            }
            item {
                CustomizeSection("Text on Card", footer = "Leave the name empty to use the card's own name.") {
                    CommittedTextField(
                        label = "Name",
                        key = card.id,
                        value = card.customTitle.orEmpty(),
                        placeholder = cardTitle(card.copy(customTitle = null)),
                    ) { text -> onCustomize { it.copy(customTitle = text.trim().ifEmpty { null }) } }
                    CommittedTextField(
                        label = "Card Number",
                        key = card.id,
                        value = card.customDisplaySerialNumber ?: card.realSerialNumber ?: card.identifierValue,
                        keyboardType = KeyboardType.Ascii,
                    ) { text -> onCustomize { it.copy(customDisplaySerialNumber = text.trim().ifEmpty { null }) } }
                    SwitchRow("Show Card Number", !card.finalHideSerialNumber) { on -> onCustomize { it.copy(hideSerialNumber = !on) } }
                }
            }
            item {
                CustomizeSection(null, footer = "Shown next to the card name and on the ride map.") {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable(role = Role.Button) { editingIcon = true }
                            .heightIn(min = 44.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(tr("Card Icon"), modifier = Modifier.weight(1f))
                        MarkerBadge(card, showsDefault = false)
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun CardIconScreen(
    card: SavedCardRecord,
    onBack: () -> Unit,
    onCustomize: ((SavedCardRecord) -> SavedCardRecord) -> Unit,
    modifier: Modifier = Modifier,
) {
    BackHandler(onBack = onBack)
    val shape: Shape = if (card.markerShape == SavedCardMarkerShape.square) RoundedCornerShape(11.dp) else CircleShape
    val candidates = markerSymbols.map { it.first } + ('A'..'Z').map { "txt:$it" } + ('0'..'9').map { "txt:$it" }
    val noneLabel = tr("None")
    Column(modifier) {
        TopAppBar(
            title = { Text(tr("Card Icon")) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = tr("Back"))
                }
            },
        )
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(start = 20.dp, end = 20.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            CustomizeSection("Shape") {
                ChoiceRow(
                    options = listOf(SavedCardMarkerShape.circle to "Circle", SavedCardMarkerShape.square to "Square"),
                    selected = card.markerShape,
                    onSelect = { markerShape -> onCustomize { it.copy(markerShape = markerShape) } },
                )
            }
            CustomizeSection("Colors") {
                Text(tr("Shape Color"))
                ColorSwatchRow(markerSwatches, card.markerColor) { color -> onCustomize { it.copy(markerColor = color) } }
                Text(tr("Symbol Color"))
                ColorSwatchRow(markerSwatches, card.markerOuterColor) { color -> onCustomize { it.copy(markerOuterColor = color) } }
            }
            CustomizeSection("Icon Symbol") {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(
                        Modifier
                            .size(44.dp)
                            .clip(shape)
                            .border(1.dp, MaterialTheme.colorScheme.outline, shape)
                            .clickable(role = Role.Button) { onCustomize { it.copy(markerSymbolName = null) } }
                            .semantics {
                                contentDescription = noneLabel
                                selected = card.markerSymbolName == null
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Filled.Block, contentDescription = null, tint = MaterialTheme.colorScheme.outline)
                    }
                    candidates.forEach { symbol ->
                        val isSelected = symbol == card.markerSymbolName
                        val fill = if (isSelected) card.markerColor.toColor() else MaterialTheme.colorScheme.surfaceVariant
                        val tint = if (isSelected) card.markerOuterColor.toColor() else MaterialTheme.colorScheme.onSurfaceVariant
                        Box(
                            Modifier
                                .size(44.dp)
                                .background(fill, shape)
                                .clip(shape)
                                .clickable(role = Role.Button) { onCustomize { it.copy(markerSymbolName = symbol) } }
                                .semantics {
                                    contentDescription = symbol.substringAfter(':')
                                    selected = isSelected
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            if (symbol.startsWith("txt:")) {
                                Text(symbol.removePrefix("txt:"), color = tint, fontWeight = FontWeight.Bold, style = MaterialTheme.typography.titleMedium)
                            } else {
                                Icon(markerIcon(symbol), contentDescription = null, tint = tint)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun CustomizeSection(header: String?, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
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
        footer?.let {
            Text(tr(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onCheckedChange: (Boolean) -> Unit) {
    val description = tr(label)
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(description, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange, modifier = Modifier.semantics { contentDescription = description })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun <T> ChoiceRow(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
        options.forEachIndexed { index, (value, label) ->
            SegmentedButton(
                selected = value == selected,
                onClick = { onSelect(value) },
                shape = SegmentedButtonDefaults.itemShape(index = index, count = options.size),
                label = { Text(tr(label)) },
            )
        }
    }
}

private fun SavedCardColor.matches(other: SavedCardColor) =
    abs(red - other.red) < 0.02 && abs(green - other.green) < 0.02 && abs(blue - other.blue) < 0.02

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ColorSwatchRow(swatches: List<Pair<String, SavedCardColor>>, selected: SavedCardColor, onSelect: (SavedCardColor) -> Unit) {
    var customizing by remember { mutableStateOf(false) }
    val isCustom = swatches.none { it.second.matches(selected) }
    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        swatches.forEach { (name, color) ->
            SwatchCircle(selected = color.matches(selected), label = name, onClick = { onSelect(color) }) {
                Box(Modifier.size(28.dp).background(color.toColor(), CircleShape).border(0.5.dp, Color.Gray.copy(alpha = 0.4f), CircleShape))
            }
        }
        SwatchCircle(selected = isCustom, label = "Custom Color", onClick = { customizing = true }) {
            Box(Modifier.size(28.dp).background(selected.toColor(), CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Colorize, contentDescription = null, tint = Color.White, modifier = Modifier.size(16.dp))
            }
        }
    }
    if (customizing) {
        CustomColorDialog(initial = selected, onDismiss = { customizing = false }) {
            onSelect(it)
            customizing = false
        }
    }
}

@Composable
private fun SwatchCircle(selected: Boolean, label: String, onClick: () -> Unit, content: @Composable () -> Unit) {
    val description = tr(label)
    Box(
        Modifier
            .size(40.dp)
            .border(BorderStroke(2.dp, if (selected) MaterialTheme.colorScheme.onSurface else Color.Transparent), CircleShape)
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics {
                contentDescription = description
                this.selected = selected
            },
        contentAlignment = Alignment.Center,
    ) {
        content()
    }
}

@Composable
private fun CustomColorDialog(initial: SavedCardColor, onDismiss: () -> Unit, onConfirm: (SavedCardColor) -> Unit) {
    var red by remember { mutableStateOf(initial.red.toFloat()) }
    var green by remember { mutableStateOf(initial.green.toFloat()) }
    var blue by remember { mutableStateOf(initial.blue.toFloat()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(tr("Custom Color")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.fillMaxWidth().aspectRatio(5f).background(Color(red, green, blue), RoundedCornerShape(8.dp)))
                listOf<Triple<String, Float, (Float) -> Unit>>(
                    Triple("R", red) { red = it },
                    Triple("G", green) { green = it },
                    Triple("B", blue) { blue = it },
                ).forEach { (label, value, update) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(label, modifier = Modifier.width(20.dp))
                        Slider(value = value, onValueChange = update, modifier = Modifier.weight(1f))
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(SavedCardColor(red.toDouble(), green.toDouble(), blue.toDouble())) }) { Text(tr("Done")) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr("Cancel")) } },
    )
}

@Composable
private fun StyleTile(card: SavedCardRecord, design: SavedCardDesign, selected: Boolean, onClick: () -> Unit) {
    val title = tr(design.name.replaceFirstChar(Char::uppercase))
    Column(
        Modifier
            .width(98.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { this.selected = selected },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(
            Modifier
                .border(2.5.dp, if (selected) MaterialTheme.colorScheme.primary else Color.Transparent, RoundedCornerShape(11.dp))
                .padding(3.dp),
        ) {
            Box(
                Modifier
                    .width(92.dp)
                    .aspectRatio(27f / 17f)
                    .clip(RoundedCornerShape(8.dp))
                    .background(cardBrush(card, card.color.toColor(), design)),
            )
        }
        Text(
            title,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

/** Saves typing after a short pause, like iOS, and flushes any pending text when the screen closes. */
@Composable
private fun CommittedTextField(
    label: String,
    key: String,
    value: String,
    placeholder: String? = null,
    keyboardType: KeyboardType = KeyboardType.Text,
    onCommit: (String) -> Unit,
) {
    var draft by rememberSaveable(key) { mutableStateOf(value) }
    val latestDraft by rememberUpdatedState(draft)
    val latestValue by rememberUpdatedState(value)
    val commit by rememberUpdatedState(onCommit)
    LaunchedEffect(draft) {
        if (draft == value) return@LaunchedEffect
        delay(400)
        commit(draft)
    }
    DisposableEffect(key) {
        onDispose { if (latestDraft != latestValue) commit(latestDraft) }
    }
    OutlinedTextField(
        value = draft,
        onValueChange = { draft = it },
        label = { Text(tr(label)) },
        placeholder = placeholder?.let { { Text(it) } },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType),
        modifier = Modifier.fillMaxWidth(),
    )
}
