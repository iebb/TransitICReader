package ad.neko.cardbal.android.data

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class CardBackupCompatibilityTest {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    @Test
    fun decodesIosSqliteBackupWithAppleReferenceDate() {
        val backup = json.decodeFromString<CardBackupData>(
            """
            {
              "version": 1,
              "cards": [
                {
                  "id": "FeliCa|01020304",
                  "cardFamily": "Japan Transit IC",
                  "markerColor": {"red": 0.0, "green": 0.0, "blue": 0.0},
                  "markerOuterColor": {"red": 1.0, "green": 1.0, "blue": 1.0},
                  "markerShape": "circle",
                  "imageFaceEnhancer": "mask",
                  "autoImageTextColors": true,
                  "technology": "FeliCa",
                  "identifierLabel": "IDm",
                  "rawIdentifierValue": "01020304",
                  "identifierValue": "01020304",
                  "rawTransactions": [],
                  "rawTransitHistory": [],
                  "resultFields": [],
                  "scannedAt": 795943233.394678,
                  "color": {"red": 0.1, "green": 0.58, "blue": 0.12},
                  "design": "classic",
                  "faceImageFileName": "suica.jpg",
                  "order": 0
                }
              ],
              "faceAssets": {
                "suica.jpg": "/9j/4AAQSkZJRg=="
              }
            }
            """.trimIndent(),
        )

        assertEquals(1, backup.cards.size)
        assertEquals("2026-03-23T07:20:33.395Z", backup.cards.first().scannedAt.toString())
        assertEquals("suica.jpg", backup.cards.first().faceImageFileName)
        assertNotNull(backup.faceAssets["suica.jpg"])
    }
}
