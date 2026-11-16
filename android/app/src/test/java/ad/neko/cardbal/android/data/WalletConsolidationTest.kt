package ad.neko.cardbal.android.data

import kotlinx.datetime.Instant
import org.junit.Assert.*
import org.junit.Test

/** One physical Macau Pass – T-Union card stays one wallet entry, as on iPhone. */
class WalletConsolidationTest {
    private val uid = "04A1B2C3"
    private fun read(aid: String, family: String, serial: String?, balance: String?, at: Long, record: String) = TransitCardSnapshot(
        technology = "ISO7816", cardFamily = family, identifierLabel = "UID", identifierValue = uid, rawIdentifierValue = uid,
        selectedAID = aid, balanceText = balance, realSerialNumber = serial, region = family,
        resultFields = listOf(ResultField("Brand", family)), rawTransactions = listOf(record), scannedAt = Instant.fromEpochSeconds(at),
    ).let { it.copy(applications = listOf(TransitApplication.from(it))) }
    private fun tUnion(at: Long, serial: String? = "3100000000000000001", balance: String? = "CNY 10.00") =
        read("A000000632010105", "China T-Union", serial, balance, at, "01".repeat(23))
    private fun macau(at: Long) = read("B0C4C3C5CDA8C7AEB0FC", "Macau Pass", "12ABCDEF", "MOP 50.00", at, "02".repeat(23))

    @Test fun savedTUnionSideJoinsTheCombinedMacauRead() {
        val saved = SavedCardRecord.from(tUnion(100)).copy(customTitle = "Travel card", order = 3, isPinned = true)
        val combined = TransitApplication.combine(listOf(macau(200), tUnion(200)))!!
        assertEquals(0, cardIndexForSnapshot(listOf(saved), combined))
        val wallet = upsertingSnapshot(listOf(saved), combined)
        val card = wallet.single()
        assertEquals(combined.storageIdentifier, card.id)
        assertEquals("Macau Pass", card.cardFamily)
        assertEquals("MOP 50.00", card.balanceText)
        assertEquals(2, card.applications!!.size)
        assertEquals(listOf("Travel card", 3, true), listOf(card.customTitle, card.order, card.isPinned))

        // Reading only the T-Union side later keeps one Macau Pass card with both histories.
        val rescanned = upsertingSnapshot(wallet, tUnion(300, balance = "CNY 8.00")).single()
        assertEquals("Macau Pass", rescanned.cardFamily)
        assertEquals(card.id, rescanned.id)
        assertEquals("B0C4C3C5CDA8C7AEB0FC", rescanned.selectedAID)
        assertEquals("MOP 50.00", rescanned.balanceText)
        assertTrue(rescanned.resultFields.any { it.title == "Brand" && it.value == "Macau Pass" })
        assertEquals("CNY 8.00", rescanned.applications!!.first { it.isTUnion }.balanceText)
        assertEquals(2, rescanned.rawTransactions.size)
        // A T-Union read without its serial still matches by UID.
        assertEquals(1, upsertingSnapshot(wallet, tUnion(400, serial = null)).size)
    }

    @Test fun earlierDuplicateEntriesBecomeOne() {
        val saved = SavedCardRecord.from(tUnion(100)).copy(customTitle = "Travel card")
        val duplicate = SavedCardRecord.from(TransitApplication.combine(listOf(macau(200), tUnion(200)))!!)
        val other = SavedCardRecord.from(read("A000000632010105", "China T-Union", "3100000000000000099", "CNY 1.00", 50, "03".repeat(23))
            .copy(identifierValue = "0A0B0C0D", rawIdentifierValue = "0A0B0C0D").let { it.copy(applications = listOf(TransitApplication.from(it))) })
        val wallet = consolidateMatchingCards(listOf(saved, other, duplicate))
        assertEquals(2, wallet.size)
        val card = wallet.first { it.id == saved.id }
        assertEquals("Travel card", card.customTitle)
        assertEquals("Macau Pass", card.cardFamily)
        assertEquals(2, card.applications!!.size)
        assertTrue(duplicate.id in card.identityAliases)
        assertEquals(other, wallet.first { it.id == other.id })
    }
}
