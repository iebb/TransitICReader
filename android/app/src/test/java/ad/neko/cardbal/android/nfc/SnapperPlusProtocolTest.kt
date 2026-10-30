package ad.neko.cardbal.android.nfc

import org.junit.Assert.*
import org.junit.Test
import java.time.Instant

class SnapperPlusProtocolTest {
    private fun put32(data: ByteArray, at: Int, value: Int) {
        repeat(4) { data[at + it] = (value ushr ((3 - it) * 8)).toByte() }
    }

    private fun transaction(type: Int = 1, cost: Int = 325, balance: Int = 1575, counter: Int = 42): ByteArray =
        ByteArray(46).also {
            it[0] = type.toByte(); it[1] = 0x2C
            put32(it, 2, balance); put32(it, 6, counter); put32(it, 10, cost)
            byteArrayOf(0x01, 0x23, 0x45, 0x67, 0x80.toByte()).copyInto(it, 14)
            (26 until 46).forEach { index -> it[index] = 0xFF.toByte() }
        }

    private fun trip(date: String = "20261030123045"): ByteArray = ByteArray(52).also {
        it[0] = 1; it[1] = 0x32; it[4] = 2; it[5] = 7; it[51] = 0x10
        date.chunked(2).map { hex -> hex.toInt(16).toByte() }.toByteArray().copyInto(it, 13)
    }

    private fun selection(issuer: Int = 2): ByteArray =
        (byteArrayOf(0x6F, 49, 0xB0.toByte(), 47) + ByteArray(47).also { it[3] = issuer.toByte() } + byteArrayOf(0x90.toByte(), 0))

    @Test fun identificationRequiresApplicationIssuerAndNonemptySignature() {
        val record = transaction()
        assertTrue(SnapperPlusProtocol.matches(SnapperPlusProtocol.APPLICATION_AID, 2, listOf(record)))
        assertFalse(SnapperPlusProtocol.matches(SnapperPlusProtocol.APPLICATION_AID, 2, emptyList()))
        assertFalse(SnapperPlusProtocol.matches(SnapperPlusProtocol.APPLICATION_AID, 8, listOf(record)))
        assertFalse(SnapperPlusProtocol.matches("D4100000140001", 2, listOf(record)))
        assertFalse(SnapperPlusProtocol.matches(SnapperPlusProtocol.APPLICATION_AID, 2, listOf(record.copyOf(40))))
        record[30] = 0
        assertFalse(SnapperPlusProtocol.matches(SnapperPlusProtocol.APPLICATION_AID, 2, listOf(record)))
    }

    @Test fun balancesAreSignedFourByteMinorUnitsWithExactSuccess() {
        assertEquals(12345L, SnapperPlusProtocol.balanceMinor(byteArrayOf(0, 0, 0x30, 0x39, 0x90.toByte(), 0)))
        assertEquals(-1L, SnapperPlusProtocol.balanceMinor(byteArrayOf(-1, -1, -1, -1, 0x90.toByte(), 0)))
        listOf(byteArrayOf(0, 0, 0, 1, 0x69, 0x82.toByte()), byteArrayOf(0x90.toByte(), 0), ByteArray(7)).forEach {
            assertNull(SnapperPlusProtocol.balanceMinor(it))
        }
    }

