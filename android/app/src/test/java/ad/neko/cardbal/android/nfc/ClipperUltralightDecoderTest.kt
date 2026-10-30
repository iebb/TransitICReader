package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexToBytes
import java.io.IOException
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

class ClipperUltralightDecoderTest {
    private val scannedAt = Instant.fromEpochSeconds(1_800_000_000)
    private fun event(sequence: Int, balanceSequence: Int, remaining: Int, type: Int = 2): ByteArray =
        ByteArray(20).also { data ->
            fun bits(offset: Int, count: Int, value: Int) {
                repeat(count) {
                    val bit = (value ushr (count - it - 1)) and 1
                    val index = (offset + it) / 8
                    data[index] = (data[index].toInt() or (bit shl (7 - (offset + it) % 8))).toByte()
                }
            }
            bits(0, 7, sequence); bits(7, 17, type); bits(24, 17, 120)
            bits(41, 17, 7); bits(68, 5, 18); bits(80, 4, balanceSequence)
            bits(84, 6, remaining); bits(100, 10, 90)
        }
    private fun ticket(first: ByteArray = event(127, 15, 2), last: ByteArray = event(0, 0, 1, 1)): ByteArray =
        ByteArray(64).also {
            "12345678".hexToBytes().copyInto(it, 12)
            it[16] = 0x13; it[17] = 4; it[20] = 2; it[21] = 0x14
            it[22] = 0xAF.toByte(); it[23] = 0xC8.toByte()
            first.copyInto(it, 24); last.copyInto(it, 44)
        }
    private val lookup = object : ClipperLookup {
        override fun defaultMode(agency: Int) = 1
        override fun agencyName(agency: Int) = "Synthetic Bus"
        override fun stationName(agency: Int, station: Int, isEnd: Boolean) = "Synthetic Stop"
        override fun stationCode(agency: Int, station: Int) = "CLIPPER:${(agency shl 16) or station}"
    }

    @Test fun readerUsesFourPageReadOrderAndRejectsOtherTicketMarkersBeforeFurtherReads() {
        val data = ticket()
        val calls = mutableListOf<Int>()
        val snapshot = ClipperUltralightDecoder(lookup).read(byteArrayOf(4, 1, 2), scannedAt) { page ->
            calls.add(page)
            data.copyOfRange(page * 4, page * 4 + 16)
        }!!
        assertEquals(listOf(4, 0, 8, 12), calls)
        assertEquals("305419896", snapshot.identifierValue)
        assertEquals("040102", snapshot.rawIdentifierValue)
        assertEquals("MIFARE Ultralight", snapshot.technology)
        assertEquals("Clipper Ticket", snapshot.cardFamily)
        assertNull(snapshot.balanceText)
        assertTrue(snapshot.rawTransactions.isEmpty())
        calls.clear()
        assertNull(ClipperUltralightDecoder().read(byteArrayOf(), scannedAt) {
            calls.add(it); ByteArray(16)
        })
        assertEquals(listOf(4), calls)
    }

    @Test fun productDatesWrappedRemainingRidesAndTransferExpiryUseRawBaseDate() {
        val snapshot = ClipperUltralightDecoder.snapshot(ticket(), byteArrayOf(), scannedAt, lookup)!!
        assertEquals("305419896", snapshot.rawIdentifierValue)
        assertEquals("Adult", snapshot.resultFields.first { it.title == "Ticket Type" }.value)
        assertEquals("Adult return", snapshot.resultFields.first { it.title == "Product" }.value)
        assertEquals("1", snapshot.resultFields.first { it.title == "Trips Remaining" }.value)
        assertEquals("2023-03-17", snapshot.resultFields.first { it.title == "Expiry Date" }.value)
        assertEquals("2022-12-18", snapshot.resultFields.first { it.title == "Issue Date" }.value)
        assertNotNull(snapshot.resultFields.firstOrNull { it.title == "Transfer Expiry" })
        assertEquals(2, snapshot.rawTransitHistory.size)
        val raw = snapshot.rawTransitHistory.map { it.hexToBytes() }
        assertTrue(raw.all { it.size == 22 && it[0] == 0xAF.toByte() && it[1] == 0xC8.toByte() })
        val events = raw.mapNotNull { ClipperUltralightDecoder.decodeTransaction(it, lookup) }
        assertEquals(1, events.size)
        assertEquals(1_679_004_000L, events.single().date!!.epochSeconds)
        assertEquals("Synthetic Stop", events.single().entryStation)
        assertEquals(TransactionCategory.bus, events.single().category)
        assertEquals("USD", events.single().currencyCode)
        assertEquals(2, events.single().fractionDigits)
        assertFalse(events.single().amountKnown)
        assertEquals(0L, events.single().amount)
    }

    @Test fun sequenceAndBalanceCountersWrapIndependentlyIncludingHiddenLatestInitialization() {
        val base = "AFC8".hexToBytes()
        val prior = ClipperUltralightDecoder.TicketEvent.parse(base + event(127, 4, 2))!!
        val next = ClipperUltralightDecoder.TicketEvent.parse(base + event(0, 4, 1))!!
        assertTrue(next.isNewerThan(prior)); assertFalse(prior.isNewerThan(next))
        val balancePrior = ClipperUltralightDecoder.TicketEvent.parse(base + event(80, 15, 2))!!
        val balanceNext = ClipperUltralightDecoder.TicketEvent.parse(base + event(1, 0, 1))!!
        assertTrue(balanceNext.isNewerThan(balancePrior)); assertFalse(balancePrior.isNewerThan(balanceNext))
        val reversed = ticket(event(0, 0, 1, 1), event(127, 15, 2))
        val snapshot = ClipperUltralightDecoder.snapshot(reversed, byteArrayOf(), scannedAt)!!
        assertEquals("1", snapshot.resultFields.first { it.title == "Trips Remaining" }.value)
        assertEquals(1, snapshot.rawTransitHistory.mapNotNull { ClipperUltralightDecoder.decodeTransaction(it.hexToBytes()) }.size)
    }

    @Test fun truncatedPagesInvalidMarkersEmptySlotsAndNonexactHistoryNeverDecode() {
        for (size in 0 until 64) assertNull(ClipperUltralightDecoder.snapshot(ByteArray(size), byteArrayOf(), scannedAt))
        assertNull(ClipperUltralightDecoder.snapshot(ticket().copyOf(65), byteArrayOf(), scannedAt))
        assertNull(ClipperUltralightDecoder.snapshot(ticket().also { it[16] = 0x12 }, byteArrayOf(), scannedAt))
        for (size in (0 until 22) + listOf(23, 42)) assertNull(ClipperUltralightDecoder.decodeTransaction(ByteArray(size)))
        assertNull(ClipperUltralightDecoder.decodeTransaction("AFC8".hexToBytes() + ByteArray(20)))
        for (badPage in listOf(0, 8, 12)) assertThrows(IOException::class.java) {
            ClipperUltralightDecoder().read(byteArrayOf(), scannedAt) { page ->
                if (page == badPage) ByteArray(15) else ticket().copyOfRange(page * 4, page * 4 + 16)
            }
        }
        val empty = ClipperUltralightDecoder.snapshot(ticket(ByteArray(20), ByteArray(20)), byteArrayOf(), scannedAt)!!
        assertTrue(empty.rawTransitHistory.isEmpty())
        assertNull(empty.resultFields.firstOrNull { it.title == "Trips Remaining" })
        assertNull(empty.balanceText)
    }
}
