package ad.neko.cardbal.android.data

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.Base64
import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CardFacePhotoFilesTest {
    @get:Rule val temporary = TemporaryFolder()
    private val filesDir by lazy { temporary.newFolder("files") }
    private val cacheDir by lazy { temporary.newFolder("cache") }
    private val photos by lazy { CardFacePhotoFiles(filesDir, cacheDir) }

    @Test fun importPublishesOnlyCompletePhotosAndKeepsExistingImportedFaces() {
        val faces = File(filesDir, "CardFaces").apply { mkdirs() }
        File(faces, "from-ios.png").writeBytes(byteArrayOf(1, 2))
        var closed = false
        val input = object : ByteArrayInputStream(byteArrayOf(3, 4)) {
            override fun close() { closed = true; super.close() }
        }
        val name = photos.importPhoto(input) { source, output ->
            assertTrue(closed)
            assertEquals(listOf("from-ios.png"), photos.savedNames())
            assertArrayEquals(byteArrayOf(3, 4), source.readBytes())
            output.write(byteArrayOf(5, 6))
        }
        assertTrue(name.startsWith("photo-") && name.endsWith(".jpg"))
        assertArrayEquals(byteArrayOf(5, 6), File(faces, name).readBytes())
        assertArrayEquals(byteArrayOf(1, 2), File(faces, "from-ios.png").readBytes())
        assertEquals(setOf("from-ios.png", name), photos.savedNames().toSet())
        assertTrue(File(cacheDir, "card-face-import").listFiles().orEmpty().isEmpty())
    }

    @Test fun failedEncodingDiscardsPartialFilesWithoutReplacingSavedPhotos() {
        val name = photos.importPhoto(byteArrayOf(1).inputStream()) { _, output -> output.write(7) }
        assertThrows(IOException::class.java) {
            photos.importPhoto(byteArrayOf(2).inputStream()) { _, output ->
                output.write(9)
                throw IOException("Interrupted encoding")
            }
        }
        assertEquals(listOf(name), photos.savedNames())
        assertArrayEquals(byteArrayOf(7), File(File(filesDir, "CardFaces"), name).readBytes())
        assertEquals(1, File(filesDir, "CardFaces").listFiles()!!.size)
        assertTrue(File(cacheDir, "card-face-import").listFiles().orEmpty().isEmpty())
    }

    @Test fun oversizedEmptyAndUnencodableSourcesDoNotBecomeSavedFaces() {
        val tooLarge = object : InputStream() {
            private var remaining = CardFacePhotoFiles.MAX_SOURCE_BYTES + 1
            override fun read(): Int = if (remaining-- > 0) 1 else -1
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (remaining <= 0) return -1
                val count = minOf(remaining, length.toLong()).toInt()
                remaining -= count
                return count
            }
        }
        assertThrows(IllegalArgumentException::class.java) { photos.importPhoto(tooLarge) { _, _ -> error("Must not encode") } }
        assertThrows(IllegalArgumentException::class.java) {
            photos.importPhoto(byteArrayOf().inputStream()) { _, _ -> error("Must not encode") }
        }
        assertThrows(IllegalStateException::class.java) { photos.importPhoto(byteArrayOf(1).inputStream()) { _, _ -> } }
        assertTrue(photos.savedNames().isEmpty())
        assertTrue(File(cacheDir, "card-face-import").listFiles().orEmpty().isEmpty())
        assertTrue(File(filesDir, "CardFaces").listFiles().orEmpty().isEmpty())
    }

    @Test fun captureIsPrivateTemporaryAndCanBeRecoveredThenCanceled() {
        val capture = photos.createCapture()
        capture.writeBytes(byteArrayOf(1))
        assertEquals(File(cacheDir, "card-face-capture").canonicalFile, checkNotNull(capture.parentFile).canonicalFile)
        assertTrue(photos.savedNames().isEmpty())
        val recreated = CardFacePhotoFiles(filesDir, cacheDir)
        assertEquals(capture, recreated.captureFile(capture.name))
        recreated.discardCapture(capture.name)
        recreated.discardCapture(capture.name)
        assertFalse(capture.exists())
        assertThrows(IllegalArgumentException::class.java) { photos.captureFile("../cards.sqlite") }
        assertThrows(IllegalArgumentException::class.java) { photos.captureFile(capture.absolutePath) }
    }

    @Test fun savedPhotoAndColorChoiceRoundTripThroughExistingBackupSchema() {
        val name = photos.importPhoto(byteArrayOf(1).inputStream()) { _, output -> output.write(byteArrayOf(2, 3)) }
        val card = SavedCardRecord(
            id = "test", cardFamily = "Suica", technology = "FeliCa", identifierLabel = "IDm",
            rawIdentifierValue = "01020304", identifierValue = "01020304",
            scannedAt = Instant.fromEpochSeconds(0), color = SavedCardColor.Black,
        ).withFaceChoice(name).withFaceChoice(null)
        val backup = CardBackupData(
            cards = listOf(card), faceAssets = mapOf(
                name to Base64.getEncoder().encodeToString(File(File(filesDir, "CardFaces"), name).readBytes()),
            ),
        )
        val reopened = RemoteFaceManifest.json.decodeFromString<CardBackupData>(RemoteFaceManifest.json.encodeToString(backup))
        assertEquals(name, reopened.cards.single().faceImageFileName)
        assertEquals(false, reopened.cards.single().isUsingImage)
        assertArrayEquals(byteArrayOf(2, 3), Base64.getDecoder().decode(reopened.faceAssets.getValue(name)))
        assertEquals(card.withFaceChoice(name), reopened.cards.single().withFaceChoice(name))
    }

    @Test fun thumbnailsAndLargePhotosAreSampledBeforeDecoding() {
        assertEquals(1, photoSampleSize(320, 200, 400))
        assertEquals(4, photoSampleSize(1600, 1000, 400))
        assertEquals(4, photoSampleSize(6000, 4000, 1600))
        assertEquals(64, photoSampleSize(1, 20000, 400))
        assertThrows(IllegalArgumentException::class.java) { photoSampleSize(0, 1, 400) }
    }
}
