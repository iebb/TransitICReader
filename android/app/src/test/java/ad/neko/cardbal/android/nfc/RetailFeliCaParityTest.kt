package ad.neko.cardbal.android.nfc

import ad.neko.cardbal.android.data.TransactionCategory
import ad.neko.cardbal.android.util.hexToBytes
import org.junit.Assert.*
import org.junit.Test

/** nanaco and WAON layouts from TRETJapanNFCReader 03470a5, using invented bytes, no card captures. */
class RetailFeliCaParityTest {
    @Test fun nanacoPointsSumBothBigEndianBucketsAndIgnoreTheGap() {
        // Bucket 1 = 0x0004D2 (1234), bytes 3-4 are not points, bucket 2 = 0x000064 (100).
        assertEquals(1334L, JapaneseCardFormats.nanacoPoints("0004D2FFFF000064000000000000FFFF".hexToBytes()))
        assertEquals(0x010203L + 0x040506L, JapaneseCardFormats.nanacoPoints("0102030000040506AAAAAAAAAAAAAAAA".hexToBytes()))
        assertNull(JapaneseCardFormats.nanacoPoints(ByteArray(15)))
        assertNull(JapaneseCardFormats.nanacoPoints(null))
    }

    @Test fun waonPointsAreBigEndian24Bit() {
        assertEquals(1234L, JapaneseCardFormats.waonPoints("0004D2FF000000000000000000000000".hexToBytes()))
        assertEquals(0x123456L, JapaneseCardFormats.waonPoints("123456".hexToBytes()))
        assertNull(JapaneseCardFormats.waonPoints(ByteArray(2)))
        assertNull(JapaneseCardFormats.waonPoints(null))
    }

    @Test fun nanacoTypeFiveCIsATopUp() {
        val clock = (26 shl 21) or (10 shl 17) or (31 shl 12) or (12 shl 6) or 34
        fun record(type: Int) = ByteArray(16).also { r ->
            r[0] = type.toByte()
            "000003E8".hexToBytes().copyInto(r, 1)
            "000007D0".hexToBytes().copyInto(r, 5)
            for (i in 0..3) r[9 + i] = (clock ushr (24 - 8 * i)).toByte()
            r[14] = 42
        }
        val tx = JapaneseCardFormats.nanaco(record(0x5C), "raw")!!
        assertEquals("Top-up", tx.type)
        assertEquals(TransactionCategory.topUp, tx.category)
        assertEquals(1000L, tx.amount)
        assertEquals(2000L, tx.balanceAfter)
        assertEquals(42, tx.recordNumber)
        assertEquals("2026-10-31T03:34:00Z", tx.date.toString())
        for (type in listOf(0x6F, 0x70)) assertEquals(TransactionCategory.topUp, JapaneseCardFormats.nanaco(record(type), "raw")!!.category)
        assertEquals(TransactionCategory.unknown, JapaneseCardFormats.nanaco(record(0x5D), "raw")!!.category)
    }

    @Test fun waonNamedOperationsStayUnknownAndKeepTheLargerAmount() {
        val labels = mapOf(
            0x08 to "Return", 0x18 to "Point Download", 0x28 to "Refund",
            0x1C to "Auto Charge", 0x20 to "Auto Charge", 0x30 to "Auto Charge",
            0x3C to "Move to New Card", 0x7C to "Point Exchange",
        )
        for ((type, label) in labels) {
            assertEquals(Triple(label, TransactionCategory.unknown, 500L), JapaneseCardFormats.waonType(type, 120, 500))
            assertEquals(Triple(label, TransactionCategory.unknown, 700L), JapaneseCardFormats.waonType(type, 700, 300))
            assertEquals(label, JapaneseCardFormats.waonTypeName(type))
        }
        assertEquals(Triple("Transaction 0x44", TransactionCategory.unknown, 500L), JapaneseCardFormats.waonType(0x44, 120, 500))
    }

    @Test fun waonPaymentAndTopUpKeepTheirDirectionalAmountFields() {
        assertEquals(Triple("Payment", TransactionCategory.payment, 120L), JapaneseCardFormats.waonType(0x04, 120, 500))
        for (type in listOf(0x0C, 0x10)) {
            assertEquals(Triple("Top-up", TransactionCategory.topUp, 300L), JapaneseCardFormats.waonType(type, 700, 300))
        }
    }
}
