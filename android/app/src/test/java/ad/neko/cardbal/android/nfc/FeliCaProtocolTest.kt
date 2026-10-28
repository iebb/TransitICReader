package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexToBytes
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException

class FeliCaProtocolTest {
    private val firstIdm = "0102030405060708".hexToBytes()
    private val otherIdm = "2102030405060708".hexToBytes()

    private fun pollingResponse(idm: ByteArray, system: String) =
        byteArrayOf(20, 1, *idm, *ByteArray(8), *system.hexToBytes())

    private fun readResponse(idm: ByteArray, data: ByteArray = ByteArray(16) { it.toByte() }) =
        byteArrayOf(29, 7, *idm, 0, 0, 1, *data)

    @Test fun secondSystemReadUsesTheIdmReturnedByItsPollingResponse() {
        val commands = mutableListOf<ByteArray>()
        val replies = ArrayDeque(listOf(
            pollingResponse(firstIdm, "0003"), readResponse(firstIdm),
            pollingResponse(otherIdm, "FE00"), readResponse(otherIdm),
        ))
        val protocol = FeliCaProtocol(firstIdm) { commands.add(it); replies.removeFirst() }
        assertTrue(protocol.polling("0003"))
        assertNotNull(protocol.readWithoutEncryption("8B00", 0))
        assertTrue(protocol.polling("FE00"))
        assertNotNull(protocol.readWithoutEncryption("1713", 0))
        assertArrayEquals(otherIdm, commands.last().copyOfRange(2, 10))
        assertArrayEquals(otherIdm, protocol.idm)
        assertArrayEquals("1713".hexToBytes(), commands.last().copyOfRange(11, 13))
    }

    @Test fun failedPollingCannotReuseAnOldSelection() {
        var exchanges = 0
        val protocol = FeliCaProtocol(firstIdm) {
            if (++exchanges == 1) pollingResponse(firstIdm, "0003") else byteArrayOf(2, 0xFF.toByte())
        }
        assertTrue(protocol.polling("0003"))
        assertFalse(protocol.polling("FE00"))
        assertNull(protocol.readWithoutEncryption("1713", 0))
        assertEquals(2, exchanges)
    }

    @Test fun malformedOrWrongSystemPollingResponsesAreRejected() {
        val responses = listOf(
            pollingResponse(otherIdm, "0003"), // wrong requested system
            pollingResponse(otherIdm, "FE00").copyOf(10),
            pollingResponse(otherIdm, "FE00").also { it[0] = 19 },
            pollingResponse(otherIdm, "FE00").also { it[1] = 3 },
        )
        for (response in responses) {
            val protocol = FeliCaProtocol(firstIdm) { response }
            assertFalse(protocol.polling("FE00"))
            assertArrayEquals(firstIdm, protocol.idm)
            assertNull(protocol.readWithoutEncryption("1713", 0))
        }
    }

    @Test fun rejectsWrongCardTruncatedAndUnsuccessfulReadResponses() {
        val responses = listOf(
            readResponse(otherIdm),
            readResponse(firstIdm).copyOf(28),
            readResponse(firstIdm).also { it[10] = 1 },
            readResponse(firstIdm).also { it[12] = 2 },
        )
        for (response in responses) {
            var calls = 0
            val protocol = FeliCaProtocol(firstIdm) {
                if (++calls == 1) pollingResponse(firstIdm, "0003") else response
            }
            assertTrue(protocol.polling("0003"))
            assertNull(protocol.readWithoutEncryption("8B00", 0))
        }
    }

    @Test fun systemCodeRequestsUseTheNewSystemAddress() {
        val commands = mutableListOf<ByteArray>()
        val replies = ArrayDeque(listOf(
            pollingResponse(otherIdm, "FE00"),
            byteArrayOf(15, 0x0D, *otherIdm, 2, 0, 3, 0xFE.toByte(), 0),
        ))
        val protocol = FeliCaProtocol(firstIdm) { commands.add(it); replies.removeFirst() }
        assertTrue(protocol.polling("FE00"))
        assertEquals(listOf("0003", "FE00"), protocol.requestSystemCodes())
        assertArrayEquals(otherIdm, commands.last().copyOfRange(2, 10))
    }

    @Test fun ioFailuresAndInvalidInputDoNotProduceData() {
        val protocol = FeliCaProtocol(firstIdm) { throw IOException("synthetic tag loss") }
        assertFalse(protocol.polling("FE00"))
        assertFalse(protocol.polling("NOTHEX"))
        assertNull(protocol.readWithoutEncryption("1713", 0))
    }
}
