package ad.neko.cardbal.android.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import ad.neko.cardbal.android.data.CardFacePhotoFiles
import ad.neko.cardbal.android.data.SavedCardRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The iOS Face Library: imported card photos, with unused ones removable. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CardFaceLibraryScreen(cards: List<SavedCardRecord>, onBack: () -> Unit, modifier: Modifier = Modifier) {
    BackHandler(onBack = onBack)
    val context = LocalContext.current
    val files = remember(context) { CardFacePhotoFiles(context.filesDir, context.cacheDir) }
    var names by remember { mutableStateOf(files.libraryNames()) }
    val usedNames = cards.map { it.faceImageFileName }
    Column(modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text(tr("Face Library")) },
            navigationIcon = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = tr("Back"))
                }
            },
        )
        if (names.isEmpty()) {
            Column(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.spacedBy(20.dp, Alignment.CenterVertically),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    Icons.Filled.PhotoLibrary,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(64.dp),
                )
                Text(tr("No Face Assets"), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            }
            return@Column
        }
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 8.dp)) {
            items(names, key = { it }) { name ->
                val inUse = CardFacePhotoFiles.isInUse(name, usedNames)
                Row(
                    Modifier.fillMaxWidth().heightIn(min = 66.dp).padding(vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    FaceThumbnail(name)
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(name, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        if (inUse) {
                            Text(
                                tr("In Use"),
                                style = MaterialTheme.typography.labelSmall,
                                modifier = Modifier
                                    .clip(RoundedCornerShape(4.dp))
                                    .background(Color(0xFF34C759).copy(alpha = 0.12f))
                                    .padding(4.dp),
                            )
                        }
                    }
                    if (!inUse) {
                        IconButton(onClick = {
                            files.deleteSaved(name)
                            names = files.libraryNames()
                        }) {
                            Icon(Icons.Filled.Delete, contentDescription = tr("Delete"), tint = MaterialTheme.colorScheme.error)
                        }
                    }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            }
        }
    }
}

@Composable
private fun FaceThumbnail(name: String) {
    val context = LocalContext.current
    val image by produceState<ImageBitmap?>(null, name) {
        value = withContext(Dispatchers.IO) { importedFaceImageFor(context, name, maxDimension = 240) }
    }
    Box(Modifier.size(80.dp, 50.dp).clip(RoundedCornerShape(8.dp)), contentAlignment = Alignment.Center) {
        image?.let { Image(it, contentDescription = null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()) }
    }
}
