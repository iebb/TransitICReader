package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.ResultField
import ad.neko.cardbal.android.data.TransitApplication
import ad.neko.cardbal.android.data.TransitCardSnapshot
import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

/** Independent review regressions using invented bytes, no card captures. */
class ReviewedCardFormatsTest {
    @Test fun koreanPurseDatesRequireActualCalendarDays() {
        val p = ByteArray(47)
        p[0] = 1; p[3] = 8; p[4] = 0x10; p[5] = 1
        byteArrayOf(0x20, 0x26, 0x02, 0x30).copyInto(p, 17)
        byteArrayOf(0x20, 0x26, 0x02, 0x28).copyInto(p, 21)
        val purse = KoreanCardFormat.purse(byteArrayOf(0xB0.toByte(), 47) + p)!!
        assertNull(purse.issueDate)
        assertEquals("2026-02-28", purse.expiryDate)
    }

    @Test fun unresolvedKoreanTransitFareIsNotAZeroCharge() {
        val record = ByteArray(52)
        record[2] = 1; record[5] = 1
        val reference = Instant.parse("2026-10-31T00:00:00Z")
        val unresolved = KoreanCardFormat.decode(record, "synthetic", "T-money", 0, reference)!!
        assertFalse(unresolved.amountKnown)
        assertEquals("010000000000", unresolved.exitStationCode)
        record[22] = 0x05; record[23] = 0xDC.toByte()
        val known = KoreanCardFormat.decode(record, "synthetic", "T-money", 0, reference)!!
        assertTrue(known.amountKnown)
        assertEquals(-1500L, known.amount)
    }

    @Test fun sharedUidDoesNotChooseCompanionMetadataAsPrimary() {
        val now = Instant.parse("2026-10-31T00:00:00Z")
        fun snapshot(aid: String, family: String, region: String) = TransitCardSnapshot(
            technology = "ISO7816", cardFamily = family, identifierLabel = "UID",
            identifierValue = "SYNTHETIC", rawIdentifierValue = "01020304", selectedAID = aid,
            region = region, realSerialNumber = family, balanceText = "CNY1.00",
            resultFields = listOf(ResultField("Brand", family)), scannedAt = now,
        )
        val cityUnion = snapshot("A00000000386980701", "City Union", "CU region")
        val tUnion = snapshot("A000000632010105", "China T-Union", "TU region")
        val combined = TransitApplication.combine(listOf(cityUnion, tUnion))!!
        assertEquals("A000000632010105", combined.selectedAID)
        assertEquals("China T-Union", combined.cardFamily)
        assertEquals("TU region", combined.region)
        assertEquals("China T-Union", combined.resultFields.single { it.title == "Brand" }.value)
        assertEquals(2, combined.applications!!.size)
    }
}
