package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexToBytes
import java.io.IOException
import java.time.ZoneId
import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

/** All fixtures are synthetic; no private or sample card captures are embedded. */
class ClipperDecoderTest {
    private val scannedAt = Instant.fromEpochSeconds(1_800_000_000)
    private fun bytes(value: String) = value.hexToBytes()
    private fun be(data: ByteArray, offset: Int, width: Int, value: Long) {
        repeat(width) { data[offset + it] = (value ushr ((width - it - 1) * 8)).toByte() }
    }
    private fun trip(agency: Int = 4, mode: Int = 0x6F, exit: Boolean = true, seconds: Long = 3_908_988_800): ByteArray =
        ByteArray(32).also {
            be(it, 2, 2, agency.toLong()); be(it, 6, 2, 630); be(it, 10, 2, 20101)
            be(it, 12, 4, seconds); be(it, 16, 4, if (exit) seconds + 600 else 0)
            be(it, 20, 2, 8); be(it, 22, 2, 39); be(it, 28, 2, 7); be(it, 30, 2, mode.toLong())
        }
    private fun refill() = ByteArray(32).also {
        be(it, 2, 2, 4); be(it, 4, 4, 3_908_988_800); be(it, 8, 4, 0xFFFFFFFE); be(it, 14, 2, 5000)
    }
    private fun files() = mapOf(
        8 to bytes("00FFFFFFFF"),
        2 to ByteArray(20).also { be(it, 18, 2, 0xFF9C) },
        1 to ByteArray(10).also { be(it, 8, 2, 45000) },
        14 to trip(),
        4 to refill(),
    )
    private val catalog = object : ClipperLookup {
        override fun agencyName(agency: Int) = if (agency == 4) "Synthetic Rail" else "Agency $agency"
        override fun stationName(agency: Int, station: Int, isEnd: Boolean) = when (station) {
            8 -> "Synthetic Entry"; 39 -> "Synthetic Exit"; else -> null
        }
        override fun stationCode(agency: Int, station: Int) = "CLIPPER:${(agency shl 16) or station}"
        override fun routeName(agency: Int, route: Int) = "Synthetic Route $route"
    }

    @Test fun snapshotKeepsUnsignedSerialSignedUsdPurseCalendarExpiryAndFileProvenance() {
        val snapshot = ClipperDecoder.snapshot(files(), byteArrayOf(), scannedAt)
        assertEquals("4294967295", snapshot.identifierValue)
        assertEquals("4294967295", snapshot.rawIdentifierValue)
        assertEquals("USD -1.00", snapshot.balanceText)
        assertEquals("9011F2", snapshot.selectedAID)
        assertEquals("2023-03-17", snapshot.resultFields.first { it.title == "Expiry Date" }.value)
        assertEquals(scannedAt, snapshot.scannedAt)
        assertEquals(2, snapshot.rawTransactions.size)
        assertEquals(1, snapshot.rawTransitHistory.size)
        assertTrue(snapshot.rawTransactions[0].startsWith("0E"))
        assertTrue(snapshot.rawTransactions[1].startsWith("04"))
        val decoded = snapshot.rawTransactions.map { it.hexToBytes() }.map { ClipperDecoder.decodeRecord(it, catalog)!! }
        assertEquals(-630L, decoded[0].amount)
        assertEquals(5000L, decoded[1].amount)
        assertEquals("4294967294", decoded[1].terminalID)
        assertNull(decoded[0].balanceAfter)
        assertTrue(decoded.all { it.currencyCode == "USD" && it.fractionDigits == 2 && it.amountIsSigned })
        assertEquals("America/Los_Angeles", decoded[0].issuerTimeZone)
        assertEquals("Synthetic Entry", decoded[0].entryStation)
        assertEquals("Synthetic Exit", decoded[0].exitStation)
        assertEquals("CLIPPER:262152", decoded[0].entryStationCode)
        assertEquals("Synthetic Rail - Synthetic Route 7", decoded[0].location)
        assertEquals("2010A", decoded[0].terminalID)
    }

