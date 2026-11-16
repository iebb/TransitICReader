package ad.neko.cardbal.android.data

import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.datetime.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TransitRouteTest {
    private val decoder = TransactionDecoder(InstrumentationRegistry.getInstrumentation().targetContext)

    /** A 48-byte T-Union travel record at a Beijing station on line 1. */
    private fun travelRecord(type: Int, station: String, time: String): String =
        "%02X".format(type) + "0000000000000000" + "00" + station.padEnd(14, '0') +
            "000000C8" + "00000FA0" + "20260105" + time + "1000" + "0".repeat(28)

    private fun tUnionCard(records: List<String>) = SavedCardRecord(
        id = "test:route:tunion",
        cardFamily = "China T-Union",
        technology = "ISO7816",
        identifierLabel = "Card Number",
        rawIdentifierValue = "3104000000000001",
        identifierValue = "3104000000000001",
        scannedAt = Instant.parse("2026-01-05T12:00:00Z"),
        rawTransactions = records,
        color = SavedCardColor.Black,
    )

    @Test
    fun tUnionEntryAndExitTapsFormOneRouteThroughIntermediateStations() {
        val card = tUnionCard(listOf(
            travelRecord(0x04, "01000A", "083000"),
            travelRecord(0x03, "010006", "080000"),
        ))

        val routes = decoder.routesFor(card)

        assertEquals(1, routes.size)
        val names = routes.single().points.map { it.name }
        assertEquals("八宝山", names.first())
        assertTrue(names.toString(), "玉泉路" in names && "五棵松" in names)
    }

    @Test
    fun tUnionExitWithoutEntryDrawsNoRoute() {
        val routes = decoder.routesFor(tUnionCard(listOf(travelRecord(0x04, "01000A", "083000"))))

        assertTrue(routes.isEmpty())
    }
}
