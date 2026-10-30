package ad.neko.cardbal.android.data

import ad.neko.cardbal.android.nfc.SnapperPlusProtocol
import ad.neko.cardbal.android.util.hexString
import ad.neko.cardbal.android.util.hexToBytes
import java.util.Locale
import kotlinx.datetime.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Test

class AdditionalCardHistoryTest {
    private fun transaction(cost: Int = 275, counter: Long = 0xFFFFFFFFL): ByteArray = ByteArray(46).also { data ->
        data[0] = 1; data[1] = 0x2C
        fun be(offset: Int, value: Long) { for (i in 0..3) data[offset + i] = (value ushr (24 - i * 8)).toByte() }
        be(2, 12345); be(6, counter); be(10, cost.toLong())
        for (i in 26..45) data[i] = 0xFF.toByte()
    }

    private fun trip(): ByteArray = ByteArray(52).also {
        it[0] = 1; it[1] = 0x32; it[51] = 0x10
        "20260115083000".hexToBytes().copyInto(it, 13)
    }

    @Test fun persistedBackupDecodesExactCentsCounterAndIssuerTime() {
        val raw = SnapperPlusProtocol.encodeHistory(transaction(), trip(), 1)!!.hexString()
        val card = SavedCardRecord.from(TransitCardSnapshot(
            technology = "ISO7816", cardFamily = "Snapper+", identifierLabel = "UID",
            identifierValue = "synthetic", rawIdentifierValue = "synthetic", rawTransactions = listOf(raw),
            scannedAt = Instant.parse("2026-01-15T00:00:00Z"),
        ))
        val restored = Json.decodeFromString<SavedCardRecord>(Json.encodeToString(card))
        val decoded = decodeSnapperHistory(restored.rawTransactions.single().hexToBytes(), raw)!!
        assertEquals(-275L, decoded.amount)
        assertEquals("NZD", decoded.currencyCode)
        assertEquals(2, decoded.fractionDigits)
        assertEquals("-NZ$2.75", formatTransactionAmount(decoded, Locale.US))
        assertEquals("NZ$123.45", formatCardMoney(decoded.balanceAfter!!, decoded.currencyCode, 2, Locale.US))
        assertEquals("2026-01-14T19:30:00Z", decoded.date.toString())
        assertEquals("Pacific/Auckland", decoded.issuerTimeZone)
        assertEquals(4294967295L, decoded.recordCounter)
        assertNull(decoded.recordNumber)
        assertNull(decoded.entryStationCode)
        assertNull(decoded.exitStationCode)
    }

    @Test fun signedReversalDisplaysCreditWithoutClaimingRefund() {
        val raw = SnapperPlusProtocol.encodeHistory(transaction(cost = -275), null, 1)!!.hexString()
        val decoded = decodeSnapperHistory(raw.hexToBytes(), raw)!!
        assertEquals(275L, decoded.amount)
        assertEquals("+NZ$2.75", formatTransactionAmount(decoded, Locale.US))
        assertEquals(TransactionCategory.payment, decoded.category)
        assertNull(decoded.date)
    }

    @Test fun rescanRingMovementEnrichesExistingRecordAfterReload() {
        val old = SnapperPlusProtocol.encodeHistory(transaction(), null, 1)!!.hexString()
        val moved = SnapperPlusProtocol.encodeHistory(transaction(), trip(), 3)!!.hexString()
        val merged = mergeCardHistory("Snapper+", listOf(old), listOf(moved))
        assertEquals(listOf(moved), merged)
        assertNotNull(decodeSnapperHistory(merged.single().hexToBytes(), merged.single())!!.date)
        assertEquals(listOf(moved), mergeCardHistory("Snapper+", merged, listOf(old)))
    }

    @Test fun idrUsesWholeUnitsAndExistingDefaultsRemainWholeYen() {
        assertEquals("Rp4,294,967,295", formatCardMoney(4294967295L, "IDR", 0, Locale.US))
        assertEquals("¥1,250", formatCardMoney(1250, null, 0, Locale.US))
    }

    @Test fun snapperStablePurseIdentityMatchesIosAndRejectsEmptySerials() {
        val snapshot = TransitCardSnapshot(
            technology = "ISO7816", cardFamily = "Snapper+", identifierLabel = "UID",
            identifierValue = "synthetic", rawIdentifierValue = "01020304", realSerialNumber = "0102 0304 A5B6 C7D8",
        )
        assertEquals("ISO7816|0102 0304 A5B6 C7D8", snapshot.storageIdentifier)
        assertEquals("ISO7816|01020304", snapshot.copy(realSerialNumber = "0000 0000 0000 0000").storageIdentifier)
        assertEquals("ISO7816|01020304", snapshot.copy(realSerialNumber = "FFFF FFFF FFFF FFFF").storageIdentifier)
        assertEquals("ISO7816|01020304", snapshot.copy(cardFamily = "T-money").storageIdentifier)
        assertEquals("FeliCa|01020304", snapshot.copy(cardFamily = "KMT", technology = "FeliCa").storageIdentifier)
    }

    @Test fun supportedSnapperRescanFindsOnlyItsLegacyUidEntry() {
        val oldSnapshot = TransitCardSnapshot(
            technology = "ISO7816", cardFamily = "T-money", identifierLabel = "UID", identifierValue = "old",
            rawIdentifierValue = "01020304", selectedAID = SnapperPlusProtocol.APPLICATION_AID,
        )
        val oldCard = SavedCardRecord.from(oldSnapshot).copy(customTitle = "My card")
        val identified = oldSnapshot.copy(cardFamily = "Snapper+", realSerialNumber = "01020304A5B6C7D8")
        assertEquals(0, cardIndexForSnapshot(listOf(oldCard), identified))
        assertEquals(-1, cardIndexForSnapshot(listOf(oldCard.copy(rawIdentifierValue = "05060708")), identified))
        assertEquals(-1, cardIndexForSnapshot(listOf(oldCard.copy(cardFamily = "NAMANE")), identified))
        assertEquals(-1, cardIndexForSnapshot(listOf(oldCard, oldCard.copy(id = "ambiguous")), identified))
        val canonical = SavedCardRecord.from(identified)
        assertEquals(1, cardIndexForSnapshot(listOf(oldCard, canonical), identified))
    }
}