    @Test fun exactReaderCommandsAndUnavailableOptionalFilesPreserveRequiredPurse() {
        val pending = mutableListOf(
            "905A0000039011F200" to bytes("9100"),
            "90F50000010800" to bytes("0000EEEE0500009100"),
            "90BD0000070800000000000000" to (files().getValue(8) + bytes("9100")),
            "90F50000010200" to bytes("0000EEEE1400009100"),
            "90BD0000070200000000000000" to (files().getValue(2) + bytes("9100")),
            "90F50000010100" to bytes("91F0"),
            "90F50000010400" to bytes("919D"),
            "90F50000010E00" to bytes("91AE"),
        )
        val snapshot = ClipperDecoder().read(bytes("04010203040506"), scannedAt) { command ->
            assertTrue(pending.isNotEmpty())
            val (expected, reply) = pending.removeAt(0)
            assertArrayEquals(bytes(expected), command)
            reply
        }
        assertTrue(pending.isEmpty())
        assertEquals("USD -1.00", snapshot.balanceText)
        assertEquals("04010203040506", snapshot.rawIdentifierValue)
        assertTrue(snapshot.rawTransactions.isEmpty())
        assertEquals("01, 04, 0E", snapshot.rawSections.first { it.title == "Clipper Read Status" }.fields.single().value)
    }

    @Test fun truncatedRequiredFilesBadHistoryLengthsAndEmptyRecordsNeverDecode() {
        for (length in 0 until 20) assertThrows(IOException::class.java) {
            ClipperDecoder.snapshot(files() + (2 to ByteArray(length)), byteArrayOf(), scannedAt)
        }
        for (length in 0 until 5) assertThrows(IOException::class.java) {
            ClipperDecoder.snapshot(files() + (8 to ByteArray(length)), byteArrayOf(), scannedAt)
        }
        for (length in 0 until 33) assertNull(ClipperDecoder.decodeRecord(ByteArray(length)))
        for (length in listOf(34, 64, 66)) assertNull(ClipperDecoder.decodeRecord(ByteArray(length)))
        assertTrue(ClipperDecoder.records(byteArrayOf(), 14).isEmpty())
        assertTrue(ClipperDecoder.records(ByteArray(32), 14).isEmpty())
        assertTrue(ClipperDecoder.records(trip() + byteArrayOf(0), 14).isEmpty())
        assertTrue(ClipperDecoder.records(trip(), 2).isEmpty())
        assertNull(ClipperDecoder.decodeRecord(byteArrayOf(1) + trip()))
        assertNull(ClipperDecoder.decodeRecord(byteArrayOf(14) + trip(agency = 0)))
        assertNull(ClipperDecoder.decodeRecord(byteArrayOf(14) + trip(seconds = 0)))
    }

    @Test fun persistedHistoryPrefersCompletedTripFromEitherRescanOrderAndKeepsReloadSeparate() {
        val pending = byteArrayOf(14) + trip(exit = false)
        val complete = byteArrayOf(14) + trip()
        val reload = byteArrayOf(4) + refill()
        for (original in listOf(listOf(pending, complete, reload), listOf(complete, pending, reload))) {
            val hex = original.map { it.joinToString("") { byte -> "%02X".format(byte) } }
            val restored = Json.decodeFromString<List<String>>(Json.encodeToString(kotlinx.serialization.serializer<List<String>>(), hex))
            val context = restored.map { it.hexToBytes() }
            val events = context.mapIndexedNotNull { index, raw -> ClipperDecoder.decodeTransaction(raw, context, index, catalog) }
            assertEquals(2, events.size)
            assertEquals(1, events.count { it.category == TransactionCategory.topUp })
            assertEquals(1, events.count { it.category == TransactionCategory.train })
            assertEquals(complete.joinToString("") { "%02X".format(it) }, events.first { it.category == TransactionCategory.train }.rawData)
        }
        assertEquals(3_908_988_800L, ClipperDecoder.tripEntryTimestamp(complete))
        assertNull(ClipperDecoder.tripEntryTimestamp(reload))
        assertEquals(listOf(complete.toList(), pending.toList()), ClipperDecoder.records(trip(exit = false) + trip(), 14).map { it.hexToBytes().toList() })
    }

    @Test fun legacyDfsVClipperEnvelopesCanonicalizeWithoutMovingSlotOrDuplicateHistory() {
        for ((kind, file, payload) in listOf(Triple(2, 4, refill()), Triple(3, 14, trip()))) {
            val expected = (byteArrayOf(file.toByte()) + payload).joinToString("") { "%02X".format(it) }
            for (index in listOf(0, 1, 65535)) {
                val envelope = StoredValueProtocol.envelope(5, kind, index, payload)
                assertEquals(expected, ClipperDecoder.canonicalHistoryRecord(envelope))
                assertEquals(expected, ClipperDecoder.canonicalHistoryRecord(envelope.lowercase()))
                assertEquals(expected, ClipperDecoder.canonicalHistoryRecord(expected))
                assertArrayEquals(payload, ClipperDecoder.canonicalHistoryRecord(envelope).hexToBytes().copyOfRange(1, 33))
            }
        }
        val oldPending = StoredValueProtocol.envelope(5, 3, 4, trip(exit = false))
        val oldComplete = StoredValueProtocol.envelope(5, 3, 7, trip())
        val newComplete = (byteArrayOf(14) + trip()).joinToString("") { "%02X".format(it) }
        val canonical = listOf(oldPending, oldComplete, newComplete)
            .map(ClipperDecoder::canonicalHistoryRecord).distinct().map { it.hexToBytes() }
        val history = canonical.mapIndexedNotNull { index, raw ->
            ClipperDecoder.decodeTransaction(raw, canonical, index, catalog)
        }
        assertEquals(2, canonical.size)
        assertEquals(1, history.size)
        assertEquals(newComplete, history.single().rawData)
    }

