package ad.neko.cardbal.android.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import java.io.File
import java.io.IOException
import java.io.OutputStream

class CardFacePhotoImporter(context: Context) {
    private val context = context.applicationContext
    val files = CardFacePhotoFiles(this.context.filesDir, this.context.cacheDir)

    fun importUri(uri: Uri): String {
        val input = context.contentResolver.openInputStream(uri) ?: throw IOException("Photo is unavailable")
        return files.importPhoto(input, ::encodePhoto)
    }

    fun importCapture(name: String): String = try {
        files.importPhoto(files.captureFile(name).inputStream(), ::encodePhoto)
    } finally {
        files.discardCapture(name)
    }

    private fun encodePhoto(source: File, output: OutputStream) {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(source.absolutePath, bounds)
        require(bounds.outWidth > 0 && bounds.outHeight > 0) { "Photo is not a supported image" }
        val options = BitmapFactory.Options().apply {
            inSampleSize = photoSampleSize(bounds.outWidth, bounds.outHeight, MAX_DIMENSION)
        }
        val bitmap = BitmapFactory.decodeFile(source.absolutePath, options)
            ?: throw IOException("Photo could not be decoded")
        var oriented = bitmap
        var resized = bitmap
        try {
            val orientation = runCatching {
                ExifInterface(source.absolutePath).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }.getOrDefault(ExifInterface.ORIENTATION_NORMAL)
            val matrix = Matrix().apply {
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> setScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                }
            }
            oriented = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
            val scale = (MAX_DIMENSION.toFloat() / maxOf(oriented.width, oriented.height)).coerceAtMost(1f)
            resized = if (scale < 1f) Bitmap.createScaledBitmap(
                oriented, (oriented.width * scale).toInt().coerceAtLeast(1),
                (oriented.height * scale).toInt().coerceAtLeast(1), true,
            ) else oriented
            if (!resized.compress(Bitmap.CompressFormat.JPEG, 90, output)) throw IOException("Photo could not be encoded")
        } finally {
            if (resized !== oriented && resized !== bitmap) resized.recycle()
            if (oriented !== bitmap) oriented.recycle()
            bitmap.recycle()
        }
    }

    companion object {
        const val MAX_DIMENSION = 1600
    }
}

/** Downsample before allocation, including unusually wide/tall imported backup photos. */
internal fun photoSampleSize(width: Int, height: Int, maxDimension: Int): Int {
    require(width > 0 && height > 0 && maxDimension > 0)
    var sample = 1
    while (maxOf(width, height) / sample > maxDimension) sample *= 2
    return sample
}
