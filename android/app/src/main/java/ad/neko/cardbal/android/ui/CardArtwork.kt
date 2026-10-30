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

fun presetDrawableFor(family: String): Int? {
    val f = family.lowercase()
    return when {
        // Published faces are drawn by rememberRemoteFace.
        RemoteFaceManifest.isToken(family) -> null
        "suica" in f -> R.drawable.suica
        "pasmo" in f -> R.drawable.pasmo
        "icoca" in f -> R.drawable.icoca
        "hayakaken" in f -> R.drawable.hayakaken
        "sugoca" in f -> R.drawable.sugoca
        "manaca" in f -> R.drawable.manaca
        "kitaca" in f -> R.drawable.kitaca
        "nimoca" in f -> R.drawable.nimoca
        "toica" in f -> R.drawable.toica
        "t-money" in f || "tmoney" in f -> R.drawable.tmoney
        // EZ-Link (Singapore) is published remotely; keep it off Korea's EZL face.
        "ezlink" in f || "ez-link" in f -> null
        "ezl" in f || "cashbee" in f -> R.drawable.ezl
        "edy" in f -> R.drawable.edy
        "waon" in f -> R.drawable.waon
        "nanaco" in f -> R.drawable.nanaco
        "climate" in f -> R.drawable.climate_card
        else -> null
    }
}

fun importedFaceImageFor(context: Context, fileName: String?): ImageBitmap? {
    if (fileName.isNullOrBlank()) return null
    val cleanName = fileName.substringAfterLast('/').substringAfterLast('\\')
    val file = File(File(context.filesDir, "CardFaces"), cleanName)
    if (!file.isFile) return null
    return BitmapFactory.decodeFile(file.absolutePath)?.asImageBitmap()
}

/** The published face for [card], downloaded on first use; null until it arrives. */
@Composable
fun rememberRemoteFace(card: SavedCardRecord): ImageBitmap? {
    val faces = RemoteCardFaces.get(LocalContext.current)
    val manifest by faces.manifest.collectAsState()
    val token = remember(manifest, card) { manifest?.faceTokenFor(card) }
    val sha256 = token?.let { manifest?.entry(it)?.design?.sha256 }
    val face by produceState<ImageBitmap?>(null, token, sha256) {
        value = token?.let { faces.face(it)?.asImageBitmap() }
    }
    return face
}
