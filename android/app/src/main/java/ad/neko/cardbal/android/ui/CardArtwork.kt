package ad.neko.cardbal.android.ui

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import ad.neko.cardbal.android.R
import ad.neko.cardbal.android.data.RemoteCardFaces
import ad.neko.cardbal.android.data.RemoteFaceManifest
import ad.neko.cardbal.android.data.SavedCardRecord
import java.io.File

fun offlineDrawableFor(card: SavedCardRecord): Int? =
    when (RemoteFaceManifest.offlineAssetFor(card)) {
        "suica" -> R.drawable.suica
        "pasmo" -> R.drawable.pasmo
        "icoca" -> R.drawable.icoca
        "tmoney" -> R.drawable.tmoney
        "ezl" -> R.drawable.ezl
        else -> null
    }

fun importedFaceImageFor(context: Context, fileName: String?): ImageBitmap? {
    if (fileName.isNullOrBlank()) return null
    val cleanName = fileName.substringAfterLast('/').substringAfterLast('\\')
    val file = File(File(context.filesDir, "CardFaces"), cleanName)
    if (!file.isFile) return null
    return BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap()
}

fun savedFaceFileNames(context: Context): List<String> =
    File(context.filesDir, "CardFaces").listFiles().orEmpty()
        .filter { it.isFile }.map { it.name }.sorted()

/** The published face for [card], downloaded on first use; null until it arrives. */
@Composable
fun rememberRemoteFace(card: SavedCardRecord): ImageBitmap? {
    val faces = RemoteCardFaces.get(LocalContext.current)
    val manifest by faces.manifest.collectAsState()
    val token = remember(manifest, card) { faces.faceTokenFor(card) }
    val sha256 = token?.let { manifest?.entry(it)?.design?.sha256 }
    val face by produceState<ImageBitmap?>(null, token, sha256) {
        value = null
        value = token?.let { faces.face(it)?.asImageBitmap() }
    }
    return face
}
