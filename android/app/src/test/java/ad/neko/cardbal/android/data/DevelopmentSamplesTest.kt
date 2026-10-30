package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.JapaneseCardFormats
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class DevelopmentSamplesTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test fun checkedInWalletsDecodeAndRoundTripWithoutArtwork() {
        val cards = listOf("owner-wallet.json" to 48, "mock-wallet.json" to 3).flatMap { (name, count) ->
            val text = javaClass.classLoader!!.getResourceAsStream(name)!!.bufferedReader().use { it.readText() }
            val wallet = json.decodeFromString<CardBackupData>(text)
            assertEquals(count, wallet.cards.size)
            assertTrue(wallet.faceAssets.isEmpty())
            assertEquals(wallet, json.decodeFromString<CardBackupData>(json.encodeToString(wallet)))
            wallet.cards.onEach { card ->
                assertNull(card.faceImageFileName)
                assertFalse(card.finalIsUsingImage)
                assertTrue(card.id.startsWith("sample:"))
                assertTrue(card.rawIdentifierValue.isNotBlank())
            }
        }
        assertEquals(51, cards.map { it.id }.toSet().size)
        assertEquals(513, cards.filter { it.id.startsWith("sample:owner:") }.sumOf { it.rawTransactions.size + it.rawTransitHistory.size })
    }

    @Test fun edyAndNanacoCaptureRecordsRetainValidDatesFaresAndBalances() {
        val text = javaClass.classLoader!!.getResourceAsStream("owner-wallet.json")!!.bufferedReader().use { it.readText() }
        val cards = json.decodeFromString<CardBackupData>(text).cards
        var decoded = 0
        for (card in cards) for (raw in card.rawTransactions) {
            val tx = when (card.cardFamily) {
                "nanaco" -> JapaneseCardFormats.nanaco(raw.hexToBytes(), raw)
                "Rakuten Edy" -> JapaneseCardFormats.edy(raw.hexToBytes(), raw)
                else -> continue
            }
            assertNotNull("${card.id} ${card.cardFamily}", tx)
            assertNotNull(tx!!.date)
            assertNotNull(tx.balanceAfter)
            assertEquals("JPY", tx.currencyCode)
            decoded++
        }
        assertEquals(11, decoded)
    }
}
