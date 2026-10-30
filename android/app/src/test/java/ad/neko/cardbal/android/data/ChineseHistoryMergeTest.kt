package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

class ChineseHistoryMergeTest {
    private fun purchase(counter:Int=1,app:String?="TU")=TransitTransaction(
        date=Instant.parse("2026-10-31T00:00:00Z"),amount=295,type="Payment",category=TransactionCategory.purchase,
        terminalID="413180000001",rawData=ByteArray(23).also{it[0]=counter.toByte();it[9]=6}.hexString(),
        currencyCode="CNY",fractionDigits=2,sourceApplicationID=app)
    @Test fun impossibleChineseDatesRemainUnknownWithoutAbortingHistory() {
        assertNull(ChineseHistoryMerge.timestamp("20260230201530".hexToBytes(),0,4,"Asia/Shanghai"))
        assertNull(ChineseHistoryMerge.timestamp("20261A31201530".hexToBytes(),0,4,"Asia/Shanghai"))
        assertEquals("2026-10-31T12:15:30Z",ChineseHistoryMerge.timestamp("20261031201530".hexToBytes(),0,4,"Asia/Shanghai").toString())
    }
    @Test fun oneSameApplicationTripEnrichesPaymentWithoutDuplicatingIt() {
        val payment=purchase()
        val trip=payment.copy(rawData=ByteArray(48){1}.hexString(),terminalID="0912000000000001",type="Exit",category=TransactionCategory.trainOff,
            exitStation="Verified station",exitStationCode="602000020201",balanceAfter=12345)
        val result=ChineseHistoryMerge.reconcile(listOf(payment,trip))
        assertEquals(1,result.size);assertEquals(payment.rawData,result.single().rawData)
        assertEquals("Verified station",result.single().exitStation);assertEquals(12345L,result.single().balanceAfter)
        assertEquals(295L,result.single().amount)
    }
    @Test fun ambiguousEqualTimeAndFareDoesNotInventAJoin() {
        val first=purchase();val second=purchase(2)
        val trip=first.copy(rawData=ByteArray(48){1}.hexString(),exitStation="Should not be inferred")
        val result=ChineseHistoryMerge.reconcile(listOf(first,second,trip))
        assertEquals(3,result.size)
        assertNull(result.first{it.rawData==first.rawData}.exitStation)
    }
    @Test fun zeroTerminalCannotBridgeSeparateApplications() {
        val p=purchase(app="CU").copy(terminalID="000000000000")
        val t=p.copy(sourceApplicationID="TU",rawData=ByteArray(48){1}.hexString(),terminalID="0000000000000000",exitStation="Unverified")
        assertEquals(2,ChineseHistoryMerge.reconcile(listOf(p,t)).size)
    }
    @Test fun mirroredApplicationsPreferVerifiedPlaceAndPreserveSameSourceMultiplicity() {
        val cu=purchase(app="CU")
        val tu=purchase(2,"TU").copy(location="Verified station",exitStation="Verified station")
        val result=ChineseHistoryMerge.reconcile(listOf(cu,tu))
        assertEquals(1,result.size);assertEquals("Verified station",result.single().location)
        assertEquals(2,ChineseHistoryMerge.reconcile(listOf(cu,cu.copy(rawData=purchase(2).rawData))).size)
    }
}
