package ad.neko.cardbal.android.nfc

import java.io.File
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class StoredValueProtocolTest {
    private fun bytes(hex: String) = hex.chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun allFiveLayoutsUseTheSameInventedFilesAndEnvelopeContractAsSwift() {
        val root = generateSequence(File(System.getProperty("user.dir"))) { it.parentFile }
            .first { File(it, "tests/runtime/fixtures/desfire_vectors.json").isFile }
        val document = Json.parseToJsonElement(File(root, "tests/runtime/fixtures/desfire_vectors.json").readText()).jsonObject
        for (element in document["vectors"]!!.jsonArray) {
            val vector = element.jsonObject
            val tag = vector["tag"]!!.jsonPrimitive.int
            val files = vector["files"]!!.jsonObject.mapKeys { it.key.toInt() }.mapValues { bytes(it.value.jsonPrimitive.content) }
            val sizes = vector["recordSizes"]!!.jsonObject.mapKeys { it.key.toInt() }.mapValues { it.value.jsonPrimitive.int }
            val card = StoredValueProtocol.parseFiles(tag, files, sizes)!!
            val expected = vector["expected"]!!.jsonObject
            assertEquals(expected["family"]!!.jsonPrimitive.content, card.family)
            assertEquals(expected["currency"]!!.jsonPrimitive.content, card.currencyCode)
            assertEquals(expected["balance"]!!.jsonPrimitive.long, card.balanceMinor)
            assertEquals(expected["serial"]!!.jsonPrimitive.content, card.serial)
            val events = StoredValueProtocol.parseHistories(card.rawTransactions, card.family)
            assertEquals(expected["histories"]!!.jsonPrimitive.int, events.size)
            assertEquals(expected["passes"]!!.jsonPrimitive.int, card.passes.size)
            if (tag in 2..4) {
                assertTrue(events.filter { it.kind == "reload" }.all { it.balanceMinor == null })
                val changedPurse = files.getValue(2).copyOf().also { it[0] = (it[0].toInt() xor 1).toByte() }
                val repeatSummary = StoredValueProtocol.envelope(tag, 2, 0, changedPurse)
                assertEquals(events.size, StoredValueProtocol.parseHistories(card.rawTransactions + repeatSummary).size)
            }
            assertTrue(events.any { it.dateEpochSeconds == expected["date"]!!.jsonPrimitive.long && it.amountMinor == expected["amount"]!!.jsonPrimitive.longOrNull })
            assertTrue(StoredValueProtocol.parseHistories(card.rawTransactions, "Other").isEmpty())
            for (raw in card.rawTransactions) {
                assertNull(StoredValueProtocol.parseHistory(raw + "00"))
                assertNull(StoredValueProtocol.parseHistory("00" + raw))
                assertNull(StoredValueProtocol.parseHistory(raw.dropLast(2)))
            }
        }
    }

    @Test fun nativeAndWrappedChainingAreExplicitAndBounded() {
        for (mode in DesfireReadSession.WireMode.entries) {
            val calls = mutableListOf<ByteArray>()
            val session = DesfireReadSession(mode) {
                calls.add(it)
                if (mode == DesfireReadSession.WireMode.NATIVE) {
                    if (calls.size == 1) byteArrayOf(0xaf.toByte(),1,2) else byteArrayOf(0,3)
                } else if (calls.size == 1) byteArrayOf(1,2,0x91.toByte(),0xaf.toByte()) else byteArrayOf(3,0x91.toByte(),0)
            }
            assertArrayEquals(byteArrayOf(1,2,3), session.command(0xbd, byteArrayOf(1)))
            assertArrayEquals(if (mode == DesfireReadSession.WireMode.NATIVE) byteArrayOf(0xaf.toByte()) else bytes("90AF000000"), calls[1])
        }
        var count = 0
        val endless = DesfireReadSession(DesfireReadSession.WireMode.WRAPPED) { count++; bytes("91AF") }
        assertThrows(DesfireReadException::class.java) { endless.command(0x60) }
        assertEquals(64, count)
    }

    @Test fun aidOrderMatchesPublishedWireBytesAndWriteCommandsNeverReachTransport() {
        val calls = mutableListOf<ByteArray>()
        val session = DesfireReadSession(DesfireReadSession.WireMode.WRAPPED) { calls.add(it); bytes("9100") }
        for ((aid, wire) in listOf(0x534531 to "314553", 0xef2011 to "1120EF", 0xef2014 to "1420EF", 0xab1000 to "0010AB", 0xf21190 to "9011F2")) {
            session.selectApplication(aid)
            assertArrayEquals(bytes("905A000003${wire}00"), calls.last())
        }
        assertThrows(DesfireReadException::class.java) { session.command(0x3d, byteArrayOf(1,2)) }
        assertEquals(5, calls.size)
    }

    @Test fun statusesFramingProtectedFilesAndReadLengthsAreStrict() {
        for (bad in listOf(byteArrayOf(), bytes("91"), bytes("9000"), bytes("01919D"))) {
            val session = DesfireReadSession(DesfireReadSession.WireMode.WRAPPED) { bad }
            assertThrows(DesfireReadException::class.java) { session.command(0x60) }
        }
        for (settings in listOf("00030000100000", "040000000C0000010000020000", "00000000010001")) {
            val session = DesfireReadSession(DesfireReadSession.WireMode.WRAPPED) {
                assertEquals(0xf5, it[1].toInt() and 255)
                bytes(settings + "9100")
            }
            assertThrows(DesfireReadException::class.java) { session.readFile(1) }
        }
        val truncated = DesfireReadSession(DesfireReadSession.WireMode.WRAPPED) {
            if ((it[1].toInt() and 255) == 0xf5) bytes("0000EEEE1000009100") else ByteArray(15) + bytes("9100")
        }
        assertThrows(DesfireReadException::class.java) { truncated.readFile(7) }
    }

    @Test fun recordFilesUseReadRecordsAndCheckSettingsCounts() {
        val session = DesfireReadSession(DesfireReadSession.WireMode.WRAPPED) {
            if ((it[1].toInt() and 255) == 0xf5) bytes("0400EEEE0C00000200000200009100")
            else { assertEquals(0xbb, it[1].toInt() and 255); ByteArray(24) + bytes("9100") }
        }
        val file = session.readFile(4)
        assertEquals(12, file.recordSize)
        assertEquals(24, file.data.size)
    }

    @Test fun noIdOnlySupportNoGuessedDatesAndNoInvalidEnvelopeAcceptance() {
        var selections = 0
        val card = StoredValueProtocol.readFirst(DesfireReadSession.WireMode.WRAPPED) {
            if ((it[1].toInt() and 255) == 0x5a) { selections++; bytes("9100") } else bytes("91F0")
        }
        assertNull(card); assertEquals(5, selections)
        assertNull(StoredValueProtocol.parseFiles(5, mapOf(8 to byteArrayOf(0,1,2,3,4))))
        assertNull(StoredValueProtocol.parseFiles(1, mapOf(7 to ByteArray(15))))
        assertNull(StoredValueProtocol.parseHistory("not hex"))
        assertNull(StoredValueProtocol.localTime(2023, 84, 210, "Europe/Helsinki"))
        assertNull(StoredValueProtocol.localTime(2023, 301, 210, "Europe/Helsinki"))
        assertNull(StoredValueProtocol.localTime(1997, 1, 1440, "Europe/Helsinki"))
    }
}
