package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.StoredValueProtocol
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class AdditionalHistoryIntegrationTest {
    @Test fun movingDesfireSlotsDoNotDuplicateVisibleHistoryOrInventFares() {
        val bytes="785634F2479A60F0FF439CB0A4030000".hexToBytes()
        val first=StoredValueProtocol.envelope(1,1,0,bytes)
        val moved=StoredValueProtocol.envelope(1,1,7,bytes)
        val merged=mergeCardHistory("Opal",listOf(first),listOf(moved))
        assertEquals(listOf(moved),merged)
        val tx=AdditionalCardHistory.decode(merged.single(),"Opal",merged)!!
        assertEquals("AUD",tx.currencyCode);assertEquals(2,tx.fractionDigits)
        assertFalse(tx.amountKnown);assertEquals(-125L,tx.balanceAfter)
        assertEquals("Australia/Sydney",tx.issuerTimeZone)
        assertNull(AdditionalCardHistory.decode(merged.single(),"HSL",merged))
    }
    @Test fun modelAdapterUsesBatchReconciliationForAllSharedLayouts() {
        val root=Json.parseToJsonElement(javaClass.classLoader!!.getResourceAsStream("desfire_vectors.json")!!.bufferedReader().readText()).jsonObject
        for(node in root.getValue("vectors").jsonArray) {
            val row=node.jsonObject;val tag=row.getValue("tag").jsonPrimitive.int
            val files=row.getValue("files").jsonObject.mapKeys{it.key.toInt()}.mapValues{it.value.jsonPrimitive.content.hexToBytes()}
            val sizes=row.getValue("recordSizes").jsonObject.mapKeys{it.key.toInt()}.mapValues{it.value.jsonPrimitive.int}
            val card=StoredValueProtocol.parseFiles(tag,files,sizes)!!
            val expected=StoredValueProtocol.parseHistories(card.rawTransactions,card.family)
            val actual=card.rawTransactions.mapNotNull{AdditionalCardHistory.decode(it,card.family,card.rawTransactions)}
            assertEquals(card.family,expected.size,actual.size)
            assertEquals(expected.map{it.amountMinor!=null},actual.map{it.amountKnown})
            assertTrue(actual.all{it.currencyCode==card.currencyCode})
        }
    }
}
