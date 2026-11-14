package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransitApplication
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ChineseLocalDecoderTest {
    private val fixture = Json.parseToJsonElement(javaClass.getResource("/china_local_synthetic.json")!!.readText()).jsonObject
    private val success = "9000".hexToBytes()
    private val missing = "6A82".hexToBytes()

    @Test fun balancesPreserveZeroFlagsAndSignedOverdrafts() {
        fixture.getValue("balances").jsonArray.forEach {
            val c = it.jsonObject
            assertEquals(c.toString(), c["minor"]!!.jsonPrimitive.longOrNull,
                ChineseLocalProtocol.balanceMinor(c["hex"]!!.jsonPrimitive.content.hexToBytes()))
        }
    }

    @Test fun historiesKeepExactCurrencySignsTimestampsAndUnknownAmounts() {
        fixture.getValue("histories").jsonArray.forEach {
            val c = it.jsonObject
            val tx = ChineseLocalDecoder.decodeRecord(c["hex"]!!.jsonPrimitive.content.hexToBytes())
            if (c["invalid"]?.jsonPrimitive?.booleanOrNull == true) assertNull(tx)
            else {
                assertNotNull(tx)
                assertEquals(c["amount"]!!.jsonPrimitive.longOrNull ?: 0, tx!!.amount)
                assertEquals(c["amount"]!!.jsonPrimitive.longOrNull != null, tx.amountKnown)
                assertEquals("CNY", tx.currencyCode)
                assertEquals("Asia/Shanghai", tx.issuerTimeZone)
                assertEquals("08:30:41", tx.time)
                assertEquals(291, tx.recordNumber)
                assertNull(tx.entryStationCode); assertNull(tx.exitStationCode)
            }
        }
        assertNull(ChineseLocalDecoder.decodeRecord(ByteArray(23)))
        assertNull(ChineseLocalDecoder.decodeRecord(ByteArray(22)))
    }

    @Test fun allThreeReadersPersistTheOriginalApplicationAndHistory() {
        for (item in fixture.getValue("cards").jsonArray) {
            val c = item.jsonObject
            val aid = c["aid"]!!.jsonPrimitive.content
            val commands = mutableListOf<ByteArray>()
            fun exchange(command: ByteArray): ByteArray {
                commands.add(command.clone())
                return when (command[1].toInt() and 255) {
                    0xA4 -> if (command[2] == 4.toByte() && command.copyOfRange(5, 5 + (command[4].toInt() and 255)).hexString() == aid) success else missing
                    0x5C -> "800004D2".hexToBytes() + success
                    0xB0 -> when (command[2].toInt() and 31) {
                        c["sfi"]!!.jsonPrimitive.int -> c["info"]!!.jsonPrimitive.content.hexToBytes() + success
                        10 -> c["serialFile"]?.jsonPrimitive?.content?.hexToBytes()?.plus(success) ?: missing
                        else -> missing
                    }
                    0xB2 -> if (command[2].toInt() in 1..4)
                        fixture.getValue("histories").jsonArray[command[2].toInt() - 1].jsonObject["hex"]!!.jsonPrimitive.content.hexToBytes() + success
                        else missing
                    else -> missing
                }
            }
            val result = ChineseLocalDecoder.read("01020304", Instant.parse("2026-11-01T00:00:00Z"), ::exchange)!!
            assertEquals(c["family"]!!.jsonPrimitive.content, result.cardFamily)
            assertEquals(c["serial"]!!.jsonPrimitive.content, result.realSerialNumber)
            assertNotNull(result.balanceText)
            assertEquals(4, result.rawTransactions.size)
            val saved = Json.decodeFromString<List<TransitApplication>>(Json.encodeToString(result.applications!!))
            assertEquals(result.applications, saved)
            assertTrue(saved.single().records.all { it.sfi == 24 && it.kind == "transaction" })
            assertTrue(commands.all { (it[1].toInt() and 255) in listOf(0xA4, 0xB0, 0xB2, 0x5C) })
        }
    }

    private val ticl = ChineseLocalProtocol.LINGNAN_PURSE_AID
    private val appy = ChineseLocalProtocol.LINGNAN_INFO_AID
    /** A real PAY.TICL SELECT reply (flutter_nfc_kit issue #32). Its 9F0C is not the card details file. */
    private val ticlFci = "6f3484085041592e5449434ca5289f0801029f0c21ffffffffffffffff000000000000000000000000000000002019082400000186a0".hexToBytes()

    private fun lingnanCard(applications: Map<String, ByteArray>, balance: String, selects: MutableList<String>): (ByteArray) -> ByteArray {
        var selected = ""
        val histories = fixture.getValue("histories").jsonArray
        return { command ->
            when (command[1].toInt() and 255) {
                0xA4 -> {
                    val name = command.copyOfRange(5, 5 + (command[4].toInt() and 255)).hexString()
                    if (command[2] == 4.toByte()) selects.add(name)
                    val reply = applications[name].takeIf { command[2] == 4.toByte() }
                    if (reply != null) { selected = name; reply + success } else missing
                }
                0x5C -> if (selected == ticl) balance.hexToBytes() + success else missing
                0xB2 -> if (selected == ticl && command[2].toInt() in 1..3)
                    histories[command[2].toInt() - 1].jsonObject["hex"]!!.jsonPrimitive.content.hexToBytes() + success else missing
                else -> missing
            }
        }
    }

    @Test fun lingnanPassReadsDetailsFromAppyAndThePurseFromTicl() {
        val info = fixture.getValue("cards").jsonArray[3].jsonObject["info"]!!.jsonPrimitive.content.hexToBytes()
        val appyFci = "6F2D8408".hexToBytes() + appy.hexToBytes() + "A5219F0C1E".hexToBytes() + info
        val selects = mutableListOf<String>()
        val result = ChineseLocalDecoder.read("01020304", Instant.parse("2026-11-01T00:00:00Z"),
            lingnanCard(mapOf(appy to appyFci, ticl to ticlFci), "00000BB8" , selects))!!
        assertEquals("Lingnan Pass", result.cardFamily)
        assertEquals(ticl, result.selectedAID)
        assertEquals("Guangzhou", result.region)
        assertEquals("5123456789", result.realSerialNumber)
        assertNotNull(result.balanceText)
        assertEquals(3, result.rawTransactions.size)
        assertTrue(result.resultFields.any { it.title == "Issue Date" && it.value == "2020-01-01" })
        assertTrue(result.resultFields.any { it.title == "Expiry Date" && it.value == "2030-12-31" })
        assertEquals(listOf("5041592E535A54", "4150312E5748435443", appy, ticl), selects.take(4))
        assertTrue(result.applications!!.single().isLingnan)
        assertTrue(result.rawSections.first().fields.any { it.value == appyFci.hexString() })
        val saved = Json.decodeFromString<List<TransitApplication>>(Json.encodeToString(result.applications!!))
        assertEquals(result.applications, saved)
    }

    @Test fun ticlReplyAloneGivesTheBalanceButNoInventedDetails() {
        val selects = mutableListOf<String>()
        val result = ChineseLocalDecoder.read("01020304", Instant.parse("2026-11-01T00:00:00Z"),
            lingnanCard(mapOf(ticl to ticlFci), "000186A0", selects))!!
        assertEquals("Lingnan Pass", result.cardFamily)
        assertEquals(ticl, result.selectedAID)
        assertNull(result.realSerialNumber)
        assertFalse(result.resultFields.any { it.title == "Issue Date" || it.title == "Expiry Date" })
        assertNull(ChineseLocalDecoder.read("01020304", Instant.parse("2026-11-01T00:00:00Z"),
            lingnanCard(mapOf(ticl to ticlFci), "FFFFFFFF", mutableListOf())))
    }

    @Test fun beijingCanReadMetadataFromMasterFileAndHistoryByPath() {
        val c = fixture.getValue("cards").jsonArray[2].jsonObject
        var selected = ""
        val result = ChineseLocalProtocol.read { command ->
            val instruction = command[1].toInt() and 255
            if (instruction == 0xA4) {
                val name = command.copyOfRange(5, 5 + command[4]).hexString()
                selected = when {
                    command[2] == 4.toByte() && name == "4F43" -> "app"
                    command[2] == 0.toByte() && name == "1001" -> "purse"
                    command[2] == 0.toByte() && name == "3F00" -> "mf"
                    command[2] == 8.toByte() && name == "10010018" -> "log"
                    else -> ""
                }
                if (selected.isNotEmpty()) success else missing
            } else when {
                instruction == 0x5C && selected == "purse" -> "000004D29000".hexToBytes()
                instruction == 0xB0 && command[2] == 0x84.toByte() && selected == "mf" ->
                    c["info"]!!.jsonPrimitive.content.hexToBytes() + success
                instruction == 0xB2 && command[2] == 1.toByte() && command[3] == 4.toByte() && selected == "log" ->
                    fixture.getValue("histories").jsonArray[0].jsonObject["hex"]!!.jsonPrimitive.content.hexToBytes() + success
                else -> missing
            }
        }!!
        assertEquals(c["serial"]!!.jsonPrimitive.content, result.serial)
        assertEquals(1234L, result.balanceMinor)
        assertEquals(1, result.records.size)
    }

    @Test fun responseProceduresAreBoundedAndBeijingNeedsCorroboratingMetadata() {
        val aid = ChineseLocalProtocol.Kind.Shenzhen.aids.single()
        var corrected = false; var continuation = false
        val result = ChineseLocalProtocol.read { command ->
            when (command[1].toInt() and 255) {
                0xA4 -> if (command[2] == 4.toByte() && command.copyOfRange(5, 5 + command[4]).hexString() == aid) success else missing
                0x5C -> if (!corrected) { corrected = true; "6C04".hexToBytes() }
                    else { continuation = true; "00006102".hexToBytes() }
                0xC0 -> "04D29000".hexToBytes()
                else -> missing
            }
        }!!
        assertEquals(1234L, result.balanceMinor)
        assertTrue(corrected && continuation)
        assertNull(ChineseLocalProtocol.read { "000004D29001".hexToBytes() })
        var requests = 0
        assertNull(ChineseLocalProtocol.read { requests++; "6100".hexToBytes() })
        assertTrue(requests <= 6 * 16)
        assertNull(ChineseLocalProtocol.read { command ->
            when (command[1].toInt() and 255) {
                0xA4 -> if (command[2] == 4.toByte() && command[4] <= 4.toByte()) success else missing
                0x5C -> "000004D29000".hexToBytes()
                else -> missing
            }
        })
        assertNull(ChineseLocalProtocol.read { command -> if (command[1] == 0xA4.toByte()) success else missing })
    }
}
