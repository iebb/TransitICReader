package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** Shares tests/runtime/fixtures/hanica-layouts.json with the Swift runtime test. */
class HanicaCardFormatTest {
    private val fixture = Json.parseToJsonElement(
        javaClass.classLoader!!.getResourceAsStream("hanica-layouts.json")!!.bufferedReader().readText()
    ).jsonObject

    @Test fun layoutsAreConfirmedOnlyBySelfConsistentLogs() {
        for (node in fixture.getValue("cases").jsonArray) {
            val row = node.jsonObject
            val name = row.getValue("name").jsonPrimitive.content
            val raw = row.getValue("blocks").jsonArray.map { it.jsonPrimitive.content }
            val blocks = raw.map { it.hexToBytes() }
            val expected = row.getValue("layout").jsonPrimitive.contentOrNull
            val layout = HanicaCardFormat.detectLayout(blocks)
            assertEquals(name, expected, layout?.name)
            assertEquals(name, row["balance"]?.jsonPrimitive?.int, HanicaCardFormat.confirmedBalance(blocks)?.second)
            blocks.forEachIndexed { index, block ->
                val value = HanicaCardFormat.value(index, blocks, layout)
                val tx = HanicaCardFormat.transaction(block, raw[index], blocks, index)!!
                assertEquals(name, raw[index], tx.rawData)
                assertEquals("JPY", tx.currencyCode)
                assertEquals("Asia/Tokyo", tx.issuerTimeZone)
                if (expected == null) {
                    assertNull(name, value)
                    assertFalse(name, tx.amountKnown)
                    assertNull(name, tx.balanceAfter)
                    assertEquals(name, 0L, tx.amount)
                } else {
                    val amount = row.getValue("amounts").jsonArray[index].jsonPrimitive.int
                    val balance = row.getValue("balances").jsonArray[index].jsonPrimitive.int
                    val topUp = row.getValue("topUps").jsonArray[index].jsonPrimitive.boolean
                    assertEquals("$name $index", HanicaCardFormat.Value(amount, balance, topUp), value)
                    assertTrue(tx.amountKnown)
                    assertEquals(amount.toLong(), tx.amount)
                    assertEquals(balance.toLong(), tx.balanceAfter)
                    assertEquals(if (topUp) TransactionCategory.topUp else TransactionCategory.bus, tx.category)
                    assertEquals(if (topUp) "Top-up" else "Bus", tx.type)
                }
            }
            // A record decoded without its neighbours never invents a balance.
            val lone = HanicaCardFormat.transaction(blocks[0], raw[0], emptyList(), 0)!!
            assertFalse(name, lone.amountKnown)
            assertNull(name, lone.balanceAfter)
        }
    }

    @Test fun datesStopsAndInvalidRecords() {
        val record = fixture.getValue("record").jsonObject
        val raw = record.getValue("raw").jsonPrimitive.content
        val decoded = HanicaCardFormat.decode(raw.hexToBytes())!!
        assertEquals(record.getValue("boarding").jsonPrimitive.content, decoded.boardingDate.toString())
        assertEquals(record.getValue("date").jsonPrimitive.content, decoded.date.toString())
        assertEquals(record.getValue("boardingStop").jsonPrimitive.content, decoded.boardingStop)
        assertEquals(record.getValue("alightingStop").jsonPrimitive.content, decoded.alightingStop)
        assertEquals(record.getValue("type").jsonPrimitive.int, decoded.typeCode)
        assertTrue(decoded.hasValidDates)
        val ride = HanicaCardFormat.transaction(raw.hexToBytes(), raw, listOf(raw.hexToBytes()), 0)!!
        assertEquals(decoded.date, ride.date)
        assertEquals(TransactionCategory.bus, ride.category)
        assertEquals("Bus stop 1201 → 1234", ride.location)
        assertEquals("Bus stop 1201", ride.entryStation)
        assertEquals("Bus stop 1234", ride.exitStation)
        val undated = fixture.getValue("undated").jsonPrimitive.content
        assertNull(HanicaCardFormat.decode(undated.hexToBytes())!!.date)
        assertNull(HanicaCardFormat.transaction(undated.hexToBytes(), undated, emptyList(), 0)!!.date)
        for (bad in listOf(ByteArray(16), ByteArray(15) { 1 }, ByteArray(17) { 1 })) {
            assertNull(HanicaCardFormat.decode(bad))
            assertFalse(HanicaCardFormat.isLogBlock(bad))
            assertNull(HanicaCardFormat.transaction(bad, "", listOf(bad), 0))
        }
        assertNull(HanicaCardFormat.detectLayout(emptyList()))
        assertNull(HanicaCardFormat.confirmedBalance(emptyList()))
    }
}
