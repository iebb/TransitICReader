package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

class CharlieCardProtocolTest {
    private val scannedAt = Instant.fromEpochSeconds(1_800_000_000)

    private fun block(hex: String): ByteArray = ByteArray(16).also { hex.hexToBytes().copyInto(it) }

    private fun card(trip: String = ""): Map<Int, List<ByteArray>> = mapOf(
        0 to listOf(block("00BC614E"), block(""), block("")),
        2 to listOf(block("00000000000000000000020000000000"), block("000000000007D0"), block("")),
        3 to listOf(block(""), block(""), block("")),
        6 to listOf(block(trip), block(""), block("")),
        7 to listOf(block(""), block(""), block("")),
        8 to listOf(block("0000000A"), block(""), block("")),
    )

    private fun field(sectors: Map<Int, List<ByteArray>>, title: String): String? =
        CharlieCardProtocol.snapshot(sectors, byteArrayOf(4, 0x11, 0x22, 0x33), scannedAt)
            ?.resultFields?.firstOrNull { it.title == title }?.value

    @Test fun parsesSerialBalanceDatesAndSecondNumber() {
        val snapshot = CharlieCardProtocol.snapshot(card(), byteArrayOf(4, 0x11, 0x22, 0x33), scannedAt)!!
        assertEquals("MIFARE Classic", snapshot.technology)
        assertEquals("CharlieCard", snapshot.cardFamily)
        assertEquals("5-12345678", snapshot.identifierValue)
        assertEquals("USD 10.00", snapshot.balanceText)
        assertEquals("2003-01-01", field(card(), "Issue Date"))
        assertEquals("2013-12-31", field(card(), "Expiry Date"))
        assertEquals("A0000000010", field(card(), "Second Card Number"))
        assertTrue(snapshot.rawTransitHistory.isEmpty())
    }

    @Test fun aUsedCardExpiresTwoYearsAfterItsLastTrip() {
        val sectors = card(trip = "00006400010064")
        val snapshot = CharlieCardProtocol.snapshot(sectors, ByteArray(0), scannedAt)!!
        assertEquals(1, snapshot.rawTransitHistory.size)
        assertEquals("2005-01-01", field(sectors, "Expiry Date"))
    }

    @Test fun decodesBusSubwayAndTicketMachineTrips() {
        val bus = CharlieCardProtocol.decodeTransaction("00006400010064".hexToBytes())!!
        assertEquals("Bus", bus.type)
        assertEquals(TransactionCategory.bus, bus.category)
        assertEquals(-50L, bus.amount)
        assertEquals("USD", bus.currencyCode)
        assertTrue(bus.amountIsSigned)
        val subway = CharlieCardProtocol.decodeTransaction("000064004A0064".hexToBytes())!!
        assertEquals("Subway", subway.type)
        assertEquals(TransactionCategory.train, subway.category)
        assertEquals("9", subway.terminalID)
        val machine = CharlieCardProtocol.decodeTransaction("00006400000064".hexToBytes())!!
        assertEquals("Ticket Machine", machine.type)
        assertEquals(TransactionCategory.purchase, machine.category)
    }

    @Test fun rejectsEmptyOrShortTripsAndParsesSignedPrice() {
        assertNull(CharlieCardProtocol.decodeTransaction("00000000000000".hexToBytes()))
        assertNull(CharlieCardProtocol.decodeTransaction("0000".hexToBytes()))
        assertEquals(-50, CharlieCardProtocol.price("8064".hexToBytes(), 0))
        assertEquals(21, CharlieCardProtocol.KEYS.size)
        assertTrue(CharlieCardProtocol.KEYS.all { it.size == 6 })
    }
}
