package ad.neko.cardbal.android.nfc

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

/** Invented responses exercise the production wire protocol without an NFC device. */
class ClipperDesfireProtocolTest {
    private fun bytes(value: String) = value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun hex(data: ByteArray) = data.joinToString("") { "%02X".format(it) }
    private fun ok(data: ByteArray = byteArrayOf()) = data + bytes("9100")
    private fun session(vararg exchanges: Pair<String, ByteArray>): Pair<ClipperDesfireProtocol, () -> Unit> {
        val pending = exchanges.toMutableList()
        val reader = ClipperDesfireProtocol { command ->
            assertTrue("Unexpected APDU ${hex(command)}", pending.isNotEmpty())
            val (expected, reply) = pending.removeAt(0)
            assertEquals(expected, hex(command))
            reply
        }
        return reader to { assertTrue("Unconsumed APDUs", pending.isEmpty()) }
    }

    @Test fun exactSelectDataRecordsAndChainingUseWireOrderAndEmptyContinuation() {
        val (reader, complete) = session(
            "905A0000039011F200" to ok(),
            "90F50000010800" to ok(bytes("0000EEEE050000")),
            "90BD0000070800000000000000" to (bytes("0012") + bytes("91AF")),
            "90AF000000" to ok(bytes("345678")),
            "90F50000010400" to ok(bytes("0400EEEE200000060000010000")),
            "90BB0000070400000000000000" to ok(ByteArray(32) { it.toByte() }),
        )
        reader.select(bytes("9011F2"))
        assertArrayEquals(bytes("0012345678"), reader.readFile(8))
        assertArrayEquals(ByteArray(32) { it.toByte() }, reader.readFile(4))
        complete()
    }

    @Test fun emptyFilesDoNotIssueDataReadsAndBackupFilesUseReadData() {
        val (reader, complete) = session(
            "90F50000010100" to ok(bytes("0000EEEE000000")),
            "90F50000010200" to ok(bytes("0100EEEE020000")),
            "90BD0000070200000000000000" to ok(bytes("1234")),
        )
        assertTrue(reader.readFile(1).isEmpty())
        assertArrayEquals(bytes("1234"), reader.readFile(2))
        complete()
    }

    @Test fun strictStatusesTruncationEmptyContinuationAndSelectBodiesAreRejected() {
        for (bad in listOf(bytes(""), bytes("91"), bytes("9000"), bytes("919D"), bytes("919E"), bytes("91AF"))) {
            val reader = ClipperDesfireProtocol { bad }
            assertThrows(IOException::class.java) { reader.command(0xBD) }
        }
        val badSelect = ClipperDesfireProtocol { ok(bytes("01")) }
        assertThrows(IOException::class.java) { badSelect.select(bytes("9011F2")) }
        for (size in listOf(0, 1, 19, 21)) {
            val (reader, complete) = session(
                "90F50000010200" to ok(bytes("0000EEEE140000")),
                "90BD0000070200000000000000" to ok(ByteArray(size)),
            )
            assertThrows(IOException::class.java) { reader.readFile(2) }
            complete()
        }
    }

    @Test fun chainsHaveBothByteAndFrameBoundsAndDoNotReturnPartialFailureData() {
        var calls = 0
        val endless = ClipperDesfireProtocol { calls++; bytes("0191AF") }
        assertThrows(IOException::class.java) { endless.command(0xBD) }
        assertEquals(256, calls)
        val large = ClipperDesfireProtocol { ok(ByteArray(8193)) }
        assertThrows(IOException::class.java) { large.command(0xBD) }
        val exact = ClipperDesfireProtocol { ok(ByteArray(8192)) }
        assertEquals(8192, exact.command(0xBD).size)
        val (partial, complete) = session(
            "90BD000000" to bytes("010291AF"),
            "90AF000000" to bytes("0304919D"),
        )
        assertThrows(IOException::class.java) { partial.command(0xBD) }
        complete()
    }

    @Test fun malformedSettingsProtectedModesCountsAndOversizedFilesAreRejectedBeforeRead() {
        for (settings in listOf("", "0000EEEE0100", "0003EEEE010000", "0000EEEEFFFFFF",
            "0400EEEE1F0000010000010000", "0400EEEE200000010000020000",
            "0400EEEE200000FFFFFF010100", "0200EEEE010000", "0400EEEE200000")) {
            val (reader, complete) = session("90F50000010800" to ok(bytes(settings)))
            assertThrows(IOException::class.java) { reader.readFile(8) }
            complete()
        }
    }

    @Test fun invalidArgumentsAndWriteAuthenticationCommandsNeverReachTheTransport() {
        val reader = ClipperDesfireProtocol { throw AssertionError("Unsafe command reached transport") }
        for (command in listOf(0x0A, 0xAA, 0x3D, 0x3B, 0x0C, 0xDC, 0xC4, 0xFC)) {
            assertThrows(IOException::class.java) { reader.command(command) }
        }
        for (size in listOf(0, 2, 4)) assertThrows(IOException::class.java) { reader.select(ByteArray(size)) }
        for (number in listOf(-1, 256)) assertThrows(IOException::class.java) { reader.readFile(number) }
        assertThrows(IOException::class.java) { reader.command(0xBD, ByteArray(256)) }
    }
}
