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

    /** A Shanghai City Union metro tap in SFI 18: terminal 200011 + station, 2026-11-05. */
    private fun shanghaiTap(counter: String, fare: String, terminal: String, time: String) =
        counter + "000000" + fare + "09" + terminal + "20261105" + time

    /** SFI 11 last-entry/exit record: minute timestamp, then the terminal's last three bytes. */
    private fun shanghaiLastTap(minute: String, terminal: String) = "01" + minute + terminal.takeLast(6) + "00".repeat(7)

    private val cityUnionEntry = shanghaiTap("0001", "00000000", "200011011101", "083000")
    private val cityUnionExit = shanghaiTap("0002", "00000190", "200011011601", "090500")

    private fun application(aid: String, family: String, records: List<TransitApplicationRecord>) = TransitApplication(
        technology = "ISO7816", cardFamily = family, identifier = "04A1B2C3", selectedAID = aid,
        records = records, scannedAt = Instant.parse("2026-11-05T12:00:00Z"),
    )

    private fun shanghaiCard(applications: List<TransitApplication>) = SavedCardRecord(
        id = "test:route:shanghai",
        cardFamily = "City Union",
        technology = "ISO7816",
        identifierLabel = "UID",
        rawIdentifierValue = "04A1B2C3",
        identifierValue = "04A1 B2C3",
        scannedAt = Instant.parse("2026-11-05T12:00:00Z"),
        applications = applications,
        color = SavedCardColor.Black,
    )

    @Test
    fun shanghaiCityUnionEntryAndExitFormOneMetroRoute() {
        val cityUnion = application("A00000000386980701", "City Union", listOf(
            TransitApplicationRecord("transaction", 0x18, 1, cityUnionExit),
            TransitApplicationRecord("transaction", 0x18, 2, cityUnionEntry),
            TransitApplicationRecord("auxiliary", 0x11, 1, shanghaiLastTap("2611050830", "200011011101")),
            TransitApplicationRecord("auxiliary", 0x11, 2, shanghaiLastTap("2611050905", "200011011601")),
        ))

        val routes = decoder.routesFor(shanghaiCard(listOf(cityUnion)))

        assertEquals(1, routes.size)
        assertEquals("莘庄 → 漕宝路", routes.single().title)
        assertTrue(routes.single().points.size > 2)
    }

    @Test
    fun shanghaiRideCanStartInCityUnionAndEndInTUnion() {
        val cityUnion = application("A00000000386980701", "City Union", listOf(
            TransitApplicationRecord("transaction", 0x18, 1, cityUnionEntry),
            TransitApplicationRecord("auxiliary", 0x11, 1, shanghaiLastTap("2611050830", "200011011101")),
        ))
        val tUnionExit = "04" + "0000000000000000" + "00" + "00010016000000" +
            "00000190" + "00000FA0" + "20261105" + "090500" + "2900" + "0".repeat(28)
        val tUnion = application("A000000632010105", "China T-Union", listOf(
            TransitApplicationRecord("transit", 0x1e, 1, tUnionExit),
        ))

        val routes = decoder.routesFor(shanghaiCard(listOf(cityUnion, tUnion)))

        assertEquals(1, routes.size)
        assertEquals("莘庄", routes.single().points.first().name)
        assertEquals("漕宝路", routes.single().points.last().name)
    }
}
