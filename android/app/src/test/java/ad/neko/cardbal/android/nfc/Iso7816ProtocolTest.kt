package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexToBytes
import ad.neko.cardbal.android.data.SavedCardRecord
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

class Iso7816ProtocolTest {
    @Test fun shanghaiCityUnionUsesCity2000ForItsTitleAndRegion() {
        val metadata = ByteArray(30).also {
            it[2] = 0x20; it[19] = 1
        }
        val aid = "A00000000386980701"
        val selection = Iso7816Protocol.select(aid) { "9000".hexToBytes() }!!
        val card = Iso7816Decoder().readApplication("SYNTHETIC", selection, Instant.parse("2026-11-01T00:00:00Z")) { command ->
            when (command.joinToString("") { "%02X".format(it) }) {
                "805C000204" -> "000030399000".hexToBytes()
                "00B095001E" -> metadata + "9000".hexToBytes()
                else -> if(command.contentEquals(Iso7816Protocol.selectCommand(aid))) "9000".hexToBytes() else "6A83".hexToBytes()
            }
        }!!
        assertEquals("上海市", card.region)
        assertEquals("上海市", card.resultFields.first { it.title=="Brand" }.value)
        assertEquals("上海市", card.resultFields.first { it.title=="Issuing City" }.value)
        assertEquals("2000", card.applications!!.single().cityCode)
        assertNotNull(card.balanceText)
        assertEquals("上海市", SavedCardRecord.from(card).displayTitle)
    }

    @Test fun koreanAndChineseBalancesUseTheirOwnReadOnlyCommands() {
        Iso7816Protocol.applications.filter { it.currency == "KRW" }.forEach {
            assertArrayEquals("904C000004".hexToBytes(), Iso7816Protocol.balanceCommand(it))
        }
        val chinese = Iso7816Protocol.applications.first { it.currency == "CNY" }
        assertArrayEquals("805C000204".hexToBytes(), Iso7816Protocol.balanceCommand(chinese))
        assertEquals(12345L, Iso7816Protocol.balanceValue("000030399000".hexToBytes()))
        assertEquals(0L, Iso7816Protocol.balanceValue("000000009000".hexToBytes()))
    }

    /** Invented bytes: SFI 4 holds two records, SFI 5 a 6282 binary block, SFI 6 a binary block behind 6C. */
    @Test fun developerModeKeepsEveryReadableKoreanBlockInRawData() {
        val aid = "D4100000030001"
        val record = ByteArray(16) { (it + 1).toByte() }
        val commands = mutableListOf<String>()
        val card: (ByteArray) -> ByteArray = { command ->
            commands.add(command.joinToString("") { "%02X".format(it) })
            val instruction = command[1].toInt() and 255
            val p1 = command[2].toInt() and 255
            val p2 = command[3].toInt() and 255
            when {
                command.contentEquals(Iso7816Protocol.selectCommand(aid)) -> "9000".hexToBytes()
                instruction == 0x4C -> "000003E89000".hexToBytes()
                instruction == 0xB2 && p2 == (4 shl 3 or 4) && p1 <= 2 -> record + "9000".hexToBytes()
                instruction == 0xB0 && p1 == 0x85 -> "0A0B6282".hexToBytes()
                instruction == 0xB0 && p1 == 0x86 && command[4] == 0.toByte() -> "6C02".hexToBytes()
                instruction == 0xB0 && p1 == 0x86 -> "0C0D9000".hexToBytes()
                else -> "6A83".hexToBytes()
            }
        }
        val selection = Iso7816Protocol.select(aid, card)!!
        val scannedAt = Instant.parse("2026-11-01T00:00:00Z")
        val plain = Iso7816Decoder().readApplication("SYNTHETIC", selection, scannedAt, card)!!
        assertTrue(plain.rawSections.none { it.title == "Developer Readable Blocks" })
        assertTrue(commands.none { it.startsWith("00B0") && it.substring(4, 6) == "85" })

        val developer = Iso7816Decoder(developerMode = true).readApplication("SYNTHETIC", selection, scannedAt, card)!!
        val section = developer.rawSections.single { it.title == "Developer Readable Blocks" }
        assertEquals(
            listOf("Readable Block Count", "SFI 04 Record 001", "SFI 04 Record 002", "SFI 05 Binary 0000", "SFI 06 Binary 0000"),
            section.fields.map { it.title },
        )
        assertEquals("4", section.fields.first().value)
        assertEquals("0102030405060708090A0B0C0D0E0F10", section.fields[1].value)
        assertEquals("0A0B", section.fields[3].value)
        assertEquals("0C0D", section.fields[4].value)
        assertEquals(plain.rawTransactions, developer.rawTransactions)
        // Read-only: only SELECT, balance, READ RECORD and READ BINARY are sent.
        assertTrue(commands.all { it.substring(2, 4) in setOf("A4", "4C", "B2", "B0") })
    }

    @Test fun rejectsFailedOrWrongLengthBalanceResponses() {
        listOf("000030396982", "0030399000", "00000030399000", "9000", "").forEach {
            assertNull(Iso7816Protocol.balanceValue(it.hexToBytes()))
        }
    }

    @Test fun configDfSelectsOnlyItsSupportedMainApplication() {
        val commands = mutableListOf<ByteArray>()
        val selection = Iso7816Protocol.select(Iso7816Protocol.CONFIGURATION_AID) {
            commands.add(it)
            if (commands.size == 1) "6F0BA5094F07D41000000300019000".hexToBytes()
            else "6F009000".hexToBytes()
        }
        assertNotNull(selection)
        assertEquals("T-money", selection!!.application.family)
        assertEquals("D4100000030001", selection.application.aid)
        assertNotNull(selection.configurationResponse)
        assertEquals(2, commands.size)
        assertArrayEquals(Iso7816Protocol.selectCommand("D4100000030001"), commands[1])
    }

    @Test fun configDfCannotMislabelUnknownOrAmbiguousApplicationsAsTransit() {
        val payloads = listOf(
            "6F004F0799000000000001", // unsupported AID
            "4F07D41000000300014F07D4100000140001", // two distinct main applications
            "4F07D410000003", // truncated value
            "6F804F07D4100000030001", // indefinite length not permitted
            "6FFF", // invalid BER length
            "", // no main application
        )
        for (payload in payloads) {
            var exchanges = 0
            val selection = Iso7816Protocol.select(Iso7816Protocol.CONFIGURATION_AID) {
                exchanges++
                (payload + "9000").hexToBytes()
            }
            assertNull(payload, selection)
            assertEquals(payload, 1, exchanges)
        }
    }

    @Test fun failedMainSelectionIsNotReportedAsSuccess() {
        var calls = 0
        val selected = Iso7816Protocol.select(Iso7816Protocol.CONFIGURATION_AID) {
            if (++calls == 1) "4F07D41000001400019000".hexToBytes() else "6A82".hexToBytes()
        }
        assertNull(selected)
    }

    @Test fun directSelectionKeepsItsExistingApplicationIdentity() {
        val aid = "A000000632010105"
        val selected = Iso7816Protocol.select(aid) { "9000".hexToBytes() }
        assertEquals("China T-Union", selected?.application?.family)
        assertNull(selected?.configurationResponse)
        assertNull(Iso7816Protocol.select(aid) { "6A82".hexToBytes() })
    }
}
