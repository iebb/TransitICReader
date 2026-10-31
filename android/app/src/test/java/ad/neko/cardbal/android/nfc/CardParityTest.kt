package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.*
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import kotlinx.serialization.json.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import org.junit.Assert.*
import org.junit.Test
import java.util.Locale

class CardParityTest {
    @Test fun sharedEdyNanacoRyutoVectorsRetainDatesFaresAndBalances() {
        val text=javaClass.classLoader!!.getResourceAsStream("card-parity.json")!!.bufferedReader().readText()
        val fixture=Json.parseToJsonElement(text).jsonObject
        for((family,node) in fixture) {
            val row=node.jsonObject;val raw=row.getValue("raw").jsonPrimitive.content
            val tx=when(family) {"edy"->JapaneseCardFormats.edy(raw.hexToBytes(),raw);"nanaco"->JapaneseCardFormats.nanaco(raw.hexToBytes(),raw);else->JapaneseCardFormats.ryuto(raw.hexToBytes(),raw)}!!
            assertEquals(family,row.getValue("date").jsonPrimitive.content,tx.date.toString())
            assertEquals(row.getValue("amount").jsonPrimitive.long,tx.amount)
            assertEquals(row.getValue("balance").jsonPrimitive.long,tx.balanceAfter)
            assertEquals("JPY",tx.currencyCode)
            assertEquals("Asia/Tokyo",tx.issuerTimeZone)
        }
    }
    @Test fun invalidDatesAndShortRecordsDoNotCrashOrBecomeRailTrips() {
        assertNull(JapaneseCardFormats.edy(ByteArray(15),""))
        assertNull(JapaneseCardFormats.edy(ByteArray(16).also{it[5]=1;it[6]=0xff.toByte();it[7]=0xff.toByte()},""))
        assertNull(JapaneseCardFormats.ryuto("355F21E245001200345202D0000004D2".hexToBytes().also{it[0]=0x34;it[1]=0x5f},""))
        assertNull(JapaneseCardFormats.ryuto(ByteArray(16),""))
        assertNull(JapaneseCardFormats.date(2026,2,30))
    }
    @Test fun koreanCompactHistoryHasUnsignedCounterAndSignedFare() {
        val block="0100000004D2FFFFFFFF00000127".hexToBytes()
        val tx=KoreanCardFormat.decode(block,"synthetic","NAMANE",0,Instant.parse("2026-10-31T00:00:00Z"))!!
        assertEquals(-295L,tx.amount);assertEquals(1234L,tx.balanceAfter)
        assertEquals(4294967295L,tx.recordCounter);assertNull(tx.recordNumber)
        assertEquals("-₩295",formatTransactionAmount(tx,Locale.KOREA))
        assertNull(tx.date)
    }
    @Test fun koreanBcdTakesPriorityAndInvalidFebruaryStaysUnknown() {
        val row=ByteArray(52);row[9]=0;row[10]=201.toByte();"20261031201530".hexToBytes().copyInto(row,11)
        assertEquals("2026-10-31T11:15:30Z",KoreanCardFormat.transitTimestamp(row,"Asia/Seoul",Instant.parse("2026-11-01T00:00:00Z")).toString())
        row[9]=2;row[10]=0x6d // Mybi-total code621 must not fall back to a speculative packed clock.
        "20260230201530".hexToBytes().copyInto(row,11)
        assertNull(KoreanCardFormat.transitTimestamp(row,"Asia/Seoul",Instant.parse("2026-11-01T00:00:00Z")))
    }
    @Test fun knownMybiClockSelectsBoardingVersusAlighting() {
        val row=ByteArray(52);row[9]=3;row[10]=0x66 // Busan Subway870
        fun clock(offset:Int,hour:Int) { val v=(10 shl 20) or (10 shl 16) or (31 shl 11) or (hour shl 6) or 15;for(i in 0..2) row[offset+i]=(v ushr (16-8*i)).toByte() }
        clock(11,8);clock(14,9)
        val reference=Instant.parse("2026-11-01T00:00:00Z")
        assertEquals("2026-10-30T23:15:00Z",KoreanCardFormat.transitTimestamp(row,"Asia/Seoul",reference).toString())
        row[2]=1
        assertEquals("2026-10-31T00:15:00Z",KoreanCardFormat.transitTimestamp(row,"Asia/Seoul",reference).toString())
    }
    @Test fun purseIdentificationDoesNotConfuseMongolianAndKoreanCards() {
        val purse=ByteArray(47);fillPurse(purse)
        val p=KoreanCardFormat.purse(byteArrayOf(0xb0.toByte(),47)+purse)!!
        assertTrue(p.isUMoney);assertEquals("1600 1234 5678 9012",p.serial)
        assertNull(KoreanCardFormat.purse(byteArrayOf(0xb0.toByte(),48)+purse))
    }
    private fun fillPurse(p:ByteArray) { p[3]=1;"1600123456789012".hexToBytes().copyInto(p,4) }
    @Test fun recordsRetainOriginalNumbersAndDoNotPairAcrossMissingSlots() {
        val result=IsoRecordReader.records(14,4,14,"transaction") { command ->
            when(command[2].toInt()){1->ByteArray(14){1}+byteArrayOf(0x90.toByte(),0);2->byteArrayOf(1,0x90.toByte(),0);3->ByteArray(14){3}+byteArrayOf(0x90.toByte(),0);else->byteArrayOf(0x6a,0x83.toByte())}
        }
        assertEquals(listOf(1,3),result.map{it.index})
    }
    @Test fun geohashDecoderMatchesSharedFixtureAndDijkstraUsesDistance() {
        val fixture=Json.parseToJsonElement(javaClass.classLoader!!.getResourceAsStream("geohash_paths.json")!!.bufferedReader().readText()).jsonObject
        val points=TransitGeometry.decodePath(fixture.getValue("encoded").jsonPrimitive.content)!!
        val wanted=fixture.getValue("decoded").jsonArray
        assertEquals(wanted.size,points.size)
        points.zip(wanted).forEach{(p,v)->assertEquals(v.jsonArray[0].jsonPrimitive.double,p.longitude,1e-10);assertEquals(v.jsonArray[1].jsonPrimitive.double,p.latitude,1e-10)}
        for(bad in listOf("","0","9","91abc","90!!!!!!!!!","90xn76urx66x")) assertNull(TransitGeometry.decodePath(bad))
        val graph=mapOf("a" to listOf(TransitGeometry.Edge("b",10.0,null),TransitGeometry.Edge("c",1.0,null)),"c" to listOf(TransitGeometry.Edge("b",1.0,null)))
        assertEquals(listOf("c","b"),TransitGeometry.shortest("a","b",graph)!!.map{it.second.to})
    }
    @Test fun malformedHexIsSafe() {
        assertTrue("not hex".hexToBytes().isEmpty())
        assertTrue("1".hexToBytes().isEmpty())
    }
    @Test fun portableApplicationsKeepSourceFilesAndMergeMissingBalance() {
        val now=Instant.parse("2026-10-31T00:00:00Z")
        val old=TransitApplication("ISO7816","City Union","uid",selectedAID="A00000000386980701",balanceText="¥12.34",balanceReadAt=now,records=listOf(TransitApplicationRecord("auxiliary",17,2,"0102")),scannedAt=now)
        val json=Json.encodeToString(old)
        val imported=Json.decodeFromString<TransitApplication>(json)
        assertEquals(old,imported)
        val merged=TransitApplication.merge(listOf(old),listOf(old.copy(balanceText=null,scannedAt=Instant.parse("2026-11-01T00:00:00Z"))))
        assertEquals("¥12.34",merged.single().balanceText)
        assertEquals(17,merged.single().records.single().sfi)
    }
}