    @Test fun invalidForeignOrUnknownLegacyEnvelopesAndNewRecordsRemainVerbatim() {
        val valid = StoredValueProtocol.envelope(5, 3, 0, trip())
        val mutations = listOf(0 to 0x45, 3 to 0x57, 4 to 2, 5 to 4, 6 to 1, 6 to 4,
            9 to 1, 10 to 31, 10 to 33).map { (offset, value) ->
            valid.hexToBytes().also { it[offset] = value.toByte() }.joinToString("") { "%02X".format(it) }
        }
        val malformed = listOf("", "not hex", valid.dropLast(1), valid.dropLast(2), valid + "00",
            valid.replaceRange(22, 23, "Z"), " $valid", "$valid\n",
            StoredValueProtocol.envelope(2, 3, 0, trip()), StoredValueProtocol.envelope(5, 2, 0, ByteArray(31)),
            StoredValueProtocol.envelope(5, 3, 0, ByteArray(33)),
            (byteArrayOf(14) + trip()).joinToString("") { "%02x".format(it) },
            ("AFC8".hexToBytes() + ByteArray(20)).joinToString("") { "%02X".format(it) })
        for (raw in mutations + malformed) assertEquals(raw, ClipperDecoder.canonicalHistoryRecord(raw))
    }

    @Test fun timestampsAreUnsignedAndIssuerClockTracksDstWithNoHostTimeZoneDependence() {
        val value = ClipperDecoder.decodeRecord(byteArrayOf(14) + trip())!!
        assertEquals(1_700_000_000L, value.date!!.epochSeconds)
        val winter = ClipperDecoder.decodeRecord(byteArrayOf(14) + trip(seconds = 1_704_067_200 + ClipperDecoder.EPOCH_OFFSET_SECONDS))!!
        val summer = ClipperDecoder.decodeRecord(byteArrayOf(14) + trip(seconds = 1_719_792_000 + ClipperDecoder.EPOCH_OFFSET_SECONDS))!!
        assertEquals("16:00:00", winter.time)
        assertEquals("17:00:00", summer.time)
        assertEquals(-28800, ZoneId.of(ClipperDecoder.ISSUER_TIME_ZONE).rules.getOffset(java.time.Instant.ofEpochSecond(winter.date!!.epochSeconds)).totalSeconds)
        val high = ClipperDecoder.decodeRecord(byteArrayOf(14) + trip(seconds = 0xFFFFFFFF))!!
        assertEquals(2_085_978_495L, high.date!!.epochSeconds)
        assertEquals(65535L, ClipperDecoder.decodeRecord(byteArrayOf(14) + trip().also { be(it, 6, 2, 65535) })!!.amount * -1)
    }

    @Test fun transitModesAndVehicleSentinelsRetainKnownLimits() {
        for ((mode, agency, expected) in listOf(
            Triple(0x61, 1, TransactionCategory.bus), Triple(0x75, 1, TransactionCategory.bus),
            Triple(0x77, 1, TransactionCategory.bus), Triple(0x6F, 4, TransactionCategory.train),
            Triple(0x78, 6, TransactionCategory.train), Triple(0x62, 6, TransactionCategory.train),
            Triple(0xFF, 4, TransactionCategory.unknown),
        )) assertEquals(expected, ClipperDecoder.decodeRecord(byteArrayOf(14) + trip(agency, mode))!!.category)
        for ((mode, agency) in listOf(0x73 to 27, 0x62 to 25, 0x62 to 27)) {
            assertTrue(ClipperDecoder.decodeRecord(byteArrayOf(14) + trip(agency, mode))!!.type.endsWith("Ferry"))
        }
        assertNull(ClipperDecoder.vehicleName(0))
        assertNull(ClipperDecoder.vehicleName(0xFFFF))
        assertEquals("9999", ClipperDecoder.vehicleName(9999))
        assertEquals("2010A", ClipperDecoder.vehicleName(20101))
    }
}
