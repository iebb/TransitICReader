package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexToBytes
import org.junit.Assert.*
import org.junit.Test

class Iso7816ProtocolTest {
    @Test fun koreanAndChineseBalancesUseTheirOwnReadOnlyCommands() {
        Iso7816Protocol.applications.filter { it.currency == "KRW" }.forEach {
            assertArrayEquals("904C000004".hexToBytes(), Iso7816Protocol.balanceCommand(it))
        }
        val chinese = Iso7816Protocol.applications.first { it.currency == "CNY" }
        assertArrayEquals("805C000204".hexToBytes(), Iso7816Protocol.balanceCommand(chinese))
        assertEquals(12345L, Iso7816Protocol.balanceValue("000030399000".hexToBytes()))
        assertEquals(0L, Iso7816Protocol.balanceValue("000000009000".hexToBytes()))
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
