package ad.neko.cardbal.android.ui

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import ad.neko.cardbal.android.R
import java.io.File

fun presetDrawableFor(family: String): Int? {
    val f = family.lowercase()
    return when {
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
