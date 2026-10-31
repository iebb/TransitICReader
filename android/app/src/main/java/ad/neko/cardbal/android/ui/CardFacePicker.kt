package ad.neko.cardbal.android.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.CreditCard
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
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
import ad.neko.cardbal.android.data.CardFaceChoice
import ad.neko.cardbal.android.data.RemoteCardFaces
import ad.neko.cardbal.android.data.RemoteFaceManifest
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.withFaceChoice
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun CardFacePicker(card: SavedCardRecord, onSelectFace: (String?) -> Unit, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val faces = RemoteCardFaces.get(context)
    val manifest by faces.manifest.collectAsState()
    val savedFaces by produceState<List<String>>(emptyList(), card.id) {
        value = withContext(Dispatchers.IO) { savedFaceFileNames(context) }
    }
    val choices = remember(manifest, card, savedFaces) {
        (manifest ?: RemoteFaceManifest(RemoteFaceManifest.SUPPORTED_SCHEMA_VERSION)).pickerChoicesFor(card, savedFaces)
    }
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(tr("Appearance"), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        LazyRow(
            modifier = Modifier.fillMaxWidth().selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(choices, key = { it.fileName ?: "color" }) { choice ->
                CardFaceOption(card, choice, onClick = { onSelectFace(choice.fileName) })
            }
        }
    }
}

@Composable
private fun CardFaceOption(card: SavedCardRecord, choice: CardFaceChoice, onClick: () -> Unit) {
    val context = LocalContext.current
    val language = LocalConfiguration.current.locales[0].language
    val preview = remember(card, choice.fileName) { card.withFaceChoice(choice.fileName) }
    val remoteImage = rememberRemoteFace(preview)
    val importedImage by produceState<ImageBitmap?>(null, choice.fileName) {
        value = withContext(Dispatchers.IO) { importedFaceImageFor(context, choice.fileName) }
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
        modifier = Modifier.width(112.dp).selectable(choice.selected, role = Role.RadioButton, onClick = onClick),
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
        }
    }
}

private fun Map<String, String>?.localizedName(language: String): String? =
    this?.get(language)?.takeIf { it.isNotBlank() }
        ?: this?.get("en")?.takeIf { it.isNotBlank() }
        ?: this?.values?.firstOrNull { it.isNotBlank() }
