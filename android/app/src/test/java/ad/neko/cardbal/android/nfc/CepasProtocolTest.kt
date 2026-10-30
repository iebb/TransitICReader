package ad.neko.cardbal.android.nfc

import org.junit.Assert.*
import org.junit.Test

/** All bytes are invented fixtures, not reference-project captures. */
class CepasProtocolTest {
    private fun purse(prefix: Int = 0x11, history: Int = 3) = ByteArray(63).also {
        it[0] = 2; it[1] = 1; it[2] = -1; it[3] = -1; it[4] = 0x9C.toByte()
        byteArrayOf(prefix.toByte(), if (prefix == 0x11) 0x10 else 0, 0x12, 0x34, 0x56, 0x78, 0x90.toByte(), 0x12).copyInto(it, 8)
        it[40] = history.toByte()
    }
    private fun record(type: Int = 0x30, amount: Int = -275, seconds: Long = 1_000_000_000) = ByteArray(16).also {
        it[0] = type.toByte()
        repeat(3) { i -> it[i+1] = (amount ushr (16-i*8)).toByte() }
        repeat(4) { i -> it[i+4] = (seconds ushr (24-i*8)).toByte() }
        "ABC-DEF ".toByteArray().copyInto(it, 8)
    }
    private fun ok(bytes: ByteArray) = bytes + byteArrayOf(0x90.toByte(), 0)
    private fun ByteArray.hex() = joinToString("") { "%02X".format(it) }

    @Test fun purseIdentityAndSignedWholeCentsRequireCompleteKnownCan() {
        val value = CepasProtocol.parsePurse(purse())!!
        assertEquals("NETS FlashPay", value.family)
        assertEquals("1110123456789012", value.serial)
        assertEquals(-100L, value.balanceMinor)
        assertEquals("EZ-Link", CepasProtocol.parsePurse(purse(0x10))!!.family)
        for (bad in listOf(ByteArray(0), purse().copyOf(62), purse().copyOf(257),
            purse().also { it[8] = 0x80.toByte() }, purse().also { it[10] = 0xA0.toByte() },
            purse().also { it[41] = 1 })) assertNull(CepasProtocol.parsePurse(bad))
    }

    @Test fun realTypesEpochSigned24AndUserDataSurviveVersionedEnvelope() {
        assertEquals("1994-12-31T16:00:00Z", java.time.Instant.ofEpochSecond(CepasProtocol.EPOCH_SECONDS).toString())
        val bytes = CepasProtocol.encodeHistory(record())!!
        val value = CepasProtocol.decodeHistory(bytes)!!
        assertEquals(21, bytes.size)
        assertEquals(-275L, value.amountMinor)
        assertEquals(CepasProtocol.Kind.Train, value.kind)
        assertEquals("ABC-DEF", value.userData)
        assertEquals(1_788_889_600L, value.epochSeconds)
        assertEquals(CepasProtocol.Kind.TopUp, CepasProtocol.decodeHistory(CepasProtocol.encodeHistory(record(3, 1000))!!)!!.kind)
        assertEquals(275L, CepasProtocol.decodeHistory(CepasProtocol.encodeHistory(record(0x76, 275))!!)!!.amountMinor)
        assertFalse(CepasProtocol.decodeHistory(CepasProtocol.encodeHistory(record(0xF0))!!)!!.hasMonetaryAmount)
        assertEquals(CepasProtocol.Kind.Unknown, CepasProtocol.decodeHistory(CepasProtocol.encodeHistory(record(0xA0))!!)!!.kind)
        assertEquals(2_936_373_248L, CepasProtocol.decodeHistory(CepasProtocol.encodeHistory(record(seconds = 0x80000000))!!)!!.epochSeconds)
        assertNull(CepasProtocol.decodeHistory(CepasProtocol.encodeHistory(record(seconds = 0))!!)!!.epochSeconds)
        for (bad in listOf(bytes.copyOf(20), bytes + byteArrayOf(0), bytes.clone().also { it[3] = 2 })) assertNull(CepasProtocol.decodeHistory(bad))
        assertNull(CepasProtocol.encodeHistory(ByteArray(16)))
        assertNull(CepasProtocol.encodeHistory(ByteArray(16) { -1 }))
    }

    @Test fun onlyImplicitReadCommandsUseActualPageOffsets() {
        val commands = mutableListOf<String>()
        val card = CepasProtocol.read { command ->
            commands.add(command.hex())
            when (commands.size) {
                1 -> ok(purse())
                2 -> ok(record() + record(0x31, -125))
                3 -> ok(record(0x75, 1000))
                else -> error("unexpected")
            }
        }!!
        assertEquals(listOf("9032030000", "90320300010000", "90320300010200"), commands)
        assertEquals(3, card.rawHistory.size)
        assertTrue(card.historyComplete)
        assertEquals("Asia/Singapore", CepasProtocol.ISSUER_TIME_ZONE)
    }

    @Test fun retriesCorrectLeOnceAndRequiresExact9000IncludingFinalChainStatus() {
        val commands = mutableListOf<ByteArray>()
        val corrected = CepasProtocol.read { command ->
            commands.add(command)
            if (commands.size == 1) byteArrayOf(0x6C, 63) else ok(purse(history = 0))
        }
        assertNotNull(corrected)
        assertEquals(63, commands[1].last().toInt())
        commands.clear()
        val chained = CepasProtocol.read { command ->
            commands.add(command)
            if (commands.size == 1) purse(history = 0).copyOfRange(0, 20) + byteArrayOf(0x61, 43)
            else ok(purse(history = 0).copyOfRange(20, 63))
        }
        assertNotNull(chained)
        assertEquals("00C000002B", commands[1].hex())
        for (bad in listOf(byteArrayOf(), byteArrayOf(0x90.toByte()), byteArrayOf(0x91.toByte(), 0),
            byteArrayOf(0x90.toByte(), 1), purse() + byteArrayOf(0x69, 0x82.toByte()))) {
            var calls = 0
            assertNull(CepasProtocol.read { calls++; bad })
            assertEquals(1, calls)
        }
        var calls = 0
        assertNull(CepasProtocol.read { calls++; byteArrayOf(0x6C, 63) })
        assertEquals(2, calls)
        calls = 0
        assertNull(CepasProtocol.read { calls++; byteArrayOf(0x61, 1) })
        assertEquals(16, calls)
    }

    @Test fun optionalUnavailableOrMalformedHistoryPreservesValidatedBalance() {
        for (bad in listOf(byteArrayOf(0x69, 0x82.toByte()), ok(ByteArray(17)))) {
            var count = 0
            val card = CepasProtocol.read { if (++count == 1) ok(purse()) else bad }!!
            assertEquals(-100L, card.balanceMinor)
            assertFalse(card.historyComplete)
            assertTrue(card.rawHistory.isEmpty())
        }
        var calls = 0
        val empty = CepasProtocol.read { calls++; ok(purse(history = 0)) }!!
        assertTrue(empty.historyComplete)
        assertEquals(1, calls)
    }
}