    @Test fun tripAndTransactionHaveSeparateLayoutsAndNZDCentSigns() {
        val encoded = SnapperPlusProtocol.encodeHistory(transaction(), trip(), 3)!!
        val value = SnapperPlusProtocol.decodeHistory(encoded)!!
        assertEquals(-325L, value.amountMinor); assertEquals(1575L, value.balanceMinor)
        assertEquals(42L, value.counter); assertEquals(3, value.recordNumber)
        assertEquals(Instant.parse("2026-10-29T23:30:45Z").toEpochMilli(), value.timestampMillis)
        assertEquals(7, value.journeyID); assertEquals(2, value.sequence); assertEquals(true, value.isTapOn)
        assertEquals("012345678", value.operatorID)
        assertArrayEquals(transaction(), value.transactionBytes)
        assertEquals(500L, SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction(type = 2, cost = 500), null, 1)!!)!!.amountMinor)
        assertEquals(325L, SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction(cost = -325), null, 1)!!)!!.amountMinor)
    }

    @Test fun missingMalformedOrAmbiguousTripKeepsAmountWithUnknownDate() {
        val invalid = listOf(null, trip().copyOf(51), trip("20260230123045"), trip("202610301A3045"),
            trip("20260405023000"), trip("20260927023000"))
        invalid.forEach { trip ->
            val value = SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction(), trip, 1)!!)!!
            assertEquals(-325L, value.amountMinor); assertNull(value.timestampMillis); assertNull(value.isTapOn)
        }
        val winter = SnapperPlusProtocol.decodeHistory(SnapperPlusProtocol.encodeHistory(transaction(), trip("20260701120000"), 1)!!)!!
        assertEquals(Instant.parse("2026-07-01T00:00:00Z").toEpochMilli(), winter.timestampMillis)
    }

    @Test fun malformedOrFutureEnvelopeVersionsAreNotDecodedAsKnownHistory() {
        val envelope = SnapperPlusProtocol.encodeHistory(transaction(), trip(), 1)!!
        listOf(envelope.copyOf(51), envelope.copyOf(103), envelope + byteArrayOf(0),
            envelope.clone().also { it[3] = 2 }, envelope.clone().also { it[4] = 0 }).forEach {
            assertNull(SnapperPlusProtocol.decodeHistory(it))
        }
        assertNull(SnapperPlusProtocol.encodeHistory(transaction().copyOf(45), null, 1))
    }

    @Test fun readerGuardsSuccessAndPairsByActualRecordNumberDespiteMissingTrip() {
        val commands = mutableListOf<ByteArray>()
        val result = SnapperPlusProtocol.read(SnapperPlusProtocol.APPLICATION_AID, selection(), byteArrayOf(0, 0, 0, 100, 0x90.toByte(), 0)) { command ->
            commands.add(command.clone())
            val number = command[2].toInt(); val sfi = command[3].toInt() ushr 3
            when {
                sfi == 4 && number == 1 -> transaction(counter = 45) + byteArrayOf(0x90.toByte(), 0)
                sfi == 4 && number == 2 -> transaction(counter = 44) + byteArrayOf(0x90.toByte(), 0)
                sfi == 3 && number == 2 -> trip() + byteArrayOf(0x90.toByte(), 0)
                else -> byteArrayOf(0x6A, 0x83.toByte())
            }
        }!!
        assertEquals(2, result.history.size)
        val first = SnapperPlusProtocol.decodeHistory(result.history[0])!!
        val second = SnapperPlusProtocol.decodeHistory(result.history[1])!!
        assertNull(first.timestampMillis); assertEquals(45L, first.counter)
        assertNotNull(second.timestampMillis); assertEquals(44L, second.counter); assertEquals(2, second.recordNumber)
        assertTrue(commands.all { it[0] == 0.toByte() && it[1] == 0xB2.toByte() })
        var calls = 0
        assertNull(SnapperPlusProtocol.read(SnapperPlusProtocol.APPLICATION_AID, byteArrayOf(0x69, 0x82.toByte()), byteArrayOf()) { calls++; byteArrayOf() })
        assertNull(SnapperPlusProtocol.read(SnapperPlusProtocol.APPLICATION_AID, selection(), byteArrayOf(0x69, 0x82.toByte())) { calls++; byteArrayOf() })
        assertNull(SnapperPlusProtocol.read(SnapperPlusProtocol.APPLICATION_AID, selection(8), byteArrayOf()) { calls++; byteArrayOf() })
        assertEquals(0, calls)
    }

    @Test fun malformedOrConflictingPurseMetadataCannotIdentifyIssuer() {
        val fci = selection().dropLast(2).toByteArray()
        assertEquals(2, SnapperPlusProtocol.purseIssuer(fci))
        assertNull(SnapperPlusProtocol.purseIssuer(fci.copyOf(fci.size - 1)))
        assertNull(SnapperPlusProtocol.purseIssuer(fci + fci))
        assertNull(SnapperPlusProtocol.purseIssuer(byteArrayOf(0xB0.toByte(), 4, 0, 0, 0, 2)))
    }

    @Test fun purseSerialMatchesIPhoneCSNOnlyFromCompleteUnambiguousMetadata() {
        val fci = selection().dropLast(2).toByteArray()
        byteArrayOf(1, 2, 3, 4, 0xA5.toByte(), 0xB6.toByte(), 0xC7.toByte(), 0xD8.toByte()).copyInto(fci, 8)
        assertEquals("0102 0304 A5B6 C7D8", SnapperPlusProtocol.purseSerial(fci))
        assertNull(SnapperPlusProtocol.purseSerial(fci.copyOf(fci.size - 1)))
        assertNull(SnapperPlusProtocol.purseSerial(fci + fci))
        assertNull(SnapperPlusProtocol.purseSerial(byteArrayOf(0xB0.toByte(), 12) + ByteArray(12)))
    }

    @Test fun movingRingSlotsDeduplicateAndLaterTripEnrichesWithoutCounterCollisionLoss() {
        fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02X".format(it) }
        val oldAmount = hex(SnapperPlusProtocol.encodeHistory(transaction(), null, 1)!!)
        val movedAmount = hex(SnapperPlusProtocol.encodeHistory(transaction(), null, 2)!!)
        val movedPair = hex(SnapperPlusProtocol.encodeHistory(transaction(), trip(), 2)!!)
        val differentPayloadSameCounter = hex(SnapperPlusProtocol.encodeHistory(transaction(cost = 999), null, 3)!!)
        assertEquals(listOf(movedAmount), SnapperPlusProtocol.mergeHistory(listOf(movedAmount, oldAmount)))
        assertEquals(listOf(movedPair), SnapperPlusProtocol.mergeHistory(listOf(movedPair, oldAmount)))
        assertEquals(listOf(movedPair), SnapperPlusProtocol.mergeHistory(listOf(movedAmount, movedPair)))
        assertEquals(listOf(movedPair), SnapperPlusProtocol.mergeHistory(listOf(oldAmount, movedPair)))
        assertEquals(listOf(movedPair, differentPayloadSameCounter),
            SnapperPlusProtocol.mergeHistory(listOf(movedPair, differentPayloadSameCounter, oldAmount)))
        assertEquals(listOf("future-envelope", movedPair), SnapperPlusProtocol.mergeHistory(listOf("future-envelope", oldAmount, movedPair)))
        val ambiguousBytes = trip("20260405023000")
        val ambiguousEnvelope = SnapperPlusProtocol.encodeHistory(transaction(), ambiguousBytes, 1)!!
        val ambiguous = hex(ambiguousEnvelope)
        assertNull(SnapperPlusProtocol.decodeHistory(ambiguousEnvelope)!!.timestampMillis)
        assertArrayEquals(ambiguousBytes, SnapperPlusProtocol.decodeHistory(ambiguousEnvelope)!!.tripBytes)
        assertEquals(listOf(ambiguous), SnapperPlusProtocol.mergeHistory(listOf(oldAmount, ambiguous)))
        assertEquals(listOf(movedPair), SnapperPlusProtocol.mergeHistory(listOf(ambiguous, movedPair)))
    }
}
