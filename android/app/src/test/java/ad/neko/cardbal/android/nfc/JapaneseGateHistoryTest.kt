package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.BusResolver
import ad.neko.cardbal.android.data.SavedCardColor
import ad.neko.cardbal.android.data.SavedCardRecord
import ad.neko.cardbal.android.data.TransactionDecoder
import ad.neko.cardbal.android.util.hexToBytes
import java.time.ZoneId
import kotlinx.datetime.Instant
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

    @Test fun mainHistoryPurchaseBusAndTopUpRowsStillShow() {
        val uses = resource("japanese-main-history.json")
        val blocks = uses.getValue("blocks").jsonArray.map { it.jsonPrimitive.content }
        val rows = uses.getValue("rows").jsonArray.map { it.jsonObject }
        val decoder = decoderWithoutStations()
        for (family in uses.getValue("families").jsonArray.map { it.jsonPrimitive.content }) {
            val card = SavedCardRecord(
                id = "test:090f", cardFamily = family, technology = "FeliCa", identifierLabel = "IDm",
                identifierValue = "0000000000000000", rawIdentifierValue = "0000000000000000",
                rawTransactions = blocks, scannedAt = Instant.parse("2025-12-09T12:00:00Z"), color = SavedCardColor.Black,
            )
            val shown = decoder.transactionsFor(card)
            assertEquals("$family rows", blocks.size, shown.size)
            for ((tx, row) in shown.zip(rows)) {
                val label = "$family $row"
                assertEquals(label, row.getValue("process").jsonPrimitive.int, tx.rawData!!.hexToBytes()[1].toInt() and 255)
                assertEquals(label, row.getValue("label").jsonPrimitive.content, tx.type)
                assertEquals(label, row.getValue("category").jsonPrimitive.content, tx.category.name)
                assertEquals(label, row.getValue("amount").jsonPrimitive.long, tx.amount)
                assertEquals(label, row.getValue("balance").jsonPrimitive.long, tx.balanceAfter)
                val day = java.time.Instant.ofEpochMilli(tx.date!!.toEpochMilliseconds()).atZone(ZoneId.of("Asia/Tokyo")).toLocalDate()
                assertEquals(label, row.getValue("date").jsonPrimitive.content, day.toString())
            }
        }
    }

    /**
     * The production decoder without an Android Context, which these JVM tests cannot create. The rows used
     * here never look up a station; bus operators resolve against an empty table.
     */
    private fun decoderWithoutStations(): TransactionDecoder {
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val unsafe = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }.get(null)
        fun <T> allocate(type: Class<T>): T = type.cast(unsafeClass.getMethod("allocateInstance", Class::class.java).invoke(unsafe, type))
        val buses = allocate(BusResolver::class.java)
        BusResolver::class.java.getDeclaredField("buses").apply { isAccessible = true }.set(buses, emptyMap<Int, String>())
        return allocate(TransactionDecoder::class.java).also {
            TransactionDecoder::class.java.getDeclaredField("busResolver").apply { isAccessible = true }.set(it, buses)
        }
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
