package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class JapaneseGateHistoryTest {
    private fun resource(name: String) =
        Json.parseToJsonElement(javaClass.classLoader!!.getResourceAsStream(name)!!.bufferedReader().use { it.readText() }).jsonObject

    @Test fun nimocaHistoryKeepsGateEventsAndHidesThe10cbRecord() {
        val fixture = resource("nimoca-gate-history.json")
        val transit = fixture.getValue("transit").jsonArray.map { it.jsonPrimitive.content.hexToBytes() }
        val rows = fixture.getValue("rows").jsonArray.map { it.jsonObject }
        // The 10CB block (the last entry station, E915, then zeros) was "Transit Activity (15)".
        assertNull(JapaneseCardFormats.gateEvent(transit[3]))
        assertEquals(rows.size, transit.count { JapaneseCardFormats.gateEvent(it) != null })
        for ((block, row) in transit.zip(rows)) {
            assertEquals(row.getValue("event").jsonPrimitive.int, JapaneseCardFormats.gateEvent(block))
            assertEquals(row.getValue("date").jsonPrimitive.content, JapaneseCardFormats.packedDate(JapaneseCardFormats.uint(block, 6, 2).toInt()))
            assertEquals(row.getValue("amount").jsonPrimitive.long, JapaneseCardFormats.uint(block, 10, 2, little = true))
        }
        // The card's uninitialised 090F block has no date either.
        val uninitialised = fixture.getValue("transactions").jsonArray.last().jsonPrimitive.content.hexToBytes()
        assertNull(JapaneseCardFormats.packedDate(JapaneseCardFormats.uint(uninitialised, 4, 2).toInt()))
    }

    @Test fun knownEventsNeedARealDay() {
        assertNull(JapaneseCardFormats.gateEvent("A000E915000000000909000000000000".hexToBytes()))
        assertNull(JapaneseCardFormats.gateEvent("A000E915000033A00909000000000000".hexToBytes())) // 2025-13-00
        assertNull(JapaneseCardFormats.gateEvent("2000E91F0000325E0923040100000000".hexToBytes())) // 2025-02-30
        assertNull(JapaneseCardFormats.gateEvent("4000E91F000033890923040100000000".hexToBytes())) // undocumented event
        assertNull(JapaneseCardFormats.gateEvent(ByteArray(15)))
        assertEquals(0xA2, JapaneseCardFormats.gateEvent("A200E915000033890909000000000000".hexToBytes()))
    }

    @Test fun sampleWalletsHideOnlyTheirUndated10cbRecords() {
        val japanese = setOf("Suica", "Japan Transit IC", "Manaca", "Nimoca", "SUGOCA", "Hayakaken", "ICOCA")
        var shown = 0
        var hidden = 0
        for (card in resource("owner-wallet.json").getValue("cards").jsonArray.map { it.jsonObject }) {
            if (card["technology"]?.jsonPrimitive?.content != "FeliCa" || card.getValue("cardFamily").jsonPrimitive.content !in japanese) continue
            for (hex in card.getValue("rawTransitHistory").jsonArray.map { it.jsonPrimitive.content }) {
                val block = hex.hexToBytes()
                if (JapaneseCardFormats.gateEvent(block) != null) shown++
                else {
                    assertTrue("gate record hidden: $hex", block.drop(2).all { it == 0.toByte() })
                    hidden++
                }
            }
        }
        assertEquals(17, shown)
        assertEquals(6, hidden)
    }
}
