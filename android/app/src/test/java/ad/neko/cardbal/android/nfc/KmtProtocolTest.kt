package ad.neko.cardbal.android.nfc

import org.junit.Assert.*
import org.junit.Test

class KmtProtocolTest {
    private val idm = ByteArray(8) { (it + 1).toByte() }

    private fun polling(system: ByteArray = byteArrayOf(0x90.toByte(), 0xB7.toByte())) =
        byteArrayOf(20, 1, *idm, *ByteArray(8), *system)

    private fun response(data: ByteArray, address: ByteArray = idm) =
        byteArrayOf(29, 7, *address, 0, 0, 1, *data)

    private fun failure() = byteArrayOf(12, 7, *idm, 1, 0)

    private fun balance() = ByteArray(16).also {
        it[0] = 4; it[1] = 3; it[2] = 2; it[3] = 1
        it[7] = 0x80.toByte()
        it[13] = 1; it[14] = 2; it[15] = 3
    }

    @Test fun positiveSelectionReadsOnlyKmtServicesWithTheirWireByteOrder() {
        val commands = mutableListOf<ByteArray>()
        val number = "KMT-TEST-0001".toByteArray().copyOf(16)
        val history = ByteArray(16).also { it[4] = 1 }
        val replies = ArrayDeque(listOf(polling(), response(balance()), response(number),
            response(ByteArray(16)), response(history), failure()))
        val protocol = FeliCaProtocol(ByteArray(8)) { commands.add(it); replies.removeFirst() }
        val card = KmtProtocol.read(protocol::polling, protocol::readWithoutEncryption)!!
        assertArrayEquals(byteArrayOf(6, 0, 0x90.toByte(), 0xB7.toByte(), 1, 0), commands[0])
        assertArrayEquals(byteArrayOf(0x17, 0x10), commands[1].copyOfRange(11, 13))
        assertArrayEquals(byteArrayOf(0x0B, 0x30), commands[2].copyOfRange(11, 13))
        assertArrayEquals(byteArrayOf(0x0F, 0x20), commands[3].copyOfRange(11, 13))
        assertArrayEquals(idm, commands[1].copyOfRange(2, 10))
        assertEquals(0x01020304L, card.balance.amountIdr)
        assertEquals(0x80000000L, card.balance.lastTransactionAmountIdr)
        assertEquals(0x010203, card.balance.transactionCounter)
        assertEquals("KMT-TEST-0001", card.cardNumber)
        assertEquals(1, card.historyBlocks.size)
        assertArrayEquals(history, card.historyBlocks.single())
    }

    @Test fun wrongSystemCannotReadOrIdentifyKmt() {
        var exchanges = 0
        val protocol = FeliCaProtocol(idm) { exchanges++; polling(byteArrayOf(0, 3)) }
        assertNull(KmtProtocol.read(protocol::polling, protocol::readWithoutEncryption))
        assertEquals(1, exchanges)
    }

    @Test fun rejectsWrongCardErrorStatusesTruncationExtraBytesAndInvalidFraming() {
        val valid = response(balance())
        val replies = listOf(
            response(balance(), idm.copyOf().also { it[0] = 99 }),
            valid.copyOf().also { it[10] = 1 },
            valid.copyOf().also { it[11] = 1 },
            valid.copyOf().also { it[12] = 2 },
            valid.copyOf().also { it[0] = 28 },
            valid.copyOf().also { it[1] = 6 },
            valid.copyOf(28), valid + byteArrayOf(0),
        )
        for (invalid in replies) {
            var exchanges = 0
            val protocol = FeliCaProtocol(idm) { if (++exchanges == 1) polling() else invalid }
            assertNull(KmtProtocol.read(protocol::polling, protocol::readWithoutEncryption))
            assertEquals(2, exchanges)
        }
    }

    @Test fun unsignedBalanceDoesNotWrapAndRequiresExactlyOneFullBlock() {
        val high = ByteArray(16) { 0xff.toByte() }
        val parsed = KmtProtocol.parseBalance(high)!!
        assertEquals(4_294_967_295L, parsed.amountIdr)
        assertEquals(4_294_967_295L, parsed.lastTransactionAmountIdr)
        assertEquals(16_777_215, parsed.transactionCounter)
        for (size in listOf(0, 3, 15, 17, 32)) assertNull(KmtProtocol.parseBalance(ByteArray(size)))
        assertEquals(0L, KmtProtocol.parseBalance(ByteArray(16))!!.amountIdr)
    }

    @Test fun optionalIdentifierAndHistoryFailuresDoNotEraseAValidBalance() {
        val replies = ArrayDeque(listOf(polling(), response(balance()), failure(), failure()))
        val protocol = FeliCaProtocol(idm) { replies.removeFirst() }
        val card = KmtProtocol.read(protocol::polling, protocol::readWithoutEncryption)!!
        assertEquals(0x01020304L, card.balance.amountIdr)
        assertNull(card.cardNumber)
        assertTrue(card.historyBlocks.isEmpty())
    }

    @Test fun onlyPrintableCompleteIdentifiersBecomeCardNumbers() {
        assertEquals("TEST KMT", KmtProtocol.identifier("TEST KMT".toByteArray().copyOf(16)))
        assertNull(KmtProtocol.identifier(ByteArray(16)))
        assertNull(KmtProtocol.identifier(ByteArray(15)))
        assertNull(KmtProtocol.identifier(ByteArray(17)))
        assertNull(KmtProtocol.identifier(ByteArray(16) { 0xff.toByte() }))
        assertNull(KmtProtocol.identifier("TEST".toByteArray().copyOf(16).also { it[2] = 1 }))
    }

    @Test fun rawHistoryIsBoundedAndDoesNotDependOnGuessedDates() {
        var historyReads = 0
        val card = KmtProtocol.read({ it == "90B7" }) { service, _ ->
            when (service) {
                KmtProtocol.BALANCE_SERVICE -> balance()
                KmtProtocol.IDENTIFIER_SERVICE -> null
                else -> ByteArray(16).also { historyReads++; it[15] = 1 }
            }
        }!!
        assertEquals(KmtProtocol.HISTORY_READ_LIMIT, historyReads)
        assertEquals(KmtProtocol.HISTORY_READ_LIMIT, card.historyBlocks.size)
    }
}
