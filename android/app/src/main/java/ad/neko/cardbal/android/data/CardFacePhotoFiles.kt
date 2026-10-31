package ad.neko.cardbal.android.data

import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID

/** Publishes complete photos under the existing, backed-up CardFaces directory. */
class CardFacePhotoFiles(private val filesDir: File, private val cacheDir: File) {
    private val faces = File(filesDir, "CardFaces")
    private val captures = File(cacheDir, "card-face-capture")

    fun createCapture(): File {
        ensureDirectory(captures)
        return File(captures, "capture-${UUID.randomUUID()}.jpg").also {
            check(it.createNewFile()) { "Could not create camera output" }
        }
    }

    fun captureFile(name: String): File {
        require(Regex("capture-[0-9a-f-]{36}\\.jpg").matches(name)) { "Invalid capture name" }
        return File(captures, name)
    }

    fun discardCapture(name: String) {
        captureFile(name).delete()
    }

    fun savedNames(): List<String> =
        faces.listFiles().orEmpty().filter { it.isFile && !it.name.startsWith(".") }
            .map { it.name }.sorted()

    /**
     * Stage a bounded source, normalize it, then atomically publish it. An interrupted
     * import leaves neither a selectable partial photo nor a changed card selection.
     */
    fun importPhoto(input: InputStream, encode: (File, OutputStream) -> Unit): String {
        val staging = File(cacheDir, "card-face-import")
        var source: File? = null
        var pending: File? = null
        try {
            input.use {
                ensureDirectory(staging)
                val stagedSource = File.createTempFile("source-", ".tmp", staging)
                source = stagedSource
                stagedSource.outputStream().use { output ->
                    val buffer = ByteArray(8192)
                    var total = 0L
                    while (true) {
                        val count = it.read(buffer)
                        if (count < 0) break
                        total += count
                        require(total <= MAX_SOURCE_BYTES) { "Photo is too large" }
                        output.write(buffer, 0, count)
                    }
                    require(total > 0) { "Photo is empty" }
                }
            }
            ensureDirectory(faces)
            val name = "photo-${UUID.randomUUID()}.jpg"
            pending = File(faces, ".$name.tmp")
            pending.outputStream().use { encode(checkNotNull(source), it) }
            check(pending.length() > 0) { "Photo could not be encoded" }
            if (!pending.renameTo(File(faces, name))) throw IOException("Could not save photo")
            return name
        } finally {
            source?.delete()
            pending?.delete()
        }
    }

    private fun ensureDirectory(directory: File) {
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Could not create photo directory")
    }

    companion object {
        const val MAX_SOURCE_BYTES = 32L * 1024 * 1024
    }
}
