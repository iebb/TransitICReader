package ad.neko.cardbal.android.data

import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class CardDetailPresentationTest {
    private fun card(detail: String?, balance: String? = null, family: String = "Hanica") = SavedCardRecord(
        id = "test:hanica", cardFamily = family, technology = "FeliCa",
        identifierLabel = "IDm", identifierValue = "0102030405060708",
        rawIdentifierValue = "0102030405060708", balanceText = balance,
        balanceDetail = detail, scannedAt = Instant.parse("2026-01-01T00:00:00Z"),
        color = SavedCardColor.Black,
    )

    @Test fun diagnosticDetailsStayInBackupsNotNormalDetails() {
        for (detail in listOf(
            "Hanica balance layout unconfirmed; the log does not prove where the balance is stored.",
            "Stored balance from the latest Hanica record (test layout).",
            "Public Calypso records; network not identified",
            "Parsed from service 0x1317 as 4-byte LE.",
            "Older DESFire generation; newer Clipper generations are not decoded",
            "HSL V1/V2 or Waltti DESFire public purse, logs and ticket products",
            "Balance decoded using this card's saved offset.",
            "Future decoder commentary",
        )) {
            val saved = card(detail)
            val restored = Json.decodeFromString<SavedCardRecord>(Json.encodeToString(saved))
            assertNull(detail, restored.balanceScopeNote)
            assertEquals(detail, restored.balanceDetail)
            assertEquals("", restored.visibleBalance)
        }
        assertNull(card(null).balanceScopeNote)
    }

    @Test fun semanticScopeAndConfirmedBalancesAreKept() {
        for (note in listOf(
            "On-card stored-value purse only. SimplyGo account balances are not read.",
            "Stored-value balance excluding the MOP 10 reserve.",
            "Balance and last-event summary; not full history",
            "Climate Card (Unlimited Pass)",
        )) assertEquals(note, card(note).balanceScopeNote)
        val nice = "Lignes d'Azur card"
        assertEquals("Solo: 3 remaining trips", card("Solo: 3 remaining trips", "3 trips", nice).balanceScopeNote)
        assertNull(card("Calypso card recognized.", null, nice).balanceScopeNote)
        assertEquals("¥0", card("diagnostic", "¥0").visibleBalance)
        assertEquals("¥1,240", card("diagnostic", "¥1,240").visibleBalance)
        assertEquals("3 trips", card("Ticket name", "3 trips").visibleBalance)
    }
}
